"""Serial job queue: one generation at a time, workers per family, warm-worker reuse.

Runs on its own thread (adapters and workers are blocking); all events go through
bus.emit_threadsafe.

Two kinds of worker slot, because "resident" is worth very different amounts
depending on the model. The *resident* slot holds the last big model and keeps
it until another big model displaces it. The *warm pool* runs small models —
the analyzers, separators, transcribers, mixers and renderers that run as a
step attached to other work. Evicting a multi-GB generator to make room for an
81 MB analyzer costs minutes on the next generation, so small models never
touch the resident slot. See `_is_small`.

The pool keeps a couple of those small workers alive for a while after their
last job rather than killing them immediately: their adapters cache loaded
checkpoints across jobs on purpose, and the app's own cadence keeps coming back
to them — an analyze job follows every ingest, and each workbench mix produces
a new song that is then analyzed, so `dsp` and `analysis` alternate all
afternoon. See `SMALL_WARM_SLOTS` / `SMALL_WARM_TTL_S`.
"""

from __future__ import annotations

import json
import os
import random
import threading
import time
import uuid

from . import envs
from .config import Settings
from .events import EventBus
from .registry import Registry
from .telemetry import physical_ram_bytes
from .worker import Worker, WorkerDied

CANCEL_GRACE_S = 10.0

TERMINAL_STATUSES = ("succeeded", "failed", "canceled")

# Terminal jobs are kept as history for the app's queue rail, but the dict
# grew without bound over a long engine run. Oldest terminal rows are evicted
# past this many total jobs; live jobs are never counted out. 0 = unbounded.
JOB_HISTORY_CAP = int(os.environ.get("LOCALMUSICGEN_JOB_HISTORY_CAP") or 200)

# Floor on the gap between two job.progress events of the same stage. Each one
# is an SSE frame, a decode and a main-thread store mutation in the app, so the
# rate the adapters happen to report at is the rate the UI has to keep up with.
# Every adapter throttles itself by convention today (~1-5 Hz); this is the
# backstop for the one that wires a per-token callback straight through and
# floods the pipe. Anything that changes what is on screen — a new stage, phase
# or take, or a finished one — is exempt, so it can only ever drop a frame that
# the next one supersedes.
PROGRESS_MIN_INTERVAL_S = 0.1

# How often the cancel watchdog re-checks the deadline it is waiting on. It
# sleeps on an event the whole time, so this is only the resolution of "the
# grace period has expired", not a poll of anything expensive.
CANCEL_POLL_S = 0.5

# "generate" is the classic prompt→audio pipeline; the rest are promptless
# task jobs returning typed artifacts. A model opts in via capabilities.tasks
# (absent ⇒ ["generate"]).
# "assist" and "plan" are the two that produce no audio at all: "assist" is the
# writing assistant drafting text, "plan" is a generative model running only the
# language-model half of its pipeline so the user can choose a plan before
# paying for the render. Both still return artifacts, so nothing else in the
# task machinery changes.
# The four music-to-text tasks are audio in (or, for "compose", notation in),
# text out: "caption" is prose about the audio (a `question` param turns it
# into QA), "lyrics" is the sung words with timed segments, "tag" is
# genre/mood/instrument labels, and "compose" writes ABC notation from a text
# prompt — the one task whose primary input is a declared string param
# (`params.prompt`), which submit validation does not presence-check, so its
# adapter fails the job on an empty prompt itself.
# The audio-transformation quartet is audio in, audio out, returned as `stem`
# artifacts so the split ingest path files them as parts: "timbre" re-voices
# a track through a neural timbre model (RAVE — the model IS the effect),
# "reamp" runs it through a captured amp/pedal rig (NAM), "convert-voice"
# re-sings a vocal in the timbre of a user-supplied reference recording, and
# "sing" performs typed lyrics to a melody in a reference voice.
TASKS = ("generate", "separate", "transcribe", "analyze", "render", "mix",
         "assist", "plan", "caption", "lyrics", "tag", "compose",
         "timbre", "reamp", "convert-voice", "sing")

# Models at or below this run in the transient slot: never evicting the
# resident model, never kept resident themselves. The catalog leaves a clean
# empty gap here — every auxiliary (non-generate) model is ≤0.91 GB and the
# smallest generation model is 1.64 GB — so this splits exactly along "does
# this model run as a step attached to other work".
SMALL_MODEL_BYTES = int(os.environ.get("LOCALMUSICGEN_SMALL_MODEL_BYTES")
                        or 1_500_000_000)

# How many small workers may stay warm at once, and for how long after their
# last job. Two covers the alternations the app actually produces (dsp↔analysis
# on every workbench mix, separation↔analysis on every split); ten minutes
# outlives think-time plus a full generation, so the analyzer that runs after
# the next track is still warm. Either at 0 restores immediate reaping.
SMALL_WARM_SLOTS = int(os.environ.get("LOCALMUSICGEN_SMALL_WARM_SLOTS") or 2)
SMALL_WARM_TTL_S = float(os.environ.get("LOCALMUSICGEN_SMALL_WARM_TTL_S") or 600)


def _is_small(model: dict) -> bool:
    """Whether this model runs in the transient slot.

    Auxiliary models may legitimately report `size_bytes: 0` — pure DSP
    (dsp-mixdown) or weights bundled with their package (basicpitch, swiftf0,
    transkun). For a *generation* model, 0 means the size lookup failed
    (user-added models size themselves from a live HF call), and co-loading
    something of unknown size is exactly what this policy must not do.
    """
    if SMALL_MODEL_BYTES <= 0:
        return False  # policy disabled: one slot, as before
    tasks = model["capabilities"].get("tasks") or ["generate"]
    size = model.get("size_bytes") or 0
    if "generate" not in tasks:
        return size <= SMALL_MODEL_BYTES
    return 0 < size <= SMALL_MODEL_BYTES


def _job_row(job: "Job", queue_position: int | None) -> dict:
    """One job as the API returns it (contract 5.2). Position is passed in
    because working it out needs the queue lock and the whole run order, which
    a listing resolves for every row at once — see JobQueue.info_many."""
    return {"job_id": job.id, "group_id": job.group_id,
            "model_id": job.model_id, "task": job.task,
            "preview": job.preview, "status": job.status,
            "priority": job.priority,
            "queue_position": queue_position, "prompt": job.prompt,
            "lyrics": job.lyrics, "duration_s": job.duration_s,
            "count": job.count, "params": job.params,
            "take_index": job.take_index, "take_of": job.take_of,
            "created_at": job.created_at, "progress": job.progress,
            "result": job.result, "error": job.error}


class SubmitError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


def _number(body: dict, key: str, kind, default):
    """One numeric field of a submit body, or a 422 saying which one.

    `body.get(key, default)` is not enough: a key that is *present and null*
    returns None rather than the default, so `float(None)` raised a TypeError
    that no handler caught and uvicorn answered with a 500 and a plain-text
    body — the one error shape the contract says never goes out. Every other
    refusal in submit() is a SubmitError; these used to be the exceptions.
    """
    raw = body.get(key)
    if raw is None:
        return default
    # bool is an int in Python, and `count: true` meaning 1 take is nobody's
    # intent.
    if isinstance(raw, bool) or isinstance(raw, (list, dict)):
        raise SubmitError(422, "VALIDATION", f"'{key}' must be a number")
    try:
        return kind(raw)
    except (TypeError, ValueError):
        raise SubmitError(422, "VALIDATION",
                          f"'{key}' must be a number, not {raw!r}") from None


class Job:
    def __init__(self, group_id: str, model_id: str, prompt: str,
                 lyrics: str | None, duration_s: float | None, count: int,
                 params: dict, task: str = "generate",
                 preview: bool = False, take_index: int = 0,
                 take_of: int = 1) -> None:
        self.id = f"job_{uuid.uuid4().hex[:12]}"
        self.group_id = group_id
        # Which take of its submission this job is, and how many there were.
        # A `count: 4` submit is expanded at submit into four sibling jobs
        # (5.1) that share a group_id and differ only by this pair, so the
        # queue is a list of takes rather than a list of batches: each take
        # gets its own position, its own cancel and its own error. `0 of 1`
        # for an ordinary single-take render and for every task job.
        self.take_index = take_index
        self.take_of = take_of
        self.model_id = model_id
        self.task = task
        self.preview = preview
        # User-set run order (contract 5.8). 0 is "no opinion", which is where
        # warm-worker locality is allowed to reorder; anything the user set is
        # an instruction the scheduler may not optimise around.
        self.priority = 0
        self.prompt = prompt
        self.lyrics = lyrics
        self.duration_s = duration_s
        self.count = count
        self.params = params
        self.status = "queued"
        self.progress: dict | None = None
        self.result: dict | None = None
        self.error: dict | None = None
        self.created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.cancel_requested = False
        self.cancel_deadline: float | None = None
        # set when work starts; drives the elapsed-based ETA for task jobs
        # (their runtime scales with input length, unknown at submit)
        self.started_monotonic: float | None = None
        # set when the job reaches a terminal status; history eviction keys
        # on it — evicting by created_at could delete a long-queued job the
        # moment it finished, before the app fetched its result (audit H5)
        self.terminal_monotonic: float | None = None
        # the uv provisioning process while envs.ensure() runs for this job,
        # so a cancel can kill the install instead of waiting it out
        self.env_proc = None
        # Backstop-throttle bookkeeping: when the last job.progress went out,
        # and what it was about. See JobQueue._progress.
        self.progress_emitted_at = 0.0
        self.progress_key: tuple | None = None
        # The worker actually running this job. Cancel and crash handling must
        # act on it rather than reaching for the resident slot, which may be
        # holding an unrelated model while a small job runs.
        self.worker: Worker | None = None


class JobQueue:
    def __init__(self, registry: Registry, bus: EventBus,
                 settings: Settings) -> None:
        self.registry = registry
        self.bus = bus
        self.settings = settings
        self.jobs: dict[str, Job] = {}
        self.order: list[str] = []
        self.active: Job | None = None
        # resident slot: the last big model, kept until another displaces it
        self.worker: Worker | None = None
        # warm pool: small models, keyed by family, capped at SMALL_WARM_SLOTS
        # and expired after SMALL_WARM_TTL_S idle
        self.small_workers: dict[str, Worker] = {}
        self.pinned_model_id: str | None = None
        # Queue hold: stop *starting* queued jobs. Never touches the running
        # one — see hold().
        self.held = False
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.runner = threading.Thread(target=self._run_forever, daemon=True)
        self.runner.start()
        # The cancel grace period is enforced from its own thread, because the
        # runner thread is inside the blocking wait it would have to interrupt.
        # See _enforce_cancels_forever.
        self.cancel_wake = threading.Event()
        self.canceller = threading.Thread(target=self._enforce_cancels_forever,
                                          daemon=True)
        self.canceller.start()

    # MARK: API surface

    def submit(self, body: dict) -> dict:
        model_ids = body.get("model_ids") or []
        task = body.get("task") or "generate"
        prompt = (body.get("prompt") or "").strip()
        if task not in TASKS:
            raise SubmitError(422, "VALIDATION", f"unknown task '{task}'")
        if not model_ids or (task == "generate" and not prompt):
            raise SubmitError(422, "VALIDATION", "model_ids and prompt are required")
        if len(model_ids) != 1:
            raise SubmitError(422, "VALIDATION",
                              "exactly one model per job; submit one job per model")
        mid = model_ids[0]
        lyrics = body.get("lyrics") or None
        force = bool(body.get("force"))
        if mid not in self.registry.models:
            raise SubmitError(404, "NOT_FOUND", f"unknown model {mid}")
        if not self.registry.is_installed(mid):
            raise SubmitError(409, "MODEL_NOT_INSTALLED",
                              f"{mid} is not installed")
        model = self.registry.models[mid]
        caps = model["capabilities"]
        if task not in (caps.get("tasks") or ["generate"]):
            raise SubmitError(422, "VALIDATION",
                              f"{mid} does not support task '{task}'")
        count = _number(body, "count", int, 1)
        if count < 1:
            raise SubmitError(422, "VALIDATION", "count must be at least 1")
        if task != "generate":
            if lyrics:
                raise SubmitError(422, "VALIDATION",
                                  f"task '{task}' does not accept lyrics")
            if count != 1:
                raise SubmitError(422, "VALIDATION",
                                  f"task '{task}' jobs run exactly one take")
        if lyrics and not caps["supports_lyrics"]:
            raise SubmitError(422, "VALIDATION",
                              f"{mid} does not support lyrics")
        preview = bool(body.get("preview"))
        # Refused rather than ignored: a caller that asked to watch the render
        # would otherwise wait for frames that are never coming, with nothing
        # anywhere saying why. Only some families can decode real partial
        # audio, and each declares it (contract 5.6).
        if preview and not caps.get("supports_preview"):
            raise SubmitError(422, "VALIDATION",
                              f"{mid} cannot preview while it renders")
        if count > caps["outputs_per_job_max"]:
            raise SubmitError(422, "VALIDATION",
                              f"count exceeds max for {mid}")
        if not force and model["requirements"]["min_ram_bytes"] > physical_ram_bytes():
            raise SubmitError(409, "INSUFFICIENT_RAM",
                              f"{mid} needs more memory than this Mac has")

        group_id = f"grp_{uuid.uuid4().hex[:12]}"
        # Params are prepared and resolved before the lock is taken: resolving
        # an upload id costs a listdir apiece and a mix spec costs a JSON walk
        # plus one per embedded id, and the runner thread and every handler
        # that reports queue state are all waiting on this same lock. Nothing
        # below touches queue state until the jobs themselves are created.
        if task == "generate":
            dur = _number(body, "duration_s", float,
                          caps["duration"]["default_s"])
            # `unlocked_max_s` is the ceiling when a model declares one —
            # the lock is an app-side affordance (a toggle behind a
            # warning), not a second server-side rule. Clamping to max_s
            # here would take an unlocked request and quietly hand back a
            # shorter take, which is the failure this whole field exists to
            # avoid. Absent ⇒ max_s is the ceiling, as it always was.
            ceiling = (caps["duration"].get("unlocked_max_s")
                       or caps["duration"]["max_s"])
            dur = max(caps["duration"]["min_s"], min(ceiling, dur))
        else:
            # output length derives from the input; echo what was sent
            dur = _number(body, "duration_s", float, None)
        known = {p["key"] for p in caps["params"]}
        defaults = {p["key"]: p.get("default") for p in caps["params"]}
        raw = body.get("params") or {}
        if not isinstance(raw, dict):
            # `raw.items()` below is an AttributeError on a list, which reached
            # the caller as a 500 in plain text rather than a refusal.
            raise SubmitError(422, "VALIDATION", "params must be an object")
        params = {k: v for k, v in raw.items() if k in known}
        dropped = set(raw) - known
        # params of type "audio"/"midi" carry an upload id; the worker gets a path
        from .api.uploads import resolve_upload
        for spec in caps["params"]:
            if spec.get("type") not in ("audio", "midi"):
                continue
            value = params.get(spec["key"])
            if value is None:
                continue
            path = resolve_upload(self.settings.uploads_dir, value)
            if path is None:
                raise SubmitError(422, "VALIDATION",
                                  f"unknown upload for '{spec['key']}'")
            params[spec["key"]] = path
        # "json" params with resolve_uploads: replace embedded up_… ids with
        # paths so structured specs (mix tracks) reach workers path-resolved
        for spec in caps["params"]:
            if spec.get("type") != "json" or not spec.get("resolve_uploads"):
                continue
            value = params.get(spec["key"])
            if value is None:
                continue
            params[spec["key"]] = self._resolve_json_uploads(
                spec["key"], value)
        # Every task, generate included. This used to skip generate, and eight
        # generate-only entries declare a mandatory slot with exactly this
        # idiom — VampNet's `src_audio` (it makes variations of a recording),
        # SongBloom's `style_audio`, ACE-Step XL vocals2music's
        # `accompany_audio`. Submitting one without its audio bought a
        # multi-GB load and then a RuntimeError from inside the adapter, where
        # this 422 was free. Safe to widen because `nullable: false` means
        # mandatory outright: a slot that is only sometimes required is
        # declared nullable with a `required_when`, checked below.
        for spec in caps["params"]:
            if (spec.get("type") in ("audio", "midi", "json")
                    and not spec.get("nullable", True)
                    and params.get(spec["key"]) is None):
                raise SubmitError(422, "VALIDATION",
                                  f"missing required input '{spec['key']}'")
        # `required_when`: an input that is optional under one setting and
        # mandatory under another. Checked for generate jobs too, unlike the
        # nullable rule above — ACE-Step's source audio is optional for
        # text2music and required for cover, and a cover submitted without one
        # was 23 seconds of model load followed by an assertion from inside the
        # pipeline, which reaches the caller as a failed job and no advice.
        for spec in caps["params"]:
            cond = spec.get("required_when")
            if not cond:
                continue
            # The controlling param may be absent from the request, in which
            # case its declared default is what the worker will see.
            current = params.get(cond["param"], defaults.get(cond["param"]))
            if current in cond["values"] and params.get(spec["key"]) is None:
                raise SubmitError(
                    422, "VALIDATION",
                    f"'{spec['key']}' is required when "
                    f"{cond['param']} is '{current}'")
        with self.lock:
            # `count: 4` is four jobs, not one job that loops four times.
            # They share the group_id and differ by take_index, so every take
            # is its own row in the queue with its own position, cancel and
            # error — and the app can group them back together by group_id.
            # They still run one after another on the same warm worker (the
            # runner is serial and the worker keeps its loaded model), so the
            # split costs nothing but honesty.
            takes = count
            jobs = [Job(group_id, mid, prompt, lyrics, dur, 1, params,
                        task=task, preview=preview, take_index=i,
                        take_of=takes)
                    for i in range(takes)]
            for job in jobs:
                self.jobs[job.id] = job
                self.order.append(job.id)
            for job in jobs:
                self.bus.emit_threadsafe(
                    "job.queued",
                    {"job_id": job.id, "group_id": group_id, "model_id": mid,
                     "queue_position": self._position_locked(job.id)})
                for k in dropped:
                    self.bus.emit_threadsafe(
                        "job.log", {"job_id": job.id,
                                    "line": f"dropped unknown param '{k}'"})
            self._trim_history_locked()
        self.wake.set()
        return {"group_id": group_id,
                "jobs": [{"job_id": job.id, "model_id": mid} for job in jobs]}

    def _trim_history_locked(self) -> None:
        """Evict the oldest terminal jobs past JOB_HISTORY_CAP total.

        Only terminal rows are candidates — a queued job is a promise, not
        history — so a queue deeper than the cap simply is not trimmed until
        it drains. Eviction order is the time each job *finished*, not
        created_at: by creation time a long-queued job could be evicted the
        moment it succeeded, before the app fetched its result (audit H5).
        """
        if not JOB_HISTORY_CAP or len(self.jobs) <= JOB_HISTORY_CAP:
            return
        terminal = sorted(
            (job for job in self.jobs.values()
             if job.status in TERMINAL_STATUSES),
            key=lambda job: (job.terminal_monotonic or 0.0,
                             job.created_at, job.id))
        overflow = len(self.jobs) - JOB_HISTORY_CAP
        for job in terminal[:overflow]:
            del self.jobs[job.id]

    def live_job_ids(self) -> set[str]:
        """Jobs the outputs-retention sweep must never touch: anything not
        terminal is (or is about to be) writing into its output dir."""
        with self.lock:
            return {jid for jid, job in self.jobs.items()
                    if job.status not in TERMINAL_STATUSES}

    def _resolve_json_uploads(self, key: str, value) -> str:
        """Parse a json param, replace every "up_…" string with its resolved
        absolute path (422 on unknown ids), and re-serialize for the worker."""
        from .api.uploads import resolve_upload
        try:
            parsed = json.loads(value)
        except (TypeError, ValueError):
            raise SubmitError(422, "VALIDATION",
                              f"'{key}' is not valid JSON") from None

        def walk(node):
            if isinstance(node, dict):
                return {k: walk(v) for k, v in node.items()}
            if isinstance(node, list):
                return [walk(v) for v in node]
            if isinstance(node, str) and node.startswith("up_"):
                path = resolve_upload(self.settings.uploads_dir, node)
                if path is None:
                    raise SubmitError(422, "VALIDATION",
                                      f"unknown upload '{node}' in '{key}'")
                return path
            return node

        return json.dumps(walk(parsed))

    def cancel(self, job_id: str) -> None:
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None:
                raise SubmitError(404, "NOT_FOUND", "unknown job")
            if job.status in TERMINAL_STATUSES:
                raise SubmitError(409, "JOB_NOT_CANCELABLE", "job already terminal")
            if job.status == "queued":
                # Set on this path too. `_next_job` hands a job to the runner
                # while its status still reads "queued" — it only becomes
                # "loading" inside `_run_job` — so a cancel landing in that
                # window took this branch, told the client "canceled", and
                # left every later checkpoint reading a flag nobody had set:
                # the model loaded and the take rendered to the end anyway.
                # For a job that really is still queued the flag is never
                # read, so this costs nothing there.
                job.cancel_requested = True
                self._set_status(job, "canceled")
                if job_id in self.order:
                    self.order.remove(job_id)
                self.bus.emit_threadsafe("job.canceled", {"job_id": job_id})
                return
            job.cancel_requested = True
            job.cancel_deadline = time.monotonic() + CANCEL_GRACE_S
            # A job stuck in provisioning has no worker yet — kill the uv
            # install instead of waiting out a minutes-long sync.
            env_proc = getattr(job, "env_proc", None)
            if env_proc is not None and env_proc.poll() is None:
                try:
                    env_proc.kill()
                except OSError:
                    pass
            # job.worker, not self.worker: a small job runs in the transient
            # slot while an unrelated model sits resident.
            if job.worker:
                job.worker.request_cancel()
        # Outside the lock, and unconditional: the request above is cooperative
        # and may never be honoured, so the grace period starts running whether
        # or not there was a worker to ask.
        self.cancel_wake.set()

    def hold(self, held: bool) -> None:
        """Stop starting queued jobs (contract 5.7).

        The running job is deliberately left alone. Suspending a worker mid-take
        would mean SIGSTOP in the middle of a Metal command buffer, which is not
        something that reliably resumes — so a hold can only ever mean "nothing
        new starts", and the UI must say so rather than imply the render
        stopped.
        """
        with self.lock:
            self.held = held
            active = self.active.id if self.active else None
        if not held:
            self.wake.set()
        # Emitted even when the state did not change: this event is the only
        # push a client's toggle gets, and swallowing the echo of a repeat
        # request leaves anyone who missed the first one showing the wrong
        # state with nothing to correct it.
        self.bus.emit_threadsafe("queue.state",
                                 {"held": held, "active_job_id": active})

    def set_priority(self, job_id: str, priority: int) -> None:
        """Set one job's explicit run order (contract 5.8)."""
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None:
                raise SubmitError(404, "NOT_FOUND", "unknown job")
            if job_id not in self.order:
                raise SubmitError(409, "JOB_NOT_QUEUED",
                                  "job is already running or terminal")
            job.priority = priority
            self._announce_queue_locked()

    def set_order(self, job_ids: list[str]) -> None:
        """Run these queued jobs in this order, ahead of every queued job not
        named (contract 5.8). One call, because a drag-and-drop that took N
        round trips would emit N reorderings and could interleave with a
        dequeue halfway through.

        Ids that are no longer queued are skipped rather than refused: the job
        at the top of the list can legitimately start while the pointer is
        still down, and failing the whole reorder over that would be useless.
        """
        with self.lock:
            for jid in job_ids:
                if jid not in self.jobs:
                    raise SubmitError(404, "NOT_FOUND", f"unknown job {jid}")
            queued = [jid for jid in job_ids if jid in self.order]
            listed = set(queued)
            base = max((self.jobs[jid].priority
                        for jid in self.order if jid not in listed),
                       default=0)
            for i, jid in enumerate(queued):
                self.jobs[jid].priority = base + len(queued) - i
            self._announce_queue_locked()

    def _announce_queue_locked(self) -> None:
        """Re-publish every queued job's position after a reorder. Caller holds
        self.lock."""
        for jid in self._run_order_locked():
            job = self.jobs[jid]
            self.bus.emit_threadsafe(
                "job.queued", {"job_id": job.id, "group_id": job.group_id,
                               "model_id": job.model_id,
                               "queue_position": self._position_locked(jid)})

    def info(self, job: Job) -> dict:
        with self.lock:
            pos = self._position_locked(job.id)
        return _job_row(job, pos)

    def info_many(self, jobs: list[Job]) -> list[dict]:
        """`info` for a whole list of jobs, taking the lock once and sorting the
        run order once.

        Per row, both of those are quadratic in the queue depth — the app polls
        /v1/jobs whenever the queue rail is open, and every one of those sorts
        was a sort the runner thread had to wait behind.
        """
        with self.lock:
            active_id = self.active.id if self.active else None
            offset = 1 if self.active else 0
            positions = {jid: i + offset
                         for i, jid in enumerate(self._run_order_locked())}
        rows = []
        for job in jobs:
            if job.status in TERMINAL_STATUSES:
                pos = None
            elif job.id == active_id:
                pos = 0
            else:
                # Absent from the run order means neither queued nor running:
                # the same null _position_locked returns for it.
                pos = positions.get(job.id)
            rows.append(_job_row(job, pos))
        return rows

    def model_in_use(self, model_id: str) -> bool:
        with self.lock:
            return any(j.model_id == model_id
                       and j.status not in TERMINAL_STATUSES
                       for j in self.jobs.values())

    def any_live_job(self) -> bool:
        """Anything queued or running, of any model — what "the engine is busy"
        means to an operation that rearranges the whole library rather than one
        model's weights."""
        with self.lock:
            return any(j.status not in TERMINAL_STATUSES
                       for j in self.jobs.values())

    def release_family(self, family: str) -> bool:
        """Free every worker running out of this family's venv, so the venv can
        be deleted. False — and nothing killed — if a job of that family is
        queued or running.

        A live worker holds its venv's python open and imports lazily out of the
        tree; deleting it underneath one turns the next import into a crash with
        no explanation attached. So the runtime is only ever removed after this
        says the family is idle.
        """
        with self.lock:
            for job in self.jobs.values():
                if job.status in ("succeeded", "failed", "canceled"):
                    continue
                model = self.registry.models.get(job.model_id)
                if model and model["family"] == family:
                    return False
            if self.worker is not None and self.worker.family == family:
                self._kill_worker_locked()
            if family in self.small_workers:
                self._drop_small_locked(family)
        return True

    def set_pin(self, model_id: str | None) -> None:
        """Pin semantics: whenever the queue is idle, this model is (re)loaded and
        its worker kept alive, so generations skip the multi-minute cold load.
        Jobs for other families still run normally — the pinned model reloads
        once the queue drains. Unpinning frees the memory if idle."""
        with self.lock:
            self.pinned_model_id = model_id
        self.wake.set()

    def release_idle_worker(self) -> None:
        """Kill the warm worker now if nothing is queued or running."""
        with self.lock:
            if self.active is None and not self.order:
                self._kill_worker_locked()

    def unload_worker(self) -> None:
        """Explicit user unload: free the resident model. Clears the pin when it
        targets the loaded model (else the idle loop would reload it at once)."""
        with self.lock:
            if self.active is not None or self.order:
                raise SubmitError(409, "ENGINE_BUSY",
                                  "a job is queued or running")
            if (self.worker is not None
                    and self.worker.loaded_model_id == self.pinned_model_id):
                self.pinned_model_id = None
            self._kill_worker_locked()
            # "free the memory" means all of it, including anything left warm
            # in the pool.
            for family in list(self.small_workers):
                self._drop_small_locked(family)

    def telemetry_worker(self) -> Worker | None:
        """The worker the sidebar readout is about: whichever one is running the
        active job, else the resident model. Both slots can be alive at once (a
        small mix model beside a big generator), and the one doing work is the
        one whose memory the user is watching."""
        with self.lock:
            job = self.active
            if job and job.worker and job.worker.is_alive():
                return job.worker
            return self.worker if self.worker and self.worker.is_alive() else None

    def kill_all(self) -> None:
        with self.lock:
            workers = [w for w in (self.worker, *self.small_workers.values())
                       if w]
            self.worker = None
            self.small_workers.clear()
        for worker in workers:
            worker.kill()

    def _run_order_locked(self) -> list[str]:
        """Queued jobs in the order they will actually run: highest explicit
        priority first, submission order within one priority (sorted() is
        stable, and self.order is submission order). Locality reorders only
        inside a single priority — see _next_job. Caller holds self.lock."""
        return sorted(self.order, key=lambda jid: -self.jobs[jid].priority)

    def _position_locked(self, job_id: str) -> int | None:
        job = self.jobs[job_id]
        if job.status in ("succeeded", "failed", "canceled"):
            return None
        if self.active and self.active.id == job_id:
            return 0
        if job_id in self.order:
            return (self._run_order_locked().index(job_id)
                    + (1 if self.active else 0))
        return None

    # MARK: runner

    def _next_job(self) -> Job | None:
        with self.lock:
            if self.held or not self.order:
                return None
            run_order = self._run_order_locked()
            # Locality is an optimisation; an explicit priority is an
            # instruction. So the warm-worker search is confined to the leading
            # equal-priority run — jobs the user left in the same bucket, where
            # nobody has said which of them goes first.
            top = self.jobs[run_order[0]].priority
            group = [jid for jid in run_order if self.jobs[jid].priority == top]
            warm = self.worker.family if self.worker and self.worker.is_alive() else None
            chosen = group[0]
            if warm:
                for jid in group:
                    family = self.registry.models[self.jobs[jid].model_id]["family"]
                    if family == warm:
                        chosen = jid
                        break
            self.order.remove(chosen)
            job = self.jobs[chosen]
            self.active = job
            return job

    def _run_forever(self) -> None:
        while True:
            job = self._next_job()
            if job is None:
                if self._ensure_pinned_loaded():
                    continue
                self.wake.clear()
                with self.lock:
                    # `not held`: a hold with jobs still queued must sleep, or
                    # this loop spins at full tilt for as long as it lasts.
                    # resume() sets the wake.
                    have_work = bool(self.order) and not self.held
                    # Sleep only until the next warm worker is due to expire,
                    # so the pool empties on a quiet (or held) queue instead of
                    # waiting for a job that may never come.
                    deadline = self._expire_small_locked(time.monotonic())
                if have_work:  # submitted between _next_job and clear
                    continue
                timeout = (max(0.05, deadline - time.monotonic())
                           if deadline is not None else None)
                self.wake.wait(timeout)
                continue
            if job.status == "canceled":
                with self.lock:
                    self.active = None
                continue
            try:
                self._run_job(job)
            except Exception as e:  # noqa: BLE001 — runner must never die
                self._fail(job, "INTERNAL", str(e))
            finally:
                with self.lock:
                    self.active = None
                    # The last-used model stays resident (and in the titlebar)
                    # until a different-family job displaces it, the user hits
                    # "Unload model", or the engine shuts down. Only reap a
                    # worker that already died.
                    if self.worker and not self.worker.is_alive():
                        self._kill_worker_locked()
                    # The small worker that just ran starts its idle clock here
                    # (identity-checked: it may have been evicted mid-job);
                    # anything already past the TTL goes now.
                    now = time.monotonic()
                    ran = job.worker
                    if ran is not None and self.small_workers.get(
                            ran.family) is ran:
                        ran.idle_since = now
                    self._expire_small_locked(now)
                    # Released here and nowhere earlier: this is the last read
                    # of job.worker, and the job is terminal by now (cancel and
                    # the cancel watchdog both skip terminal jobs). It used to
                    # be held for the life of the history row, so a session
                    # that switched models kept a dead Worker — its Popen, its
                    # log handle, its message queue — for up to
                    # JOB_HISTORY_CAP jobs at a time.
                    job.worker = None

    def relieve_memory_pressure(self, culprit: Worker) -> list[str]:
        """Drop idle warm workers when the memory guard trips; what was
        dropped, so the warning can name it.

        Called from the offending worker's stdout reader thread (see
        `Worker._relieve_memory`), so the lock covers a couple of dict
        operations and the kills happen outside it — a reader thread blocked on
        this lock is a worker that cannot drain its stdout.

        Only idle workers go, and never the one that tripped the guard. The
        pool exists because its members are cheap to rebuild, so dropping one
        is strictly better than telling the user to pick a smaller model — and
        the guard only warns, so before this there was no response to memory
        pressure at all. The resident slot goes too when no job is using it,
        unless it holds the pinned model: the idle loop would reload that
        immediately, and a reload loop under memory pressure is worse than the
        pressure.
        """
        freed: list[str] = []
        doomed: list[Worker] = []
        with self.lock:
            for family, worker in list(self.small_workers.items()):
                if worker is culprit or worker.idle_since is None:
                    continue
                del self.small_workers[family]
                doomed.append(worker)
                freed.append(worker.loaded_model_id or family)
            resident = self.worker
            busy = self.active.worker if self.active else None
            if (resident is not None and resident is not culprit
                    and resident is not busy
                    and resident.loaded_model_id != self.pinned_model_id):
                self.worker = None
                doomed.append(resident)
                freed.append(resident.loaded_model_id or resident.family)
                # The titlebar must stop claiming this model is loaded, so this
                # eviction announces itself where a displacement does not.
                self.bus.emit_threadsafe("worker.state", {
                    "state": "stopped", "model_id": resident.loaded_model_id,
                    "family": resident.family})
        for worker in doomed:
            worker.kill()
        return freed

    def _drop_small_locked(self, family: str) -> None:
        """Caller holds self.lock."""
        worker = self.small_workers.pop(family, None)
        if worker is not None:
            worker.kill()

    def _make_room_locked(self) -> None:
        """Evict the least-recently-used idle worker if the pool is full.

        A worker mid-job is never evicted — `idle_since` is None for exactly as
        long as it is working. Caller holds self.lock.
        """
        while len(self.small_workers) >= max(0, SMALL_WARM_SLOTS):
            idle = [(w.idle_since, f) for f, w in self.small_workers.items()
                    if w.idle_since is not None]
            if not idle:
                return  # everything is busy; let the pool run over rather than
                        # kill a worker out from under a running job
            self._drop_small_locked(min(idle)[1])

    def _expire_small_locked(self, now: float) -> float | None:
        """Drop pooled workers idle past the TTL; return the next deadline.

        The returned value is what the runner sleeps on, so expiry happens on
        an idle (or held) queue rather than only after the next job.
        Caller holds self.lock.
        """
        if SMALL_WARM_TTL_S <= 0 or SMALL_WARM_SLOTS <= 0:
            # policy off: behave as before, dropping idle workers immediately
            for family in [f for f, w in self.small_workers.items()
                           if w.idle_since is not None]:
                self._drop_small_locked(family)
            return None
        next_deadline: float | None = None
        for family, worker in list(self.small_workers.items()):
            if not worker.is_alive():
                self._drop_small_locked(family)
                continue
            if worker.idle_since is None:
                continue
            deadline = worker.idle_since + SMALL_WARM_TTL_S
            if deadline <= now:
                self._drop_small_locked(family)
            elif next_deadline is None or deadline < next_deadline:
                next_deadline = deadline
        return next_deadline

    def _claim_worker_locked(self, small: bool, family: str) -> Worker | None:
        """The live worker this job can run on, or None if one has to be built.

        Splitting the claim from the build is the whole point: a claim is a
        couple of dict lookups, while building a Worker opens a log file, forks
        and execs the family's venv python and starts two reader threads. That
        second part must not happen under this lock — `jobs_list`, `/v1/system`,
        submit and cancel all take it from the event loop, so a spawn held
        inside it stalls REST and the event stream together, for exactly as long
        as fork/exec takes under whatever memory pressure the render created.
        Caller holds self.lock.
        """
        if small:
            # The pool never touches self.worker, so whatever big model is
            # resident stays loaded (and stays in the titlebar) right through
            # this job.
            worker = self.small_workers.get(family)
            if worker and not worker.is_alive():
                del self.small_workers[family]
                return None
            if worker is not None:
                worker.idle_since = None
            return worker
        worker = self.worker
        if worker and (worker.family != family or not worker.is_alive()):
            # Displaced rather than unloaded, so no worker.state "stopped" goes
            # out: the next thing the app hears about this slot is the incoming
            # model's "loaded".
            worker.kill()
            self.worker = None
            return None
        return worker

    def _install_worker_locked(self, worker: Worker, small: bool,
                               family: str) -> bool:
        """Put a freshly built worker into its slot, if the slot is still free.

        False means the state moved while the worker was being built and the
        caller is holding a process with nothing to do. Only the runner thread
        ever fills a slot, but any thread can empty one (an unload, a family
        release, a crash reaped elsewhere), so the emptiness is re-established
        here rather than assumed. Caller holds self.lock.
        """
        if small:
            if family in self.small_workers:
                return False
            self._make_room_locked()
            self.small_workers[family] = worker
            worker.idle_since = None
            return True
        if self.worker is not None:
            return False
        self.worker = worker
        return True

    def _spawn_worker(self, family: str, python: str, small: bool) -> Worker:
        """Build a worker for this family and put it in its slot, with the lock
        released across the build itself.

        The retry is not a spin: an install can only be refused by a slot that
        is occupied, and the claim that follows either hands that occupant back
        or empties the slot (it was dead), so the second pass always settles.
        """
        while True:
            spawned = Worker(family, python, self.settings, self.bus,
                             log_suffix="transient" if small else None)
            # The memory guard's first move is to drop idle warm workers, and
            # only the queue knows which those are.
            spawned.on_memory_pressure = self.relieve_memory_pressure
            with self.lock:
                if self._install_worker_locked(spawned, small, family):
                    return spawned
                existing = self._claim_worker_locked(small, family)
            # Nothing has been sent to this process, so dropping it costs only
            # the spawn it took to build.
            spawned.kill()
            if existing is not None:
                return existing

    def _kill_worker_locked(self) -> None:
        """Caller holds self.lock."""
        worker = self.worker
        self.worker = None
        if worker is None:
            return
        model_id = worker.loaded_model_id
        family = worker.family
        worker.kill()
        self.bus.emit_threadsafe("worker.state", {
            "state": "stopped", "model_id": model_id, "family": family})

    def _ensure_pinned_loaded(self) -> bool:
        """Idle-time preload of the pinned model. Returns True if it did work
        (the caller should re-check the queue before sleeping)."""
        with self.lock:
            mid = self.pinned_model_id
            worker = self.worker
        if mid is None:
            return False
        if mid not in self.registry.models or not self.registry.is_installed(mid):
            with self.lock:
                self.pinned_model_id = None
            return False
        if worker and worker.is_alive() and worker.loaded_model_id == mid:
            # pin satisfied; nothing to do (unpin of a stale worker is handled
            # by the keep logic after the next job)
            return False
        model = self.registry.models[mid]
        family = model["family"]
        self.bus.emit_threadsafe("worker.state", {
            "state": "loading", "model_id": mid, "family": family})
        try:
            python = envs.ensure(family, progress=lambda m: None)
            with self.lock:
                worker = self.worker
                if worker and (worker.family != family or not worker.is_alive()):
                    self._kill_worker_locked()
                    worker = None
            if worker is None:
                # Built with the lock released — see _claim_worker_locked.
                worker = self._spawn_worker(family, python, False)
            if not worker.ready_seen:
                worker.wait_until({"ready"}, timeout=60)
                worker.ready_seen = True
            worker.send({"t": "load", "model_id": mid,
                         "model_paths": self.registry.snapshot_dirs(mid),
                         "work_dir": self.settings.output_dir,
                         "settings": model.get("settings", {})})
            msg = worker.wait_until({"loaded", "error"})
            if msg["t"] == "error":
                raise RuntimeError(msg.get("message", "load failed"))
            worker.loaded_model_id = mid
            self.bus.emit_threadsafe("worker.state", {
                "state": "loaded", "model_id": mid, "family": family})
        except Exception as e:  # noqa: BLE001 — a bad pin must not kill the runner
            with self.lock:
                self.pinned_model_id = None  # don't retry-loop a failing load
                self._kill_worker_locked()
            self.bus.emit_threadsafe("engine.warning", {
                "message": f"could not keep {mid} loaded: {e}"})
        return True

    def _run_job(self, job: Job) -> None:
        model = self.registry.models[job.model_id]
        family = model["family"]
        self.bus.emit_threadsafe("job.started", {"job_id": job.id})
        self._set_status(job, "loading")
        self._progress(job, "loading", None, "preparing runtime")

        if job.cancel_requested:
            self._canceled(job)
            return

        # on_proc gives the cancel path a handle on the uv install: a first
        # provisioning pulls a torch-sized tree for minutes, far too long to
        # keep running after the user said stop (audit §4 minors).
        try:
            python = envs.ensure(
                family,
                progress=lambda m: self._progress(job, "loading", None, m),
                on_proc=lambda p: setattr(job, "env_proc", p))
        except envs.ProvisionError:
            if job.cancel_requested:
                self._canceled(job)
                return
            raise
        finally:
            job.env_proc = None

        if job.cancel_requested:
            self._canceled(job)
            return

        small = _is_small(model)
        with self.lock:
            worker = self._claim_worker_locked(small, family)
        if worker is None:
            worker = self._spawn_worker(family, python, small)
        worker.current_job_id = job.id
        job.worker = worker

        # A cancel that arrived while this job had no worker yet had nowhere to
        # send its request — and the window above is not small, because
        # envs.ensure() may be installing a family runtime. Ending it here
        # rather than forwarding the request keeps the worker clean: nothing has
        # been sent to it, so there is no stale cancel for the next command to
        # trip over.
        if job.cancel_requested:
            # current_job_id by hand: this returns above _run_job's own
            # try/finally, and a worker left owning a cancelled job's id
            # attributes its next lines of stderr to it.
            worker.current_job_id = None
            self._canceled(job)
            return

        if not worker.ready_seen:
            try:
                worker.wait_until({"ready"}, timeout=60)
                worker.ready_seen = True
            except (WorkerDied, TimeoutError) as e:
                self._worker_crashed(job, worker, str(e))
                return

        # Assigned before the try: the finally below sweeps previews from it,
        # and binding it only after a successful load turned every load-time
        # failure on a previewed job into an UnboundLocalError that masked
        # the real error (audit H4).
        out_dir = os.path.join(self.settings.output_dir, job.id)

        try:
            if worker.loaded_model_id != job.model_id:
                self._progress(job, "loading", None,
                               f"loading {model['display_name']}")
                worker.send({"t": "load", "model_id": job.model_id,
                             "model_paths": self.registry.snapshot_dirs(job.model_id),
                             "work_dir": self.settings.output_dir,
                             "settings": model.get("settings", {})})
                msg = worker.wait_until(
                    {"loaded", "error"},
                    on_progress=lambda f, m, **staged: self._progress(
                        job, "loading", f, m, **staged))
                if msg["t"] == "error":
                    self._handle_worker_error(job, msg)
                    return
                worker.loaded_model_id = job.model_id
                if not small:
                    # Transient loads are deliberately silent: worker.state
                    # drives the titlebar's "resident model", and a small model
                    # passing through must not claim that spot.
                    self.bus.emit_threadsafe("worker.state", {
                        "state": "loaded", "model_id": job.model_id,
                        "family": family})

            self._set_status(job, "generating")
            os.makedirs(out_dir, exist_ok=True)
            started = time.monotonic()
            job.started_monotonic = started

            if job.task != "generate":
                self._run_task_locked_free(job, worker, out_dir, started)
                return

            outputs = []
            meta: dict = {}
            # `count` is 1 on every job the API can now create: a multi-take
            # submission is expanded into sibling jobs at submit (5.1). The
            # loop stays because the per-take bookkeeping below — seeds, the
            # preview sweep, `job.take_done` — is what it always was, and a
            # job built with count > 1 by anything else still renders.
            for i in range(job.count):
                if job.cancel_requested:
                    self._canceled(job)
                    return
                # The previous take is on disk now, so its frames are dead
                # weight. Without this a `count: 4` previewed render holds
                # every frame of every take at once — for an 11 s stereo
                # Stable Audio take that is hundreds of MB of transient WAV.
                if i > 0 and job.preview:
                    self._sweep_previews(out_dir)
                params = dict(job.params)
                if params.get("seed") is None:
                    params["seed"] = random.randrange(2**31)
                out_path = os.path.join(out_dir, f"take-{i}.wav")

                def on_progress(f: float | None, m: str, take: int = i,
                                **staged) -> None:
                    # Single take, unknown fraction: stay null — the app has a
                    # spinner for that, and flattening it to 0.0 kept a dozen
                    # phase-only families' bars frozen at zero for whole
                    # renders (audit H1). A BATCH with an unknown take is
                    # different: takes 0..take-1 are finished and counted, and
                    # nulling the whole readout sent a 4-take render back to a
                    # spinner at every boundary, right after showing 25/50/75%.
                    if f is None:
                        overall = None if job.count == 1 else take / job.count
                    else:
                        overall = (take + f) / job.count
                    # the phase and its step counts belong to the take the
                    # worker is on, so they pass through unscaled — and the
                    # take itself is named, so the app can say which of the
                    # four it is watching rather than inferring it from a
                    # fraction that may be null
                    self._progress(job, "generating", overall, m, take=take,
                                   **staged)

                def on_preview(path: str, sample_rate: int, duration_s: float,
                               step: int | None, take: int = i) -> None:
                    self._preview(job, out_dir, path, sample_rate, duration_s,
                                  step, take)

                send_params = {**params, "duration_s": job.duration_s}
                if job.preview:
                    # The same flag the worker reads to install its writer and
                    # the adapter reads to decide whether to decode at all.
                    send_params["preview"] = True
                worker.send({"t": "generate", "job_id": job.id,
                             "prompt": job.prompt, "lyrics": job.lyrics,
                             "params": send_params, "out_path": out_path})
                msg = worker.wait_until({"result", "error"},
                                        on_progress=on_progress,
                                        on_preview=on_preview)
                if msg["t"] == "error":
                    self._handle_worker_error(job, msg)
                    return
                # `extra` is whatever the adapter chose to say about the take
                # beyond the audio itself — for ACE-Step, the plan its language
                # model wrote before the DiT rendered it. Per-take, because two
                # takes of one job have two different plans, and the app's
                # "keep this plan, change the sound" path needs the one that
                # belongs to the take the user picked.
                take_meta = msg.get("extra") or {}
                output = {"path": msg["wav_path"], "format": "wav",
                          "sample_rate": msg["sample_rate"],
                          "duration_s": msg["duration_s"],
                          "seed_used": msg.get("seed_used")}
                # Separated parts of this take, for the models that render a
                # song as parts (5.6a). Path-checked exactly as a task artifact
                # is: a worker naming a file outside the job's own directory
                # loses the stem, never the take — the song itself is fine and
                # failing the render over a part would be the wrong trade.
                stems = []
                stem_root = os.path.realpath(out_dir)
                for s in msg.get("stems") or []:
                    real = os.path.realpath(str(s.get("path", "")))
                    if (not real.startswith(stem_root + os.sep)
                            or not os.path.isfile(real)):
                        self.bus.emit_threadsafe(
                            "job.log",
                            {"job_id": job.id,
                             "line": "dropped a stem with an invalid path"})
                        continue
                    stems.append({"label": s.get("label") or "stem",
                                  "path": real, "format": "wav",
                                  "sample_rate": s.get("sample_rate"),
                                  "duration_s": s.get("duration_s")})
                if stems:
                    output["stems"] = stems
                if take_meta:
                    output["meta"] = take_meta
                    meta.update(take_meta)
                outputs.append(output)
                # The finished take is on disk and final, so the app can land
                # it in the library NOW instead of when the whole batch ends.
                # job.completed stays the source of truth: a client that
                # missed this event ingests everything there, one that saw it
                # dedups by take index (contract §5.5).
                self.bus.emit_threadsafe(
                    "job.take_done",
                    {"job_id": job.id, "take": i, "output": output})

            self._set_status(job, "encoding")
            # Still the last take: every one is rendered by now, and dropping
            # to null here would blank a "take 4 of 4" readout for the frame or
            # two before the job completes.
            self._progress(job, "encoding", 1.0, "finishing",
                           take=job.count - 1)
            self._sweep_previews(out_dir)
            job.result = {"outputs": outputs,
                          "timings": {"total_s": round(time.monotonic() - started, 2)}}
            # Mirrors the task path's `result.meta`. Only present when an
            # adapter had something to say — a generate result that carries no
            # meta looks exactly as it always has.
            if meta:
                job.result["meta"] = meta
            self._set_status(job, "succeeded")
            self.bus.emit_threadsafe("job.completed", {"job_id": job.id})
        except WorkerDied as e:
            self._worker_crashed(job, worker, str(e))
        finally:
            worker.current_job_id = None
            # A failed render has nothing worth keeping. A CANCELED one might:
            # "Keep partial" is the app copying the frame it was already handed,
            # and deleting it here would race that. Those are collected at
            # startup instead, with the uploads.
            if job.preview and job.status == "failed":
                self._sweep_previews(out_dir)

    def _run_task_locked_free(self, job: Job, worker: Worker, out_dir: str,
                              started: float) -> None:
        """Run a non-generate task job on an already-loaded worker. Caller owns
        the WorkerDied handling (invoked from inside _run_job's try block)."""

        def on_progress(f: float | None, m: str, **staged) -> None:
            self._progress(job, "generating", f, m, **staged)

        worker.send({"t": "task", "job_id": job.id, "task": job.task,
                     "params": job.params, "out_dir": out_dir})
        msg = worker.wait_until({"task_result", "error"}, on_progress=on_progress)
        if msg["t"] == "error":
            self._handle_worker_error(job, msg)
            return
        out_root = os.path.realpath(out_dir)
        artifacts = []
        for a in msg.get("artifacts") or []:
            path = os.path.realpath(str(a.get("path", "")))
            if not path.startswith(out_root + os.sep) or not os.path.isfile(path):
                self._fail(job, "INTERNAL",
                           f"worker returned an invalid artifact path for {job.task}")
                return
            artifacts.append({"kind": a.get("kind") or "audio",
                              "label": a.get("label") or "",
                              "path": path,
                              "format": a.get("format") or "wav",
                              "sample_rate": a.get("sample_rate"),
                              "duration_s": a.get("duration_s")})
        if not artifacts:
            self._fail(job, "INTERNAL", f"{job.task} produced no artifacts")
            return
        self._set_status(job, "encoding")
        self._progress(job, "encoding", 1.0, "finishing")
        job.result = {"artifacts": artifacts, "meta": msg.get("meta") or {},
                      "timings": {"total_s": round(time.monotonic() - started, 2)}}
        self._set_status(job, "succeeded")
        self.bus.emit_threadsafe("job.completed", {"job_id": job.id})

    # MARK: helpers

    def _preview(self, job: Job, out_dir: str, path: str, sample_rate: int,
                 duration_s: float, step: int | None, take: int) -> None:
        """Announce a partial take (contract 5.6).

        The path is validated exactly as a task artifact's is: a worker may only
        hand back files inside this job's own output directory. A preview that
        fails is dropped with a log line rather than failing the job — it is a
        side channel, and losing a frame of it must not lose the render.
        """
        root = os.path.realpath(out_dir)
        real = os.path.realpath(path)
        if not real.startswith(root + os.sep) or not os.path.isfile(real):
            self.bus.emit_threadsafe(
                "job.log", {"job_id": job.id,
                            "line": f"ignored a preview outside {root}"})
            return
        self.bus.emit_threadsafe(
            "job.preview", {"job_id": job.id, "take": take, "path": real,
                            "sample_rate": sample_rate,
                            "duration_s": round(duration_s, 3), "step": step})

    def _sweep_previews(self, out_dir: str) -> None:
        """Drop a finished job's previews. They are several MB apiece and the
        take they were previewing is now on disk; the only reason to keep one is
        a cancel the user asked to keep, which never reaches here.

        Matched on `preview-<n>.wav` down to the digits: a transcribe job's
        audition renders are `preview-<track>.wav`, and while no directory ever
        holds both, a sweep that took the prefix on trust would delete a task's
        real artifacts the moment one did.
        """
        try:
            names = os.listdir(out_dir)
        except OSError:
            return
        for name in names:
            if not (name.startswith("preview-") and name.endswith(".wav")):
                continue
            if not name[len("preview-"):-len(".wav")].isdigit():
                continue
            try:
                os.unlink(os.path.join(out_dir, name))
            except OSError:
                pass

    def _enforce_cancels_forever(self) -> None:
        """Hard-kill backstop: SIGKILL a worker that ignored a cancel past its
        grace period (contract 5.3).

        On its own thread, and this is the whole point of the thread. This used
        to be a call at the top of the progress callback, which made the
        backstop depend on the worker still reporting progress — precisely what
        a worker that has stopped yielding no longer does. ACE-Step is the
        worked example: it runs its diffusion on an internal thread, drives our
        progress shim from a *separate* estimator thread, and wraps the call in
        `except Exception: pass` — so the CancelledError the shim raises is
        swallowed, the shim stops forwarding progress, and the one thing that
        could have killed the worker was the one thing the cancel had just
        switched off. The take then ran to completion (or to upstream's own 600
        s timeout) with the button pressed and nothing happening.

        Nothing here consults the worker: a deadline that has passed is enough,
        which is the only claim that survives a worker that has gone silent.
        """
        while True:
            # Cleared before the deadline is read, so a cancel arriving during
            # the read is still holding the event set when we reach wait().
            self.cancel_wake.clear()
            with self.lock:
                deadline = self._next_cancel_deadline_locked()
            if deadline is None:
                # Nothing armed; cancel() will wake us when something is.
                self.cancel_wake.wait()
            else:
                # Bounded even with a deadline in hand: a job cancelled during
                # its runtime install has no worker to kill yet, and the retry
                # has to come from somewhere.
                self.cancel_wake.wait(
                    min(CANCEL_POLL_S, max(0.0, deadline - time.monotonic())))
            self._enforce_cancels()

    def _next_cancel_deadline_locked(self) -> float | None:
        """The soonest grace period still running. Caller holds self.lock."""
        deadlines = [job.cancel_deadline for job in self.jobs.values()
                     if job.cancel_requested and job.cancel_deadline
                     and job.status not in TERMINAL_STATUSES]
        return min(deadlines) if deadlines else None

    def _enforce_cancels(self) -> None:
        now = time.monotonic()
        doomed: list[tuple[Job, Worker]] = []
        with self.lock:
            for job in self.jobs.values():
                if (job.cancel_requested and job.cancel_deadline
                        and now > job.cancel_deadline and job.worker
                        and job.status not in TERMINAL_STATUSES):
                    # Disarmed as it fires: the kill is what ends this job, and
                    # a deadline left standing would re-kill whatever worker
                    # the pool hands out next.
                    job.cancel_deadline = None
                    doomed.append((job, job.worker))
        for job, worker in doomed:
            worker._log_write(
                f"[job {job.id}] cancel ignored for {CANCEL_GRACE_S:.0f}s "
                f"— killing the worker\n".encode())
            # Outside the lock: the runner thread is about to see EOF on this
            # worker's stdout and will want the lock to finish the job.
            worker.kill()

    def _handle_worker_error(self, job: Job, msg: dict) -> None:
        kind = msg.get("kind", "runtime")
        if kind == "cancelled":
            self._canceled(job)
            return
        # keep the worker traceback: some exceptions stringify to "" (bare
        # asserts, RuntimeError()) and the message alone is undebuggable
        if msg.get("traceback") and job.worker:
            job.worker._log_write(
                f"[job {job.id} error]\n{msg['traceback']}\n".encode())
        if kind == "oom":
            self._fail(job, "OOM", "the model ran out of memory")
            if job.worker:
                job.worker.kill()
        else:
            detail = msg.get("message") or "generation failed"
            self._fail(job, "INTERNAL", detail)

    def _worker_crashed(self, job: Job, worker: Worker, detail: str) -> None:
        with self.lock:
            if self.worker is worker:
                self._kill_worker_locked()
            else:
                # drop it from the pool by identity, not by family: another
                # worker may already hold that key
                for family, pooled in list(self.small_workers.items()):
                    if pooled is worker:
                        del self.small_workers[family]
                worker.kill()
        if job.cancel_requested:
            self._canceled(job)
        else:
            self._fail(job, "WORKER_CRASHED",
                       f"the engine worker exited unexpectedly ({detail})")

    def _canceled(self, job: Job) -> None:
        self._set_status(job, "canceled")
        self.bus.emit_threadsafe("job.canceled", {"job_id": job.id})

    def _fail(self, job: Job, code: str, message: str) -> None:
        self._set_status(job, "failed")
        job.error = {"code": code, "message": message}
        self.bus.emit_threadsafe("job.failed",
                                 {"job_id": job.id, "error": job.error})

    def _set_status(self, job: Job, status: str) -> None:
        job.status = status
        if status in TERMINAL_STATUSES and job.terminal_monotonic is None:
            job.terminal_monotonic = time.monotonic()

    def _progress(self, job: Job, stage: str, fraction: float | None,
                  message: str, *, phase: str | None = None,
                  step: int | None = None, steps: int | None = None,
                  take: int | None = None) -> None:
        eta = None
        if job.task != "generate":
            # runtime scales with input length (unknown at submit): once real
            # progress exists, project from elapsed time instead of estimates
            if (fraction is not None and fraction >= 0.05
                    and job.started_monotonic is not None):
                elapsed = time.monotonic() - job.started_monotonic
                eta = round(max(0.0, elapsed * (1 - fraction) / fraction), 1)
        elif fraction is not None and fraction > 0:
            est = self.registry.models[job.model_id]["capabilities"][
                "est_seconds_per_audio_second"]
            total_est = est * job.duration_s * job.count
            eta = round(max(0.0, total_est * (1 - fraction)), 1)
        # fraction stays null when the adapter does not know: flattening it to
        # 0.0 drew a bar frozen at zero for the whole of a load, which reads as
        # a hang. An honest indeterminate bar is better than a false number.
        # `take` is 0-based and names which of the job's `count` takes is
        # running. Without it the app could only guess from the fraction, which
        # is null for adapters that do not know theirs — and a job that renders
        # four takes then reported them all as one piece of work.
        job.progress = {"stage": stage,
                        "fraction": None if fraction is None else round(fraction, 4),
                        "eta_s": eta, "message": message,
                        "phase": phase, "step": step, "steps": steps,
                        "take": take}
        # What is dropped here is the push, never the state: job.progress above
        # is always current, so /v1/jobs and the job's own row answer with every
        # value regardless. A change of stage, phase or take always goes out —
        # it is a different piece of work, and the first report of one is the
        # one that names it — and so does a completed fraction.
        #
        # A report with no fraction is keyed by its words instead, because words
        # are all it is: "Installing musicgen runtime…" arrives microseconds
        # after "preparing runtime" and then stands for the whole of a uv sync,
        # so dropping it would leave the render card reading the wrong thing for
        # minutes. Anything measuring itself is keyed by its stage, which is
        # what the rate limit is actually here to hold down.
        now = time.monotonic()
        key = (stage, phase, take, message if fraction is None else None)
        if (key == job.progress_key
                and not (fraction is not None and fraction >= 1.0)
                and now - job.progress_emitted_at < PROGRESS_MIN_INTERVAL_S):
            return
        job.progress_key = key
        job.progress_emitted_at = now
        self.bus.emit_threadsafe("job.progress",
                                 {"job_id": job.id, **job.progress})

"""Download manager: HF snapshot downloads as supervised subprocesses.

Progress is sampled from cache-directory size (robust across hub versions and
resume-aware); pause/resume/cancel are SIGSTOP/SIGCONT/SIGKILL on the subprocess.

Downloads run one at a time (contract 4.2). They share a link and, worse, they
share the xet staging directory that progress is *measured* from, so two at once
made both reported rates wrong. The ones waiting say `queued` — which is what
they are — rather than reporting a transfer moving at 0 B/s.
"""

from __future__ import annotations

import fnmatch
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

from huggingface_hub import HfApi

from . import envs
from .events import EventBus
from .registry import Registry

SAMPLE_INTERVAL = 0.5
MAX_RETRIES = 2

# How many downloads may transfer at once. Overridable for a link fast enough
# that serialising is the bottleneck, but the default is 1 for the reasons in
# the module docstring.
MAX_ACTIVE_DOWNLOADS = max(
    1, int(os.environ.get("LOCALMUSIC_MAX_ACTIVE_DOWNLOADS") or 1))


class DownloadError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class DownloadTask:
    def __init__(self, model_id: str, bytes_total: int,
                 runtime_only: bool = False) -> None:
        self.id = f"dl_{uuid.uuid4().hex[:12]}"
        self.model_id = model_id
        # Every download starts queued and is promoted by _pump the moment a
        # slot is free — which, for the first one, is before start() returns.
        self.state = "queued"
        # A runtime install has no weights to fetch, so it says what it is from
        # the moment it is accepted rather than reading `weights` until dispatch
        # like a real download does.
        self.runtime_only = runtime_only
        self.stage = "provisioning" if runtime_only else "weights"
        self.message = ""
        self.bytes_done = 0
        self.bytes_total = bytes_total
        self.speed_bps = 0
        self.cancelled = False
        self.xet_baseline = 0
        self.proc: subprocess.Popen | None = None
        self.lock = threading.Lock()

    def info(self) -> dict:
        return {"download_id": self.id, "model_id": self.model_id,
                "state": self.state, "bytes_done": self.bytes_done,
                "bytes_total": self.bytes_total, "speed_bps": self.speed_bps,
                "stage": self.stage, "message": self.message,
                "runtime_only": self.runtime_only}


class DownloadManager:
    def __init__(self, registry: Registry, bus: EventBus,
                 hf_token_provider) -> None:
        self.registry = registry
        self.bus = bus
        self.hf_token_provider = hf_token_provider   # () -> str | None
        self.tasks: dict[str, DownloadTask] = {}
        self.pending: list[str] = []   # waiting for a slot, in arrival order
        self.active: set[str] = set()  # transferring (or provisioning) now
        self.lock = threading.Lock()

    # MARK: API surface

    def _xet_bytes(self) -> int:
        """Xet-backed downloads stage chunks under hf-cache/xet before the repo dir
        sees them; count that too so progress doesn't sit at zero."""
        total = 0
        xet = os.path.join(self.registry.settings.hf_cache_dir, "xet")
        for root, _dirs, files in os.walk(xet):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        return total

    def start(self, model_id: str) -> str:
        with self.lock:
            for t in self.tasks.values():
                if t.model_id == model_id:
                    return t.id
        model = self.registry.models[model_id]
        need = model["requirements"]["disk_bytes"] * 1.2
        free = shutil.disk_usage(self.registry.settings.data_dir).free
        if free < need:
            raise DownloadError("INSUFFICIENT_DISK", "not enough free disk space")
        # record the attempt: this is what makes a later interruption report
        # "partial" (and the UI offer "Resume download") without mistaking
        # shared files that other entries brought in for progress of our own
        self.registry.mark_attempted(model_id)
        task = DownloadTask(model_id, model["size_bytes"])
        # Already-cached bytes, so a resumed download shows its partial
        # progress while it waits rather than starting the bar at zero.
        task.bytes_done = self.registry.cache_bytes(model_id)
        return self._enqueue(task)

    def start_runtime(self, model_id: str) -> str:
        """Install this model's family runtime on its own, with no weights.

        The repair path for a model whose weights are already here — one
        downloaded before its family had a runtime step, or whose adapter has
        since been updated. It runs through the same queue as a real download
        because it is the same kind of work: one heavy install at a time.
        """
        family = self.registry.models[model_id]["family"]
        if not envs.has_project(family):
            raise DownloadError("NO_RUNTIME",
                                f"no runtime package exists for '{family}'")
        with self.lock:
            # The runtime belongs to the family, not the model, so a second
            # model of the same family joins the install already running rather
            # than queueing a duplicate uv sync behind it.
            for t in self.tasks.values():
                if (self.registry.models[t.model_id]["family"] == family
                        and t.stage == "provisioning"):
                    return t.id
                if t.model_id == model_id:
                    return t.id
        # Deliberately no mark_attempted: nothing about the weights is being
        # touched, and an interrupted runtime install must not leave the model
        # reading "partial" and offering "Resume download".
        return self._enqueue(DownloadTask(model_id, 0, runtime_only=True))

    def _enqueue(self, task: DownloadTask) -> str:
        with self.lock:
            self.tasks[task.id] = task
            self.pending.append(task.id)
            # Announced on arrival, not on dispatch: _pump only emits for the
            # downloads it starts, so without this one waiting its turn produces
            # no event at all and a client watching the stream cannot see that
            # it exists — which is what the `queued` state is for. Emitted under
            # the lock (call_soon_threadsafe only schedules) so a _pump on
            # another thread cannot publish the dispatch of this same download
            # first and leave the client's last word "queued".
            self.bus.emit_threadsafe("download.progress", task.info())
        # synchronous, so the state is already right for a GET /v1/downloads
        # issued straight after the POST
        self._pump()
        self.bus.emit_threadsafe("models.changed", {})
        return task.id

    def families_in_flight(self) -> set[str]:
        """Families with any outstanding download — weights or runtime, running
        or queued. A family's venv must not be deleted while one of these is
        building or about to build it."""
        with self.lock:
            return {self.registry.models[t.model_id]["family"]
                    for t in self.tasks.values()
                    if t.model_id in self.registry.models}

    def provisioning_families(self) -> set[str]:
        """Families with a runtime install outstanding — running or waiting its
        turn. What makes every model of the family say "installing" at once,
        rather than only the row the install was started from."""
        with self.lock:
            return {self.registry.models[t.model_id]["family"]
                    for t in self.tasks.values()
                    if t.stage == "provisioning" and t.model_id in self.registry.models}

    def _pump(self) -> None:
        """Start as many waiting downloads as the budget allows, oldest first.
        Called on every arrival and every departure."""
        while True:
            with self.lock:
                if len(self.active) >= MAX_ACTIVE_DOWNLOADS or not self.pending:
                    return
                task = self.tasks.get(self.pending.pop(0))
                if task is None or task.cancelled:
                    continue
                self.active.add(task.id)
            family = self.registry.models[task.model_id]["family"]
            with task.lock:
                # Read at DISPATCH, not at submit: a download that waited its
                # turn can find its family already provisioned by the one ahead
                # of it, and announcing a provisioning step that will not happen
                # puts a spinner over nothing.
                # A runtime install provisions unconditionally: it was asked for
                # over its own endpoint, and `uv sync` over an up-to-date venv
                # is the cheap no-op that repairs a half-built one.
                provisioning = task.runtime_only or not envs.is_provisioned(family)
                task.state = "provisioning" if provisioning else "downloading"
                task.stage = "provisioning" if provisioning else "weights"
                # The message belongs to THIS event: a provisioning row draws a
                # message and no bar (contract 4.2), so dispatching with an
                # empty one leaves a blank spinner until uv says something,
                # which on a cold sync can be a while. Said here rather than
                # left to envs.ensure's callback for the same reason — that one
                # fires inside the per-family lock, so a second model of the
                # same family would sit on an empty row until the first install
                # finished.
                task.message = (f"Setting up the {family} runtime…"
                                if provisioning else "")
            # Also sampled at dispatch: the xet staging directory is shared, so
            # a baseline taken while the download ahead was still filling it
            # would count that one's bytes as ours. This is what serialising is
            # for — take the reading when we are the only writer.
            task.xet_baseline = self._xet_bytes()
            task.bytes_done = self.registry.cache_bytes(task.model_id)
            self.bus.emit_threadsafe("download.progress", task.info())
            threading.Thread(target=self._run, args=(task,), daemon=True).start()

    def list(self) -> list[dict]:
        with self.lock:
            return [t.info() for t in self.tasks.values()]

    def get(self, download_id: str) -> DownloadTask | None:
        with self.lock:
            return self.tasks.get(download_id)

    def active_for(self, model_id: str) -> DownloadTask | None:
        with self.lock:
            for t in self.tasks.values():
                if t.model_id == model_id:
                    return t
        return None

    def pause(self, task: DownloadTask) -> None:
        with task.lock:
            # `uv sync` is not resumable, and reporting "paused" over an
            # installer that is still unpacking wheels would be a lie. Nor is
            # there anything to suspend in a download that has not started.
            # Both are accepted and ignored (contract 4.2).
            if task.state in ("provisioning", "queued"):
                return
            task.state = "paused"
            task.speed_bps = 0   # a stopped transfer is not still moving
            if task.proc and task.proc.poll() is None:
                task.proc.send_signal(signal.SIGSTOP)
        self.bus.emit_threadsafe("download.progress", task.info())

    def resume(self, task: DownloadTask) -> None:
        with task.lock:
            if task.state in ("provisioning", "queued"):
                return
            task.state = "downloading"
            if task.proc and task.proc.poll() is None:
                task.proc.send_signal(signal.SIGCONT)
        self.bus.emit_threadsafe("download.progress", task.info())

    def cancel(self, task: DownloadTask) -> None:
        with task.lock:
            task.cancelled = True
            if task.proc and task.proc.poll() is None:
                task.proc.send_signal(signal.SIGCONT)
                task.proc.kill()
        # A download still waiting for its turn has no thread to notice the
        # flag, so _run's bookkeeping never runs for it: do it here. It holds no
        # slot, so nothing is freed and nothing else can start.
        with self.lock:
            started = task.id in self.active
            if not started:
                if task.id in self.pending:
                    self.pending.remove(task.id)
                self.tasks.pop(task.id, None)
        if not started:
            self.bus.emit_threadsafe("models.changed", {})

    # MARK: worker thread

    def _run(self, task: DownloadTask) -> None:
        model = self.registry.models[task.model_id]
        token = self.hf_token_provider()
        try:
            if task.stage == "provisioning":
                self._provision(task, model["family"])
            if task.cancelled:
                self.bus.emit_threadsafe("models.changed", {})
                return
            if task.runtime_only:
                # No weights, no marker: the model's install state is whatever
                # it already was, and only the family's runtime has changed.
                self.bus.emit_threadsafe("download.completed",
                                         {"download_id": task.id,
                                          "model_id": task.model_id,
                                          "runtime_only": True})
                self.bus.emit_threadsafe("models.changed", {})
                return
            total = self._total_bytes(model, token)
            if total:
                task.bytes_total = total
            for repo in model["hf_repos"]:
                self._download_repo(task, repo, token)
                if task.cancelled:
                    break
            if task.cancelled:
                self.bus.emit_threadsafe("models.changed", {})
                return
            final_bytes = self.registry.cache_bytes(task.model_id)
            self.registry.write_marker(task.model_id, final_bytes)
            self.registry.clear_attempt(task.model_id)
            self.bus.emit_threadsafe("download.completed",
                                     {"download_id": task.id,
                                      "model_id": task.model_id,
                                      "runtime_only": False})
            self.bus.emit_threadsafe("models.changed", {})
        except Exception as e:  # noqa: BLE001 — report any failure over SSE
            if task.cancelled:
                # killing the provisioning subprocess surfaces as a failure;
                # the user asked for it, so it is not one
                self.bus.emit_threadsafe("models.changed", {})
                return
            code = getattr(e, "code", "INTERNAL")
            # An authorization failure is not an interruption. Nothing of this
            # model's weights reached the disk (a gated repo serves only its
            # README and LICENSE), and retrying without access fails
            # identically — so leaving the attempt behind would offer a
            # "Resume download" that can never succeed. Cleared, the row goes
            # back to "Download" and the client can say what is actually
            # needed: the licence, accepted on the hub.
            if code == "UNAUTHORIZED":
                self.registry.clear_attempt(task.model_id)
            self.bus.emit_threadsafe(
                "download.failed",
                {"download_id": task.id, "model_id": task.model_id,
                 "error": {"code": code, "message": str(e)}})
            self.bus.emit_threadsafe("models.changed", {})
        finally:
            with self.lock:
                self.tasks.pop(task.id, None)
                self.active.discard(task.id)
            self._pump()

    def _provision(self, task: DownloadTask, family: str) -> None:
        """Build the family's adapter venv, reported on this download's events.

        First install of a family pulls a torch-sized dependency tree and really
        does take minutes; before this it ran unannounced at job time and the
        user watched a still screen. uv reports no progress of its own, so this
        emits one event per message it does print — there is nothing to count,
        and a synthetic bar would be worse than the spinner the app draws for
        `state: "provisioning"`.
        """
        def register(proc) -> None:
            with task.lock:
                task.proc = proc
                if task.cancelled:   # cancelled before uv got started
                    proc.kill()

        # The opening "Setting up the … runtime" line is on the dispatch event
        # in _pump, so this starts straight into uv's own messages.
        had_runtime = envs.is_provisioned(family)
        try:
            envs.ensure(family, progress=lambda m: self._provision_message(task, m),
                        on_proc=register)
        except BaseException:
            # uv creates the venv before it installs into it, so a cancelled or
            # failed sync leaves a directory with a python in it and no
            # packages. Left there it would answer "runtime installed" for a
            # runtime that imports nothing — the exact state this whole feature
            # exists to stop the user meeting at generation time.
            if not had_runtime:
                envs.remove(family)
            raise
        finally:
            with task.lock:
                task.proc = None
                # A runtime install has nothing to move on to, and saying
                # "downloading" over the moment it finishes would put a bar at
                # 0 / 0 bytes on the row for as long as the last event lives.
                if not task.runtime_only:
                    task.state = "downloading"
                    task.stage = "weights"

    def _provision_message(self, task: DownloadTask, message: str) -> None:
        with task.lock:
            task.message = message
        self.bus.emit_threadsafe("download.progress", task.info())

    def _total_bytes(self, model: dict, token: str | None) -> int | None:
        try:
            api = HfApi(token=token)
            total = 0
            for repo in model["hf_repos"]:
                info = api.model_info(repo["repo_id"], files_metadata=True)
                pats = repo.get("allow_patterns")
                for s in info.siblings:
                    if pats and not any(fnmatch.fnmatch(s.rfilename, p)
                                        for p in pats):
                        continue
                    total += s.size or 0
            return total or None
        except Exception:  # noqa: BLE001 — size is best-effort; catalog estimate stands
            return None

    def _download_repo(self, task: DownloadTask, repo: dict,
                       token: str | None) -> None:
        repo_id = repo["repo_id"]
        env = {**os.environ, "HF_HOME": self.registry.settings.hf_cache_dir,
               "HF_HUB_DISABLE_TELEMETRY": "1"}
        if token:
            env["HF_TOKEN"] = token
        cmd = [sys.executable, "-m", "supervisor.download_worker",
               "--repo", repo_id]
        if repo.get("allow_patterns"):
            cmd += ["--patterns", json.dumps(repo["allow_patterns"])]
        attempts = 0
        while True:
            if task.cancelled:
                return
            with task.lock:
                task.message = f"fetching {repo_id}"
                proc = subprocess.Popen(
                    cmd, env=env, stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE)
                task.proc = proc
                if task.state == "paused":
                    proc.send_signal(signal.SIGSTOP)

            last_bytes, last_t = task.bytes_done, time.monotonic()
            while proc.poll() is None:
                time.sleep(SAMPLE_INTERVAL)
                if task.state == "paused":
                    # keep the rate window anchored to the pause: leaving it
                    # behind makes the first sample after resume divide one
                    # interval's bytes by the whole paused duration, and the
                    # download reads as stalled just as it restarts
                    last_bytes, last_t = task.bytes_done, time.monotonic()
                    continue
                done = self.registry.cache_bytes(task.model_id) + max(
                    0, self._xet_bytes() - task.xet_baseline)
                now = time.monotonic()
                task.speed_bps = max(0, int((done - last_bytes) / max(0.1, now - last_t)))
                last_bytes, last_t = done, now
                task.bytes_done = min(done, task.bytes_total)
                self.bus.emit_threadsafe("download.progress", task.info())

            if task.cancelled:
                return
            if proc.returncode == 0:
                return
            stderr = (proc.stderr.read() if proc.stderr else b"").decode()[-2000:]
            attempts += 1
            if attempts > MAX_RETRIES:
                if "401" in stderr or "403" in stderr or "gated" in stderr.lower():
                    raise DownloadError(
                        "UNAUTHORIZED",
                        f"{repo_id} is gated — add a Hugging Face token with access")
                raise DownloadError("INTERNAL",
                                    f"download of {repo_id} failed: {stderr[-300:]}")
            time.sleep(2 * attempts)

#!/usr/bin/env python3
"""Verification of the REAL supervisor. Grows with each engine milestone.

M1 scope: bootstrap handshake, auth, /v1/system, SSE heartbeats, parent-death
watchdog, /v1/shutdown, SIGTERM.

Usage: python3 scripts/verify_engine.py
"""

from __future__ import annotations

import hashlib
import glob
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time

from contractlib import (Client, SSEListener, check, click_wav, onset_frames,
                         peak_between, report, tone_wav, wav_duration_s)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUP = os.path.join(ROOT, "engine", "supervisor")


def spawn(tmp: str, token: str, parent_pid: int,
          extra_env: dict | None = None, stderr=subprocess.PIPE) -> subprocess.Popen:
    handshake = os.path.join(tmp, "handshake.json")
    if os.path.exists(handshake):
        os.unlink(handshake)
    return subprocess.Popen(
        ["uv", "run", "local-music-engine",
         "--handshake-file", handshake, "--parent-pid", str(parent_pid),
         "--data-dir", os.path.join(tmp, "data"),
         "--output-dir", os.path.join(tmp, "outputs"),
         "--log-level", "warning"],
        cwd=SUP, env={**os.environ, "LOCALMUSIC_AUTH_TOKEN": token,
                      "LOCALMUSIC_TEST_CATALOG": "1",
                      # never the shared system cache: the suite downloads AND
                      # deletes repos (rmtree)
                      "HF_HOME": os.path.join(tmp, "data", "hf-cache"),
                      **(extra_env or {})},
        stderr=stderr, stdout=subprocess.PIPE)


def _choices_of(model: dict, key: str) -> set[str]:
    for param in model["capabilities"]["params"]:
        if param["key"] == key:
            return {c["value"] for c in param.get("choices") or []}
    return set()


def wait_handshake(tmp: str, proc: subprocess.Popen) -> dict | None:
    handshake = os.path.join(tmp, "handshake.json")
    deadline = time.time() + 60
    while time.time() < deadline:
        if os.path.exists(handshake):
            return json.load(open(handshake))
        if proc.poll() is not None:
            print(proc.stderr.read().decode())
            return None
        time.sleep(0.1)
    return None


class _PoolWorker:
    """Stand-in for a Worker in the warm-pool logic checks below."""

    def __init__(self, family: str, idle_since: float | None,
                 alive: bool = True) -> None:
        self.family = family
        self.idle_since = idle_since
        self.loaded_model_id = f"model-{family}"
        self.current_job_id = None if idle_since is not None else "job_x"
        self._alive = alive
        self.killed = False

    def is_alive(self) -> bool:
        return self._alive and not self.killed

    def kill(self) -> None:
        self.killed = True


def check_warm_pool_logic() -> None:
    """The pool's rules, without spawning anything.

    Eviction order and TTL expiry are pure bookkeeping, and exercising them
    through real jobs would need a second runnable adapter family plus a
    ten-minute wait. These call the helpers directly instead.
    """
    print("• warm pool policy (logic)")
    sys.path.insert(0, os.path.join(SUP, "src"))
    from supervisor import jobqueue as jq

    def queue_with(pool: dict) -> "jq.JobQueue":
        q = object.__new__(jq.JobQueue)   # no runner thread, no registry
        q.small_workers = dict(pool)
        return q

    slots, ttl = jq.SMALL_WARM_SLOTS, jq.SMALL_WARM_TTL_S
    check("defaults are two warm slots and a 10-minute idle life",
          slots == 2 and ttl == 600, f"{slots} slots / {ttl}s")

    now = 1000.0
    # least-recently-used goes first
    q = queue_with({"analysis": _PoolWorker("analysis", now - 30),
                    "dsp": _PoolWorker("dsp", now - 5)})
    oldest = q.small_workers["analysis"]
    q._make_room_locked()
    check("a full pool evicts the least recently used",
          "analysis" not in q.small_workers and oldest.killed
          and "dsp" in q.small_workers, str(list(q.small_workers)))

    # a worker mid-job has idle_since None and must survive
    busy_a = _PoolWorker("analysis", None)
    busy_b = _PoolWorker("dsp", None)
    q = queue_with({"analysis": busy_a, "dsp": busy_b})
    q._make_room_locked()
    check("a worker running a job is never evicted",
          not busy_a.killed and not busy_b.killed
          and len(q.small_workers) == 2)

    # TTL: past its welcome goes, fresh stays, and the deadline is the next one
    stale = _PoolWorker("analysis", now - ttl - 1)
    fresh = _PoolWorker("dsp", now - 10)
    q = queue_with({"analysis": stale, "dsp": fresh})
    deadline = q._expire_small_locked(now)
    check("an idle worker past the TTL is dropped",
          stale.killed and "analysis" not in q.small_workers)
    check("one still inside the TTL is kept",
          not fresh.killed and "dsp" in q.small_workers)
    check("expiry reports when the next one is due",
          deadline == fresh.idle_since + ttl, str(deadline))

    # a worker that died on its own is reaped rather than reported warm
    dead = _PoolWorker("analysis", now - 1, alive=False)
    q = queue_with({"analysis": dead})
    q._expire_small_locked(now)
    check("a dead worker is dropped from the pool",
          "analysis" not in q.small_workers)

    # nothing idle to expire ⇒ no deadline, so the runner sleeps indefinitely
    q = queue_with({"dsp": _PoolWorker("dsp", None)})
    check("a pool with nothing idle asks for no wake-up",
          q._expire_small_locked(now) is None)


def check_retention_logic() -> None:
    """Outputs sweeping and job-history trimming, without an engine.

    Both are pure enough to drive with staged mtimes and stand-in jobs; the
    live daily loop only strings these together with a sleep.
    """
    print("• retention policy (logic)")
    sys.path.insert(0, os.path.join(SUP, "src"))
    from supervisor import jobqueue as jq
    from supervisor.retention import outputs_retention_days, sweep_outputs

    check("retention defaults to 14 days when the env is unset",
          "LOCALMUSIC_OUTPUTS_RETENTION_DAYS" not in os.environ
          and outputs_retention_days() == 14)

    out = tempfile.mkdtemp(prefix="localmusic-verify-retention-")
    now = time.time()
    old_age = now - 20 * 86400
    for name, mtime in (("job_old", old_age), ("job_live", old_age),
                        ("job_new", now - 3600)):
        d = os.path.join(out, name)
        os.makedirs(d)
        with open(os.path.join(d, "take-0.wav"), "wb") as f:
            f.write(b"RIFF")
        os.utime(d, (mtime, mtime))
    with open(os.path.join(out, "stray.txt"), "w") as f:
        f.write("not ours")
    os.utime(os.path.join(out, "stray.txt"), (old_age, old_age))

    removed = sweep_outputs(out, 14, keep={"job_live"}, now=now)
    left = sorted(os.listdir(out))
    check("aged output dirs are removed, live and fresh ones kept",
          removed == ["job_old"] and "job_live" in left and "job_new" in left,
          f"removed={removed} left={left}")
    check("stray top-level files are not the sweep's to delete",
          "stray.txt" in left)
    check("retention 0 keeps everything",
          sweep_outputs(out, 0, now=now) == []
          and sorted(os.listdir(out)) == left)

    class _Job:
        def __init__(self, jid: str, status: str, created_at: str) -> None:
            self.id, self.status, self.created_at = jid, status, created_at

    q = object.__new__(jq.JobQueue)   # no runner thread, no registry
    q.jobs = {}
    for i in range(5):
        jid = f"job_{i}"
        q.jobs[jid] = _Job(jid, "succeeded", f"2026-08-0{i + 1}T00:00:00Z")
    q.jobs["job_run"] = _Job("job_run", "generating", "2026-08-01T00:00:00Z")
    cap = jq.JOB_HISTORY_CAP
    try:
        jq.JOB_HISTORY_CAP = 4
        q._trim_history_locked()
        check("history trim evicts the oldest terminal jobs past the cap",
              sorted(q.jobs) == ["job_2", "job_3", "job_4", "job_run"],
              str(sorted(q.jobs)))
        jq.JOB_HISTORY_CAP = 1
        q._trim_history_locked()
        check("a running job is never evicted, even over the cap",
              "job_run" in q.jobs, str(sorted(q.jobs)))
        jq.JOB_HISTORY_CAP = 0
        before = dict(q.jobs)
        q._trim_history_locked()
        check("cap 0 disables history trimming", q.jobs == before)
    finally:
        jq.JOB_HISTORY_CAP = cap
    check("history cap defaults to 200", cap == 200, str(cap))


def check_catalog_curation() -> None:
    """The shipped catalog's curation, which no runtime test would notice.

    `featured` is what the Models screen shows before you open "Show all", and
    it is also the only thing standing between a fresh install and a user who
    cannot find the 200 MB of auxiliary models that half the app depends on.
    Two rules keep that honest, and both fail silently in the UI.
    """
    print("• catalog curation")
    import re

    catalog = json.load(open(os.path.join(ROOT, "engine", "catalog",
                                          "models.json")))
    models = catalog["models"]
    by_id = {m["id"]: m for m in models}
    featured = [m for m in models if m.get("featured")]

    # ModelListLayout.plan places a *group* by whether its base id is
    # recommended and never consults a variant's own flag, so featuring a
    # variant changes nothing on screen — the most plausible future mistake.
    strays = [m["id"] for m in featured if m.get("variant_of")]
    check("every featured model is a base, not a variant",
          not strays, f"variants marked featured: {strays}")

    # A task with no featured model is a feature the user cannot discover.
    # ("plan" is deliberately absent: it rides the featured generate models.
    # The music-to-text tasks — tag, lyrics, caption, compose — join this
    # list one by one, in the same change that lands each task's featured
    # catalog entry, so the check never fails against work not yet done.)
    tasks = ["generate", "analyze", "separate", "transcribe", "mix", "render",
             "assist", "tag", "lyrics", "caption", "compose"]
    covered = {t for m in featured
               for t in (m["capabilities"].get("tasks") or ["generate"])}
    check("every task has at least one featured model",
          set(tasks) <= covered, f"uncovered: {sorted(set(tasks) - covered)}")

    # Cards name their preferred model by id (`prefersModelIds`). A typo there
    # is invisible at run time — the card opens on whatever else can do the
    # job — so it is checked here, against the catalog, which the app's own
    # tests cannot see. Ids for models that have not shipped yet are listed in
    # PENDING_PREFERRED and expected to be absent; a pending id that turns up
    # in the catalog should be taken off the list.
    PENDING_PREFERRED: set[str] = set()
    recipe_src = open(os.path.join(ROOT, "app", "LocalMusic", "Features",
                                   "SplitRecombine",
                                   "RecipeCatalog.swift")).read()
    preferred: list[str] = []
    for block in re.findall(r"prefersModelIds: \[(.*?)\]", recipe_src, re.S):
        preferred += re.findall(r'"([^"]+)"', block)
    unknown = [i for i in preferred
               if i not in by_id and i not in PENDING_PREFERRED]
    check("every card's preferred model exists in the catalog",
          not unknown, f"unknown ids: {unknown}")
    arrived = sorted(PENDING_PREFERRED & set(by_id))
    check("no pending preferred id has quietly shipped",
          not arrived,
          f"now in the catalog, remove from PENDING_PREFERRED: {arrived}")

    # The first-run sheet installs by id; a renamed catalog entry would silently
    # drop a model from onboarding rather than fail anywhere visible.
    plan_src = open(os.path.join(ROOT, "app", "LocalMusic", "Features",
                                 "Onboarding", "OnboardingPlan.swift")).read()
    plan_ids = []
    for block in re.findall(r"static let \w+Ids = \[(.*?)\]", plan_src, re.S):
        plan_ids += re.findall(r'"([^"]+)"', block)
    check("OnboardingPlan names some models", len(plan_ids) >= 8,
          f"{len(plan_ids)} ids")
    unknown = [i for i in plan_ids if i not in by_id]
    check("every model onboarding installs exists in the catalog",
          not unknown, f"unknown ids: {unknown}")

    # Onboarding deliberately avoids gated repos: a token in the Keychain is
    # the wrong thing to demand in the first minute of the app.
    gated = [i for i in plan_ids
             if any(r.get("gated") for r in by_id.get(i, {}).get("hf_repos", []))]
    check("nothing onboarding installs is gated", not gated, f"gated: {gated}")

    # Every control the parameter panel renders says what it does, under the
    # control itself. A param with no `help` draws a bare slider with a jargon
    # label — which is what Studio's "Full control" was for months, and is
    # invisible from the engine side because the job still submits fine.
    # build_catalog raises on this too; the check is here because the catalog
    # is a checked-in artifact that can be hand-edited without re-running it.
    unexplained = [f"{m['id']}.{p['key']}" for m in models
                   for p in m["capabilities"].get("params", [])
                   if not p.get("internal") and not p.get("help")]
    check("every rendered param explains itself", not unexplained,
          f"no help: {unexplained[:6]}")

    # --- Style Transfer -----------------------------------------------------
    # Every mode of the workspace has to be reachable by *some* model in the
    # catalog, and the modes a default install can serve have to be reachable
    # without a Hugging Face token. Neither fails visibly: an unreachable mode
    # is drawn dimmed with a plausible-looking reason under it, which is
    # indistinguishable from a mode the user simply has not installed for yet.
    def declares(model, key):
        return any(p["key"] == key for p in model["capabilities"]["params"])

    def offers_task(model, value):
        for p in model["capabilities"]["params"]:
            if p["key"] == "task_type":
                return any(c["value"] == value
                           for c in (p.get("choices") or []))
        return False

    def generative(model):
        return "generate" in (model["capabilities"].get("tasks") or ["generate"])

    # Keyed exactly as StyleTransferMode.requirements is, so the two cannot
    # drift apart without this failing.
    style_modes = {
        "cover": lambda m: offers_task(m, "cover"),
        "reference": lambda m: (declares(m, "reference_audio")
                                or declares(m, "style_audio")),
        "melody": lambda m: declares(m, "melody_audio"),
        "morph": lambda m: declares(m, "flow_edit_morph"),
        "shape": lambda m: declares(m, "init_audio"),
        "stems": lambda m: offers_task(m, "cover"),
        "repaint": lambda m: offers_task(m, "repaint"),
        "complete": lambda m: offers_task(m, "complete"),
        "continue": lambda m: declares(m, "extend_audio"),
        "layer": lambda m: offers_task(m, "lego"),
        "extract": lambda m: offers_task(m, "extract"),
    }
    for mode, matches in style_modes.items():
        servers = [m["id"] for m in models if generative(m) and matches(m)]
        check(f"some model can serve style mode '{mode}'", servers,
              "no model in the catalog declares it")

    # Onboarding's own generators, against the same predicates.
    onboarding = [by_id[i] for i in plan_ids if i in by_id]
    reachable = {mode for mode, matches in style_modes.items()
                 for m in onboarding if generative(m) and matches(m)}
    # These four are what a default install buys, and are the reason
    # acestep-15-dit-base is offered: extract/layer/complete need a Base or SFT
    # DiT and are unreachable without one.
    for mode in ("cover", "reference", "repaint", "morph", "stems",
                 "extract", "layer", "complete"):
        check(f"a default install can serve style mode '{mode}'",
              mode in reachable,
              f"reachable from onboarding: {sorted(reachable)}")

    # The chain needs a separator and a real mixdown, both from onboarding.
    def has_task(model, task):
        return task in (model["capabilities"].get("tasks") or ["generate"])
    check("onboarding installs a separation model",
          any(has_task(m, "separate") for m in onboarding))
    check("onboarding installs a mixdown model",
          any(has_task(m, "mix") and declares(m, "mix_spec")
              for m in onboarding))

    # A style excerpt needs the feature extractor the conditioner builds at load
    # time; without it declared, the first style generation stops mid-job to
    # download a model the install never accounted for. The shipped
    # musicgen-style checkpoint asks for MERT, not the EnCodec whose checkpoint
    # path sits unused beside it in the same config block.
    for m in models:
        if (m.get("settings") or {}).get("style"):
            repos = [r["repo_id"] for r in m["hf_repos"]]
            check(f"{m['id']} declares its style feature extractor",
                  "m-a-p/MERT-v1-95M" in repos, f"repos: {repos}")

    # Which style modes a user without a Hugging Face token can reach. Not an
    # assertion — Stable Audio is gated upstream and there is nothing the
    # catalog can do about it — but a change that quietly moved a mode behind a
    # token would otherwise be invisible.
    def token_free(model):
        return not any(r.get("gated") for r in model["hf_repos"])

    tokenless = {mode for mode, matches in style_modes.items()
                 for m in models
                 if generative(m) and token_free(m) and matches(m)}
    gated_only = sorted(set(style_modes) - tokenless)
    print(f"    style modes needing a Hugging Face token: "
          f"{gated_only or 'none'}")

    # A false applies_when is worse than none: it dims the control *and* keeps
    # sending it. Upstream honours this one on every task with a source.
    liars = [m["id"] for m in models
             for p in m["capabilities"]["params"]
             if p["key"] == "audio_cover_strength" and p.get("applies_when")]
    check("audio_cover_strength claims no false task scope", not liars,
          f"declares applies_when: {liars}")


def check_adapter_binaries() -> None:
    """Prebuilt helper executables load their libraries from beside themselves.

    acestep.cpp is compiled by scripts/build_acestep_cpp.sh and shipped as
    binaries in engine/adapters/acestepcpp/bin/. cmake bakes an ABSOLUTE
    LC_RPATH pointing at its own build tree, and for a while only the three
    executables were copied out — so they loaded libggml*.dylib across a path
    in the developer's home directory. That works on the machine that compiled
    them, right up until the checkout moves, and it has never worked inside the
    .app at all. The symptom is a job that dies with `dyld: Library not loaded`
    and exit -6, which reaches the user as a red queue row and nothing else.

    Two invariants, both cheap: nothing in bin/ may name a path outside itself,
    and the libraries it asks for have to be there.
    """
    print("• adapter binaries")
    adapters = os.path.join(ROOT, "engine", "adapters")
    if not os.path.isdir(adapters):
        return
    bins = sorted(glob.glob(os.path.join(adapters, "*", "bin", "*")))
    machos, absolute, missing = [], [], []
    for path in bins:
        if os.path.basename(path).startswith("."):
            continue
        head = open(path, "rb").read(4)
        if head not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
            continue          # not Mach-O (a README, a revision stamp)
        machos.append(path)
        out = subprocess.run(["otool", "-l", path], capture_output=True,
                             text=True).stdout
        lines = out.splitlines()
        for i, line in enumerate(lines):
            if "LC_RPATH" not in line:
                continue
            for follow in lines[i:i + 4]:
                parts = follow.split()
                if len(parts) >= 2 and parts[0] == "path":
                    if not parts[1].startswith("@"):
                        absolute.append(f"{os.path.basename(path)} → {parts[1]}")
                    break
        deps = subprocess.run(["otool", "-L", path], capture_output=True,
                              text=True).stdout
        for dep in re.findall(r"@rpath/(\S+)", deps):
            if not os.path.exists(os.path.join(os.path.dirname(path), dep)):
                missing.append(f"{os.path.basename(path)} needs {dep}")

    check("adapter bin/ holds Mach-O binaries to check", bool(machos),
          "found none — has the acestep.cpp build been run?")
    check("no adapter binary has an absolute rpath", not absolute,
          f"{absolute[:4]}")
    check("every @rpath library sits beside its binary", not missing,
          f"{sorted(set(missing))[:4]}")


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="localmusic-verify-engine-")
    token = secrets.token_hex(16)

    check_catalog_curation()
    check_adapter_binaries()
    check_warm_pool_logic()
    check_retention_logic()

    print("• bootstrap & system")
    proc = spawn(tmp, token, os.getpid())
    try:
        hs = wait_handshake(tmp, proc)
        check("handshake file appears", hs is not None)
        if hs is None:
            return report()
        check("handshake has port/pid/version/contract",
              all(k in hs for k in ("port", "pid", "version", "contract")))
        c = Client(hs["port"], token)

        status, body = c.req("GET", "/healthz", auth=False)
        check("GET /healthz without auth", status == 200 and body["status"] == "ok")
        status, body = c.req("GET", "/v1/system", auth=False)
        check("401 without bearer token",
              status == 401 and body["error"]["code"] == "UNAUTHORIZED")
        status, body = c.req("GET", "/v1/system")
        check("GET /v1/system", status == 200 and body["ram_bytes"] > 0
              and body["free_disk_bytes"] > 0 and body["machine"])
        # contract 3: no worker yet, so every memory figure must be null —
        # reporting 0 would draw a confident lie in the app's sidebar
        usage = body.get("usage") or {}
        check("telemetry reports nothing rather than zero when idle",
              "worker_bytes" in usage and usage["worker_bytes"] is None
              and usage["accelerator_bytes"] is None
              and (usage["gpu_percent"] is None
                   or 0 <= usage["gpu_percent"] <= 100), str(usage))
        check("data dirs created",
              all(os.path.isdir(os.path.join(tmp, "data", d))
                  for d in ("hf-cache", "envs")))
        status, _ = c.req("POST", "/v1/settings/hf-token", {"token": "hf_x"})
        check("POST hf-token", status == 204)

        print("• SSE (heartbeat wait ~16 s)")
        sse = SSEListener(hs["port"], token)
        sse.start()
        deadline = time.time() + 20
        while time.time() < deadline and sse.heartbeats == 0:
            time.sleep(0.25)
        check("SSE heartbeat within 20 s", sse.heartbeats > 0)

        print("• catalog & downloads (real HF, tiny repo)")
        status, body = c.req("GET", "/v1/models")
        models = {m["id"]: m for m in body.get("models", [])}
        check("catalog served with test model",
              status == 200 and "test-tiny" in models and len(models) >= 6)
        check("catalog entries carry capabilities + params",
              all("params" in m["capabilities"] and "license" in m
                  for m in models.values()))
        real = [m for m in models.values() if not m["id"].startswith("test-")]
        check("catalog entries carry usage tags",
              all(m.get("tags") for m in real),
              str([m["id"] for m in real if not m.get("tags")][:5]))
        # contract 4.1: every generation model sorts its controls into named
        # sections; task-only entries deliberately declare none and let the app
        # classify the two or three controls they have
        gen = [m for m in real
               if "generate" in (m["capabilities"].get("tasks") or ["generate"])]
        ungrouped = [(m["id"], p["key"]) for m in gen
                     for p in m["capabilities"]["params"]
                     if p.get("group") not in ("sampling", "musical", "task")]
        check("generation params declare a known group", not ungrouped,
              str(ungrouped[:5]))
        # contract 5.6: exactly the entries whose adapter can decode audio the
        # model has GENUINELY produced part-way through. Spelled out as a family
        # rule rather than an id list so an adapter gaining or losing the
        # ability shows up here as a mismatch instead of drifting quietly — the
        # transformers/MLX split inside `musicgen` is the whole reason this is
        # declared per model.
        def can_preview(m: dict) -> bool:
            caps = m["capabilities"]
            if "generate" not in (caps.get("tasks") or ["generate"]):
                return False
            if m["family"] in ("stableaudio", "stableaudio3", "diffusers"):
                return True
            return (m["family"] == "musicgen"
                    and (m.get("settings") or {}).get("backend") == "mlx")

        wrong = [m["id"] for m in real
                 if bool(m["capabilities"].get("supports_preview"))
                 != can_preview(m)]
        check("preview support is declared exactly where it is real",
              not wrong, str(wrong[:5]))
        check("preview support is never declared by a task model",
              not [m["id"] for m in real
                   if m["capabilities"].get("supports_preview")
                   and "generate" not in (m["capabilities"].get("tasks")
                                          or ["generate"])])
        check("task-only entries leave grouping to the app",
              all("group" not in p for m in real for p in m["capabilities"]["params"]
                  if "generate" not in (m["capabilities"].get("tasks") or ["generate"])))
        # a gate naming a value its param never offers would dim the control
        # for good — the ACE-Step turbo DiTs drop three of the six tasks
        bad_gate = [(m["id"], p["key"]) for m in gen
                    for p in m["capabilities"]["params"]
                    if p.get("applies_when")
                    and not set(p["applies_when"]["values"])
                    <= _choices_of(m, p["applies_when"]["param"])]
        check("applies_when only names values its param offers", not bad_gate,
              str(bad_gate[:5]))
        check("catalog install states resolve",
              all(m["install_state"] in
                  ("not_installed", "partial", "installed", "downloading")
                  for m in models.values()))
        status, _ = c.req("GET", "/v1/models/nope")
        check("404 unknown model", status == 404)

        status, body = c.req("POST", "/v1/models/test-tiny/download")
        check("start download", status == 202 and "download_id" in body)
        done = sse.wait_for("download.completed", 120,
                            lambda d: d["model_id"] == "test-tiny")
        check("download.completed (real snapshot)", done is not None)
        got_progress = sse.wait_for("download.progress", 1,
                                    lambda d: d["model_id"] == "test-tiny")
        check("download.progress events seen", got_progress is not None)
        # the app draws the bar off these three and derives its own ETA, so a
        # missing or negative one is a broken row rather than a slow one
        check("download.progress carries byte counters and a rate",
              got_progress is not None and got_progress["bytes_total"] > 0
              and got_progress["bytes_done"] >= 0
              and got_progress["speed_bps"] >= 0, str(got_progress))
        _, body = c.req("GET", "/v1/models/test-tiny")
        check("model installed with bytes",
              body["install_state"] == "installed" and body["installed_bytes"] > 0)
        # test-tiny-shared points at the same repo, so its content is now on
        # disk — but the user never asked for it, so it must not masquerade as
        # an interrupted download ("Resume download" on a never-touched model)
        _, body = c.req("GET", "/v1/models/test-tiny-shared")
        check("untouched model sharing an installed repo stays not_installed",
              body["install_state"] == "not_installed", body["install_state"])

        status, _ = c.req("DELETE", "/v1/models/test-tiny")
        check("delete model accepted", status == 202)
        _, body = c.req("GET", "/v1/models/test-tiny")
        check("model deleted", body["install_state"] == "not_installed")

        # pause/resume flow on a fresh download of the same tiny repo
        mark = sse.mark()
        status, body = c.req("POST", "/v1/models/test-tiny/download")
        dl_id = body["download_id"]
        def download_row(want: str, tries: int = 200) -> dict | None:
            row = None
            for _ in range(tries):
                _, listing = c.req("GET", "/v1/downloads")
                row = next((d for d in listing["downloads"]
                            if d["download_id"] == dl_id), None)
                if row is None or row["state"] == want:
                    return row
                time.sleep(0.05)
            return row

        # Pause is a documented no-op on a download that is still `queued` or
        # still provisioning its runtime (4.2), so the transfer has to be the
        # thing that is running before pausing it means anything. Firing the
        # pause immediately after the POST raced the dispatcher: usually it
        # landed, sometimes it was correctly ignored and this check failed on a
        # download that had never been paused at all.
        row = download_row("downloading")
        check("transfer under way before pausing",
              row is not None and row["state"] == "downloading", str(row))
        status, _ = c.req("POST", f"/v1/downloads/{dl_id}/pause")
        check("pause accepted", status == 202)
        row = download_row("paused", tries=40)
        check("paused state visible", row is not None and row["state"] == "paused",
              str(row))
        status, _ = c.req("POST", f"/v1/downloads/{dl_id}/resume")
        check("resume accepted", status == 202)
        done = sse.wait_for("download.completed", 120,
                            lambda d: d["model_id"] == "test-tiny", since=mark)
        check("resumed download completes", done is not None)

        # cancel flow
        c.req("DELETE", "/v1/models/test-tiny")
        status, body = c.req("POST", "/v1/models/test-tiny/download")
        dl_id = body["download_id"]
        status, _ = c.req("DELETE", f"/v1/downloads/{dl_id}")
        check("cancel accepted", status == 202)
        time.sleep(1.5)
        _, body = c.req("GET", "/v1/downloads")
        check("canceled download gone from list",
              all(d["download_id"] != dl_id for d in body["downloads"]))

        print("• jobs (real worker on tiny model)")
        mark = sse.mark()
        c.req("POST", "/v1/models/test-tiny/download")
        done = sse.wait_for("download.completed", 120,
                            lambda d: d["model_id"] == "test-tiny", since=mark)
        check("test model reinstalled", done is not None)

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["acestep-base"], "prompt": "x"})
        check("409 MODEL_NOT_INSTALLED",
              status == 409 and body["error"]["code"] == "MODEL_NOT_INSTALLED")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "x", "lyrics": "la"})
        check("422 lyrics on instrumental model",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny", "test-tiny"], "prompt": "x"})
        check("422 on multi-model submission",
              status == 422 and body["error"]["code"] == "VALIDATION")
        # contract 5.6: test-tiny runs the transformers MusicGen adapter, which
        # cannot decode a real partial take — refused, not silently ignored, so
        # nobody waits for frames that are never coming
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "x", "preview": True})
        check("422 preview on a model that cannot",
              status == 422 and body["error"]["code"] == "VALIDATION")

        # three serial jobs; cancel one queued, let the others run
        ids = []
        for _ in range(3):
            _, body = c.req("POST", "/v1/jobs", {
                "model_ids": ["test-tiny"], "prompt": "serial check",
                "duration_s": 2, "params": {"bogus": 1}})
            ids.append(body["jobs"][0]["job_id"])
        _, info = c.req("GET", f"/v1/jobs/{ids[2]}")
        check("third job queued behind the others",
              info["status"] == "queued" and info["queue_position"] >= 1)
        dropped = sse.wait_for("job.log", 10,
                               lambda d: "bogus" in d.get("line", ""))
        check("unknown param dropped via job.log", dropped is not None)
        status, _ = c.req("POST", f"/v1/jobs/{ids[1]}/cancel")
        canceled = sse.wait_for("job.canceled", 10,
                                lambda d: d["job_id"] == ids[1])
        check("cancel queued job", status == 202 and canceled is not None)

        finished = sse.wait_for("job.completed", 600,
                                lambda d: d["job_id"] == ids[2])
        check("queue drains through to the last job", finished is not None)
        _, job = c.req("GET", f"/v1/jobs/{ids[0]}")
        check("first job succeeded", job["status"] == "succeeded")
        out = job["result"]["outputs"][0]
        check("output WAV exists", os.path.exists(out["path"]))
        status, body = c.req("POST", f"/v1/jobs/{ids[0]}/cancel")
        check("409 cancel terminal job",
              status == 409 and body["error"]["code"] == "JOB_NOT_CANCELABLE")

        # contract 5.5: several takes are ONE job rendering them one after
        # another, and `take` is the only thing on the wire that says which one
        # is running — `fraction` is the average across all of them, and null
        # for adapters that cannot count at all. Every counter in the app
        # reported a four-take render as a single piece of work until this
        # existed.
        mark = sse.mark()
        _, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "two takes",
            "duration_s": 2, "count": 2})
        multi = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 600,
                                lambda d: d["job_id"] == multi)
        check("multi-take job completes", finished is not None)
        _, job = c.req("GET", f"/v1/jobs/{multi}")
        check("a count:2 job returns two outputs",
              len(((job.get("result") or {}).get("outputs")) or []) == 2,
              str(job.get("result")))
        multi_events = [d for _, e, d in sse.events[mark:]
                        if e == "job.progress" and d["job_id"] == multi]
        gen_takes = [d["take"] for d in multi_events
                     if d["stage"] == "generating"]
        check("job.progress names the take it is rendering",
              bool(gen_takes) and set(gen_takes) == {0, 1}, str(gen_takes[:8]))
        # Monotonic: an index that went backwards would draw the render walking
        # back through takes it had already finished.
        check("take never goes backwards",
              all(b >= a for a, b in zip(gen_takes, gen_takes[1:])),
              str(gen_takes))
        encode_takes = [d["take"] for d in multi_events
                        if d["stage"] == "encoding"]
        check("the final encode stays on the last take rather than blanking",
              bool(encode_takes) and all(t == 1 for t in encode_takes),
              str(encode_takes))

        time.sleep(3)
        ps = subprocess.run(["pgrep", "-f", f"engine_protocol.worker_main.*--parent-pid {hs['pid']}"],
                            capture_output=True, text=True)
        check("worker stays resident after queue drains", ps.stdout.strip() != "")
        _, body = c.req("GET", "/v1/system")
        check("system reports resident model",
              body.get("warm_model_id") == "test-tiny")
        # contract 3: with a live worker the telemetry is real — a footprint
        # read out of libproc, and the backend the worker reported for itself
        usage = body.get("usage") or {}
        accel = body.get("accelerator") or {}
        check("telemetry measures the live worker",
              (usage.get("worker_bytes") or 0) > 100_000_000, str(usage))
        check("telemetry names the backend the worker chose",
              accel.get("backend") in ("mlx", "metal", "cpu")
              and (accel.get("working_set_bytes") or 0) > 0, str(accel))
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/worker/unload")
        stopped = sse.wait_for("worker.state", 10,
                               lambda d: d["state"] == "stopped", since=mark)
        check("explicit unload stops the worker",
              status == 202 and stopped is not None)
        time.sleep(1)
        ps = subprocess.run(["pgrep", "-f", f"engine_protocol.worker_main.*--parent-pid {hs['pid']}"],
                            capture_output=True, text=True)
        check("worker gone after unload", ps.stdout.strip() == "")

        print("• shared-repo delete safety")
        mark = sse.mark()
        c.req("POST", "/v1/models/test-tiny-shared/download")
        done = sse.wait_for("download.completed", 120,
                            lambda d: d["model_id"] == "test-tiny-shared",
                            since=mark)
        check("shared-repo model installs (cache hit)", done is not None)
        status, _ = c.req("DELETE", "/v1/models/test-tiny-shared")
        check("shared-repo model deleted", status == 202)
        _, body = c.req("GET", "/v1/models/test-tiny")
        check("sibling model survives shared-repo delete",
              body.get("install_state") == "installed")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "still works after delete",
            "duration_s": 2})
        shared_job = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == shared_job)
        check("sibling model still generates", finished is not None)

        print("• pattern-scoped download (allow_patterns)")
        mark = sse.mark()
        c.req("POST", "/v1/models/test-tiny-patterns/download")
        done = sse.wait_for("download.completed", 120,
                            lambda d: d["model_id"] == "test-tiny-patterns",
                            since=mark)
        check("pattern-scoped model installs", done is not None)
        _, body = c.req("GET", "/v1/models/test-tiny-patterns")
        check("pattern-scoped model reports installed",
              body.get("install_state") == "installed")
        pat_repo = os.path.join(
            tmp, "data", "hf-cache", "hub",
            "models--hf-internal-testing--tiny-random-T5ForConditionalGeneration",
            "snapshots")
        pat_files = set()
        for root, _dirs, files in os.walk(pat_repo):
            pat_files.update(files)
        check("matching files downloaded", "config.json" in pat_files)
        check("non-matching files excluded",
              "pytorch_model.bin" not in pat_files
              and "tf_model.h5" not in pat_files, str(sorted(pat_files)))

        print("• download queue (one at a time)")
        c.req("DELETE", "/v1/models/test-tiny")
        c.req("DELETE", "/v1/models/test-tiny-patterns")
        mark = sse.mark()
        _, body = c.req("POST", "/v1/models/test-tiny/download")
        dl_first = body["download_id"]
        _, body = c.req("POST", "/v1/models/test-tiny-patterns/download")
        dl_second = body["download_id"]
        _, body = c.req("GET", "/v1/downloads")
        rows = {d["download_id"]: d for d in body["downloads"]}
        # contract 4.2: two at once corrupt each other's progress, because it is
        # measured from the size of a xet staging directory they share
        check("a second download waits its turn instead of running",
              rows.get(dl_second, {}).get("state") == "queued"
              and rows.get(dl_first, {}).get("state") in ("downloading",
                                                          "provisioning"),
              str(rows))
        check("a queued download invents no transfer",
              rows.get(dl_second, {}).get("speed_bps") == 0
              and rows.get(dl_second, {}).get("bytes_total", 0) > 0,
              str(rows.get(dl_second)))
        # the dispatch event says nothing about the ones behind it, so a
        # download waiting its turn has to announce itself on arrival or a
        # client watching the stream never learns it exists
        check("the waiting download announced itself over SSE",
              sse.wait_for("download.progress", 5,
                           lambda d: d["download_id"] == dl_second
                           and d["state"] == "queued", since=mark) is not None)
        done = sse.wait_for("download.completed", 180,
                            lambda d: d["model_id"] == "test-tiny-patterns",
                            since=mark)
        check("the queued download runs once the one ahead finishes",
              done is not None)
        _, body = c.req("GET", "/v1/models/test-tiny")
        check("both models installed after the queue drains",
              body.get("install_state") == "installed", str(body.get("install_state")))

        print("• queue hold & order")
        status, _ = c.req("POST", "/v1/queue/pause")
        held = sse.wait_for("queue.state", 5, lambda d: d["held"] is True)
        check("queue pause accepted and announced",
              status == 202 and held is not None)
        _, body = c.req("GET", "/v1/system")
        check("system reports the hold", body.get("queue_held") is True)
        hold_ids = []
        for i in range(3):
            _, body = c.req("POST", "/v1/jobs", {
                "model_ids": ["test-tiny"], "prompt": f"hold {i}",
                "duration_s": 1})
            hold_ids.append(body["jobs"][0]["job_id"])
        time.sleep(2)
        states = [c.req("GET", f"/v1/jobs/{j}")[1]["status"] for j in hold_ids]
        check("nothing starts while the queue is held",
              set(states) == {"queued"}, str(states))
        # contract 5.8. Only one model is installed here, so this proves the
        # ordering endpoints and the re-announcement — not that priority beats
        # warm-worker locality, which needs two families to be observable at all.
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/queue/order",
                          {"job_ids": [hold_ids[2], hold_ids[0]]})
        _, info = c.req("GET", f"/v1/jobs/{hold_ids[2]}")
        check("an explicitly ordered job takes the front",
              status == 202 and info["queue_position"] == 0
              and info["priority"] > 0, str(info))
        _, info = c.req("GET", f"/v1/jobs/{hold_ids[1]}")
        check("an unlisted job falls behind every ordered one",
              info["queue_position"] == 2 and info["priority"] == 0, str(info))
        requeued = sse.wait_for(
            "job.queued", 5,
            lambda d: d["job_id"] == hold_ids[1] and d["queue_position"] == 2,
            since=mark)
        check("a reorder re-announces the jobs nobody dragged",
              requeued is not None)
        status, body = c.req("PATCH", f"/v1/jobs/{hold_ids[1]}/priority",
                             {"priority": True})
        check("422 a bool is not a priority",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, _ = c.req("PATCH", f"/v1/jobs/{hold_ids[1]}/priority",
                          {"priority": 99})
        _, info = c.req("GET", f"/v1/jobs/{hold_ids[1]}")
        check("a priority patch overrides an earlier explicit order",
              status == 202 and info["queue_position"] == 0, str(info))
        c.req("POST", f"/v1/jobs/{hold_ids[2]}/cancel")
        run_mark = sse.mark()
        status, _ = c.req("POST", "/v1/queue/resume")
        released = sse.wait_for("queue.state", 5, lambda d: d["held"] is False)
        check("queue resume accepted and announced",
              status == 202 and released is not None)
        # hold_ids[0] stays queued so that "first" means something — released on
        # its own, this job would start whatever the order was. It is canceled
        # the moment the first start arrives, so only one take ever renders.
        started = sse.wait_for("job.started", 60,
                               lambda d: d["job_id"] in hold_ids,
                               since=run_mark)
        c.req("POST", f"/v1/jobs/{hold_ids[0]}/cancel")
        check("the job the user put first is the one that starts",
              started is not None and started["job_id"] == hold_ids[1],
              str(started))
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == hold_ids[1])
        check("the released job runs to completion", finished is not None)
        status, body = c.req("PATCH", f"/v1/jobs/{hold_ids[1]}/priority",
                             {"priority": 1})
        check("409 reordering a job that is no longer queued",
              status == 409 and body["error"]["code"] == "JOB_NOT_QUEUED",
              str(body))

        print("• uploads (audio params)")
        wav_path = out["path"]
        with open(wav_path, "rb") as f:
            wav_bytes = f.read()
        status, body = c.req_raw("POST", "/v1/uploads?filename=ref.wav",
                                 wav_bytes)
        check("upload accepted",
              status == 201 and body.get("upload_id", "").startswith("up_")
              and body["bytes"] == len(wav_bytes))
        upload_id = body.get("upload_id", "")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "x",
            "duration_s": 2, "params": {"melody_audio": "up_bogus"}})
        check("422 unknown upload id",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "with reference audio",
            "duration_s": 2, "params": {"melody_audio": upload_id}})
        check("job accepts audio param", status == 202)
        up_job = body["jobs"][0]["job_id"]
        _, info = c.req("GET", f"/v1/jobs/{up_job}")
        check("upload id resolved to a path for the worker",
              str(info["params"].get("melody_audio", "")).startswith("/"))
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == up_job)
        check("audio-param job completes", finished is not None)

        print("• task jobs (real dsp worker, weightless install)")
        _, body = c.req("GET", "/v1/models/test-split")
        check("weightless task model in catalog",
              body.get("capabilities", {}).get("tasks") == ["mix"]
              and body.get("install_state") == "not_installed")
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/models/test-split/download")
        done = sse.wait_for("download.completed", 60,
                            lambda d: d["model_id"] == "test-split", since=mark)
        check("empty-hf_repos install completes", status == 202 and done)
        _, body = c.req("GET", "/v1/models/test-split")
        check("weightless model reports installed",
              body.get("install_state") == "installed")

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "prompt": "x", "task": "generate"})
        check("422 generate on task-only model",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "", "task": "mix",
            "params": {"mix_spec": "{}"}})
        check("422 task outside capabilities.tasks",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "shred"})
        check("422 unknown task name",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix", "lyrics": "la",
            "params": {"mix_spec": "{}"}})
        check("422 lyrics on task job",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix", "count": 2,
            "params": {"mix_spec": "{}"}})
        check("422 count>1 on task job",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix"})
        check("422 missing required json param",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": "not json"}})
        check("422 invalid JSON in json param",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": json.dumps(
                {"tracks": [{"source": "up_nope"}]})}})
        check("422 unknown upload inside json param",
              status == 422 and body["error"]["code"] == "VALIDATION")

        status, body = c.req_raw("POST", "/v1/uploads?filename=b.wav", wav_bytes)
        upload_b = body.get("upload_id", "")
        mix_spec = json.dumps({
            "target": {"bpm": 120.0, "sample_rate": out["sample_rate"]},
            "tracks": [
                {"source": upload_id, "role": "melody", "gain_db": -3.0,
                 "stretch": {"mode": "none"}},
                {"source": upload_b, "role": "pad", "offset_s": 0.5,
                 "stretch": {"mode": "none"}}]})
        # Small models must run without disturbing the resident model: the
        # last job was a test-tiny generate, so it should still be loaded
        # after an entire small-model job has come and gone.
        _, sysinfo = c.req("GET", "/v1/system")
        check("a big model is resident before the small job",
              sysinfo.get("warm_model_id") == "test-tiny")
        resident_mark = sse.mark()

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": mix_spec, "keep_tracks": True}})
        check("mix job accepted (promptless)", status == 202)
        mix_job = body["jobs"][0]["job_id"]
        # Both slots should be loaded at once while the small job runs.
        max_workers, saw_transient = 0, False
        deadline = time.time() + 600
        while time.time() < deadline:
            _, mid_run = c.req("GET", "/v1/system")
            if "test-split" in (mid_run.get("transient_model_ids") or []):
                saw_transient = True
            ps = subprocess.run(
                ["pgrep", "-f",
                 f"engine_protocol.worker_main.*--parent-pid {hs['pid']}"],
                capture_output=True, text=True)
            max_workers = max(max_workers,
                              len(ps.stdout.split()) if ps.stdout.strip() else 0)
            _, jrow = c.req("GET", f"/v1/jobs/{mix_job}")
            if jrow.get("status") in ("succeeded", "failed", "canceled"):
                break
            time.sleep(0.3)
        check("small model runs in its own worker beside the resident one",
              max_workers >= 2, f"max concurrent workers seen: {max_workers}")
        check("system reports the transient model while it runs", saw_transient)
        _, info = c.req("GET", f"/v1/jobs/{mix_job}")
        check("task echoed in JobInfo",
              info.get("task") == "mix" and info.get("duration_s") is None)
        resolved_spec = json.loads(info["params"]["mix_spec"])
        check("json param upload ids resolved to paths",
              all(t["source"].startswith("/") and os.path.exists(t["source"])
                  for t in resolved_spec["tracks"]))
        finished = sse.wait_for("job.completed", 600,
                                lambda d: d["job_id"] == mix_job)
        check("mix job completes (dsp venv provisioned on demand)",
              finished is not None)

        # The Editor's shape, against the real adapter: reverse, a per-track
        # effect chain, per-ramp fade curves, loudness left alone and a
        # different container. The filter cutoffs here sit ABOVE Nyquist for
        # a low-rate source on purpose — unbounded they make the biquads
        # degenerate and the render comes back as noise from a job that
        # reports success, which is exactly the failure this pins.
        edit_spec = json.dumps({
            "target": {"sample_rate": out["sample_rate"]},
            "tracks": [{"source": upload_id, "role": "edit", "gain_db": 0.0,
                        "offset_s": 0.0, "reverse": True,
                        "fade_in_s": 0.05, "fade_in_curve": "scurve",
                        "fade_out_s": 0.05, "fade_out_curve": "log",
                        "effects": [
                            {"type": "highpass", "cutoff_hz": 80.0},
                            {"type": "lowpass", "cutoff_hz": 18000.0},
                            {"type": "eq3", "low_db": 2.5, "mid_db": 0.0,
                             "high_db": 1.5},
                            {"type": "compressor", "threshold_db": -18.0,
                             "ratio": 3.0, "attack_ms": 8.0,
                             "release_ms": 120.0},
                            {"type": "gate", "threshold_db": -54.0}],
                        "stretch": {"mode": "none"},
                        "pitch_shift_st": 0.0}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": edit_spec, "normalize": False,
                       "limiter": False, "output_format": "flac",
                       "bit_depth": "pcm24"}})
        check("editor-shaped mix accepted", status == 202, str(body))
        edit_job = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 600,
                                lambda d: d["job_id"] == edit_job)
        check("editor-shaped mix completes", finished is not None)
        _, edit_row = c.req("GET", f"/v1/jobs/{edit_job}")
        edit_result = edit_row.get("result") or {}
        edit_arts = edit_result.get("artifacts") or []
        check("output_format reshapes the artifact",
              len(edit_arts) == 1 and edit_arts[0]["format"] == "flac"
              and edit_arts[0]["path"].endswith(".flac")
              and os.path.exists(edit_arts[0]["path"]),
              json.dumps(edit_arts)[:200])
        check("normalize=false leaves loudness out of meta",
              "lufs" not in (edit_result.get("meta") or {}),
              str(edit_result.get("meta")))
        # Filters bounded below Nyquist: unbounded, an 18 kHz low-pass on a
        # sub-36 kHz source renders inf/NaN, which np.clip turns into a
        # full-scale square wave — and FLAC of a square wave compresses to
        # almost nothing, where real music does not.
        if edit_arts:
            rendered = os.path.getsize(edit_arts[0]["path"])
            check("the rendered edit is real audio, not clipped noise",
                  rendered > 4096, f"{rendered} bytes")

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": edit_spec, "output_format": "flac",
                       "bit_depth": "float32"}})
        check("float32 flac accepted then fails", status == 202)
        f32_job = body["jobs"][0]["job_id"]
        check("float32 flac fails the job",
              sse.wait_for("job.failed", 600,
                           lambda d: d["job_id"] == f32_job) is not None)

        bad_effect = json.dumps({
            "target": {"sample_rate": out["sample_rate"]},
            "tracks": [{"source": upload_id, "role": "edit",
                        "effects": [{"type": "flanger"}],
                        "stretch": {"mode": "none"}}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": bad_effect}})
        check("unknown effect type accepted then fails", status == 202)
        bad_job = body["jobs"][0]["job_id"]
        check("unknown effect type fails the job",
              sse.wait_for("job.failed", 600,
                           lambda d: d["job_id"] == bad_job) is not None)

        # The whole point: the small job neither evicted the resident model nor
        # claimed the titlebar, and left nothing of its own behind.
        evicted = sse.wait_for("worker.state", 0.5,
                               lambda d: d["state"] == "stopped",
                               since=resident_mark)
        check("small job never evicts the resident model", evicted is None)
        claimed = sse.wait_for("worker.state", 0.5,
                               lambda d: d.get("model_id") == "test-split",
                               since=resident_mark)
        check("small model never claims the titlebar", claimed is None)
        time.sleep(2)
        _, sysinfo = c.req("GET", "/v1/system")
        check("resident model survives the small job",
              sysinfo.get("warm_model_id") == "test-tiny")
        # The pool deliberately holds it now — that is the warm-pool behaviour,
        # and the TTL test below proves it does eventually go.
        check("small model stays warm in the pool after its job",
              sysinfo.get("transient_model_ids") == ["test-split"],
              str(sysinfo.get("transient_model_ids")))
        _, job = c.req("GET", f"/v1/jobs/{mix_job}")
        arts = (job.get("result") or {}).get("artifacts") or []
        mixdown = next((a for a in arts if a["label"] == "mixdown"), None)
        check("mixdown artifact present with metadata",
              mixdown is not None and mixdown["kind"] == "audio"
              and mixdown["format"] == "wav"
              and os.path.exists(mixdown["path"])
              and (mixdown.get("duration_s") or 0) > 0.4)
        check("keep_tracks emits per-track stems",
              sorted(a["label"] for a in arts if a["kind"] == "stem")
              == ["melody", "pad"])
        check("artifacts live under the job output dir",
              all(f"/{mix_job}/" in a["path"] for a in arts))
        check("no legacy outputs on task jobs",
              (job.get("result") or {}).get("outputs") is None)

        # determinism: literal recombination must be reproducible — an
        # identical spec yields a byte-identical mixdown
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": mix_spec, "keep_tracks": True}})
        mix2_job = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == mix2_job)
        check("second identical mix completes", finished is not None)
        _, job2 = c.req("GET", f"/v1/jobs/{mix2_job}")
        arts2 = (job2.get("result") or {}).get("artifacts") or []
        mixdown2 = next((a for a in arts2 if a["label"] == "mixdown"), None)

        def _sha(p: str) -> str:
            h = hashlib.sha256()
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            return h.hexdigest()

        check("mixdown is deterministic (byte-identical)",
              mixdown is not None and mixdown2 is not None
              and _sha(mixdown["path"]) == _sha(mixdown2["path"]))

        print("• mix placement geometry (timeline)")
        # A click track at the target rate: no resampling (a resampler's
        # pre-ring would smear the onset) and no section trim (the 2 ms edge
        # fade would eat the burst), so the only thing under test is placement.
        place_sr = 44100
        clicks = click_wav(1.0, place_sr, at=[0.0])
        _, up = c.req_raw("POST", "/v1/uploads?filename=click.wav", clicks)
        click_id = up.get("upload_id", "")
        a_s, b_s = 0.2371, 0.7551
        place_spec = json.dumps({
            "target": {"bpm": 120.0, "sample_rate": place_sr},
            "tracks": [
                {"source": click_id, "role": "a", "offset_s": a_s,
                 "stretch": {"mode": "none"}},
                {"source": click_id, "role": "b", "offset_s": b_s,
                 "stretch": {"mode": "none"}}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": place_spec}})
        place_job = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == place_job)
        check("sub-second placement mix completes",
              status == 202 and finished is not None)
        _, job3 = c.req("GET", f"/v1/jobs/{place_job}")
        arts3 = (job3.get("result") or {}).get("artifacts") or []
        placed = next((a for a in arts3 if a["label"] == "mixdown"), None)
        onsets = onset_frames(placed["path"]) if placed else []
        check("two clicks land as two distinct onsets", len(onsets) == 2,
              f"onsets: {onsets}")
        if len(onsets) == 2:
            # Absolute: fractional offsets are not quantized to whole seconds
            # (the old `round(offset_s) * sr` put both of these at 0 and 44100).
            check("a fractional offset lands within 1.5 ms",
                  abs(onsets[0] - round(a_s * place_sr)) <= 64,
                  f"{onsets[0]} vs {round(a_s * place_sr)}")
            # Relative: any constant pipeline latency cancels in the gap, so
            # this is the assertion that can never go flaky.
            check("the gap between two placements is sample-exact",
                  abs((onsets[1] - onsets[0])
                      - round((b_s - a_s) * place_sr)) <= 4,
                  f"gap {onsets[1] - onsets[0]} vs "
                  f"{round((b_s - a_s) * place_sr)}")

        # Geometry parity: the app draws clips using length × source/target bpm,
        # so pin the direction the engine actually stretches in.
        geom_spec = json.dumps({
            "target": {"bpm": 150.0, "sample_rate": place_sr},
            "tracks": [{"source": click_id, "role": "a", "offset_s": 0.5,
                        "source_bpm": 120.0,
                        "stretch": {"mode": "uniform"}}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": geom_spec}})
        geom_job = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == geom_job)
        _, job4 = c.req("GET", f"/v1/jobs/{geom_job}")
        arts4 = (job4.get("result") or {}).get("artifacts") or []
        stretched = next((a for a in arts4 if a["label"] == "mixdown"), None)
        want = 0.5 + 1.0 * 120.0 / 150.0
        check("a stretched clip renders at source_bpm/target_bpm of its length",
              stretched is not None
              and abs(wav_duration_s(stretched["path"]) - want) < 0.05,
              f"{wav_duration_s(stretched['path']) if stretched else None} "
              f"vs {want}")

        # Fades, measured as a ratio WITHIN one file: a linear 0.5 s ramp puts
        # 0.25 s at half the height of 0.75 s. A steady tone rather than clicks
        # — sparse clicks in near-silence get normalised up until every one of
        # them hits the limiter, which flattens exactly the ratio under test.
        _, up_fade = c.req_raw("POST", "/v1/uploads?filename=fade.wav",
                               tone_wav(1.5, place_sr))
        fade_spec = json.dumps({
            "target": {"bpm": 120.0, "sample_rate": place_sr},
            "tracks": [{"source": up_fade.get("upload_id", ""), "role": "a",
                        "offset_s": 0.0, "fade_in_s": 0.5,
                        "stretch": {"mode": "none"}}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": fade_spec}})
        fade_job = body["jobs"][0]["job_id"]
        finished = sse.wait_for("job.completed", 300,
                                lambda d: d["job_id"] == fade_job)
        check("fade mix completes", status == 202 and finished is not None)
        _, job5 = c.req("GET", f"/v1/jobs/{fade_job}")
        arts5 = (job5.get("result") or {}).get("artifacts") or []
        faded = next((a for a in arts5 if a["label"] == "mixdown"), None)
        if faded:
            early = peak_between(faded["path"], 0.24, 0.28)
            late = peak_between(faded["path"], 0.74, 0.78)
            ratio = early / late if late > 0 else 0
            # 0.5 exactly, with room for the limiter squashing the louder one
            check("fade_in_s ramps linearly across the window",
                  late > 0 and 0.3 < ratio < 0.75,
                  f"early {early}, late {late}, ratio {ratio}")

        # target.duration_s pads the mix so trailing silence renders.
        pad_spec = json.dumps({
            "target": {"bpm": 120.0, "sample_rate": place_sr,
                       "duration_s": 4.0},
            "tracks": [{"source": click_id, "role": "a", "offset_s": 0.0,
                        "stretch": {"mode": "none"}}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": pad_spec}})
        pad_job = body["jobs"][0]["job_id"]
        sse.wait_for("job.completed", 300, lambda d: d["job_id"] == pad_job)
        _, job6 = c.req("GET", f"/v1/jobs/{pad_job}")
        arts6 = (job6.get("result") or {}).get("artifacts") or []
        padded = next((a for a in arts6 if a["label"] == "mixdown"), None)
        check("target.duration_s pads the mixdown",
              padded is not None
              and abs(wav_duration_s(padded["path"]) - 4.0) < 0.01,
              f"{wav_duration_s(padded['path']) if padded else None}")

        neg_spec = json.dumps({
            "target": {"bpm": 120.0, "sample_rate": place_sr},
            "tracks": [{"source": click_id, "role": "a", "offset_s": -0.5,
                        "stretch": {"mode": "none"}}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-split"], "task": "mix",
            "params": {"mix_spec": neg_spec}})
        neg_job = body["jobs"][0]["job_id"]
        failed = sse.wait_for("job.failed", 300,
                              lambda d: d["job_id"] == neg_job)
        check("negative offset_s fails loudly instead of silently clamping",
              failed is not None
              and "offset_s" in json.dumps(failed.get("error") or {}))

        # The determinism check above exercises none of the Rubber Band path.
        # A second pair on a rich spec (fractional offsets, trim, beat-mode
        # stretch with downbeats, pitch shift, fades) localises a failure to
        # "stretch" rather than "placement".
        rich_spec = json.dumps({
            "target": {"bpm": 132.0, "sample_rate": out["sample_rate"]},
            "tracks": [
                {"source": upload_id, "role": "a", "offset_s": 0.1234,
                 "section": {"start_s": 0.2, "end_s": 1.4},
                 "source_bpm": 120.0, "source_downbeats": [0.25, 0.75, 1.25],
                 "fade_in_s": 0.1, "fade_out_s": 0.2,
                 "stretch": {"mode": "beat", "transient_mode": "crisp",
                             "preserve_formants": True},
                 "pitch_shift_st": 2.0},
                {"source": upload_b, "role": "b", "offset_s": 0.9876,
                 "source_bpm": 96.0,
                 "stretch": {"mode": "uniform", "transient_mode": "smooth",
                             "preserve_formants": False},
                 "pitch_shift_st": -1.0}]})
        rich_paths = []
        for _ in range(2):
            _, body = c.req("POST", "/v1/jobs", {
                "model_ids": ["test-split"], "task": "mix",
                "params": {"mix_spec": rich_spec}})
            rich_job = body["jobs"][0]["job_id"]
            sse.wait_for("job.completed", 300,
                         lambda d, j=rich_job: d["job_id"] == j)
            _, rich_info = c.req("GET", f"/v1/jobs/{rich_job}")
            rich_arts = (rich_info.get("result") or {}).get("artifacts") or []
            found = next((a for a in rich_arts if a["label"] == "mixdown"), None)
            if found:
                rich_paths.append(found["path"])
        check("stretch + trim + fades are deterministic too",
              len(rich_paths) == 2
              and _sha(rich_paths[0]) == _sha(rich_paths[1]))

        print("• pin (keep model loaded)")
        c.req("POST", "/v1/worker/unload")  # start from a clean slate
        time.sleep(1)
        mark = sse.mark()
        status, _ = c.req("PUT", "/v1/models/test-tiny/pin", {"enabled": True})
        loaded = sse.wait_for("worker.state", 120,
                              lambda d: d["state"] == "loaded"
                              and d["model_id"] == "test-tiny", since=mark)
        check("pin preloads the model while idle", status == 202 and loaded)
        _, body = c.req("GET", "/v1/system")
        check("system reports warm/pinned model",
              body.get("warm_model_id") == "test-tiny"
              and body.get("pinned_model_id") == "test-tiny")
        ps = subprocess.run(["pgrep", "-f", f"engine_protocol.worker_main.*--parent-pid {hs['pid']}"],
                            capture_output=True, text=True)
        check("pinned worker stays alive while idle", ps.stdout.strip() != "")
        status, _ = c.req("PUT", "/v1/models/test-tiny/pin", {"enabled": False})
        time.sleep(1)
        ps = subprocess.run(["pgrep", "-f", f"engine_protocol.worker_main.*--parent-pid {hs['pid']}"],
                            capture_output=True, text=True)
        check("unpin keeps the model resident",
              status == 202 and ps.stdout.strip() != "")
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/worker/unload")
        stopped = sse.wait_for("worker.state", 10,
                               lambda d: d["state"] == "stopped", since=mark)
        check("unload after unpin frees the worker",
              status == 202 and stopped is not None)

        print("• arbitrary models (inspect/custom)")
        status, body = c.req("POST", "/v1/models/inspect",
                             {"repo_id": "facebook/musicgen-small"})
        check("inspect classifies MusicGen repo",
              status == 200 and body.get("family") == "musicgen"
              and body.get("size_bytes", 0) > 0)
        status, body = c.req("POST", "/v1/models/inspect", {"repo_id": "gpt2"})
        check("inspect refuses unsupported architecture",
              status == 422 and body["error"]["code"] == "UNSUPPORTED_MODEL")
        status, body = c.req("POST", "/v1/models/custom",
                             {"repo_id": "facebook/musicgen-small"})
        check("custom model persisted", status == 201 and body.get("id"))
        custom_id = body.get("id", "")
        _, body = c.req("GET", "/v1/models")
        check("custom model in catalog",
              any(m["id"] == custom_id for m in body["models"]))
        status, _ = c.req("DELETE", f"/v1/models/{custom_id}")
        _, body = c.req("GET", "/v1/models")
        check("custom model removable",
              status == 202 and all(m["id"] != custom_id for m in body["models"]))

        # ---- staged progress: every phase reported was declared (contract 5.5)
        #
        # A standing invariant over EVERY job this run submitted, rather than a
        # check bolted to one of them. Four adapters were once found reporting a
        # `steps` total they had invented — a constant mirroring an upstream
        # default that had since changed, a duration x rate projection, and two
        # requested lengths the stage routinely stops short of. Each looked
        # perfectly plausible in isolation; what gives them away is the pair of
        # rules below.
        print("• staged progress invariants")
        progress_events = [d for _, e, d in sse.events if e == "job.progress"]
        check("progress events were observed", bool(progress_events))
        # Resolve each job individually: the unfiltered `GET /v1/jobs` omits
        # terminal jobs (api/jobs.py), and by this point in the run every job
        # has finished — so building the map from the list endpoint silently
        # yields nothing and makes the phase check below vacuous. That is not
        # hypothetical: it is what a negative control found it doing.
        model_of: dict[str, str] = {}
        count_of: dict[str, int] = {}
        for job_id in {d.get("job_id", "") for d in progress_events} - {""}:
            st_code, one = c.req("GET", f"/v1/jobs/{job_id}")
            if st_code == 200 and one.get("model_id"):
                model_of[job_id] = one["model_id"]
                count_of[job_id] = int(one.get("count") or 1)

        undeclared = []
        for d in progress_events:
            phase = d.get("phase")
            if not phase:
                continue
            model = models.get(model_of.get(d.get("job_id", ""), ""))
            declared = {st["id"] for st in
                        (model or {}).get("capabilities", {}).get("pipeline") or []}
            # An unknown model id means the job predates this listing, not that
            # the phase is wrong; only judge what we can resolve.
            if model is not None and phase not in declared:
                undeclared.append((d.get("job_id"), phase, sorted(declared)))
        check("every reported phase is one the model declared",
              not undeclared, str(undeclared[:3]))
        # Guard against the check above going quiet: if nothing resolved, it
        # asserted nothing at all.
        resolvable = [d for d in progress_events
                      if d.get("phase") and d.get("job_id") in model_of]
        check("phases were actually checked against a declared pipeline",
              bool(resolvable), f"{len(model_of)} jobs resolved")

        # `take` is bounded by the job's own `count`. A take past the end would
        # have the app drawing "take 5 of 4"; a take reported while nothing is
        # rendering would have it claim work that has not started.
        out_of_range = [d for d in progress_events
                        if d.get("take") is not None
                        and d.get("job_id") in count_of
                        and not 0 <= d["take"] < count_of[d["job_id"]]]
        check("a reported take is inside its job's count",
              not out_of_range, str(out_of_range[:3]))
        loading = [d for d in progress_events if d.get("stage") == "loading"]
        check("nothing is rendering during a load, and take says so",
              bool(loading) and all(d.get("take") is None for d in loading),
              str(loading[:2]))
        # Non-vacuity: a run in which no take was ever reported would satisfy
        # every rule above by saying nothing at all.
        check("takes were actually reported",
              any(d.get("take") is not None for d in progress_events))

        # `step` and `steps` are independently nullable precisely so an adapter
        # can say "I am counting, but I do not know the total". What it must
        # never do is claim a total the count then walks past.
        overrun = [d for d in progress_events
                   if d.get("steps") and d.get("step") is not None
                   and not 0 <= d["step"] <= d["steps"]]
        check("a reported step never exceeds its declared total",
              not overrun, str(overrun[:3]))

        # The projection smell: a total the count never gets near.
        #
        # "Never reaches its total exactly" is the wrong test — adapters sample
        # every N steps, so the last tick a phase reports is usually one stride
        # short (musicgen ticks every 25 tokens of 100, so it is last seen at
        # 75). What separates that from an invented total is the SIZE of the
        # shortfall: a projection is short by a large fraction of the whole
        # (the MiniMax diffusion bug reported twice the work that ran, so it
        # stopped dead at 50%), while a cadence gap is short by one stride.
        by_phase: dict[tuple[str, str], list[dict]] = {}
        for d in progress_events:
            if d.get("steps") and d.get("step") is not None:
                by_phase.setdefault((d.get("job_id", ""), d["phase"]), []).append(d)
        stranded = []
        for (job_id, phase), events in by_phase.items():
            steps_seen = [d["step"] for d in events]
            total = events[-1]["steps"]
            stride = max([b - a for a, b in zip(steps_seen, steps_seen[1:])]
                         + [steps_seen[0], 1])
            if total - max(steps_seen) > stride:
                stranded.append((job_id, phase, max(steps_seen), total, stride))
        check("a counted phase gets within one stride of its total",
              not stranded, str(stranded[:3]))

        print("• preview invariants")
        # Nothing installed in this run declares supports_preview, and no job
        # asked. A frame here would be a real audio file the app would draw and
        # attribute to a model that cannot produce one.
        previews = [d for _, e, d in sse.events if e == "job.preview"]
        check("no job published a preview it was not asked for",
              not previews, str(previews[:2]))
        not_echoed = []
        for job_id in model_of:
            st_code, one = c.req("GET", f"/v1/jobs/{job_id}")
            if st_code == 200 and one.get("preview") is not False:
                not_echoed.append((job_id, one.get("preview")))
        check("every job echoes its preview flag",
              bool(model_of) and not not_echoed, str(not_echoed[:3]))

        sse.stop()

        print("• shutdown paths")
        status, _ = c.req("POST", "/v1/shutdown")
        check("POST /v1/shutdown accepted", status == 202)
        try:
            proc.wait(timeout=10)
            check("exits after /v1/shutdown", True)
        except subprocess.TimeoutExpired:
            check("exits after /v1/shutdown", False)
            proc.kill()

        # memory warning: a 1-byte level means the first sample after torch
        # loads crosses it — the engine must WARN (engine.warning + job.log)
        # but the job must still complete
        proc = spawn(tmp, token, os.getpid(),
                     extra_env={"LOCALMUSIC_MEM_GUARD_BYTES": "1"})
        hs = wait_handshake(tmp, proc)
        check("relaunch for memory-warning test", hs is not None)
        if hs is not None:
            cg = Client(hs["port"], token)
            sse_g = SSEListener(hs["port"], token)
            sse_g.start()
            status, body = cg.req("GET", "/v1/system")
            check("system reports memory warning level",
                  status == 200 and body["memory_guard"]["limit_bytes"] == 1)
            _, body = cg.req("POST", "/v1/jobs", {
                "model_ids": ["test-tiny"], "prompt": "warning check",
                "duration_s": 2})
            gj = body["jobs"][0]["job_id"]
            warned = sse_g.wait_for(
                "engine.warning", 180,
                lambda d: "memory" in d.get("message", "").lower())
            check("memory warning emitted past the level", warned is not None)
            deadline = time.time() + 180
            job = {}
            while time.time() < deadline:
                _, job = cg.req("GET", f"/v1/jobs/{gj}")
                if job.get("status") in ("failed", "succeeded", "canceled"):
                    break
                time.sleep(2)
            check("job completes despite memory warning",
                  job.get("status") == "succeeded")
            sse_g.stop()
            cg.req("POST", "/v1/shutdown")
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

        # kill-switch: with the policy disabled every model uses the single
        # resident slot again, so a small model DOES take the titlebar
        proc = spawn(tmp, token, os.getpid(),
                     extra_env={"LOCALMUSIC_SMALL_MODEL_BYTES": "0"})
        hs = wait_handshake(tmp, proc)
        check("relaunch with the small-model policy disabled", hs is not None)
        if hs is not None:
            cs = Client(hs["port"], token)
            sse_s = SSEListener(hs["port"], token)
            sse_s.start()
            # uploads are purged on startup, so re-upload for this instance
            _, up = cs.req_raw("POST", "/v1/uploads?filename=a.wav", wav_bytes)
            spec = json.dumps({
                "target": {"bpm": 120.0, "sample_rate": out["sample_rate"]},
                "tracks": [{"source": up["upload_id"], "role": "melody",
                            "stretch": {"mode": "none"}}]})
            status, body = cs.req("POST", "/v1/jobs", {
                "model_ids": ["test-split"], "task": "mix",
                "params": {"mix_spec": spec}})
            check("mix job accepted with policy disabled", status == 202,
                  json.dumps(body)[:200])
            dj = body["jobs"][0]["job_id"]
            done = sse_s.wait_for("job.completed", 600,
                                  lambda d: d["job_id"] == dj)
            check("job runs with the policy disabled", done is not None)
            _, body = cs.req("GET", "/v1/system")
            check("disabled policy puts small models back in the resident slot",
                  body.get("warm_model_id") == "test-split"
                  and not body.get("transient_model_ids"))
            sse_s.stop()
            cs.req("POST", "/v1/shutdown")
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

        # the warm pool lets go on its own: with a 2 s life, a small model is
        # gone a few seconds after its job with nothing else submitted. This is
        # the timed wake-up the idle runner has to perform — a queue that only
        # expired workers after the *next* job would keep it forever.
        proc = spawn(tmp, token, os.getpid(),
                     extra_env={"LOCALMUSIC_SMALL_WARM_TTL_S": "2"})
        hs = wait_handshake(tmp, proc)
        check("relaunch with a short warm-pool life", hs is not None)
        if hs is not None:
            ct = Client(hs["port"], token)
            sse_t = SSEListener(hs["port"], token)
            sse_t.start()
            _, up = ct.req_raw("POST", "/v1/uploads?filename=a.wav", wav_bytes)
            spec = json.dumps({
                "target": {"bpm": 120.0, "sample_rate": out["sample_rate"]},
                "tracks": [{"source": up["upload_id"], "role": "melody",
                            "stretch": {"mode": "none"}}]})
            _, body = ct.req("POST", "/v1/jobs", {
                "model_ids": ["test-split"], "task": "mix",
                "params": {"mix_spec": spec}})
            tj = body["jobs"][0]["job_id"]
            done = sse_t.wait_for("job.completed", 600,
                                  lambda d: d["job_id"] == tj)
            check("job runs with a short warm-pool life", done is not None)
            _, body = ct.req("GET", "/v1/system")
            check("small model is warm immediately after its job",
                  body.get("transient_model_ids") == ["test-split"],
                  str(body.get("transient_model_ids")))
            # nothing else is submitted: only a timed wake-up can clear this
            deadline = time.time() + 20
            emptied = False
            while time.time() < deadline:
                _, body = ct.req("GET", "/v1/system")
                if not body.get("transient_model_ids"):
                    emptied = True
                    break
                time.sleep(0.5)
            check("the pool expires on an idle queue, unprompted", emptied)
            ps = subprocess.run(
                ["pgrep", "-f",
                 f"engine_protocol.worker_main.*--parent-pid {hs['pid']}"],
                capture_output=True, text=True)
            check("the expired worker's process is really gone",
                  ps.stdout.strip() == "", ps.stdout.strip())
            sse_t.stop()
            ct.req("POST", "/v1/shutdown")
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

        # venv provisioning on the download stream (contract 4.2). A scratch
        # adapters root holding one dependency-free family is the only way to
        # watch a cold provision here: every real family is already synced in a
        # dev checkout, and the engine skips a family it already has.
        prov_root = os.path.join(tmp, "adapters")
        prov_dir = os.path.join(prov_root, "test-provision")
        os.makedirs(prov_dir, exist_ok=True)
        with open(os.path.join(prov_dir, "pyproject.toml"), "w") as f:
            f.write('[project]\nname = "adapter-test-provision"\n'
                    'version = "0.1.0"\nrequires-python = ">=3.11"\n'
                    'dependencies = []\n\n[tool.uv]\npackage = false\n')
        proc = spawn(tmp, token, os.getpid(),
                     extra_env={"LOCALMUSIC_ADAPTERS_DIR": prov_root})
        hs = wait_handshake(tmp, proc)
        check("relaunch for provisioning test", hs is not None)
        if hs is not None:
            cv = Client(hs["port"], token)
            sse_v = SSEListener(hs["port"], token)
            sse_v.start()
            # provisioning announces itself once, on entry, and there is
            # nothing to re-report while uv works — so the listener has to be
            # attached before the POST, not racing it
            time.sleep(0.5)
            status, _ = cv.req("POST", "/v1/models/test-provision/download")
            check("download of an unprovisioned family accepted", status == 202)
            prov = sse_v.wait_for(
                "download.progress", 60,
                lambda d: (d["model_id"] == "test-provision"
                           and d["state"] == "provisioning"))
            check("venv provisioning reported on the download stream",
                  prov is not None and prov["stage"] == "provisioning"
                  and prov["message"] != "", str(prov))
            # nothing is transferring yet, and the installer counts nothing
            check("provisioning reports no invented rate",
                  prov is not None and prov["speed_bps"] == 0, str(prov))
            done = sse_v.wait_for("download.completed", 300,
                                  lambda d: d["model_id"] == "test-provision")
            check("install finishes once the runtime is built", done is not None)
            venv_python = os.path.join(prov_dir, ".venv", "bin", "python")
            check("the venv it reported really exists",
                  os.path.exists(venv_python))
            # contract 4.1: a download that has finished means ready to render,
            # and the model says so rather than leaving the first generation to
            # discover a missing runtime
            _, body = cv.req("GET", "/v1/models/test-provision")
            check("a downloaded model reports its runtime installed",
                  body.get("runtime_state") == "installed",
                  str(body.get("runtime_state")))

            # contract 4.1: the runtime goes with the last model of its family
            status, _ = cv.req("DELETE", "/v1/models/test-provision")
            check("delete accepted", status == 202)
            check("deleting the last model of a family removes its venv",
                  not os.path.exists(os.path.join(prov_dir, ".venv")))
            _, body = cv.req("GET", "/v1/models/test-provision")
            check("the model then reports no runtime",
                  body.get("runtime_state") == "not_installed",
                  str(body.get("runtime_state")))

            # contract 4.2: and it can be built back on its own, without the
            # weights this weightless entry does not have anyway
            mark = sse_v.mark()
            status, body = cv.req("POST", "/v1/models/test-provision/runtime")
            check("runtime install accepted on its own", status == 202)
            rt = sse_v.wait_for(
                "download.progress", 60,
                lambda d: (d["model_id"] == "test-provision"
                           and d.get("runtime_only") is True), since=mark)
            check("a runtime install declares it carries no weights",
                  rt is not None and rt["stage"] == "provisioning", str(rt))
            done = sse_v.wait_for("download.completed", 300,
                                  lambda d: d["model_id"] == "test-provision",
                                  since=mark)
            check("runtime install completes", done is not None)
            check("the venv is back", os.path.exists(venv_python))
            _, body = cv.req("GET", "/v1/models/test-provision")
            check("runtime install leaves the install state alone",
                  body.get("runtime_state") == "installed"
                  and body["install_state"] == "not_installed", str(body))
            sse_v.stop()
            cv.req("POST", "/v1/shutdown")
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

        # SIGTERM path
        proc = spawn(tmp, token, os.getpid())
        hs = wait_handshake(tmp, proc)
        check("relaunch for SIGTERM test", hs is not None)
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
            check("exits on SIGTERM within 10 s", True)
        except subprocess.TimeoutExpired:
            check("exits on SIGTERM within 10 s", False)
            proc.kill()

        # parent-death watchdog. The fake parent must OWN the engine's stderr
        # pipe, exactly like the app does: parent death then closes the pipe and
        # the watchdog's own "shutting down" print raises BrokenPipeError — the
        # bug class that orphaned engines for hours while a keep-the-pipe-open
        # version of this test stayed green.
        fake_parent = subprocess.Popen(["cat"], stdin=subprocess.PIPE,
                                       stdout=subprocess.DEVNULL)
        proc = spawn(tmp, token, fake_parent.pid, stderr=fake_parent.stdin)
        hs = wait_handshake(tmp, proc)
        check("relaunch for watchdog test", hs is not None)
        fake_parent.terminate()
        fake_parent.wait()
        try:
            proc.wait(timeout=10)
            check("exits when parent dies (stderr pipe closed)", True)
        except subprocess.TimeoutExpired:
            check("exits when parent dies (stderr pipe closed)", False)
            proc.kill()

        return report()
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())

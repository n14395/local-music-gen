#!/usr/bin/env python3
"""Fast checks for the supervisor's pure logic. No engine, no models, no GPU.

The other `verify_*` scripts drive a running engine, which means a real model
and real minutes. The logic checked here has neither dependency, and it is the
kind that fails quietly: a log mirror that drops too much looks exactly like a
model that had nothing to say.

    python3 scripts/check_supervisor.py
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine/supervisor/src"))
sys.path.insert(0, str(ROOT / "engine/protocol/src"))

from engine_protocol.adapter import AUX_DIRS, AUX_LEGACY_DIRS  # noqa: E402
from engine_protocol.staging import INCOMPLETE_MARKER  # noqa: E402
from supervisor import envs                         # noqa: E402
from supervisor.config import Settings              # noqa: E402
from supervisor.logmirror import LogMirror          # noqa: E402
from supervisor.registry import Registry            # noqa: E402
from supervisor.worker import Worker                # noqa: E402

FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        FAILURES.append(name)


# MARK: - LogMirror

def check_log_mirror() -> None:
    m = LogMirror(lines_per_second=3)

    bar = " 76%|███████▌  | 38/50 [00:06<00:01,  8.74it/s]"
    check("a progress-bar redraw is not mirrored", m.offer(bar, 0.0) == [])
    check("a blank line is not a line", m.offer("   ", 0.0) == [])

    check("ordinary lines pass", m.offer("a", 0.0) == ["a"])
    m.offer("b", 0.1)
    m.offer("c", 0.2)
    check("the cap bites", m.offer("d", 0.3) == [] and m.offer("e", 0.4) == [])

    # The whole point of the cap announcing itself: a truncated render and a
    # quiet one must not look the same.
    out = m.offer("f", 1.5)
    check("the next window says what was dropped",
          out == ["… 2 more lines not shown (see the worker log)", "f"], repr(out))
    check("and does not repeat itself once the flood stops",
          m.offer("g", 2.6) == ["g"])

    m2 = LogMirror(lines_per_second=1)
    m2.offer("x", 0.0)
    m2.offer("y", 0.1)
    m2.reset()
    check("a reset forgets the previous job's suppression",
          m2.offer("z", 5.0) == ["z"])

    quiet = LogMirror()
    emitted = [line for i in range(200)
               for line in quiet.offer(f"line {i}", i * 0.5)]
    check("a render that prints slowly is never touched",
          len(emitted) == 200, f"{len(emitted)} of 200")


# MARK: - Worker stderr path

class _FakeBus:
    def __init__(self) -> None:
        self.events: list[tuple[str, dict]] = []

    def emit_threadsafe(self, event: str, data: dict) -> None:
        self.events.append((event, data))


def check_worker_stderr() -> None:
    """`_read_stderr` in situ, against a fake process.

    Constructed without `__init__` on purpose: the real one spawns a
    subprocess, and the six attributes this method touches are the whole of
    its world.
    """
    lines = ([" 12%|█▏        | 6/50 [00:01<00:05,  8.7it/s]"]
             + [f"step {i}/40" for i in range(40)])

    worker = object.__new__(Worker)
    worker.bus = _FakeBus()
    worker.log_mirror = LogMirror()
    worker._current_job_id = "job_1"
    worker.proc = type("P", (), {"stderr": iter(lines)})()
    written: list[bytes] = []
    worker._log_write = written.append
    worker._read_stderr()

    mirrored = [d["line"] for _, d in worker.bus.events]
    check("the log file gets everything, bar frames included",
          len(written) == len(lines), f"{len(written)} of {len(lines)}")
    check("the mirror drops the bar frame",
          not any("it/s]" in line for line in mirrored))
    # Every line here arrives in the same instant, so one second's budget is
    # all there is: 8 lines, and then the truth about the rest.
    check("the mirror caps a burst", len(mirrored) <= LogMirror().lines_per_second + 1,
          f"{len(mirrored)} lines")
    # The burst is the last thing this worker says, so nothing later can
    # carry the note — end of stream has to.
    check("and the app is told it was capped, even at end of stream",
          "not shown" in mirrored[-1], repr(mirrored[-1:]))
    check("the note counts what was actually dropped",
          "32 more lines" in mirrored[-1], repr(mirrored[-1:]))

    worker.current_job_id = "job_2"
    check("a new job resets the budget", worker.log_mirror._suppressed == 0)


def check_no_job_no_mirror() -> None:
    worker = object.__new__(Worker)
    worker.bus = _FakeBus()
    worker.log_mirror = LogMirror()
    worker._current_job_id = None
    worker.proc = type("P", (), {"stderr": iter(["loading weights"])})()
    written: list[bytes] = []
    worker._log_write = written.append
    worker._read_stderr()
    check("stderr between jobs still reaches the file", len(written) == 1)
    check("but belongs to no job, so it is not mirrored",
          worker.bus.events == [])


# MARK: - aux cache


def check_aux_dirs() -> None:
    """AUX_DIRS is the list the library counts, moves and clears. A directory
    an adapter writes without naming it there is one the app cannot see — the
    exact bug the aux root exists to have fixed — so the two must agree."""
    used: set[str] = set()
    legacy: list[str] = []
    for path in sorted((ROOT / "engine/adapters").glob("*/src/*/*.py")):
        src = path.read_text()
        used.update(re.findall(r'aux_dir\("([^"]+)"\)', src))
        if "dirname(hf_home)" in src or 'dirname(os.environ["HF_HOME"])' in src:
            legacy.append(str(path.relative_to(ROOT)))

    unlisted = sorted(used - set(AUX_DIRS))
    check("every aux_dir() name is in AUX_DIRS", not unlisted,
          "unlisted: " + ", ".join(unlisted))
    unused = sorted(set(AUX_DIRS) - used)
    check("every AUX_DIRS name is used by an adapter", not unused,
          "unused: " + ", ".join(unused))
    check("no adapter still derives its cache from HF_HOME", not legacy,
          ", ".join(legacy))
    # A retired directory is counted and cleared but never written again;
    # an adapter naming one would be resurrecting a route on the quiet.
    revived = sorted(used & set(AUX_LEGACY_DIRS))
    check("no adapter writes a legacy aux dir", not revived,
          "revived: " + ", ".join(revived))
    check("legacy aux dirs are not also current ones",
          not set(AUX_LEGACY_DIRS) & set(AUX_DIRS))


# MARK: - runtime provisioning


def check_envs_husk() -> None:
    """A sync that dies part-way must not leave a venv behind.

    uv creates `.venv/bin/python` before it installs anything, and a
    marker-less venv is indistinguishable from a runtime built before markers
    existed — so a cancelled first install used to report `installed` forever.
    The fake uv here reproduces exactly that: it makes the python and exits
    non-zero. No network, no real uv.
    """
    saved = {k: os.environ.get(k)
             for k in ("LOCALMUSICGEN_ADAPTERS_DIR", "LOCALMUSICGEN_UV")}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fam = root / "fam"
        fam.mkdir()
        (fam / "pyproject.toml").write_text("[project]\nname = 'fam'\n")
        fake_uv = root / "fake-uv"
        fake_uv.write_text("#!/bin/sh\nmkdir -p .venv/bin\n"
                           "touch .venv/bin/python\nexit 1\n")
        fake_uv.chmod(0o755)
        os.environ["LOCALMUSICGEN_ADAPTERS_DIR"] = str(root)
        os.environ["LOCALMUSICGEN_UV"] = str(fake_uv)
        try:
            try:
                envs.ensure("fam")
                check("a failed sync raises", False, "it returned")
            except envs.ProvisionError:
                pass
            check("a failed first sync leaves no husk venv",
                  not (fam / ".venv").exists())
            check("so the family does not report a runtime",
                  not envs.is_provisioned("fam"))

            # The other half: a runtime that was already there is not the
            # husk, and a re-sync that fails must not take it away.
            (fam / ".venv" / "bin").mkdir(parents=True)
            (fam / ".venv" / "bin" / "python").touch()
            try:
                envs.ensure("fam")
            except envs.ProvisionError:
                pass
            check("a failed re-sync keeps the runtime that was already there",
                  (fam / ".venv" / "bin" / "python").exists())
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


# MARK: - install state


def _tombstone_fixture(hub: Path, repo_id: str) -> Path:
    repo = hub / ("models--" + repo_id.replace("/", "--"))
    snap = repo / "snapshots" / "rev1"
    snap.mkdir(parents=True)
    (snap / "config.json").write_text("{}")
    return repo


def check_relocate_tombstone() -> None:
    """An interrupted relocate tombstones the destination; `is_installed` has
    to read it. It did not, so a snapshot tree of links into blobs that never
    arrived reported `installed` and the job died inside the worker."""
    saved_hf = os.environ.get("HF_HOME")
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["HF_HOME"] = os.path.join(tmp, "library")
        try:
            settings = Settings(data_dir=os.path.join(tmp, "data"),
                                output_dir=os.path.join(tmp, "out"),
                                handshake_file=os.path.join(tmp, "hs.json"),
                                parent_pid=None, auth_token="t")
            os.makedirs(settings.data_dir, exist_ok=True)
            registry = Registry(settings)
            model_id = next(
                (mid for mid, m in sorted(registry.models.items())
                 if len(m.get("hf_repos") or []) == 1
                 and not m["hf_repos"][0].get("allow_patterns")
                 and not m.get("ms_repos")), None)
            if model_id is None:
                check("a single-repo catalog entry to test with", False)
                return
            repo_id = registry.models[model_id]["hf_repos"][0]["repo_id"]
            repo = _tombstone_fixture(Path(settings.hf_cache_dir) / "hub",
                                      repo_id)
            registry.write_marker(model_id, 1)
            check("a downloaded repo reads installed",
                  registry.is_installed(model_id))
            (repo / INCOMPLETE_MARKER).write_text("partial\n")
            check("a tombstoned repo does not",
                  not registry.is_installed(model_id))
            check("and hands no snapshot path to a worker",
                  repo_id not in registry.hf_snapshot_dirs(model_id))
            # Finishing the download is what makes it whole again; without
            # this the entry would offer a download that could never take.
            registry.write_marker(model_id, 1)
            check("a completed download clears the tombstone",
                  registry.is_installed(model_id))
        finally:
            if saved_hf is None:
                os.environ.pop("HF_HOME", None)
            else:
                os.environ["HF_HOME"] = saved_hf


def check_snapshot_twin() -> None:
    """On an ExFAT library volume macOS keeps extended attributes in an
    AppleDouble `._<rev>` file beside the snapshot directory. The registry's
    "latest snapshot" pick listed the folder and sorted by mtime, so the twin
    could win — a 4 KB file handed to workers as the snapshot, and an install
    check that found no files under it (Magenta RT 2, 2026-09-16)."""
    saved_hf = os.environ.get("HF_HOME")
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["HF_HOME"] = os.path.join(tmp, "library")
        try:
            settings = Settings(data_dir=os.path.join(tmp, "data"),
                                output_dir=os.path.join(tmp, "out"),
                                handshake_file=os.path.join(tmp, "hs.json"),
                                parent_pid=None, auth_token="t")
            os.makedirs(settings.data_dir, exist_ok=True)
            registry = Registry(settings)
            model_id = next(
                (mid for mid, m in sorted(registry.models.items())
                 if len(m.get("hf_repos") or []) == 1
                 and not m["hf_repos"][0].get("allow_patterns")
                 and not m.get("ms_repos")), None)
            if model_id is None:
                check("a single-repo catalog entry to test with", False)
                return
            repo_id = registry.models[model_id]["hf_repos"][0]["repo_id"]
            repo = _tombstone_fixture(Path(settings.hf_cache_dir) / "hub",
                                      repo_id)
            snap = repo / "snapshots" / "rev1"
            twin = repo / "snapshots" / "._rev1"
            twin.write_bytes(b"\x00\x05\x16\x07" + b"\x00" * 60)
            # Newer than the directory, which is how the twin won.
            later = os.path.getmtime(snap) + 60
            os.utime(twin, (later, later))
            registry.write_marker(model_id, 1)
            check("an AppleDouble twin beside the snapshot is not the snapshot",
                  registry.hf_snapshot_dirs(model_id).get(repo_id) == str(snap),
                  str(registry.hf_snapshot_dirs(model_id)))
            check("and the model still reads installed",
                  registry.is_installed(model_id))
        finally:
            if saved_hf is None:
                os.environ.pop("HF_HOME", None)
            else:
                os.environ["HF_HOME"] = saved_hf


def check_required_inputs() -> None:
    """Submit now presence-checks non-nullable audio/midi/json params for
    every task, generate included. That is only safe while `nullable: false`
    on such a param means "mandatory outright" — a default the worker would
    have used instead would turn into a 422 the user cannot answer."""
    with open(ROOT / "engine/catalog/models.json") as f:
        models = json.load(f)["models"]
    offenders = [f"{m['id']}.{p['key']}"
                 for m in models
                 for p in (m.get("capabilities") or {}).get("params") or []
                 if p.get("type") in ("audio", "midi", "json")
                 and not p.get("nullable", True)
                 and p.get("default") is not None]
    check("every mandatory file input defaults to null", not offenders,
          ", ".join(offenders))


if __name__ == "__main__":
    check_log_mirror()
    check_worker_stderr()
    check_no_job_no_mirror()
    check_aux_dirs()
    check_envs_husk()
    check_relocate_tombstone()
    check_snapshot_twin()
    check_required_inputs()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed: " + ", ".join(FAILURES))
        sys.exit(1)
    print("all checks pass")

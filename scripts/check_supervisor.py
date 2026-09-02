#!/usr/bin/env python3
"""Fast checks for the supervisor's pure logic. No engine, no models, no GPU.

The other `verify_*` scripts drive a running engine, which means a real model
and real minutes. The logic checked here has neither dependency, and it is the
kind that fails quietly: a log mirror that drops too much looks exactly like a
model that had nothing to say.

    python3 scripts/check_supervisor.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine/supervisor/src"))
sys.path.insert(0, str(ROOT / "engine/protocol/src"))

from engine_protocol.adapter import AUX_DIRS        # noqa: E402
from supervisor.logmirror import LogMirror          # noqa: E402
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


if __name__ == "__main__":
    check_log_mirror()
    check_worker_stderr()
    check_no_job_no_mirror()
    check_aux_dirs()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed: " + ", ".join(FAILURES))
        sys.exit(1)
    print("all checks pass")

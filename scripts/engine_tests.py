#!/usr/bin/env python3
"""Run the engine's Python tests, each group under the interpreter that owns it.

No engine, no models, no GPU, no network. The tests under `engine/tests/` are
pure-logic regressions for the helpers the audit found had no tests at all —
ABC cleaning, lyric-section parsing, interview parsing, the mask a melody MIDI
builds, the coercions `submit` performs on a request body. Every one of the
adapter bugs found by running the app on 2026-09-16 would have been a single
assertion here.

Layout (one directory per interpreter, because the families' venvs do not
share packages and a test that imports torch in the wrong venv is a false
failure, not a finding):

    engine/tests/supervisor/          engine/supervisor/.venv
    engine/tests/protocol/            engine/supervisor/.venv (engine_protocol is editable there)
    engine/tests/catalog/             this interpreter (stdlib only: walks models.json)
    engine/tests/adapters/<family>/   engine/adapters/<family>/.venv

Plain `unittest` on purpose: it ships with every interpreter, so running the
tests never touches a `uv.lock` (`check_pin_drift.py` and `uv lock --check`
exist because a lock that drifts is how a model dies on its first in-app run).

    python3 scripts/engine_tests.py             # everything
    python3 scripts/engine_tests.py yue notation  # groups whose name contains one of these
    python3 scripts/engine_tests.py --list

A group whose interpreter is missing (a family never provisioned in this
source tree) is reported as SKIP and does not fail the run; a test failure
does. Exit 1 on any failure.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "engine" / "tests"
SUPERVISOR_PY = ROOT / "engine" / "supervisor" / ".venv" / "bin" / "python"


def groups() -> list[tuple[str, Path, Path | None]]:
    """(name, test dir, interpreter or None when it does not exist)."""
    out: list[tuple[str, Path, Path | None]] = []
    for name in ("supervisor", "protocol"):
        d = TESTS / name
        if d.is_dir():
            out.append((name, d, SUPERVISOR_PY if SUPERVISOR_PY.exists() else None))
    if (TESTS / "catalog").is_dir():
        out.append(("catalog", TESTS / "catalog", Path(sys.executable)))
    adapters = TESTS / "adapters"
    if adapters.is_dir():
        for d in sorted(p for p in adapters.iterdir() if p.is_dir()):
            py = ROOT / "engine" / "adapters" / d.name / ".venv" / "bin" / "python"
            out.append((f"adapters/{d.name}", d, py if py.exists() else None))
    return out


def has_tests(d: Path) -> bool:
    return any(d.glob("test_*.py"))


def run(name: str, d: Path, py: Path) -> tuple[bool, str, float]:
    env = {
        **os.environ,
        # Belt and braces: a test that reaches for the Hub is a bug in the
        # test, and it should fail fast rather than download something.
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "LOCALMUSICGEN_TESTS": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    t0 = time.monotonic()
    proc = subprocess.run(
        [str(py), "-m", "unittest", "discover", "-s", str(d), "-p", "test_*.py",
         "-t", str(d), "-q"],
        cwd=str(ROOT), env=env, capture_output=True, text=True)
    dt = time.monotonic() - t0
    return proc.returncode == 0, (proc.stdout + proc.stderr), dt


def main(argv: list[str]) -> int:
    wanted = [a for a in argv if not a.startswith("--")]
    listing = "--list" in argv
    failed = 0
    ran = 0
    for name, d, py in groups():
        if wanted and not any(w in name for w in wanted):
            continue
        if not has_tests(d):
            continue
        if listing:
            print(f"{name:<28} {py if py else '(no interpreter)'}")
            continue
        if py is None:
            print(f"SKIP {name:<24} no interpreter (family venv not provisioned here)")
            continue
        ok, out, dt = run(name, d, py)
        ran += 1
        if ok:
            tail = out.strip().splitlines()[-1] if out.strip() else ""
            print(f"ok   {name:<24} {tail}  ({dt:.1f}s)")
        else:
            failed += 1
            print(f"FAIL {name:<24} ({dt:.1f}s)")
            print("\n".join("     " + line for line in out.rstrip().splitlines()))
    if listing:
        return 0
    print()
    if failed:
        print(f"{failed} of {ran} groups failed")
        return 1
    print(f"all {ran} groups passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

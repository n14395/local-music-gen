"""Per-family adapter venv provisioning via uv.

Dev layout: engine/adapters/<family>/ with pyproject.toml; `uv sync` creates .venv in
place. Packaged builds (M9) point LOCALMUSICGEN_ADAPTERS_DIR at a writable copy under
Application Support and LOCALMUSICGEN_UV at the bundled uv binary.

A family's venv is its *runtime*: the torch-sized dependency tree its adapter
imports. It is downloaded with the first model of the family (contract 4.2),
reported per model as `runtime_state` (4.1), and removed with the last model of
the family (4.1). Everything the rest of the engine needs to ask about one is
here: does it exist, is it current, build it, delete it.
"""

from __future__ import annotations

import json
import hashlib
import os
import shutil
import subprocess
import sys
import threading
import time
from typing import Callable

_LOCKS: dict[str, threading.Lock] = {}
_GLOBAL = threading.Lock()

# Written into the venv after a successful sync, so it dies with the venv and
# can never outlive what it describes.
MARKER_NAME = ".localmusicgen-runtime.json"

# (path, mtime_ns, size) -> digest. `/v1/models` asks about every family in the
# catalog on every refresh, and hashing a megabyte of uv.lock 60 times per
# request is a real cost for an answer that only changes when the app updates.
_FINGERPRINTS: dict[tuple[str, int, int], str] = {}


class ProvisionError(Exception):
    pass


def adapters_root() -> str:
    if custom := os.environ.get("LOCALMUSICGEN_ADAPTERS_DIR"):
        return custom
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", "..", "..", "adapters"))


def _uv() -> str:
    return os.environ.get("LOCALMUSICGEN_UV", "uv")


def family_dir(family: str) -> str:
    return os.path.join(adapters_root(), family)


def python_for(family: str) -> str:
    return os.path.join(family_dir(family), ".venv", "bin", "python")


def venv_dir(family: str) -> str:
    return os.path.join(family_dir(family), ".venv")


def has_project(family: str) -> bool:
    """Is there anything to install for this family? A model whose family ships
    no adapter project has no runtime to offer and must not be given a button
    that would only ever fail."""
    return os.path.exists(os.path.join(family_dir(family), "pyproject.toml"))


def _fingerprint(family: str) -> str | None:
    """What the family's runtime is pinned to: its lockfile, or its pyproject
    where a lock has not been generated yet. Nil when neither exists."""
    fdir = family_dir(family)
    for name in ("uv.lock", "pyproject.toml"):
        path = os.path.join(fdir, name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        key = (path, st.st_mtime_ns, st.st_size)
        if (cached := _FINGERPRINTS.get(key)) is not None:
            return cached
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        _FINGERPRINTS[key] = digest
        return digest
    return None


def marker_path(family: str) -> str:
    return os.path.join(venv_dir(family), MARKER_NAME)


def _write_marker(family: str) -> None:
    try:
        with open(marker_path(family), "w") as f:
            json.dump({"lock": _fingerprint(family), "installed_at": time.time()}, f)
    except OSError:
        # The venv is built and usable; a marker we could not write only costs
        # us the ability to notice drift later. Never fail a sync over it.
        pass


def is_provisioned(family: str) -> bool:
    """Is this family's runtime installed *and* current?

    A venv whose marker no longer matches the lockfile is stale — the app was
    updated and its adapter now wants different packages — and reporting it as
    installed would put the multi-minute `uv sync` back where this feature
    exists to remove it from: the middle of the user's first generation.

    A venv with no marker at all is one built before markers existed. It is
    taken at its word: those are real, working runtimes, and demanding a
    reinstall of every one of them on upgrade would be a worse lie than not
    knowing whether they have drifted. What that word used to cover for was a
    half-built venv from a cancelled or failed first sync, which looks
    identical from here; `ensure` now removes one rather than leaving it to be
    mistaken for a pre-marker runtime.
    """
    if not os.path.exists(python_for(family)):
        return False
    try:
        with open(marker_path(family)) as f:
            recorded = json.load(f).get("lock")
    except (OSError, json.JSONDecodeError, AttributeError):
        return True
    return recorded == _fingerprint(family)


def remove(family: str) -> bool:
    """Delete the family's venv. True if there was one to delete.

    Callers must have established that nothing is running out of it — a worker
    holds its python open, and pulling the tree out from under a live one turns
    the next import into an unexplainable crash. See JobQueue.release_family.
    """
    path = venv_dir(family)
    if not os.path.isdir(path):
        return False
    shutil.rmtree(path, ignore_errors=True)
    return not os.path.isdir(path)


def ensure(family: str, progress: Callable[[str], None] | None = None,
           on_proc: Callable[[subprocess.Popen], None] | None = None) -> str:
    """Sync the family's venv (idempotent; fast when already synced). Returns the
    venv's python path.

    `on_proc` receives the uv process as soon as it exists. The download manager
    uses it to kill a provisioning step the user cancelled — a first install
    pulls a torch-sized dependency tree and can run for minutes, which is far
    too long to leave running after the user has said stop.
    """
    with _GLOBAL:
        lock = _LOCKS.setdefault(family, threading.Lock())
    with lock:
        fdir = family_dir(family)
        if not os.path.exists(os.path.join(fdir, "pyproject.toml")):
            raise ProvisionError(f"no adapter project for family '{family}'")
        if progress:
            progress(f"Installing {family} runtime…")
        # --frozen when a lock exists keeps provisioning deterministic; the first dev
        # sync creates the lockfile.
        has_lock = os.path.exists(os.path.join(fdir, "uv.lock"))
        cmd = [_uv(), "sync", "--quiet"] + (["--frozen"] if has_lock else [])
        # uv creates .venv/bin/python first and installs the torch-sized tree
        # after, so a sync that is cancelled (the download path kills this
        # process by design) or fails part-way leaves a husk: a venv with a
        # python, no packages, and no marker — and is_provisioned() takes a
        # marker-less venv at its word, because that is what a runtime built
        # before markers existed looks like. The husk therefore read
        # "installed" forever: the Install-runtime affordance disappeared, the
        # download path skipped provisioning, and the next job died inside the
        # worker with ModuleNotFoundError. So a venv that did not exist before
        # this call is torn down if the call does not finish. `fresh` and not
        # is_provisioned(): a stale runtime that fails to re-sync is still a
        # working runtime, and deleting that would be the worse outcome.
        fresh = not os.path.exists(python_for(family))
        try:
            proc = subprocess.Popen(cmd, cwd=fdir, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, text=True)
            if on_proc:
                on_proc(proc)
            try:
                _, stderr = proc.communicate(timeout=1800)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                raise ProvisionError(f"uv sync for {family} timed out after 30 min")
            if proc.returncode != 0:
                raise ProvisionError(
                    f"uv sync failed for {family}: {(stderr or '')[-500:]}")
            python = python_for(family)
            if not os.path.exists(python):
                raise ProvisionError(f"venv python missing after sync: {python}")
            _write_marker(family)
        except BaseException:
            # BaseException, not Exception: a cancel arrives as the uv process
            # being killed, but the thread running this can also be taken down
            # on its way out, and a husk left by either is the same lie.
            if fresh:
                remove(family)
            raise
        print(f"envs: {family} provisioned at {python}", file=sys.stderr)
        return python

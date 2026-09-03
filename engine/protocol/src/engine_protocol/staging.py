"""Staged-tree helpers shared by the adapters.

Two failure modes from the 2026-09-03 audit live here:

- An `os.path.isdir` guard cannot tell a finished stage from the half-copied
  husk an interrupted library relocate leaves behind — six models died with
  ModuleNotFoundError behind guards that passed. Guards go through
  :func:`staged`, which also demands the landmark files only a complete
  stage contains.
- `extractall(filter="data")` aborts a whole extraction when a pinned repo
  ships an absolute symlink (BSRNN's ``data/musdb18hq``), and extracting
  straight into the cache leaves a poisoned partial tree the next run
  mistakes for a finished one. :func:`fetch_tarball_tree` extracts into a
  temp dir with :func:`safe_data_filter` and lands the result by a single
  rename, so the final path is complete-or-absent.
"""

import os
import shutil
import tarfile
import tempfile
import urllib.request

# A relocate that could not finish copying a directory drops this tombstone
# into the partial destination; `staged` treats such a tree as absent.
INCOMPLETE_MARKER = ".relocate-incomplete"


def staged(path: str, *landmarks: str) -> bool:
    """True iff `path` is a completely staged tree.

    Present, not tombstoned by an interrupted relocate, and carrying every
    one of the `landmarks` (paths relative to `path`) that only a full
    stage contains. Pick landmarks the adapter actually loads — the module
    inits and data files whose absence is the failure.
    """
    if not os.path.isdir(path):
        return False
    if os.path.exists(os.path.join(path, INCOMPLETE_MARKER)):
        return False
    return all(os.path.exists(os.path.join(path, lm)) for lm in landmarks)


def safe_data_filter(member: tarfile.TarInfo,
                     dest: str) -> tarfile.TarInfo | None:
    """``filter="data"`` that skips hostile members instead of aborting.

    Several pinned research repos ship members stock Python refuses —
    absolute symlinks, out-of-tree links — and one such member must not
    cost the whole tree.
    """
    try:
        return tarfile.data_filter(member, dest)
    except tarfile.FilterError:
        return None


def fetch_tarball_tree(url: str, cache: str, dest_name: str, *,
                       timeout: float = 300.0) -> str:
    """Download `url` and stage its single top-level directory at
    ``cache/dest_name``, whatever the tarball called it (GitHub names a
    tarball root after the repository, which for forks is not the upstream
    name). An existing tree at the destination is assumed to be a husk —
    callers only reach here after :func:`staged` said no — and is replaced.
    """
    dest = os.path.join(cache, dest_name)
    os.makedirs(cache, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".staging-", dir=cache)
    try:
        tar_path = os.path.join(tmp, "dl.tar.gz")
        with urllib.request.urlopen(url, timeout=timeout) as resp, \
                open(tar_path, "wb") as f:
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
        with tarfile.open(tar_path) as tar:
            tar.extractall(tmp, filter=safe_data_filter)
        os.unlink(tar_path)
        tops = [e for e in os.listdir(tmp)
                if os.path.isdir(os.path.join(tmp, e))]
        if len(tops) != 1:
            raise RuntimeError(
                f"expected one top-level directory in {url}, got {tops!r}")
        if os.path.isdir(dest) and not os.path.islink(dest):
            shutil.rmtree(dest)
        elif os.path.lexists(dest):
            os.unlink(dest)
        os.rename(os.path.join(tmp, tops[0]), dest)
        return dest
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

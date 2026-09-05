"""One-shot migration into the aux cache root.

Before that root existed, every adapter derived its own cache as a *sibling of
`HF_HOME`* — `~/.cache/<name>` on a default install, or the parent of a
relocated library folder. Two things were wrong with that: moving the library
silently stranded gigabytes (the lookup path moved, the bytes did not), and
nothing in `/v1/models/library` could see them.

This moves what the old derivation left behind, once, and then gets out of the
way. It is deliberately quiet about failure: a directory that cannot be moved
is left exactly where it is and re-downloaded on demand, which is slow but
never wrong. Nothing here reports to the event bus — it runs at startup, long
before a client asks the library anything.
"""

from __future__ import annotations

import os
import shutil
import sys

from engine_protocol.adapter import AUX_DIRS

# Written into the aux root once the sweep has run. Without it, a
# `torch-cache` the user's *other* tooling recreates at the legacy path would
# be swallowed on every launch.
MARKER = ".localmusicgen-migrated"


def _legacy_bases(settings) -> list[str]:
    """Where the old derivation would have put things: the parent of the
    current HF cache, and the default `~/.cache` for a library that has since
    been relocated. Anything inside the aux root itself is not a source."""
    aux = os.path.realpath(settings.aux_cache_dir)
    out: list[str] = []
    seen: set[str] = set()
    for base in (os.path.dirname(os.path.abspath(settings.hf_cache_dir)),
                 os.path.expanduser("~/.cache")):
        real = os.path.realpath(base)
        if real in seen or real == aux or real.startswith(aux + os.sep):
            continue
        seen.add(real)
        if os.path.isdir(base):
            out.append(base)
    return out


def migrate_legacy(settings) -> None:
    from .library import dir_bytes

    aux = settings.aux_cache_dir
    marker = os.path.join(aux, MARKER)
    if os.path.exists(marker):
        return

    moved: list[tuple[str, int]] = []
    for base in _legacy_bases(settings):
        for name in AUX_DIRS:
            src = os.path.join(base, name)
            dst = os.path.join(aux, name)
            # A symlinked source is someone else's arrangement, not ours.
            if os.path.exists(dst) or os.path.islink(src) \
                    or not os.path.isdir(src):
                continue
            size = dir_bytes(src)
            try:
                os.rename(src, dst)
            except OSError:
                # Across volumes, or a source we may not move: copy first and
                # only then remove, so a failure costs the destination rather
                # than the weights.
                try:
                    shutil.copytree(src, dst, symlinks=True)
                except (OSError, shutil.Error) as e:
                    shutil.rmtree(dst, ignore_errors=True)
                    print(f"aux-cache: leaving {name} at {base} ({e})",
                          file=sys.stderr)
                    continue
                shutil.rmtree(src, ignore_errors=True)
            moved.append((name, size))
            print(f"aux-cache: moved {name} ({size >> 20} MB) from {base}",
                  file=sys.stderr)

    try:
        with open(marker, "w") as f:
            f.write("\n".join(name for name, _ in moved))
    except OSError:
        # An unwritable aux root is a much larger problem than a repeated
        # sweep; let the first real download be the one that reports it.
        pass
    if moved:
        total = sum(size for _, size in moved)
        print(f"aux-cache: migrated {len(moved)} director"
              f"{'y' if len(moved) == 1 else 'ies'}, {total >> 20} MB total",
              file=sys.stderr)

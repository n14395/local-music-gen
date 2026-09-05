"""Disk retention for the engine's transient artifacts.

Outputs/<job_id>/ directories were historically never deleted: every take is
moved into the app's library at ingest, so what stays behind is the residue —
outputs of failed and cancelled jobs, keep_tracks stems nobody collected,
takes from app sessions that crashed mid-ingest. This sweeps them by age, at
startup and then daily.

The app owns the knob (Settings → Engine) and passes it as
LOCALMUSICGEN_OUTPUTS_RETENTION_DAYS; 0 keeps everything forever.
"""

from __future__ import annotations

import os
import shutil
import time

DEFAULT_RETENTION_DAYS = 14


def outputs_retention_days() -> int:
    env = os.environ.get("LOCALMUSICGEN_OUTPUTS_RETENTION_DAYS")
    if env is None:
        return DEFAULT_RETENTION_DAYS
    try:
        return max(0, int(env or 0))
    except ValueError:
        return DEFAULT_RETENTION_DAYS


def sweep_outputs(output_dir: str, days: int, *,
                  keep: frozenset[str] | set[str] = frozenset(),
                  now: float | None = None) -> list[str]:
    """Remove Outputs/<job_id> directories untouched for `days` days.

    `keep` names job ids that survive regardless of age — the queue's live
    jobs, whose directories are being written right now. Age is the
    directory's own mtime: files are only ever *created* into a job dir, and
    creation bumps it. Stray plain files at the top level are left alone;
    the engine never puts any there, so whatever did knows better than us.

    Returns the removed job ids, oldest first, for the startup log line.
    """
    if days <= 0:
        return []
    cutoff = (now if now is not None else time.time()) - days * 86400
    removed: list[tuple[float, str]] = []
    try:
        entries = list(os.scandir(output_dir))
    except OSError:
        return []
    for entry in entries:
        if not entry.is_dir(follow_symlinks=False) or entry.name in keep:
            continue
        try:
            mtime = entry.stat(follow_symlinks=False).st_mtime
        except OSError:
            continue
        if mtime < cutoff:
            shutil.rmtree(entry.path, ignore_errors=True)
            removed.append((mtime, entry.name))
    return [name for _, name in sorted(removed)]

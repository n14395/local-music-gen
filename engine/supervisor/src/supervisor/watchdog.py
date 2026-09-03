from __future__ import annotations

import asyncio
import os
import subprocess
import sys


def _start_time(pid: int) -> str | None:
    """The process's start time per `ps`, as an opaque string.

    The cross-check that tells the original pid holder from a later process
    that recycled its number — `os.kill(pid, 0)` alone cannot (audit H7:
    a recycled parent pid meant a permanently orphaned engine, matching the
    unexplained 2026-08-17 orphans).
    """
    try:
        out = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                             capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or None
    except Exception:  # noqa: BLE001 — a probe failure must not kill anyone
        return None


async def watch_parent(ppid: int, on_death) -> None:
    """Exit when the parent (the app) dies; workers do the same one level down.

    Everything on the death path must be exception-proof: stderr is a pipe held
    by the (now dead) parent, so even print() raises BrokenPipeError here — an
    uncaught exception would kill this task at exactly the moment it must act,
    leaving the engine orphaned forever.
    """
    expected = await asyncio.to_thread(_start_time, ppid)
    while True:
        await asyncio.sleep(2)
        dead = False
        try:
            os.kill(ppid, 0)
        except OSError:
            dead = True
        if not dead and expected is not None:
            # The pid answers — but is it still the same process? A changed
            # start time means the number was recycled and the real parent
            # is gone. A None probe (ps hiccup) is not evidence of death.
            now = await asyncio.to_thread(_start_time, ppid)
            if now is not None and now != expected:
                dead = True
        if dead:
            try:
                print("supervisor: parent died; shutting down", file=sys.stderr)
                on_death()
            except Exception:  # noqa: BLE001 — nothing may stop the exit
                pass
            finally:
                os._exit(0)

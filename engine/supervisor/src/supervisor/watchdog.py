from __future__ import annotations

import asyncio
import os
import sys


async def watch_parent(ppid: int, on_death) -> None:
    """Exit when the parent (the app) dies; workers do the same one level down.

    Everything on the death path must be exception-proof: stderr is a pipe held
    by the (now dead) parent, so even print() raises BrokenPipeError here — an
    uncaught exception would kill this task at exactly the moment it must act,
    leaving the engine orphaned forever.
    """
    while True:
        await asyncio.sleep(2)
        try:
            os.kill(ppid, 0)
        except OSError:
            try:
                print("supervisor: parent died; shutting down", file=sys.stderr)
                on_death()
            except Exception:  # noqa: BLE001 — nothing may stop the exit
                pass
            finally:
                os._exit(0)

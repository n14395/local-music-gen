from __future__ import annotations

import argparse
import asyncio
import json
import os
import secrets
import socket
import sys

import uvicorn

from . import CONTRACT, VERSION
from .api import build_app
from .aux_cache import migrate_legacy
from .config import Settings
from .events import EventBus
from .retention import outputs_retention_days, sweep_outputs
from .state import EngineState
from .watchdog import watch_parent


async def telemetry_loop(state: EngineState, bus: EventBus) -> None:
    """Push resource usage to the app so its sidebar readout is live without a
    poll. Fast while a worker is alive, slow when idle, and silent when nothing
    is listening — the probes are cheap but not free, and an engine nobody is
    connected to should not be sampling the GPU at all."""
    while True:
        await asyncio.sleep(2.0 if state.queue.telemetry_worker() else 10.0)
        if bus.subscribers:
            bus.emit("system.telemetry", state.usage())


async def retention_loop(state: EngineState, settings: Settings) -> None:
    """Sweep aged Outputs/<job_id> dirs — once at startup, then daily.

    Everything the user keeps is moved into the app's library at ingest, so
    what this deletes is the residue: failed and cancelled jobs' partials,
    takes from sessions that never collected them. Live jobs are exempted by
    id on top of the day-scale age threshold."""
    days = outputs_retention_days()
    if not days:
        return
    while True:
        removed = await asyncio.to_thread(
            sweep_outputs, settings.output_dir, days,
            keep=state.queue.live_job_ids())
        if removed:
            print(f"retention: removed {len(removed)} output dir(s) "
                  f"older than {days} days", file=sys.stderr)
        await asyncio.sleep(86400)


async def run(settings: Settings) -> None:
    settings.ensure_dirs()
    # Weights the old sibling-of-HF_HOME derivation left in ~/.cache. Cheap
    # after the first launch (a marker file), and it must happen before any
    # worker can start looking for them.
    migrate_legacy(settings)

    bus = EventBus(asyncio.get_running_loop())
    state = EngineState(settings, bus)
    app = build_app(state)

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

    # Bounded graceful shutdown: open SSE streams never close on their own, and the
    # contract requires exit within 10 s of SIGTERM.
    config = uvicorn.Config(app, log_level=settings.log_level, access_log=False,
                            lifespan="on", timeout_graceful_shutdown=3)
    server = uvicorn.Server(config)

    def kill_workers() -> None:
        state.queue.kill_all()

    # The event loop only holds weak references to tasks: without a strong ref
    # the watchdog task can be garbage-collected and silently stop, leaving the
    # engine to outlive its parent (observed as a multi-hour orphan).
    background_tasks = []
    if settings.parent_pid:
        background_tasks.append(
            asyncio.create_task(watch_parent(settings.parent_pid, kill_workers)))
    background_tasks.append(asyncio.create_task(telemetry_loop(state, bus)))
    background_tasks.append(asyncio.create_task(retention_loop(state, settings)))

    async def write_handshake() -> None:
        while not server.started:
            await asyncio.sleep(0.05)
        tmp = settings.handshake_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"port": port, "pid": os.getpid(), "version": VERSION,
                       "contract": CONTRACT}, f)
        os.replace(tmp, settings.handshake_file)
        print(f"supervisor ready on 127.0.0.1:{port}", file=sys.stderr)

    background_tasks.append(asyncio.create_task(write_handshake()))
    await server.serve(sockets=[sock])  # uvicorn installs SIGTERM/SIGINT handlers


def cli() -> None:
    ap = argparse.ArgumentParser(prog="local-music-gen-engine")
    ap.add_argument("--handshake-file", required=True)
    ap.add_argument("--parent-pid", type=int, default=None)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--log-level", default="info")
    args = ap.parse_args()

    token = os.environ.get("LOCALMUSICGEN_AUTH_TOKEN") or ""
    if not token:
        token = secrets.token_hex(16)
        print(f"LOCALMUSICGEN_AUTH_TOKEN not set; using {token}", file=sys.stderr)

    settings = Settings(data_dir=args.data_dir, output_dir=args.output_dir,
                        handshake_file=args.handshake_file,
                        parent_pid=args.parent_pid, auth_token=token,
                        log_level=args.log_level)
    asyncio.run(run(settings))


if __name__ == "__main__":
    cli()

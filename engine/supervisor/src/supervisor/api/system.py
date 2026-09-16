from __future__ import annotations

import asyncio
import os
import shutil
import signal
import sys

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

from .. import VERSION
from ..state import EngineState
from ..telemetry import machine_model, physical_ram_bytes

router = APIRouter()


def _engine(request: Request) -> EngineState:
    return request.app.state.engine


@router.get("/healthz")
async def healthz(request: Request):
    return {"status": "ok", "version": VERSION,
            "uptime_s": _engine(request).uptime_s()}


def _library_free_bytes(st: EngineState) -> int | None:
    """Free space where weights land.

    The library folder may be configured but not created yet, or on a
    volume that is not mounted; the nearest existing ancestor is what
    `disk_usage` can answer for, and a folder with no answer at all is
    reported as unknown rather than as the boot disk's figure.
    """
    from ..library import _nearest_existing
    try:
        return shutil.disk_usage(_nearest_existing(st.settings.hf_cache_dir)).free
    except OSError:
        return None


@router.get("/v1/system")
async def system(request: Request):
    st = _engine(request)
    worker = st.queue.worker
    small = [w for w in st.queue.small_workers.values() if w.is_alive()]
    active = st.queue.active
    return {"ram_bytes": physical_ram_bytes(),
            # The data folder's volume — outputs, the database, the logs.
            "free_disk_bytes": shutil.disk_usage(st.settings.data_dir).free,
            # The library's volume, where a download lands. A different disk
            # on any Mac whose library was relocated, and the one every
            # "will this model fit" question in the app is really about.
            "library_free_disk_bytes": _library_free_bytes(st),
            "machine": machine_model(),
            "warm_family": worker.family if worker and worker.is_alive() else None,
            "warm_model_id": worker.loaded_model_id
            if worker and worker.is_alive() else None,
            # Small models held in the warm pool; they never displace
            # warm_model_id above, and are dropped after an idle period.
            "transient_model_ids": [w.loaded_model_id for w in small
                                    if w.loaded_model_id],
            "pinned_model_id": st.queue.pinned_model_id,
            "active_job_id": active.id if active else None,
            # A hold stops the queue starting anything; `active_job_id` is
            # still set while the take it could not stop finishes (5.7).
            "queue_held": st.queue.held,
            "memory_guard": {
                "limit_bytes": st.settings.mem_guard_bytes,
                # `or None`: mem_bytes starts at 0 and the sampler waits 2 s
                # for its first reading, so a worker mid-cold-load would
                # otherwise report a confident 0 — which the sidebar draws as
                # "0.0 / 36 GB". Matches `state.usage()` right below.
                "worker_bytes": (worker.mem_bytes or None)
                if worker and worker.is_alive() else None,
            },
            "accelerator": st.accelerator(),
            "usage": st.usage(),
            "engine_versions": {"python": sys.version.split()[0],
                                "supervisor": VERSION}}


@router.post("/v1/worker/unload", status_code=202)
async def worker_unload(request: Request):
    """Free the resident model now (409 ENGINE_BUSY while a job is active)."""
    from ..jobqueue import SubmitError
    from .errors import err
    st = _engine(request)
    try:
        st.queue.unload_worker()
    except SubmitError as e:
        return err(e.status, e.code, str(e))
    return {}


@router.post("/v1/shutdown", status_code=202)
async def shutdown():
    asyncio.get_running_loop().call_later(
        0.2, lambda: os.kill(os.getpid(), signal.SIGTERM))
    return {}


@router.post("/v1/settings/hf-token", status_code=204)
async def hf_token(request: Request, body: dict):
    _engine(request).hf_token = body.get("token")
    return None


@router.get("/v1/events")
async def events(request: Request):
    st = _engine(request)
    return StreamingResponse(
        st.bus.stream(request.headers.get("last-event-id")),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

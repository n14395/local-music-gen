from __future__ import annotations

from fastapi import APIRouter, Request

from ..library import LibraryError
from ..state import EngineState
from .errors import err

router = APIRouter()


def _engine(request: Request) -> EngineState:
    return request.app.state.engine


@router.get("/v1/models/library")
async def library_info(request: Request):
    """Where the model library is, how much of it is ours, and how much room
    the disk it sits on has left (contract §4.4)."""
    import anyio

    # Off the event loop: this walks every one of our repo directories, which
    # on a full library is tens of thousands of stat calls.
    return await anyio.to_thread.run_sync(_engine(request).library.info)


@router.get("/v1/models/library/verify")
async def library_verify(request: Request):
    import anyio

    return await anyio.to_thread.run_sync(_engine(request).library.verify)


@router.post("/v1/models/library/clear", status_code=202)
async def library_clear(request: Request, body: dict | None = None):
    st = _engine(request)
    try:
        return st.library.start_clear((body or {}).get("scope") or "all")
    except LibraryError as e:
        return err(e.status, e.code, str(e))


@router.post("/v1/models/library/relocate", status_code=202)
async def library_relocate(request: Request, body: dict):
    """Point the library at a new folder, and say what becomes of the models in
    the old one: `move`, `delete` or `leave` (contract §4.4).

    The engine reads HF_HOME once, at launch, so this endpoint only rearranges
    the files — the client applies the new path and restarts the engine when
    `library.completed` names `restart_required`.
    """
    st = _engine(request)
    path = (body.get("path") or "").strip()
    if not path:
        return err(422, "VALIDATION", "path is required")
    try:
        return st.library.start_relocate(path, body.get("disposition") or "move")
    except LibraryError as e:
        return err(e.status, e.code, str(e))


@router.post("/v1/models/library/cancel", status_code=202)
async def library_cancel(request: Request):
    _engine(request).library.cancel()
    return {}

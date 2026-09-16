"""Transient audio uploads referenced by job params of type "audio".

Raw-body POST (no multipart) keeps the client trivial; the uploads directory is
purged at engine startup (jobs are in-memory, so upload ids cannot usefully
outlive the engine).
"""

from __future__ import annotations

import os
import shutil
import uuid

from fastapi import APIRouter, Request

from ..state import EngineState
from .errors import err

# 256 MB fits roughly a 25-minute stereo 16/44.1 WAV, or 12 minutes at 24/96.
# This used to claim longer sources were "FLAC-compressed app-side before
# upload": there is no such path anywhere in the app — wav/aiff are passthrough
# on import and `uploadAudio` streams the stored file as it is — so a long
# recording really does arrive at full size and really is refused.
MAX_UPLOAD_BYTES = 256 * 1024 * 1024

router = APIRouter()


def _engine(request: Request) -> EngineState:
    return request.app.state.engine


def resolve_upload(uploads_dir: str, upload_id: str) -> str | None:
    """Upload id → absolute file path, or None if it doesn't resolve."""
    if not isinstance(upload_id, str) or os.path.basename(upload_id) != upload_id:
        return None
    d = os.path.join(uploads_dir, upload_id)
    try:
        names = os.listdir(d)
    except OSError:
        return None
    return os.path.join(d, names[0]) if names else None


def _open_upload(directory: str, name: str):
    """Create the upload's directory and open its file, as one hop off the
    event loop."""
    os.makedirs(directory, exist_ok=True)
    return open(os.path.join(directory, name), "wb")


@router.post("/v1/uploads", status_code=201)
async def upload(request: Request, filename: str = "audio"):
    """Stream the body straight to disk (contract 4.6).

    The client uploads from a file rather than from memory precisely so a
    couple of hundred MB of audio never has to be resident; reading the whole
    body here would hand that saving straight back, and the write that followed
    would hold the event loop — and with it every SSE frame of the render
    running at the time — for as long as the disk took.
    """
    import anyio

    st = _engine(request)
    # A declared length is a refusal that can happen before the bytes do:
    # reading a 400 MB body to the end only to reject it costs the transfer
    # twice over. A chunked upload declares no length, and for that one the
    # read-and-drop path below is still what makes the 422 deliverable.
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > MAX_UPLOAD_BYTES:
        return err(422, "VALIDATION",
                   f"upload exceeds {MAX_UPLOAD_BYTES // (1 << 20)} MB")
    upload_id = f"up_{uuid.uuid4().hex[:12]}"
    safe_name = os.path.basename(filename).strip() or "audio"
    d = os.path.join(st.settings.uploads_dir, upload_id)
    total = 0
    over = False
    kept = False
    f = await anyio.to_thread.run_sync(_open_upload, d, safe_name)
    try:
        async for chunk in request.stream():
            if over or not chunk:
                # Once over the cap we keep reading and drop the bytes: the
                # 422 below only reaches a client that is still being read
                # from, and hanging up on a half-sent upload would reach it as
                # a connection error with nothing in it to explain the refusal.
                continue
            total += len(chunk)
            if total > MAX_UPLOAD_BYTES:
                over = True
                continue
            await anyio.to_thread.run_sync(f.write, chunk)
        kept = total > 0 and not over
    finally:
        # Both of these are cheap enough to do here: close flushes at most the
        # tail of one buffer, and the discard is an unlink and an rmdir. A
        # partial file left behind would be indistinguishable from a good one
        # to everything that later resolves this upload id.
        f.close()
        if not kept:
            shutil.rmtree(d, ignore_errors=True)
    if over:
        return err(422, "VALIDATION",
                   f"upload exceeds {MAX_UPLOAD_BYTES // (1 << 20)} MB")
    if not total:
        return err(422, "VALIDATION", "empty upload body")
    return {"upload_id": upload_id, "bytes": total, "filename": safe_name}

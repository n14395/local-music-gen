"""Transient audio uploads referenced by job params of type "audio".

Raw-body POST (no multipart) keeps the client trivial; the uploads directory is
purged at engine startup (jobs are in-memory, so upload ids cannot usefully
outlive the engine).
"""

from __future__ import annotations

import os
import uuid

from fastapi import APIRouter, Request

from ..state import EngineState
from .errors import err

# 256 MB fits a ~10-minute imported WAV; sources beyond this are FLAC-compressed
# app-side before upload
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


@router.post("/v1/uploads", status_code=201)
async def upload(request: Request, filename: str = "audio"):
    st = _engine(request)
    data = await request.body()
    if not data:
        return err(422, "VALIDATION", "empty upload body")
    if len(data) > MAX_UPLOAD_BYTES:
        return err(422, "VALIDATION",
                   f"upload exceeds {MAX_UPLOAD_BYTES // (1 << 20)} MB")
    upload_id = f"up_{uuid.uuid4().hex[:12]}"
    safe_name = os.path.basename(filename).strip() or "audio"
    d = os.path.join(st.settings.uploads_dir, upload_id)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, safe_name), "wb") as f:
        f.write(data)
    return {"upload_id": upload_id, "bytes": len(data), "filename": safe_name}

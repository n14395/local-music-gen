# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

from fastapi import APIRouter, Request

from .errors import err
from ..downloader import DownloadError
from ..state import EngineState

router = APIRouter()


def _engine(request: Request) -> EngineState:
    return request.app.state.engine


@router.post("/v1/models/{model_id}/download", status_code=202)
async def download_start(request: Request, model_id: str):
    st = _engine(request)
    if model_id not in st.registry.models:
        return err(404, "NOT_FOUND", f"unknown model {model_id}")
    if model_id in st.deleting:
        # The removal runs off the event loop and takes seconds on a large
        # entry; a download started inside that window wrote into the tree
        # being removed and came out partial.
        return err(409, "DELETE_ACTIVE",
                   "this model is being deleted — wait for that to finish")
    try:
        download_id = st.downloads.start(model_id)
    except DownloadError as e:
        return err(409, e.code, str(e))
    return {"download_id": download_id}


@router.post("/v1/models/{model_id}/runtime", status_code=202)
async def runtime_install(request: Request, model_id: str):
    """Install this model's family runtime without touching its weights.

    The repair for a model whose files are already here but whose runtime is
    not — downloaded before the runtime step existed, or left behind when the
    app's adapter was updated. Reported on the same download events as any
    other install (`stage: "provisioning"`, `runtime_only: true`).
    """
    st = _engine(request)
    if model_id not in st.registry.models:
        return err(404, "NOT_FOUND", f"unknown model {model_id}")
    # The family's, not just this model's: deleting the last model of a family
    # removes the family venv, which is exactly what this would be building.
    family = st.registry.models[model_id]["family"]
    if any(st.registry.models[m]["family"] == family for m in st.deleting):
        return err(409, "DELETE_ACTIVE",
                   "a model of this family is being deleted — wait for that "
                   "to finish")
    try:
        download_id = st.downloads.start_runtime(model_id)
    except DownloadError as e:
        return err(409, e.code, str(e))
    return {"download_id": download_id}


@router.get("/v1/downloads")
async def downloads_list(request: Request):
    return {"downloads": _engine(request).downloads.list()}


@router.post("/v1/downloads/{download_id}/pause", status_code=202)
async def download_pause(request: Request, download_id: str):
    st = _engine(request)
    task = st.downloads.get(download_id)
    if not task:
        return err(404, "NOT_FOUND", "unknown download")
    st.downloads.pause(task)
    return {}


@router.post("/v1/downloads/{download_id}/resume", status_code=202)
async def download_resume(request: Request, download_id: str):
    st = _engine(request)
    task = st.downloads.get(download_id)
    if not task:
        return err(404, "NOT_FOUND", "unknown download")
    st.downloads.resume(task)
    return {}


@router.delete("/v1/downloads/{download_id}", status_code=202)
async def download_cancel(request: Request, download_id: str):
    st = _engine(request)
    task = st.downloads.get(download_id)
    if not task:
        return err(404, "NOT_FOUND", "unknown download")
    st.downloads.cancel(task)
    return {}

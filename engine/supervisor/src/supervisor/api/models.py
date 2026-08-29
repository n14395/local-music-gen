from __future__ import annotations

from fastapi import APIRouter, Request

from .errors import err
from ..state import EngineState

router = APIRouter()


def _engine(request: Request) -> EngineState:
    return request.app.state.engine


@router.get("/v1/models")
async def models_list(request: Request):
    import anyio

    # Off the event loop: every entry's install state is answered from the
    # filesystem — a stat of its marker, a listdir of each snapshot, and a walk
    # of anything already on disk — and across the whole catalog that is long
    # enough to be a visible hitch in the event stream, worst of all while a
    # download is writing thousands of files into the same cache.
    return {"models": await anyio.to_thread.run_sync(_engine(request).model_infos)}


@router.get("/v1/models/{model_id}")
async def models_get(request: Request, model_id: str):
    st = _engine(request)
    if model_id not in st.registry.models:
        return err(404, "NOT_FOUND", f"unknown model {model_id}")
    return st.model_info(model_id)


@router.put("/v1/models/{model_id}/pin", status_code=202)
async def models_pin(request: Request, model_id: str, body: dict):
    """Keep this model loaded whenever the queue is idle (see JobQueue.set_pin)."""
    st = _engine(request)
    enabled = bool(body.get("enabled"))
    if model_id not in st.registry.models:
        return err(404, "NOT_FOUND", f"unknown model {model_id}")
    if enabled and not st.registry.is_installed(model_id):
        return err(409, "MODEL_NOT_INSTALLED", f"{model_id} is not installed")
    if enabled:
        st.queue.set_pin(model_id)
    elif st.queue.pinned_model_id == model_id:
        # unpin only removes the reload guarantee; the model stays resident
        # (that's the default now) until unloaded or displaced
        st.queue.set_pin(None)
    st.bus.emit("models.changed", {})
    return {}


@router.delete("/v1/models/{model_id}", status_code=202)
async def models_delete(request: Request, model_id: str):
    st = _engine(request)
    if model_id not in st.registry.models:
        return err(404, "NOT_FOUND", f"unknown model {model_id}")
    if st.downloads.active_for(model_id):
        return err(409, "DOWNLOAD_ACTIVE", "cancel the download first")
    if st.model_in_use(model_id):
        return err(409, "MODEL_IN_USE", "a queued or running job uses this model")
    st.delete_model(model_id)
    st.bus.emit("models.changed", {})
    return {}


@router.post("/v1/models/inspect")
async def models_inspect(request: Request, body: dict):
    import anyio

    from ..inspect_models import UnsupportedModel, inspect_repo

    st = _engine(request)
    repo = (body.get("repo_id") or "").strip()
    try:
        entry = await anyio.to_thread.run_sync(inspect_repo, repo, st.hf_token)
    except UnsupportedModel as e:
        return err(422, "UNSUPPORTED_MODEL", str(e))
    except Exception as e:  # noqa: BLE001 — network/auth failures surface as-is
        return err(422, "UNSUPPORTED_MODEL", f"could not inspect {repo}: {e}")
    entry["install_state"] = "not_installed"
    entry["installed_bytes"] = 0
    # Nothing is persisted by an inspect, but the family's runtime is real
    # whether or not this entry is ever added — a dry run of a model whose
    # family is already installed must not claim it would need one.
    entry["runtime_state"] = st.runtime_state(entry["family"])
    return entry


@router.post("/v1/models/custom", status_code=201)
async def models_custom(request: Request, body: dict):
    import anyio

    from ..inspect_models import UnsupportedModel, inspect_repo

    st = _engine(request)
    repo = (body.get("repo_id") or "").strip()
    try:
        entry = await anyio.to_thread.run_sync(inspect_repo, repo, st.hf_token)
    except UnsupportedModel as e:
        return err(422, "UNSUPPORTED_MODEL", str(e))
    except Exception as e:  # noqa: BLE001
        return err(422, "UNSUPPORTED_MODEL", f"could not inspect {repo}: {e}")
    st.registry.add_user_model(entry)
    st.bus.emit("models.changed", {})
    return st.model_info(entry["id"])

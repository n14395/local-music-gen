from __future__ import annotations

from fastapi import APIRouter, Request

from ..jobqueue import SubmitError
from ..state import EngineState
from .errors import err

router = APIRouter()


def _engine(request: Request) -> EngineState:
    return request.app.state.engine


@router.post("/v1/jobs", status_code=202)
async def jobs_submit(request: Request, body: dict):
    st = _engine(request)
    try:
        return st.queue.submit(body)
    except SubmitError as e:
        return err(e.status, e.code, str(e))


@router.get("/v1/jobs")
async def jobs_list(request: Request, status: str | None = None,
                    group_id: str | None = None):
    st = _engine(request)
    matched = []
    for job in list(st.queue.jobs.values()):
        if group_id and job.group_id != group_id:
            continue
        if status:
            if job.status != status and not (
                    status == "running"
                    and job.status in ("loading", "generating", "encoding")):
                continue
        elif group_id is None and job.status in ("succeeded", "failed", "canceled"):
            continue
        matched.append(job)
    # One call, so the queue lock is taken once and the run order sorted once
    # for the whole listing rather than once per row.
    return {"jobs": st.queue.info_many(matched)}


@router.get("/v1/jobs/{job_id}")
async def jobs_get(request: Request, job_id: str):
    st = _engine(request)
    job = st.queue.jobs.get(job_id)
    if job is None:
        return err(404, "NOT_FOUND", "unknown job")
    return st.queue.info(job)


@router.post("/v1/jobs/{job_id}/cancel", status_code=202)
async def jobs_cancel(request: Request, job_id: str):
    st = _engine(request)
    try:
        st.queue.cancel(job_id)
    except SubmitError as e:
        return err(e.status, e.code, str(e))
    return {}


@router.patch("/v1/jobs/{job_id}/priority", status_code=202)
async def jobs_priority(request: Request, job_id: str, body: dict):
    """Explicit run order for one queued job (contract 5.8)."""
    st = _engine(request)
    raw = body.get("priority")
    # bool is an int in Python and would silently become 1/0
    if not isinstance(raw, int) or isinstance(raw, bool):
        return err(422, "VALIDATION", "priority must be an integer")
    try:
        st.queue.set_priority(job_id, raw)
    except SubmitError as e:
        return err(e.status, e.code, str(e))
    return {}


@router.post("/v1/queue/pause", status_code=202)
async def queue_pause(request: Request):
    """Stop starting queued jobs. The running one is not suspended (5.7)."""
    _engine(request).queue.hold(True)
    return {}


@router.post("/v1/queue/resume", status_code=202)
async def queue_resume(request: Request):
    _engine(request).queue.hold(False)
    return {}


@router.post("/v1/queue/order", status_code=202)
async def queue_order(request: Request, body: dict):
    """Reorder queued jobs in one call (contract 5.8)."""
    st = _engine(request)
    ids = body.get("job_ids")
    if not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
        return err(422, "VALIDATION", "job_ids must be a list of job ids")
    try:
        st.queue.set_order(ids)
    except SubmitError as e:
        return err(e.status, e.code, str(e))
    return {}

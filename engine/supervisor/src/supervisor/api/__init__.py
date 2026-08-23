from __future__ import annotations

from fastapi import FastAPI, Request

from ..state import EngineState
from .errors import err


def build_app(state: EngineState) -> FastAPI:
    from . import (downloads, jobs, library,  # deferred: avoids circular imports
                   models, system, uploads)

    app = FastAPI()
    app.state.engine = state

    @app.middleware("http")
    async def auth(request: Request, call_next):
        if request.url.path != "/healthz":
            expected = f"Bearer {state.settings.auth_token}"
            if request.headers.get("authorization") != expected:
                return err(401, "UNAUTHORIZED", "missing or invalid bearer token")
        return await call_next(request)

    app.include_router(system.router)
    # Before models: "/v1/models/library" must not be caught by the
    # "/v1/models/{model_id}" route, which would look it up as a model id.
    app.include_router(library.router)
    app.include_router(models.router)
    app.include_router(downloads.router)
    app.include_router(jobs.router)
    app.include_router(uploads.router)
    return app

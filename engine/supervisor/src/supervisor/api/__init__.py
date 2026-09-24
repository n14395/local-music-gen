# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import sys
import traceback

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from ..state import EngineState
from .errors import err

# HTTP statuses the framework raises on its own, mapped onto the contract's
# codes. Anything else becomes INTERNAL, which is what an unexpected status is.
_STATUS_CODES = {401: "UNAUTHORIZED", 403: "UNAUTHORIZED", 404: "NOT_FOUND",
                 405: "NOT_FOUND", 422: "VALIDATION"}


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

    # Contract preamble: EVERY non-2xx carries {"error": {code, message,
    # detail}}. Without these three, FastAPI answered an unknown route and a
    # malformed body with its own {"detail": …} and an unhandled exception with
    # plain text — shapes `BackendClient.validated` cannot decode, so the app
    # reported them as INTERNAL "HTTP 404" with nothing in them to act on.
    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request, exc: RequestValidationError):
        return err(422, "VALIDATION", "malformed request",
                   {"errors": [{k: str(v) for k, v in e.items()
                                if k in ("loc", "msg", "type")}
                               for e in exc.errors()]})

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request: Request, exc: StarletteHTTPException):
        code = _STATUS_CODES.get(exc.status_code, "INTERNAL")
        return err(exc.status_code, code, str(exc.detail))

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception):
        # The traceback goes to stderr (the app tails it into today's engine
        # log) — this handler is the only thing between an unexpected KeyError
        # in a handler and a client with nothing but "Internal Server Error".
        traceback.print_exception(type(exc), exc, exc.__traceback__,
                                  file=sys.stderr)
        return err(500, "INTERNAL",
                   f"{type(exc).__name__}: {exc}" if str(exc)
                   else type(exc).__name__)

    app.include_router(system.router)
    # Before models: "/v1/models/library" must not be caught by the
    # "/v1/models/{model_id}" route, which would look it up as a model id.
    app.include_router(library.router)
    app.include_router(models.router)
    app.include_router(downloads.router)
    app.include_router(jobs.router)
    app.include_router(uploads.router)
    return app

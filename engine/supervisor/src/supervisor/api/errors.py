# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

from fastapi.responses import JSONResponse


def err(status: int, code: str, message: str, detail: dict | None = None) -> JSONResponse:
    return JSONResponse(status_code=status,
                        content={"error": {"code": code, "message": message,
                                           "detail": detail or {}}})

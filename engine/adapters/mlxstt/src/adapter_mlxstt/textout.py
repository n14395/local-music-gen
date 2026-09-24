# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Writing a text artifact, shared by both engines in this family."""

from __future__ import annotations

import json
import os


def write_payload(out_dir: str, label: str, payload: dict) -> str:
    """One text artifact, written complete (tmp + rename) per contract 5.2."""
    path = os.path.join(out_dir, f"{label}.json")
    tmp = path + ".part"
    with open(tmp, "w") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp, path)
    return path


def preview(text: str, limit: int = 200) -> str:
    """The short form that rides `result.meta` for a job row."""
    flat = " ".join((text or "").split())
    return flat[:limit]

"""The catalog, loaded once, plus the little accessors the linter needs.

Stdlib only and no engine import on purpose: this group runs under whatever
`python3` is to hand (see `scripts/engine_tests.py`), and the catalog is a
JSON file that has to be checkable without a venv.
"""

from __future__ import annotations

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CATALOG_PATH = os.path.join(SRC, "engine", "catalog", "models.json")

# File-valued params. Their `nullable` flag means something different from
# every other type's: `nullable: false` on one of these is "mandatory
# outright" — `JobQueue.submit` presence-checks them for every task — and the
# default is null precisely because there is no value the worker could fall
# back to. See `scripts/check_supervisor.py::check_required_inputs`.
FILE_TYPES = ("audio", "midi", "json")

NUMERIC_TYPES = ("int", "float")

# Rates a macOS audio pipeline can actually be asked for. An entry outside
# this set is far more likely a typo than a model nobody has heard of.
SANE_SAMPLE_RATES = (8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000)

# `settings.<key>` is the adapter's fallback when the catalog declares no
# param for it; the param's `default` is what the user actually gets. 09-B9:
# when both exist they must agree, or changing nothing changes the render.
SETTING_TO_PARAMS = {
    "steps_default": ("steps", "inference_steps"),
    "cfg_scale_default": ("cfg_scale",),
    "guidance_scale_default": ("guidance_scale",),
}


def load_models() -> list[dict]:
    with open(CATALOG_PATH) as f:
        return json.load(f)["models"]


def params_of(model: dict) -> list[dict]:
    return model["capabilities"].get("params") or []


def param_named(model: dict, key: str) -> dict | None:
    return next((p for p in params_of(model) if p["key"] == key), None)


def choice_values(param: dict) -> list:
    return [c["value"] for c in param.get("choices") or []]


def describe(model: dict, param: dict | None = None) -> str:
    return f"{model['id']}.{param['key']}" if param else model["id"]

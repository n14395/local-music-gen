"""Arbitrary HF model inspection: classify a repo into a supported family by
fetching ONLY its config files — never a snapshot, never remote code.

Supported in v1:
- transformers MusicGen family (config.json architectures Musicgen*)
- diffusers audio pipelines (model_index.json _class_name in the allowlist)

Anything needing trust_remote_code is refused outright: model repos are untrusted
input and remote code would execute on the user's machine.
"""

from __future__ import annotations

import copy
import json

from huggingface_hub import HfApi, hf_hub_download

MUSICGEN_ARCHS = {"MusicgenForConditionalGeneration",
                  "MusicgenMelodyForConditionalGeneration"}
DIFFUSERS_CLASSES = {
    "StableAudioPipeline": 44100,
    "AudioLDM2Pipeline": 16000,
    "AudioLDMPipeline": 16000,
    "MusicLDMPipeline": 16000,
}

# A user-added model runs the same adapter as the catalog's, so it reports the
# same stages. Only the two families this module can classify appear here; keep
# in step with PIPELINES in scripts/build_catalog.py.
PIPELINES = {
    "musicgen": [{"id": "prompt_encode", "label": "Prompt encode"},
                 {"id": "lm_decode", "label": "Token decode"},
                 {"id": "master", "label": "Master & save"}],
    "diffusers": [{"id": "prompt_encode", "label": "Prompt encode"},
                  {"id": "diffusion", "label": "Diffusion"},
                  {"id": "master", "label": "Master & save"}],
}


class UnsupportedModel(Exception):
    pass


def _slug(repo_id: str) -> str:
    return "user-" + repo_id.lower().replace("/", "--").replace("_", "-")


def _fetch_json(repo_id: str, filename: str, token: str | None) -> dict | None:
    try:
        path = hf_hub_download(repo_id, filename, token=token)
    except Exception:  # noqa: BLE001 — missing file / auth / network all mean "no"
        return None
    with open(path) as f:
        return json.load(f)


def _repo_size(repo_id: str, token: str | None) -> tuple[int, bool]:
    api = HfApi(token=token)
    info = api.model_info(repo_id, files_metadata=True)
    size = sum(s.size or 0 for s in info.siblings)
    return size, bool(getattr(info, "gated", False))


def inspect_repo(repo_id: str, token: str | None) -> dict:
    """Return a synthesized catalog entry, or raise UnsupportedModel."""
    if not repo_id or repo_id.count("/") != 1:
        raise UnsupportedModel("expected a repo id like 'org/name'")

    config = _fetch_json(repo_id, "config.json", token)
    if config:
        archs = set(config.get("architectures") or [])
        if config.get("auto_map") or config.get("custom_pipeline"):
            raise UnsupportedModel(
                f"{repo_id} requires trust_remote_code — refusing to run "
                "arbitrary code from a model repo")
        if archs & MUSICGEN_ARCHS:
            return _entry(repo_id, token, family="musicgen",
                          sample_rate=32000, max_s=30,
                          description="Community MusicGen model",
                          params=_musicgen_params())

    index = _fetch_json(repo_id, "model_index.json", token)
    if index:
        cls = index.get("_class_name", "")
        if cls in DIFFUSERS_CLASSES:
            max_s = 47 if cls == "StableAudioPipeline" else 20
            return _entry(repo_id, token, family="diffusers",
                          sample_rate=DIFFUSERS_CLASSES[cls], max_s=max_s,
                          description=f"Diffusers audio pipeline ({cls})",
                          params=_diffusers_params(),
                          settings={"pipeline_class": cls})
        if cls:
            raise UnsupportedModel(
                f"diffusers pipeline '{cls}' is not a supported audio pipeline")

    if config and (archs := set(config.get("architectures") or [])):
        raise UnsupportedModel(
            f"architecture {sorted(archs)} is not supported — only MusicGen-style "
            "models and diffusers audio pipelines can be added")
    raise UnsupportedModel(
        f"{repo_id} has no config.json or model_index.json this app understands")


def _entry(repo_id: str, token: str | None, family: str, sample_rate: int,
           max_s: int, description: str, params: list,
           settings: dict | None = None) -> dict:
    size, gated = _repo_size(repo_id, token)
    entry = {
        "id": _slug(repo_id),
        "family": family,
        "display_name": repo_id.split("/")[1],
        "description": f"{description} — added from {repo_id}",
        "hf_repos": [{"repo_id": repo_id, "gated": gated}],
        "size_bytes": size,
        "capabilities": {
            "supports_lyrics": False,
            "instrumental_only": True,
            "duration": {"min_s": 1, "max_s": max_s,
                         "default_s": min(10, max_s)},
            "sample_rate": sample_rate,
            "outputs_per_job_max": 2,
            "est_seconds_per_audio_second": 3.0,
            "pipeline": copy.deepcopy(PIPELINES.get(family)),
            "params": params,
        },
        "requirements": {"min_ram_bytes": max(int(size * 2.5), 4 << 30),
                         "disk_bytes": size, "speed_tier": "medium"},
        "license": {"name": "See model card", "commercial_use": False,
                    "requires_hf_token": gated,
                    "url": f"https://huggingface.co/{repo_id}"},
        "notes": "User-added model — capabilities are conservative estimates.",
    }
    if settings:
        entry["settings"] = settings
    return entry


# Every control either family exposes is a sampler knob, so the group is a
# constant here rather than the table scripts/build_catalog.py needs.
def _musicgen_params() -> list:
    return [
        {"key": "guidance_scale", "type": "float", "label": "Guidance",
         "default": 3.0, "nullable": False, "min": 1.0, "max": 15.0, "step": 0.5,
         "group": "sampling"},
        {"key": "temperature", "type": "float", "label": "Temperature",
         "default": 1.0, "nullable": False, "min": 0.1, "max": 2.0, "step": 0.1,
         "group": "sampling"},
        {"key": "top_k", "type": "int", "label": "Top-K", "default": 250,
         "nullable": False, "min": 10, "max": 1000, "group": "sampling"},
        {"key": "seed", "type": "int", "label": "Seed", "default": None,
         "nullable": True, "min": 0, "max": 4294967295, "group": "sampling"},
    ]


def _diffusers_params() -> list:
    return [
        {"key": "steps", "type": "int", "label": "Steps", "default": 50,
         "nullable": False, "min": 5, "max": 200, "group": "sampling"},
        {"key": "guidance_scale", "type": "float", "label": "Guidance",
         "default": 3.5, "nullable": False, "min": 1.0, "max": 15.0, "step": 0.5,
         "group": "sampling"},
        {"key": "negative_prompt", "type": "string", "label": "Negative prompt",
         "default": "low quality", "nullable": False, "placeholder": "low quality",
         "group": "sampling"},
        {"key": "seed", "type": "int", "label": "Seed", "default": None,
         "nullable": True, "min": 0, "max": 4294967295, "group": "sampling"},
    ]

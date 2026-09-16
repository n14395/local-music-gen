"""Fakes for the ACE-Step (Python runtime) adapter.

`generate()` reaches into `acestep.inference`, `acestep.constants`, torch and
MLX. All four are injected here so the request the adapter builds can be read
back without a 10 GB model, an accelerator, or a 90 s render.
"""

from __future__ import annotations

import dataclasses
import sys
import types

# Every field the adapter offers `_build_flexible`. The real dataclasses have
# many more; `_build_flexible` filters by signature, which is the behaviour
# under test, so the stand-ins declare exactly what the adapter may send.
PARAM_FIELDS = (
    "task_type", "caption", "lyrics", "instrumental", "duration",
    "inference_steps", "guidance_scale", "seed", "shift", "thinking", "bpm",
    "vocal_language", "keyscale", "timesignature", "use_cot_metas",
    "use_cot_caption", "use_cot_language", "lm_temperature", "lm_cfg_scale",
    "lm_top_p", "audio_codes", "src_audio", "reference_audio",
    "audio_cover_strength", "repainting_start", "repainting_end",
    "flow_edit_morph", "flow_edit_source_caption", "instruction",
    "enable_normalization",
)
CONFIG_FIELDS = ("batch_size", "audio_format", "seeds", "use_random_seed")


def _dataclass(name: str, fields) -> type:
    return dataclasses.make_dataclass(
        name, [(f, object, dataclasses.field(default=None)) for f in fields])


GenerationParams = _dataclass("GenerationParams", PARAM_FIELDS)
GenerationConfig = _dataclass("GenerationConfig", CONFIG_FIELDS)

CALLS: list[dict] = []


def _write_wav(path: str) -> None:
    import numpy as np
    import soundfile as sf

    t = np.arange(8000, dtype=np.float32) / 8000.0
    sf.write(path, 0.2 * np.sin(2 * np.pi * 220.0 * t), 8000, format="WAV",
             subtype="PCM_16")


def fake_generate_music(dit, llm, gen_params, gen_config, save_dir=None,
                        progress=None):
    import os

    path = os.path.join(save_dir, "take.wav")
    _write_wav(path)
    CALLS.append({"params": gen_params, "config": gen_config})
    return types.SimpleNamespace(
        success=True, extra_outputs={},
        audios=[{"path": path, "sample_rate": 8000, "params": {}}])


TASK_INSTRUCTIONS = {
    "repaint": "repaint this", "cover": "cover this",
    "extract": "extract {TRACK_NAME}", "extract_default": "extract",
    "lego": "lego {TRACK_NAME}", "lego_default": "lego",
    "complete": "complete {TRACK_CLASSES}", "complete_default": "complete",
}


class FakeWaveletCache:
    def __init__(self) -> None:
        self._cache = {("mps", "float32", "haar"): object()}


def install_fake_runtime() -> None:
    """acestep.inference / acestep.constants / torch / mlx.core."""
    if "acestep.inference" not in sys.modules:
        package = types.ModuleType("acestep")
        inference = types.ModuleType("acestep.inference")
        inference.GenerationParams = GenerationParams
        inference.GenerationConfig = GenerationConfig
        inference.generate_music = fake_generate_music
        constants = types.ModuleType("acestep.constants")
        constants.TASK_INSTRUCTIONS = TASK_INSTRUCTIONS
        package.inference = inference
        package.constants = constants
        sys.modules["acestep"] = package
        sys.modules["acestep.inference"] = inference
        sys.modules["acestep.constants"] = constants
    if "torch" not in sys.modules:
        torch = types.ModuleType("torch")
        torch.manual_seed = lambda _s: None
        sys.modules["torch"] = torch
    if "mlx.core" not in sys.modules:
        mlx = types.ModuleType("mlx")
        core = types.ModuleType("mlx.core")
        core.random = types.SimpleNamespace(seed=lambda _s: None)
        core.clear_cache = lambda: None
        mlx.core = core
        sys.modules["mlx"] = mlx
        sys.modules["mlx.core"] = core


def install_fake_wavelet_cache() -> FakeWaveletCache:
    module = types.ModuleType("acestep.models.common.dcw_loader")
    cache = FakeWaveletCache()
    module.WAVELET_CACHE = cache
    sys.modules["acestep.models.common.dcw_loader"] = module
    return cache


def noop_progress(fraction, message, **kwargs) -> None:
    pass

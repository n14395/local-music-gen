"""Stable Audio Open: ask up front whether the sampler takes a callback.

09-B5 — the old `except TypeError` wrapped the whole render, so a TypeError
raised anywhere inside the model, the conditioner or the preview decode ran
the entire diffusion a second time with no progress and no cancel, and
reported the retry's traceback instead of the real one.
09-B9 — `steps`/`cfg_scale` fall back to the catalog entry's own defaults.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
import types
import unittest

import torch

CALLS: list[dict] = []
RAISE: list[BaseException] = []


def fake_generate_diffusion_cond(model=None, steps=None, cfg_scale=None,
                                 conditioning=None, sample_size=None,
                                 seed=None, device=None, callback=None,
                                 apg_scale=None, sampler_type=None,
                                 negative_conditioning=None, init_audio=None,
                                 init_noise_level=None):
    CALLS.append({"steps": steps, "cfg_scale": cfg_scale,
                  "sampler_type": sampler_type, "apg_scale": apg_scale,
                  "callback": callback})
    if RAISE:
        raise RAISE[0]
    return torch.zeros(1, 2, 8000)


def _install_fake_tools() -> None:
    if "stable_audio_tools.inference.generation" in sys.modules:
        return
    generation = types.ModuleType("stable_audio_tools.inference.generation")
    generation.generate_diffusion_cond = fake_generate_diffusion_cond
    inference = types.ModuleType("stable_audio_tools.inference")
    inference.generation = generation
    package = types.ModuleType("stable_audio_tools")
    package.inference = inference
    sys.modules["stable_audio_tools"] = package
    sys.modules["stable_audio_tools.inference"] = inference
    sys.modules["stable_audio_tools.inference.generation"] = generation


_install_fake_tools()

from adapter_stableaudio.adapter import (StableAudioAdapter,  # noqa: E402
                                         _takes_callback)
from engine_protocol.adapter import CancelToken  # noqa: E402


def _noop(fraction, message, **kwargs) -> None:
    pass


class TakesCallbackTest(unittest.TestCase):
    """09-B5 — the four answers, none of them "run it and see"."""

    def test_explicit_callback_parameter(self) -> None:
        def fn(x, callback=None):
            pass

        self.assertTrue(_takes_callback(fn))

    def test_var_keyword_catch_all(self) -> None:
        def fn(x, **sampler_kwargs):
            pass

        self.assertTrue(_takes_callback(fn))

    def test_neither(self) -> None:
        def fn(x, y=1):
            pass

        self.assertFalse(_takes_callback(fn))

    def test_c_builtin_without_a_signature(self) -> None:
        self.assertFalse(_takes_callback(time.time))


class RenderErrorTest(unittest.TestCase):
    """09-B5 — the real failure is reported, and reported once."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        CALLS.clear()
        RAISE.clear()
        self.adapter = StableAudioAdapter("stableaudio-test", {},
                                          self.tmp.name,
                                          {"steps_default": 50,
                                           "cfg_scale_default": 7.0})
        self.adapter.model = object()
        self.adapter.config = {"sample_rate": 8000, "sample_size": 8000}
        self.out = os.path.join(self.tmp.name, "take.wav")

    def _render(self, params=None):
        return self.adapter.generate("a prompt", None,
                                     {"duration_s": 1.0, **(params or {})},
                                     self.out, _noop, CancelToken())

    def test_a_type_error_inside_the_render_is_not_retried(self) -> None:
        RAISE.append(TypeError("something deep inside the model"))
        with self.assertRaises(TypeError):
            self._render()
        self.assertEqual(len(CALLS), 1)

    def test_steps_fall_back_to_the_catalog_entrys_default(self) -> None:
        """09-B9: adapter fallback == the entry's declared default."""
        self._render()
        self.assertEqual(CALLS[0]["steps"], 50)

    def test_cfg_scale_falls_back_to_the_catalog_entrys_default(self) -> None:
        """09-B9: guidance switched off used to disable the negative prompt."""
        self._render()
        self.assertEqual(CALLS[0]["cfg_scale"], 7.0)


if __name__ == "__main__":
    unittest.main()

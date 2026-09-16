"""Stable Audio 3: the callback probe, the catalog's step default, and the
one-audio-input rule.

09-B5 — a TypeError from inside the render used to re-run the whole diffusion.
09-B9 — `steps` falls back to the entry's `steps_default`, not to Small's 8.
09-B10 — a second audio attachment used to vanish without a word.
"""

from __future__ import annotations

import contextlib
import io
import os
import tempfile
import time
import types
import unittest

import numpy as np
import soundfile as sf
import torch

from adapter_stableaudio3.adapter import (StableAudio3Adapter,  # noqa: E402
                                          _takes_callback)
from engine_protocol.adapter import CancelToken  # noqa: E402


def _noop(fraction, message, **kwargs) -> None:
    pass


def _write_wav(path: str, seconds: float, sample_rate: int = 8000) -> str:
    t = np.arange(int(seconds * sample_rate), dtype=np.float32) / sample_rate
    sf.write(path, 0.2 * np.sin(2 * np.pi * 220.0 * t), sample_rate,
             format="WAV", subtype="PCM_16")
    return path


class FakeSA:
    """The library handle `load()` builds, minus the 4 GB of weights."""

    def __init__(self) -> None:
        self.model_config = {"sample_size": 8000}
        self.model = types.SimpleNamespace(sample_rate=8000, pretransform=None)
        self.calls: list[dict] = []
        self.raise_with: BaseException | None = None

    def generate(self, *, prompt=None, duration=None, steps=None,
                 cfg_scale=None, seed=None, sample_size=None, callback=None,
                 negative_prompt=None, inpaint_audio=None,
                 inpaint_mask_start_seconds=None,
                 inpaint_mask_end_seconds=None, init_audio=None,
                 init_noise_level=None):
        self.calls.append({"steps": steps, "cfg_scale": cfg_scale,
                           "duration": duration, "callback": callback})
        if self.raise_with is not None:
            raise self.raise_with
        return torch.zeros(1, 2, 8000)


class TakesCallbackTest(unittest.TestCase):
    """09-B5 — the four answers."""

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


class GenerateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = StableAudio3Adapter("sa3-test", {}, self.tmp.name,
                                           {"steps_default": 50})
        self.sa = FakeSA()
        self.adapter.sa = self.sa
        self.adapter.sample_rate = 8000
        self.out = os.path.join(self.tmp.name, "take.wav")

    def _render(self, params=None):
        return self.adapter.generate("a prompt", None,
                                     {"duration_s": 1.0, **(params or {})},
                                     self.out, _noop, CancelToken())

    def test_a_type_error_inside_the_render_is_not_retried(self) -> None:
        """09-B5: one call, and the real traceback."""
        self.sa.raise_with = TypeError("something deep inside the sampler")
        with self.assertRaises(TypeError):
            self._render()
        self.assertEqual(len(self.sa.calls), 1)

    def test_steps_fall_back_to_the_catalog_entrys_default(self) -> None:
        """09-B9: adapter fallback == the entry's declared default."""
        self._render()
        self.assertEqual(self.sa.calls[0]["steps"], 50)

    def test_a_second_audio_input_says_it_was_dropped(self) -> None:
        """09-B10: exactly one line, naming the key that lost."""
        inpaint = _write_wav(os.path.join(self.tmp.name, "a.wav"), 2.0)
        extend = _write_wav(os.path.join(self.tmp.name, "b.wav"), 2.0)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self._render({"inpaint_audio": inpaint, "extend_audio": extend})
        lines = [line for line in err.getvalue().splitlines() if line.strip()]
        self.assertEqual(len(lines), 1)
        self.assertIn("extend_audio", lines[0])
        self.assertIn("inpaint_audio", lines[0])


if __name__ == "__main__":
    unittest.main()

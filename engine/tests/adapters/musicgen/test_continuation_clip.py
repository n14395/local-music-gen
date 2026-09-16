"""MusicGen (transformers path): the continuation excerpt and dropped inputs.

The excerpt's channel count is not optional — EnCodec's feature extractor
transposes whatever it is handed and checks the last axis, so a stereo
checkpoint wants (channels, samples) and a mono one a flat (samples,).
09-B10: a melody file handed to a checkpoint with no chroma conditioner used
to be dropped in silence.
"""

from __future__ import annotations

import contextlib
import io
import os
import tempfile
import types
import unittest

import numpy as np
import soundfile as sf
import torch

from adapter_musicgen.adapter import CONTINUE_PROMPT_S, MusicGenAdapter
from engine_protocol.adapter import CancelToken

RATE = 8000


def _noop(fraction, message, **kwargs) -> None:
    pass


def _write_wav(path: str, seconds: float, channels: int = 2) -> str:
    t = np.arange(int(seconds * RATE), dtype=np.float32) / RATE
    tone = 0.2 * np.sin(2 * np.pi * 220.0 * t)
    sf.write(path, np.tile(tone[:, None], (1, channels)), RATE, format="WAV",
             subtype="PCM_16")
    return path


class _FakeTensor:
    def to(self, device):
        return self


class _FakeModel:
    def __init__(self) -> None:
        self.config = types.SimpleNamespace(
            audio_encoder=types.SimpleNamespace(sampling_rate=RATE))

    def generate(self, **kwargs):
        return torch.zeros(1, 1, RATE)


class ContinuationClipTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = MusicGenAdapter("musicgen-test", {}, self.tmp.name, {})
        self.adapter.model = _FakeModel()
        self.src = _write_wav(os.path.join(self.tmp.name, "src.wav"), 12.0)

    def _clip(self, feature_size: int):
        self.adapter.processor = types.SimpleNamespace(
            feature_extractor=types.SimpleNamespace(
                feature_size=feature_size, sampling_rate=RATE))
        return self.adapter._continuation_clip(self.src)

    def test_the_excerpt_is_the_tail_not_the_opening(self) -> None:
        clip, rate = self._clip(1)
        self.assertEqual(rate, RATE)
        self.assertEqual(clip.shape[-1], int(CONTINUE_PROMPT_S * RATE))

    def test_a_stereo_checkpoint_gets_channels_first(self) -> None:
        """"Expected stereo audio but example has 320000 channels" was the
        length talking."""
        clip, _rate = self._clip(2)
        self.assertEqual(clip.shape, (2, int(CONTINUE_PROMPT_S * RATE)))

    def test_a_mono_checkpoint_gets_a_flat_array(self) -> None:
        clip, _rate = self._clip(1)
        self.assertEqual(clip.ndim, 1)


class DroppedMelodyTest(unittest.TestCase):
    """09-B10 — one line, naming the input that was dropped."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = MusicGenAdapter("musicgen-test", {}, self.tmp.name, {})
        self.adapter.model = _FakeModel()
        self.adapter.processor = lambda **kwargs: {"input_ids": _FakeTensor()}
        self.adapter.is_melody = False

    def test_a_melody_on_a_plain_checkpoint_says_so(self) -> None:
        melody = _write_wav(os.path.join(self.tmp.name, "melody.wav"), 2.0)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.adapter.generate("a prompt", None,
                                  {"duration_s": 1.0, "melody_audio": melody,
                                   "seed": 5},
                                  os.path.join(self.tmp.name, "take.wav"),
                                  _noop, CancelToken())
        lines = [line for line in err.getvalue().splitlines() if line.strip()]
        self.assertEqual(len(lines), 1)
        self.assertIn("melody_audio", lines[0])

    def test_continuation_on_a_melody_checkpoint_raises_instead(self) -> None:
        """The same argument, a different mechanism — say so rather than
        quietly doing the other thing."""
        self.adapter.is_melody = True
        src = _write_wav(os.path.join(self.tmp.name, "src.wav"), 2.0)
        with self.assertRaises(RuntimeError):
            self.adapter.generate("a prompt", None,
                                  {"duration_s": 1.0, "continue_audio": src},
                                  os.path.join(self.tmp.name, "take.wav"),
                                  _noop, CancelToken())


if __name__ == "__main__":
    unittest.main()

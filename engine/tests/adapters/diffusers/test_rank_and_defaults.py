"""The generic diffusers audio adapter: CLAP ranking and catalog defaults.

09-B8 — `_rank` moves the pipeline's LIVE text encoder to CPU to retry, and
the move back has to happen even when the CPU attempt also fails: otherwise
the next generate on the warm worker died with a device mismatch that named
nothing about ranking.
09-B9 — `steps`/`guidance_scale` fall back to the entry's declared defaults.
"""

from __future__ import annotations

import contextlib
import io
import os
import tempfile
import types
import unittest

import numpy as np

from adapter_diffusers.adapter import DiffusersAudioAdapter
from engine_protocol.adapter import CancelToken


def _noop(fraction, message, **kwargs) -> None:
    pass


class _FakeTensor:
    def to(self, device):
        return self


class _FailingEncoder:
    """A CLAP text tower that is broken on every device."""

    def __init__(self) -> None:
        self.to_calls: list[str] = []

    def get_audio_features(self, *args, **kwargs):     # presence is the probe
        raise AssertionError("not called by _rank")

    def to(self, device) -> None:
        self.to_calls.append(str(device))

    def __call__(self, **kwargs):
        raise RuntimeError("no kernel for this op on this device")


class _FakeExtractor:
    sampling_rate = 16000

    def __call__(self, resampled, return_tensors=None, sampling_rate=None):
        return types.SimpleNamespace(input_features=_FakeTensor())


def _fake_tokenizer(texts, return_tensors=None, padding=None):
    return {"input_ids": _FakeTensor()}


class FakePipe:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def __call__(self, prompt=None, num_inference_steps=None,
                 guidance_scale=None, negative_prompt=None, generator=None,
                 num_waveforms_per_prompt=None, audio_end_in_s=None,
                 callback_on_step_end=None):
        self.calls.append({"num_inference_steps": num_inference_steps,
                           "guidance_scale": guidance_scale})
        return types.SimpleNamespace(
            audios=[np.zeros(16000, dtype=np.float32)])


class RankTest(unittest.TestCase):
    """09-B8 — a failed ranking is not a failed render, and leaves no mess."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = DiffusersAudioAdapter("diffusers-test", {},
                                             self.tmp.name, {})
        self.encoder = _FailingEncoder()
        self.adapter.pipe = types.SimpleNamespace(
            text_encoder=self.encoder, feature_extractor=_FakeExtractor(),
            tokenizer=_fake_tokenizer)

    def _rank(self):
        takes = [np.zeros(1600, dtype=np.float32) for _ in range(3)]
        with contextlib.redirect_stderr(io.StringIO()):
            return self.adapter._rank(takes, "a prompt", 16000)

    def test_an_encoder_that_fails_everywhere_keeps_the_first_take(self) -> None:
        self.assertEqual(self._rank(), (0, None))

    def test_the_encoder_is_left_on_the_pipeline_device(self) -> None:
        """09-B8: the move back happens even when the CPU retry also raises."""
        self._rank()
        self.assertEqual(self.encoder.to_calls[-1], self.adapter.device)

    def test_ranking_is_skipped_without_an_audio_tower(self) -> None:
        """AudioLDM 1 has no `get_audio_features`: take zero, no score."""
        self.adapter.pipe = types.SimpleNamespace(
            text_encoder=object(), feature_extractor=_FakeExtractor(),
            tokenizer=_fake_tokenizer)
        self.assertEqual(self.adapter._rank([], "a prompt", 16000), (0, None))


class CatalogDefaultsTest(unittest.TestCase):
    """09-B9 — the fallback is the entry's, not a constant."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = DiffusersAudioAdapter(
            "diffusers-test", {}, self.tmp.name,
            {"steps_default": 50, "guidance_scale_default": 2.0})
        self.pipe = FakePipe()
        self.adapter.pipe = self.pipe

    def _render(self, params=None) -> None:
        self.adapter.generate("a prompt", None, {"duration_s": 1.0,
                                                 **(params or {})},
                              os.path.join(self.tmp.name, "take.wav"), _noop,
                              CancelToken())

    def test_steps_come_from_the_entry_when_the_job_omits_them(self) -> None:
        self._render()
        self.assertEqual(self.pipe.calls[0]["num_inference_steps"], 50)

    def test_guidance_comes_from_the_entry_when_the_job_omits_it(self) -> None:
        self._render()
        self.assertEqual(self.pipe.calls[0]["guidance_scale"], 2.0)

    def test_an_explicit_step_count_still_wins(self) -> None:
        self._render({"steps": 7})
        self.assertEqual(self.pipe.calls[0]["num_inference_steps"], 7)


if __name__ == "__main__":
    unittest.main()

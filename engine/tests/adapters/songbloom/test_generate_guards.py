"""SongBloom's render guards, the block-sampler wrapper and its unload.

The sampler froze `max_frames` at load from the yaml's 150 s; without a
per-render update the duration slider was dead and every take decoded to EOS
(audit §2). The per-block wrapper is the render's only cancel checkpoint and
its only real progress — three messages across a possible 55-minute render
before it existed (audit §3/§5).

No weights: the "model" is a fake with the two seams the adapter reaches for.
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np
import torch
from adapter_songbloom import adapter as songbloom
from adapter_songbloom.adapter import SongBloomAdapter
from engine_protocol.adapter import CancelledError, CancelToken

LYRICS = "[verse] la la , [chorus] la la"
SR = 48000


class Progress:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def __call__(self, fraction, message, *, phase=None, step=None,
                 steps=None) -> None:
        self.calls.append({"fraction": fraction, "message": message,
                           "step": step, "steps": steps})

    def messages(self, needle: str) -> list[str]:
        return [c["message"] for c in self.calls if needle in c["message"]]


class CancelAfter:
    def __init__(self, n: int) -> None:
        self.n = n
        self.asks = 0

    @property
    def cancelled(self) -> bool:
        self.asks += 1
        return self.asks > self.n


class FakeDiffusion:
    block_size = 32

    def __init__(self, blocks: int) -> None:
        self.blocks = blocks
        self.calls = 0

    def _sample_next_block(self, *a, **kw):
        self.calls += 1
        return None


class FakeModel:
    sample_rate = SR

    def __init__(self, blocks: int = 60) -> None:
        self.diffusion = FakeDiffusion(blocks)
        self.generation_params: dict = {}
        self.prompt_wav = None

    def set_generation_params(self, **kwargs) -> None:
        self.generation_params.update(kwargs)

    def generate(self, lyrics, prompt_wav):
        self.lyrics = lyrics
        self.prompt_wav = prompt_wav
        for _ in range(self.diffusion.blocks):
            self.diffusion._sample_next_block()
        return torch.zeros(1, SR // 10)


class RenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.style = os.path.join(self.tmp.name, "style.wav")
        import soundfile as sf
        sf.write(self.style, np.zeros(SR * 12, dtype="float32"), SR,
                 format="WAV", subtype="PCM_16")
        self.out = os.path.join(self.tmp.name, "take.wav")
        self.progress = Progress()
        self.adapter = SongBloomAdapter("songbloom", {}, self.tmp.name, {})
        self.adapter._cfg = type("Cfg", (), {"max_dur": 150})()

    def render(self, model=None, cancel=None, **params):
        self.adapter.model = model or FakeModel()
        return self.adapter.generate(
            "a hazy waltz", LYRICS,
            {"style_audio": self.style, "duration_s": 60.0, **params},
            self.out, self.progress, cancel or CancelToken())

    def test_lyrics_are_required_and_the_format_is_pointed_at(self):
        self.adapter.model = FakeModel()
        with self.assertRaises(RuntimeError) as caught:
            self.adapter.generate("x", "  ", {"style_audio": self.style},
                                  self.out, self.progress, CancelToken())
        self.assertIn("lyrics hint", str(caught.exception))

    def test_a_style_clip_is_required_and_its_length_is_named(self):
        self.adapter.model = FakeModel()
        with self.assertRaises(RuntimeError) as caught:
            self.adapter.generate("x", LYRICS, {}, self.out, self.progress,
                                  CancelToken())
        self.assertIn("style_audio", str(caught.exception))
        self.assertIn("10 s", str(caught.exception))

    def test_the_duration_slider_reaches_the_sampler(self):
        """audit §2: max_frames froze at load and every take ran to EOS."""
        model = FakeModel()
        self.render(model=model, duration_s=45.0)
        self.assertEqual(model.generation_params["max_frames"], 45 * 25)
        self.assertEqual(self.adapter._cfg.max_dur, 45)

    def test_the_duration_is_capped_at_the_models_own_ceiling(self):
        model = FakeModel()
        self.render(model=model, duration_s=600.0)
        self.assertEqual(model.generation_params["max_frames"], 150 * 25)

    def test_every_block_is_a_progress_report(self):
        """audit §5: three messages across a possible 55-minute render."""
        model = FakeModel(blocks=10)
        self.render(model=model)
        self.assertEqual(
            len(self.progress.messages("writing the song — block")), 10)

    def test_a_cancel_between_blocks_raises_cancelled(self):
        """audit §3: the wrapper is the render's only cancel checkpoint."""
        model = FakeModel(blocks=10)
        with self.assertRaises(CancelledError):
            self.render(model=model, cancel=CancelAfter(3))
        self.assertLess(model.diffusion.calls, 10)

    def test_the_sampler_is_unwrapped_after_a_cancelled_render(self):
        model = FakeModel(blocks=10)
        original = model.diffusion._sample_next_block
        with self.assertRaises(CancelledError):
            self.render(model=model, cancel=CancelAfter(3))
        self.assertEqual(model.diffusion._sample_next_block, original)

    def test_the_style_clip_is_trimmed_to_ten_seconds(self):
        """SongBloom sets its sound from a ~10 s reference."""
        model = FakeModel(blocks=1)
        self.render(model=model)
        self.assertEqual(model.prompt_wav.shape, (1, 10 * SR))

    def test_a_drawn_seed_is_reported_back(self):
        result = self.render(model=FakeModel(blocks=1))
        self.assertIsInstance(result.seed_used, int)
        self.assertEqual(
            self.render(model=FakeModel(blocks=1), seed=7).seed_used, 7)

    def test_a_finished_render_leaves_no_part_file(self):
        self.render(model=FakeModel(blocks=1))
        self.assertNotIn("take.wav.part", os.listdir(self.tmp.name))
        self.assertIn("take.wav", os.listdir(self.tmp.name))


class UnloadTests(unittest.TestCase):
    """10-B12: rebinding frees the Python objects; the Metal arena the DiT
    and its codec filled stays checked out until the allocator is told."""

    def test_the_model_is_dropped_before_the_allocator_flush(self):
        adapter = SongBloomAdapter("songbloom", {}, "/tmp", {})
        adapter.model = FakeModel()
        seen: list[object] = []
        with mock.patch.object(songbloom, "release_accelerator_memory",
                               lambda: seen.append(adapter.model)):
            adapter.unload()
        self.assertEqual(seen, [None])

    def test_the_allocator_is_flushed_exactly_once(self):
        adapter = SongBloomAdapter("songbloom", {}, "/tmp", {})
        calls = []
        with mock.patch.object(songbloom, "release_accelerator_memory",
                               lambda: calls.append(1)):
            adapter.unload()
        self.assertEqual(len(calls), 1)


class SettingsTests(unittest.TestCase):
    def test_the_variant_and_device_come_from_the_entry(self):
        default = SongBloomAdapter("songbloom", {}, "/tmp", {})
        self.assertEqual(default.variant, "songbloom_full_150s_dpo")
        self.assertEqual(default.device, "cpu")
        picked = SongBloomAdapter("songbloom", {}, "/tmp",
                                  {"variant": "songbloom_full_150s",
                                   "device": "mps"})
        self.assertEqual(picked.variant, "songbloom_full_150s")
        self.assertEqual(picked.device, "mps")

    def test_the_mps_fallback_is_armed_at_import(self):
        self.assertEqual(os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK"), "1")


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

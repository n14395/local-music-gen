"""audiocraft: continuation length, the style-excerpt pad, and dropped inputs.

09-B2/M44: `duration` here counts prompt + continuation, and the old 30 s clamp
on the sum meant anything past ~20 s of new music came back short without a
word (a 30 s request returned 20 s, and so did a 600 s one).
09-B10: a second audio input used to vanish silently.
"""

from __future__ import annotations

import contextlib
import io
import os
import tempfile
import unittest

import torch
from _fixtures import FakeModel, noop_progress, write_wav

from adapter_audiocraft.adapter import (CONTINUE_PROMPT_S, AudiocraftAdapter,
                                        _pad_to_excerpt, _tail_clip)
from engine_protocol.adapter import CancelToken


class TailClipTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_tail_clip_keeps_the_end_not_the_start(self) -> None:
        """A continuation continues an ending."""
        path = write_wav(os.path.join(self.tmp.name, "src.wav"), 12.0)
        clip, rate = _tail_clip(path, CONTINUE_PROMPT_S)
        self.assertEqual(rate, 8000)
        self.assertEqual(clip.shape[-1], int(CONTINUE_PROMPT_S * 8000))


class PadToExcerptTest(unittest.TestCase):
    def test_short_style_reference_is_looped_to_the_excerpt(self) -> None:
        """A 2 s loop under a 3 s excerpt used to raise "empty range"."""
        wav = torch.ones(1, 2 * 8000)
        padded = _pad_to_excerpt(wav, 8000, 3.0)
        self.assertGreaterEqual(padded.shape[-1], int(3.0 * 8000))

    def test_long_enough_reference_is_left_alone(self) -> None:
        wav = torch.ones(1, 5 * 8000)
        self.assertIs(_pad_to_excerpt(wav, 8000, 3.0), wav)


class ContinuationWindowTest(unittest.TestCase):
    """09-B2/M44 — the continuation's own generation params."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = AudiocraftAdapter("audiocraft-test", {}, self.tmp.name,
                                         {"device": "cpu"})
        self.model = FakeModel(seconds=55.0)
        self.adapter.model = self.model
        self.src = write_wav(os.path.join(self.tmp.name, "src.wav"), 12.0)
        self.out = os.path.join(self.tmp.name, "take.wav")

    def _render(self, duration_s: float):
        return self.adapter.generate(
            "a prompt", None,
            {"duration_s": duration_s, "continue_audio": self.src, "seed": 3},
            self.out, noop_progress, CancelToken())

    def test_continuation_past_thirty_seconds_is_not_clamped(self) -> None:
        """09-B2: 45 s of new music over a 10 s prompt asks for 55 s."""
        self._render(45.0)
        self.assertEqual(self.model.calls, ["generate_continuation"])
        self.assertEqual(self.model.params[-1]["duration"],
                         45.0 + CONTINUE_PROMPT_S)

    def test_continuation_passes_the_extend_stride_it_needs(self) -> None:
        """M44: the windowed path asserts a stride; the default is not it."""
        self._render(45.0)
        self.assertEqual(self.model.params[-1]["extend_stride"], 18.0)

    def test_the_prompt_is_cut_back_off_the_take(self) -> None:
        """The length asked for was a length of NEW music."""
        result = self._render(45.0)
        self.assertAlmostEqual(result.duration_s, 45.0, places=3)


class DroppedInputTest(unittest.TestCase):
    """09-B10 — exactly one line, naming the input that was dropped."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = AudiocraftAdapter("audiocraft-test", {}, self.tmp.name,
                                         {"device": "cpu", "melody": True})
        self.adapter.model = FakeModel(seconds=10.0)

    def test_melody_plus_style_says_which_one_lost(self) -> None:
        ref = write_wav(os.path.join(self.tmp.name, "ref.wav"), 4.0)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.adapter.generate(
                "a prompt", None,
                {"duration_s": 10.0, "melody_audio": ref, "style_audio": ref,
                 "seed": 3},
                os.path.join(self.tmp.name, "take.wav"), noop_progress,
                CancelToken())
        lines = [line for line in err.getvalue().splitlines() if line.strip()]
        self.assertEqual(len(lines), 1)
        self.assertIn("style_audio", lines[0])


if __name__ == "__main__":
    unittest.main()

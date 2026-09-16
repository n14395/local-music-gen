"""HeartMuLa's decode wrapper.

Covers M48. `HeartCodec.detokenize` decodes in 29.76 s windows on a 25.6 s
hop — five flow-matching passes for a two-minute song, thirteen for six,
about half the render's wall time — and offers no hook, so the bar used to
sit at 0.92 for all of it and Cancel waited for the whole decode. The
wrapper is the decode's progress voice and its cancel checkpoint, and it is
restored in `finally` so a failed take cannot leave the codec wrapped.

No heartlib, no weights: `pipe` is a fake that runs the same call shape.
"""

import os
import sys
import tempfile
import unittest

from _fixtures import CancelAfter, FakePipe, Progress
from adapter_heartmula.adapter import HeartMuLaAdapter
from engine_protocol.adapter import CancelledError, CancelToken

LYRICS = "[verse]\nsomething to sing"


class DecodeWrapperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "take.wav")
        self.progress = Progress()
        self.adapter = HeartMuLaAdapter("heartmula", {}, self.tmp.name, {})

    def render(self, pipe, cancel=None, **params):
        self.adapter.pipe = pipe
        return self.adapter.generate(
            "pop", LYRICS, {"duration_s": 8.0, **params}, self.out,
            self.progress, cancel or CancelToken())

    def test_the_decode_reports_one_message_per_window(self):
        """M48: the bar used to sit at 0.92 for the whole decode."""
        pipe = FakePipe(windows=5)
        self.render(pipe)
        labels = self.progress.messages("decoding with HeartCodec — window")
        self.assertEqual(len(labels), 5)
        for i in range(1, 6):
            self.assertIn(f"window {i}/5", labels[i - 1])

    def test_the_decode_fractions_only_ever_rise(self):
        """M48: a bar that falls back reads as a restart."""
        pipe = FakePipe(windows=5)
        self.render(pipe)
        fractions = self.progress.fractions("decoding with HeartCodec")
        self.assertEqual(fractions, sorted(fractions))
        self.assertGreaterEqual(fractions[0], 0.92)
        self.assertLessEqual(fractions[-1], 0.99)

    def test_a_cancel_during_the_decode_raises_cancelled(self):
        """M48: Cancel used to wait for the whole decode."""
        pipe = FakePipe(windows=5)
        with self.assertRaises(CancelledError):
            self.render(pipe, cancel=CancelAfter(3))
        # It stopped part-way rather than decoding every window.
        self.assertLess(pipe.codec.flow_matching.calls, 5)

    def test_the_codec_is_unwrapped_after_a_cancelled_decode(self):
        """A failed take must not leave the codec wrapped for the next one."""
        pipe = FakePipe(windows=5)
        original = pipe.codec.flow_matching.inference_codes
        with self.assertRaises(CancelledError):
            self.render(pipe, cancel=CancelAfter(3))
        self.assertEqual(pipe.codec.flow_matching.inference_codes, original)

    def test_the_codec_is_unwrapped_after_a_successful_decode(self):
        pipe = FakePipe(windows=3)
        original = pipe.codec.flow_matching.inference_codes
        self.render(pipe)
        self.assertEqual(pipe.codec.flow_matching.inference_codes, original)

    def test_a_finished_render_writes_the_take_and_no_part_file(self):
        pipe = FakePipe(windows=2)
        result = self.render(pipe)
        self.assertEqual(result.sample_rate, 48000)
        self.assertEqual(sorted(os.listdir(self.tmp.name)), ["take.wav"])


class FrameWrapperTests(unittest.TestCase):
    """The LM half uses the same wrapping idiom — one call per 80 ms frame."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.progress = Progress()
        self.adapter = HeartMuLaAdapter("heartmula", {}, self.tmp.name, {})

    def render(self, pipe, cancel=None):
        self.adapter.pipe = pipe
        return self.adapter.generate(
            "pop", LYRICS, {"duration_s": 8.0},
            os.path.join(self.tmp.name, "take.wav"), self.progress,
            cancel or CancelToken())

    def test_frames_are_counted_every_twenty_five(self):
        """M48: one generate_frame call per 80 ms frame is the bar."""
        pipe = FakePipe(lm_frames=50, windows=1)
        self.render(pipe)
        self.assertEqual(len(self.progress.messages("writing music — frame")),
                         2)

    def test_a_cancel_during_the_lm_raises_cancelled(self):
        pipe = FakePipe(lm_frames=50, windows=1)
        with self.assertRaises(CancelledError):
            self.render(pipe, cancel=CancelAfter(5))
        self.assertLess(pipe.mula.calls, 50)

    def test_the_model_is_unwrapped_after_a_failed_take(self):
        pipe = FakePipe(lm_frames=50, windows=1)
        original = pipe.mula.generate_frame
        with self.assertRaises(CancelledError):
            self.render(pipe, cancel=CancelAfter(5))
        self.assertEqual(pipe.mula.generate_frame, original)

    def test_empty_lyrics_are_refused_before_anything_is_wrapped(self):
        pipe = FakePipe()
        self.adapter.pipe = pipe
        with self.assertRaises(RuntimeError) as caught:
            self.adapter.generate("pop", "  ", {},
                                  os.path.join(self.tmp.name, "take.wav"),
                                  self.progress, CancelToken())
        self.assertIn("lyrics", str(caught.exception))
        self.assertEqual(pipe.mula.calls, 0)


class DecodeWindowTests(unittest.TestCase):
    """`_decode_windows` repeats upstream's own padding arithmetic so the
    decode bar has a total; only the bar depends on it being exact."""

    def test_it_never_reports_fewer_than_one_window(self):
        for n in (0, 1, 10):
            self.assertGreaterEqual(HeartMuLaAdapter._decode_windows(n), 1)

    def test_it_does_not_shrink_as_the_song_grows(self):
        counts = [HeartMuLaAdapter._decode_windows(n)
                  for n in range(0, 4000, 250)]
        self.assertEqual(counts, sorted(counts))

    def test_a_two_minute_song_decodes_in_several_windows(self):
        # 12.5 Hz codec frames: two minutes is 1500 of them.
        self.assertGreater(HeartMuLaAdapter._decode_windows(1500), 1)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

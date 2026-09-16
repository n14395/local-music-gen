"""InspireMusic's continuation clip: the END of the song, and not left behind.

Upstream head-truncates its audio prompt to ~5 s, so handing it a whole file
conditioned "continue this song" on the opening bars — the wrong end
(audit §3). `_tail_clip` writes the last five seconds to $TMPDIR instead,
and every continuation render used to leave that file there; it is now made
and deleted inside the same `finally` that unwraps the token generator.

No model and no InspireMusic package: `inspiremusic.utils.common` is a stub
in `sys.modules`, the model is a fake that records what it was handed, and
$TMPDIR is a directory this test owns.
"""

import os
import sys
import tempfile
import types
import unittest
from unittest import mock

import numpy as np
import soundfile as sf
from adapter_inspiremusic.adapter import InspireMusicAdapter
from engine_protocol.adapter import CancelToken

SR = 24000


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


def write_tone(path: str, seconds: float) -> None:
    n = int(seconds * SR)
    t = np.arange(n, dtype="float32") / SR
    # A ramp, so the head and the tail of the file are distinguishable.
    sf.write(path, t / max(t[-1], 1e-9), SR, format="WAV", subtype="PCM_16")


class TailClipTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        original = tempfile.tempdir
        tempfile.tempdir = self.tmp.name
        self.addCleanup(lambda: setattr(tempfile, "tempdir", original))

    def test_a_long_file_is_cut_down_to_its_last_five_seconds(self):
        src = os.path.join(self.tmp.name, "song.wav")
        write_tone(src, 20.0)
        clip = InspireMusicAdapter._tail_clip(src)
        self.assertNotEqual(clip, src)
        audio, sr = sf.read(clip, dtype="float32", always_2d=True)
        self.assertEqual(sr, SR)
        self.assertEqual(audio.shape[0], 5 * SR)

    def test_the_clip_is_the_end_of_the_song_not_its_opening_bars(self):
        """audit §3: conditioning on the intro is the wrong end."""
        src = os.path.join(self.tmp.name, "song.wav")
        write_tone(src, 20.0)
        whole, _sr = sf.read(src, dtype="float32", always_2d=True)
        clip, _sr = sf.read(InspireMusicAdapter._tail_clip(src),
                            dtype="float32", always_2d=True)
        self.assertAlmostEqual(float(clip[0, 0]), float(whole[-5 * SR, 0]),
                               places=4)
        self.assertAlmostEqual(float(clip[-1, 0]), float(whole[-1, 0]),
                               places=4)

    def test_a_file_shorter_than_the_window_is_passed_through_unchanged(self):
        src = os.path.join(self.tmp.name, "short.wav")
        write_tone(src, 2.0)
        self.assertEqual(InspireMusicAdapter._tail_clip(src), src)
        self.assertEqual(
            [e for e in os.listdir(self.tmp.name) if e.startswith("im-tail")],
            [])

    def test_a_file_soundfile_cannot_read_is_left_for_upstream_to_report(self):
        src = os.path.join(self.tmp.name, "not-audio.wav")
        with open(src, "wb") as f:
            f.write(b"not a wav at all")
        self.assertEqual(InspireMusicAdapter._tail_clip(src), src)


class FakeModel:
    """Just enough of InspireMusicModel for the render's bookkeeping."""

    def __init__(self) -> None:
        self.max_generate_audio_seconds = 0.0
        self.kwargs: dict = {}

    def inference(self, **kwargs) -> None:
        self.kwargs = kwargs


class RenderCleanupTests(unittest.TestCase):
    """The tail clip must not survive the render that made it."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        original = tempfile.tempdir
        tempfile.tempdir = self.tmp.name
        self.addCleanup(lambda: setattr(tempfile, "tempdir", original))

        # `inspiremusic.utils.common` is staged from a tarball at load time
        # and is not importable here; the render only calls its seed helper.
        common = types.ModuleType("inspiremusic.utils.common")
        common.set_all_random_seed = lambda seed: None
        utils = types.ModuleType("inspiremusic.utils")
        utils.common = common
        patch = mock.patch.dict(sys.modules, {
            "inspiremusic.utils": utils,
            "inspiremusic.utils.common": common}, clear=False)
        patch.start()
        self.addCleanup(patch.stop)

        self.adapter = InspireMusicAdapter("inspiremusic", {}, self.tmp.name,
                                           {})
        self.model = FakeModel()
        self.adapter.model = self.model
        self.adapter._out_root = os.path.join(self.tmp.name, "out")
        os.makedirs(self.adapter._out_root)

    def tails(self) -> list[str]:
        return [e for e in os.listdir(self.tmp.name)
                if e.startswith("im-tail-")]

    def test_the_tail_clip_is_unlinked_after_the_render(self):
        """Every continuation render used to leave a 5-second file behind."""
        src = os.path.join(self.tmp.name, "song.wav")
        write_tone(src, 20.0)
        with self.assertRaises(RuntimeError) as caught:
            self.adapter.generate(
                "more of this", None, {"extend_audio": src},
                os.path.join(self.tmp.name, "take.wav"), progress,
                CancelToken())
        # The fake model writes nothing, so the render ends here — after the
        # `finally` that deletes the clip.
        self.assertIn("produced no audio", str(caught.exception))
        handed = self.model.kwargs["audio_prompt"]
        self.assertNotEqual(handed, src)
        self.assertFalse(os.path.exists(handed))
        self.assertEqual(self.tails(), [])

    def test_a_short_source_is_handed_over_and_never_deleted(self):
        """`_tail_clip` returns its input when it wrote nothing; deleting
        that would delete the user's own file."""
        src = os.path.join(self.tmp.name, "short.wav")
        write_tone(src, 2.0)
        with self.assertRaises(RuntimeError):
            self.adapter.generate(
                "more of this", None, {"extend_audio": src},
                os.path.join(self.tmp.name, "take.wav"), progress,
                CancelToken())
        self.assertEqual(self.model.kwargs["audio_prompt"], src)
        self.assertTrue(os.path.exists(src))

    def test_a_text_to_music_render_makes_no_clip_at_all(self):
        with self.assertRaises(RuntimeError):
            self.adapter.generate(
                "a hazy waltz", None, {}, os.path.join(self.tmp.name,
                                                       "take.wav"),
                progress, CancelToken())
        self.assertEqual(self.model.kwargs["task"], "text-to-music")
        self.assertNotIn("audio_prompt", self.model.kwargs)
        self.assertEqual(self.tails(), [])

    def test_the_duration_is_capped_at_the_models_own_ceiling(self):
        with self.assertRaises(RuntimeError):
            self.adapter.generate(
                "a hazy waltz", None, {"duration_s": 600.0},
                os.path.join(self.tmp.name, "take.wav"), progress,
                CancelToken())
        self.assertEqual(self.model.max_generate_audio_seconds, 180.0)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

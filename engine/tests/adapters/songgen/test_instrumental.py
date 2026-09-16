"""SongGen and an empty lyrics box.

Covers M47 / 10-B5. SongGen has no instrumental path — no instrumental
token, mode or checkpoint exists in the package — and the adapter used to
substitute "la la la" for an empty lyrics box, so a user who asked for an
instrumental got a voice singing nonsense instead of an answer.

Nothing is loaded: the refusal happens before the model is touched, so the
"model" here is a sentinel that would fail loudly if it were used.
"""

import sys
import tempfile
import unittest

from adapter_songgen import adapter as songgen
from adapter_songgen.adapter import SongGenAdapter
from engine_protocol.adapter import CancelToken


class Sentinel:
    """Anything at all done to this is a test failure."""

    def __getattr__(self, name):
        raise AssertionError(f"the model was used ({name})")


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


class InstrumentalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = SongGenAdapter("songgen-mixed", {}, "/tmp", {})
        self.adapter.model = Sentinel()
        self.adapter.processor = Sentinel()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def render(self, lyrics):
        return self.adapter.generate(
            "a hazy waltz", lyrics, {"duration_s": 15.0},
            self.tmp.name + "/take.wav", progress, CancelToken())

    def test_an_empty_lyrics_box_is_refused_not_sung_as_la_la_la(self):
        """M47/10-B5: say there is no instrumental mode, do not invent one."""
        with self.assertRaises(RuntimeError) as caught:
            self.render("")
        message = str(caught.exception)
        self.assertIn("instrumental", message)
        self.assertNotIn("la la la", message)

    def test_whitespace_only_lyrics_are_refused_too(self):
        with self.assertRaises(RuntimeError) as caught:
            self.render("  \n\t ")
        self.assertIn("instrumental", str(caught.exception))

    def test_absent_lyrics_are_refused(self):
        with self.assertRaises(RuntimeError) as caught:
            self.render(None)
        self.assertIn("instrumental", str(caught.exception))


class DualTrackTests(unittest.TestCase):
    """SongGen's two entries differ by checkpoint, not by a flag."""

    def test_the_dual_track_entry_is_selected_by_its_setting(self):
        mixed = SongGenAdapter("songgen-mixed", {}, "/tmp", {})
        dual = SongGenAdapter("songgen-dual", {}, "/tmp",
                              {"dual_track": True})
        self.assertFalse(mixed.dual)
        self.assertTrue(dual.dual)

    def test_the_device_defaults_to_cpu(self):
        self.assertEqual(SongGenAdapter("songgen", {}, "/tmp", {}).device,
                         "cpu")
        self.assertEqual(
            SongGenAdapter("songgen", {}, "/tmp", {"device": "mps"}).device,
            "mps")


class SnapshotTests(unittest.TestCase):
    def test_a_snapshot_is_found_by_needle(self):
        a = SongGenAdapter("songgen", {"LiuZH-19/SongGen_mixed_pro": "/a",
                                       "ZhenYe234/xcodec": "/b"},
                           "/tmp", {})
        self.assertEqual(a._snapshot("songgen"), "/a")
        self.assertEqual(a._snapshot("xcodec"), "/b")

    def test_a_missing_snapshot_is_named(self):
        a = SongGenAdapter("songgen", {}, "/tmp", {})
        with self.assertRaises(RuntimeError) as caught:
            a._snapshot("xcodec")
        self.assertIn("xcodec", str(caught.exception))


class EnvironmentTests(unittest.TestCase):
    def test_the_mps_fallback_is_armed_at_import(self):
        """Read at torch import: a stray op the MPS backend lacks must fall
        back to CPU rather than abort the render."""
        import os
        self.assertEqual(os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK"), "1")
        self.assertTrue(hasattr(songgen, "TOKENS_PER_S"))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

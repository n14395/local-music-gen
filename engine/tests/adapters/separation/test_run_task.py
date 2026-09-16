"""The separation family's routing, stem naming and unload contract.

The engine switch and the stem labelling are the two pieces that run without
a model: audio-separator's default output names embed the MODEL name (which
may itself contain "vocals"), so the `_(stem)_` marker is authoritative when
it is there.

No separator is built and nothing is downloaded.
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

from adapter_separation import adapter as sep
from adapter_separation.adapter import SeparationAdapter, stem_label
from engine_protocol.adapter import CancelToken


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


class RoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, "song.wav")
        open(self.src, "wb").close()

    def adapter(self, settings=None) -> SeparationAdapter:
        return SeparationAdapter("htdemucs", {}, self.tmp.name,
                                 settings or {})

    def test_an_unsupported_task_is_refused(self):
        with self.assertRaises(NotImplementedError) as caught:
            self.adapter().run_task("transcribe", {}, self.tmp.name,
                                    progress, CancelToken())
        self.assertIn("transcribe", str(caught.exception))

    def test_a_missing_source_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.adapter().run_task("separate", {}, self.tmp.name, progress,
                                    CancelToken())
        self.assertIn("source_audio", str(caught.exception))

    def test_a_source_that_is_not_there_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.adapter().run_task(
                "separate", {"source_audio": "/no/such/song.wav"},
                self.tmp.name, progress, CancelToken())
        self.assertIn("source_audio", str(caught.exception))

    def test_an_unknown_engine_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.adapter({"engine": "spleeter"}).run_task(
                "separate", {"source_audio": self.src}, self.tmp.name,
                progress, CancelToken())
        self.assertIn("spleeter", str(caught.exception))

    def test_an_ensemble_card_without_a_preset_says_what_it_needs(self):
        """An ensemble card carries no checkpoint of its own."""
        with self.assertRaises(RuntimeError) as caught:
            self.adapter({"engine": "roformer"}).run_task(
                "separate", {"source_audio": self.src}, self.tmp.name,
                progress, CancelToken())
        self.assertIn("ensemble preset", str(caught.exception))

    def test_generation_is_refused(self):
        with self.assertRaises(NotImplementedError):
            self.adapter().generate("x", None, {}, "/tmp/a.wav", progress,
                                    CancelToken())


class StemNamingTests(unittest.TestCase):
    """audio-separator names its files after the MODEL as well as the stem."""

    def test_the_stem_marker_beats_a_model_name_containing_vocals(self):
        self.assertEqual(
            stem_label("/out/song_(Instrumental)_Kim_Vocal_2.wav"),
            "instrumental")
        self.assertEqual(
            stem_label("/out/song_(Vocals)_Kim_Vocal_2.wav"), "vocals")

    def test_every_word_for_the_backing_track_lands_on_one_label(self):
        for name in ("Other", "No Vocals", "no_vocals", "accompaniment",
                     "Instrumental"):
            with self.subTest(name=name):
                self.assertEqual(stem_label(f"/out/song_({name})_model.wav"),
                                 "instrumental")

    def test_an_unmarked_name_falls_back_to_the_file_stem(self):
        self.assertEqual(stem_label("/out/drums.wav"), "drums")

    def test_an_unmarked_vocal_name_is_still_vocals(self):
        self.assertEqual(stem_label("/out/lead_vocals.wav"), "vocals")


class UnloadTests(unittest.TestCase):
    """10-B12: the separator runs on MPS when it is there and is kept across
    jobs, so its arena is the biggest thing this worker holds."""

    def test_the_separator_is_dropped_before_the_allocator_flush(self):
        adapter = SeparationAdapter("htdemucs", {}, "/tmp", {})
        adapter._separator = object()
        seen: list[object] = []
        with mock.patch.object(sep, "release_accelerator_memory",
                               lambda: seen.append(adapter._separator)):
            adapter.unload()
        self.assertEqual(seen, [None])
        self.assertIsNone(adapter._separator)

    def test_the_allocator_is_flushed_exactly_once(self):
        adapter = SeparationAdapter("htdemucs", {}, "/tmp", {})
        calls = []
        with mock.patch.object(sep, "release_accelerator_memory",
                               lambda: calls.append(1)):
            adapter.unload()
        self.assertEqual(len(calls), 1)


class CallbackTests(unittest.TestCase):
    """demucs' Separator captures its callback at construction; the
    trampoline lets each job swap in its own closure without rebuilding the
    weight-holding Separator."""

    def test_a_fresh_adapter_has_an_empty_callback_holder(self):
        adapter = SeparationAdapter("htdemucs", {}, "/tmp", {})
        self.assertEqual(adapter._callback_holder, {"cb": None})
        self.assertIsNone(adapter._separator)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

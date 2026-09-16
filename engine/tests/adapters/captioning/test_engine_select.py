"""The captioning family's engine switch and its refusals.

One engine is wired (LP-MusicCaps) and five are planned. A catalog entry
that ships ahead of its engine has to fail as a sentence, not as a KeyError;
and this checkpoint was trained to describe, not to answer, so a question is
refused rather than silently ignored — "Ask about this song" must not look
as though it answered something it never read.

No checkpoint is loaded: these are the branches that run before `load()`
reaches the weights, plus the unload contract.
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

from adapter_captioning import adapter as cap
from adapter_captioning.adapter import (ENGINES, PLANNED, CaptioningAdapter)
from engine_protocol.adapter import CancelToken


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


def make(settings=None, paths=None) -> CaptioningAdapter:
    return CaptioningAdapter("lp-musiccaps", paths or {}, "/tmp",
                             settings or {})


class EngineTests(unittest.TestCase):
    def test_the_default_engine_is_the_one_that_is_wired(self):
        self.assertEqual(make()._engine(), "lpmusiccaps")
        self.assertEqual(ENGINES, ("lpmusiccaps",))

    def test_a_planned_engine_fails_as_a_sentence(self):
        for engine in PLANNED:
            with self.subTest(engine=engine):
                with self.assertRaises(RuntimeError) as caught:
                    make({"engine": engine})._engine()
                self.assertIn("not wired up yet", str(caught.exception))
                self.assertIn(engine, str(caught.exception))

    def test_an_unknown_engine_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            make({"engine": "nope"})._engine()
        self.assertIn("nope", str(caught.exception))

    def test_no_planned_engine_is_also_listed_as_wired(self):
        self.assertEqual(set(ENGINES) & set(PLANNED), set())


class SnapshotTests(unittest.TestCase):
    def test_a_snapshot_is_found_by_any_of_its_needles(self):
        a = make(paths={"seungheondoh/lp-music-caps": "/a",
                        "facebook/bart-base": "/b"})
        self.assertEqual(a._find("lp-music-caps"), "/a")
        self.assertEqual(a._find("bart-base"), "/b")
        self.assertEqual(a._find("nope", "bart-base"), "/b")

    def test_a_missing_snapshot_is_absent_rather_than_an_error(self):
        self.assertIsNone(make()._find("lp-music-caps"))


class LoadGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_a_model_with_no_snapshot_says_so(self):
        with self.assertRaises(RuntimeError) as caught:
            make().load(progress)
        self.assertIn("no downloaded snapshot", str(caught.exception))

    def test_a_snapshot_with_no_checkpoint_says_so(self):
        a = make(paths={"seungheondoh/lp-music-caps": self.tmp.name})
        with self.assertRaises(RuntimeError) as caught:
            a.load(progress)
        self.assertIn("no checkpoint", str(caught.exception))
        self.assertIn(self.tmp.name, str(caught.exception))

    def test_a_missing_bart_snapshot_is_named(self):
        """BART's config and tokenizer are fetched as their own repo so the
        captioner never reaches for the network mid-job."""
        open(os.path.join(self.tmp.name, "transfer.pth"), "w").close()
        a = make(paths={"seungheondoh/lp-music-caps": self.tmp.name})
        with self.assertRaises(RuntimeError) as caught:
            a.load(progress)
        self.assertIn("BART", str(caught.exception))


class TaskGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, "song.wav")
        open(self.src, "wb").close()
        self.adapter = make()
        self.adapter.bundle = object()

    def caption(self, params):
        return self.adapter.run_task("caption", params, self.tmp.name,
                                     progress, CancelToken())

    def test_a_missing_source_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.caption({})
        self.assertIn("source_audio", str(caught.exception))

    def test_a_question_is_refused_rather_than_silently_ignored(self):
        """This model has no instruction channel at all."""
        with self.assertRaises(RuntimeError) as caught:
            self.caption({"source_audio": self.src,
                          "question": "what key is this in?"})
        message = str(caught.exception)
        self.assertIn("cannot answer questions", message)
        self.assertIn("Qwen2-Audio", message)

    def test_an_unsupported_task_falls_through_to_the_base_class(self):
        with self.assertRaises(NotImplementedError):
            self.adapter.run_task("separate", {}, self.tmp.name, progress,
                                  CancelToken())

    def test_generation_is_refused_with_a_pointer_to_the_task(self):
        with self.assertRaises(NotImplementedError) as caught:
            self.adapter.generate("x", None, {}, "/tmp/a.wav", progress,
                                  CancelToken())
        self.assertIn("caption", str(caught.exception))


class UnloadTests(unittest.TestCase):
    """10-B12: the caption model goes to MPS when it is there, and the
    allocator keeps its blocks until it is told, however few references are
    left."""

    def test_the_bundle_is_dropped_before_the_allocator_flush(self):
        adapter = make()
        adapter.bundle = object()
        seen: list[object] = []
        with mock.patch.object(cap, "release_accelerator_memory",
                               lambda: seen.append(adapter.bundle)):
            adapter.unload()
        self.assertEqual(seen, [None])
        self.assertIsNone(adapter.bundle)

    def test_the_allocator_is_flushed_exactly_once(self):
        adapter = make()
        calls = []
        with mock.patch.object(cap, "release_accelerator_memory",
                               lambda: calls.append(1)):
            adapter.unload()
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

"""YuE's load(): the checkout guard and the infer.py patch.

Covers 10-B9. `exists("inference")` passed on the half-copied husk an
interrupted library relocate leaves behind — the directory was there,
infer.py was not, `_teach_infer_sdpa` returned without a word, and the render
died hours later as "YuE infer.py exited with 2".

Nothing here clones, downloads, or loads a checkpoint: `subprocess.run` is
replaced and `aux_dir` is pointed at a temp tree.
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

from _fixtures import INFER_PY, FakeRun, Progress, make_checkout
from adapter_yue import adapter as yue
from adapter_yue.adapter import YuEAdapter


class LoadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = self.tmp.name
        self.addCleanup(self.tmp.cleanup)
        self.run = FakeRun()
        # aux_dir() would otherwise create a directory on the library volume.
        patches = [mock.patch.object(yue, "aux_dir",
                                     lambda name: self.base),
                   mock.patch.object(yue.subprocess, "run", self.run)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.progress = Progress()

    def adapter(self) -> YuEAdapter:
        # No xcodec snapshot: the symlink branch is not what these test.
        return YuEAdapter("yue-s1-7b", {}, self.base, {})

    def test_load_names_the_checkout_when_infer_py_is_missing(self):
        """10-B9: a checkout with no infer.py must say which one.

        `_teach_infer_sdpa` used to return quietly, so the render reached
        `python infer.py` and failed with an exit code instead of a reason.
        """
        repo = make_checkout(self.base, infer_py=False)
        a = self.adapter()
        with self.assertRaises(RuntimeError) as caught:
            a.load(self.progress)
        self.assertIn(repo, str(caught.exception))
        self.assertIn("infer.py", str(caught.exception))

    def test_the_relocate_tombstone_forces_a_fresh_clone(self):
        """10-B9/M14: a tombstoned tree is absent, however complete it looks.

        Every landmark is present here; only `.relocate-incomplete` says the
        copy never finished.
        """
        make_checkout(self.base, tombstone=True)
        a = self.adapter()
        with self.assertRaises(RuntimeError):
            # The fake clone writes nothing, so the patch step then reports
            # the missing infer.py — which is the point: the clone ran.
            a.load(self.progress)
        self.assertTrue(self.run.cloned, self.run.calls)
        self.assertEqual(self.run.calls[0][:2], ["git", "clone"])
        self.assertEqual(self.run.calls[0][-1],
                         os.path.join(self.base, "YuE"))

    def test_a_complete_checkout_is_not_re_cloned(self):
        """10-B9: the guard must not re-fetch what is already staged."""
        make_checkout(self.base)
        self.adapter().load(self.progress)
        self.assertFalse(self.run.cloned, self.run.calls)

    def test_load_teaches_infer_py_sdpa(self):
        """There is no flash-attn wheel for macOS: transformers raised
        ImportError at the first from_pretrained, before a single token."""
        repo = make_checkout(self.base)
        self.adapter().load(self.progress)
        with open(os.path.join(repo, "inference", "infer.py")) as f:
            src = f.read()
        self.assertIn('attn_implementation="sdpa"', src)
        self.assertNotIn("flash_attention_2", src)
        self.assertIn("LOCALMUSIC-SDPA", src)

    def test_the_patch_is_idempotent_across_loads(self):
        """Re-applied on every load, because a re-clone would restore the
        blocker."""
        repo = make_checkout(self.base)
        path = os.path.join(repo, "inference", "infer.py")
        a = self.adapter()
        a.load(self.progress)
        with open(path) as f:
            once = f.read()
        a.load(self.progress)
        with open(path) as f:
            self.assertEqual(f.read(), once)

    def test_an_unrecognised_infer_py_is_refused_rather_than_guessed_at(self):
        repo = make_checkout(self.base)
        with open(os.path.join(repo, "inference", "infer.py"), "w") as f:
            f.write("# upstream moved the attention line\n")
        with self.assertRaises(RuntimeError) as caught:
            self.adapter().load(self.progress)
        self.assertIn("refusing to guess", str(caught.exception))

    def test_the_husk_is_removed_before_the_clone(self):
        """git clone refuses a non-empty destination, so the husk that
        failed `staged()` has to go first."""
        repo = make_checkout(self.base, infer_py=False)
        with self.assertRaises(RuntimeError):
            self.adapter().load(self.progress)
        self.assertTrue(self.run.cloned)
        # The fake clone writes nothing, so a surviving husk would show up
        # as the directory still carrying its old landmarks.
        self.assertFalse(os.path.exists(
            os.path.join(repo, "inference", "mmtokenizer.py")))

    def test_the_readiness_message_is_reported_once_loaded(self):
        make_checkout(self.base)
        self.adapter().load(self.progress)
        self.assertTrue(any("YuE ready" in m
                            for m in self.progress.messages),
                        self.progress.messages)


class InferPatchTests(unittest.TestCase):
    def test_the_patch_preserves_everything_else_in_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            repo = make_checkout(d)
            a = YuEAdapter("yue-s1-7b", {}, d, {})
            a.repo_dir = repo
            a._teach_infer_sdpa()
            with open(os.path.join(repo, "inference", "infer.py")) as f:
                src = f.read()
            self.assertEqual(src.splitlines()[0],
                             INFER_PY.splitlines()[0])


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

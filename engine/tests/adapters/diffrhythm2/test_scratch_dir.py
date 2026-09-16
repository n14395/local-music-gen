"""DiffRhythm2's scratch tree: complete-or-absent, on every exit.

Covers 10-B10. Every render used to leave the .lrc, the input jsonl and the
produced mp3 (tens of MB for a 3½-minute song) under $TMPDIR — on success,
failure and cancel alike. The tree now lives inside a `finally`.

Nothing is spawned: `subprocess.Popen` is replaced, and `tempfile.tempdir`
is pointed at a directory this test owns so the scratch tree is countable.
"""

import io
import os
import sys
import tempfile
import unittest
from unittest import mock

from adapter_diffrhythm2 import adapter as dr2
from adapter_diffrhythm2.adapter import DiffRhythm2Adapter
from engine_protocol.adapter import CancelledError, CancelToken


class FakeProc:
    def __init__(self, returncode: int = 0, stderr: str = "") -> None:
        self.stderr = io.StringIO(stderr)
        self.returncode = returncode
        self.kills = 0
        self.waits = 0

    def poll(self):
        return self.returncode

    def wait(self):
        self.waits += 1
        return self.returncode

    def kill(self):
        self.kills += 1


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


class ScratchTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.scratch = os.path.join(self.tmp.name, "tmpdir")
        os.makedirs(self.scratch)
        # $TMPDIR, not work_dir: a scratch tree belongs nowhere near the
        # takes. Redirect it so the leftovers are this test's to count.
        original = tempfile.tempdir
        tempfile.tempdir = self.scratch
        self.addCleanup(lambda: setattr(tempfile, "tempdir", original))

        self.launched: list[list[str]] = []
        self.adapter = DiffRhythm2Adapter("diffrhythm2", {}, self.tmp.name,
                                          {})
        self.adapter.repo = self.tmp.name
        self.adapter.device = "cpu"

    def patch_popen(self, factory):
        def popen(cmd, **kwargs):
            self.launched.append(list(cmd))
            return factory()

        patch = mock.patch.object(dr2.subprocess, "Popen", popen)
        patch.start()
        self.addCleanup(patch.stop)

    def render(self, **params):
        return self.adapter.generate(
            "Pop, catchy", "[00:00.00]hello",
            {"duration_s": 30.0, **params},
            os.path.join(self.tmp.name, "take.wav"), progress, CancelToken())

    def leftovers(self) -> list[str]:
        return [e for e in os.listdir(self.scratch) if e.startswith("dr2-")]

    def test_a_render_that_raises_leaves_no_scratch_tree(self):
        """10-B10: the tens of megabytes stayed behind on every failure."""
        def blow_up():
            raise RuntimeError("the renderer could not start")

        self.patch_popen(blow_up)
        with self.assertRaises(RuntimeError):
            self.render()
        self.assertEqual(self.leftovers(), [])

    def test_a_failing_child_leaves_no_scratch_tree(self):
        """10-B10: a non-zero exit is the common failure, not an exception."""
        self.patch_popen(lambda: FakeProc(returncode=1,
                                          stderr="CUDA not found\n"))
        with self.assertRaises(RuntimeError) as caught:
            self.render()
        self.assertIn("DiffRhythm2 failed", str(caught.exception))
        self.assertEqual(self.leftovers(), [])

    def test_a_cancelled_render_leaves_no_scratch_tree(self):
        """10-B10: cancel too — that was the third leaking path."""
        self.patch_popen(lambda: FakeProc(returncode=0))
        cancelled = CancelToken()
        cancelled.cancel()
        with self.assertRaises(CancelledError):
            self.adapter.generate(
                "Pop", "[00:00.00]hi", {"duration_s": 30.0},
                os.path.join(self.tmp.name, "take.wav"), progress, cancelled)
        self.assertEqual(self.leftovers(), [])

    def test_a_render_that_produced_nothing_leaves_no_scratch_tree(self):
        """Gotcha rule: fire on empty results, not just exceptions."""
        self.patch_popen(lambda: FakeProc(returncode=0))
        with self.assertRaises(RuntimeError) as caught:
            self.render()
        self.assertIn("produced no audio", str(caught.exception))
        self.assertEqual(self.leftovers(), [])

    def test_the_scratch_tree_is_not_written_beside_the_takes(self):
        """work_dir is the app's output directory."""
        self.patch_popen(lambda: FakeProc(returncode=0))
        with self.assertRaises(RuntimeError):
            self.render()
        self.assertEqual(
            [e for e in os.listdir(self.tmp.name) if e.startswith("dr2-")],
            [])


class ArgvTests(unittest.TestCase):
    """The CLI's argparse uses `type=bool`, where every non-empty string is
    truthy — the empty string is the only False it accepts."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        original = tempfile.tempdir
        tempfile.tempdir = self.tmp.name
        self.addCleanup(lambda: setattr(tempfile, "tempdir", original))
        self.launched: list[list[str]] = []

        def popen(cmd, **kwargs):
            self.launched.append(list(cmd))
            return FakeProc(returncode=0)

        patch = mock.patch.object(dr2.subprocess, "Popen", popen)
        patch.start()
        self.addCleanup(patch.stop)
        self.adapter = DiffRhythm2Adapter("diffrhythm2", {}, self.tmp.name,
                                          {})
        self.adapter.repo = self.tmp.name
        self.adapter.device = "cpu"

    def code(self, **params) -> str:
        with self.assertRaises(RuntimeError):
            self.adapter.generate(
                "Pop", "[00:00.00]hi", {"duration_s": 30.0, **params},
                os.path.join(self.tmp.name, "take.wav"), progress,
                CancelToken())
        return self.launched[-1][2]

    def test_fake_stereo_off_is_sent_as_the_empty_string(self):
        self.assertIn("'--fake-stereo', ''", self.code(fake_stereo=False))

    def test_fake_stereo_on_sends_no_flag_at_all(self):
        self.assertNotIn("--fake-stereo", self.code(fake_stereo=True))
        self.assertNotIn("--fake-stereo", self.code())

    def test_the_seed_is_substituted_into_the_bootstrap(self):
        code = self.code(seed=4242)
        self.assertIn("4242", code)
        self.assertNotIn("SEED", code)

    def test_the_step_count_and_guidance_are_clamped(self):
        self.assertIn("'--steps', '4'", self.code(steps=1))
        self.assertIn("'--steps', '32'", self.code(steps=9999))
        self.assertIn("'--steps', '8'", self.code(steps=0))

    def test_the_duration_is_capped_at_the_models_own_ceiling(self):
        self.assertIn("'--max-secs', '210.0'", self.code(duration_s=600.0))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

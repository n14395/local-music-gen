"""`engine_protocol.staging.staged` — the guard six models died behind.

An `os.path.isdir` check cannot tell a finished stage from the half-copied
husk an interrupted library relocate leaves behind (audit M14/M15); `staged`
is the guard that can, and these pin all three of its answers.
"""

from __future__ import annotations

import os
import tempfile
import unittest

import _fixtures  # noqa: F401 — path bootstrap

from engine_protocol.staging import INCOMPLETE_MARKER, safe_data_filter, staged


class StagedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tree = os.path.join(self.tmp.name, "checkout")
        os.makedirs(os.path.join(self.tree, "inference"))
        for rel in ("inference/__init__.py", "inference/infer.py", "setup.py"):
            with open(os.path.join(self.tree, rel), "w") as f:
                f.write("# staged\n")

    def test_absent_tree_is_not_staged(self) -> None:
        """M14: nothing there at all is the easy half."""
        self.assertFalse(staged(os.path.join(self.tmp.name, "nope"),
                                "setup.py"))

    def test_a_file_is_not_a_staged_tree(self) -> None:
        path = os.path.join(self.tmp.name, "a-file")
        with open(path, "w") as f:
            f.write("x")
        self.assertFalse(staged(path))

    def test_every_landmark_present_is_staged(self) -> None:
        self.assertTrue(staged(self.tree, "setup.py", "inference/infer.py"))

    def test_a_missing_landmark_is_not_staged(self) -> None:
        """10-B9: the file the adapter actually loads is the landmark — a
        checkout whose `inference/infer.py` went missing must read absent."""
        os.unlink(os.path.join(self.tree, "inference", "infer.py"))
        self.assertFalse(staged(self.tree, "setup.py", "inference/infer.py"))

    def test_no_landmarks_means_present_and_not_tombstoned(self) -> None:
        self.assertTrue(staged(self.tree))

    def test_the_relocate_tombstone_makes_a_whole_tree_read_absent(self) -> None:
        """M15: `library._mark_incomplete` drops this file into a destination
        it could not finish copying. Every landmark is still there — that is
        exactly why the marker has to be read."""
        with open(os.path.join(self.tree, INCOMPLETE_MARKER), "w") as f:
            f.write("partial copy from an interrupted relocate\n")
        self.assertFalse(staged(self.tree, "setup.py", "inference/infer.py"))
        self.assertFalse(staged(self.tree))

    def test_clearing_the_tombstone_restores_the_tree(self) -> None:
        marker = os.path.join(self.tree, INCOMPLETE_MARKER)
        with open(marker, "w") as f:
            f.write("partial\n")
        os.unlink(marker)
        self.assertTrue(staged(self.tree, "setup.py"))


class SafeDataFilterTest(unittest.TestCase):
    """A hostile tar member is skipped, not fatal (BSRNN's absolute symlink)."""

    def test_an_absolute_symlink_member_is_skipped_not_raised(self) -> None:
        import tarfile
        member = tarfile.TarInfo("data/musdb18hq")
        member.type = tarfile.SYMTYPE
        member.linkname = "/absolute/elsewhere"
        self.assertIsNone(safe_data_filter(member, "/tmp/dest"))

    def test_an_ordinary_file_member_passes(self) -> None:
        import tarfile
        member = tarfile.TarInfo("pkg/README.md")
        member.size = 3
        self.assertIsNotNone(safe_data_filter(member, "/tmp/dest"))


if __name__ == "__main__":
    unittest.main()

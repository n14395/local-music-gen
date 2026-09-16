"""`engine_protocol.adapter` path helpers — the aux cache and its stale links.

The aux root is where adapters put weights they fetch themselves. It moves
with the library folder, which is why `aux_dir` must read the environment
every time and why `clear_stale_link` exists at all: a relocate strands every
staging symlink that still names the old root, and a dangling link reads as
*absent* to `os.path.exists`, so the guard that should have re-staged
re-staged into an EEXIST instead.
"""

from __future__ import annotations

import os
import tempfile
import unittest

import _fixtures  # noqa: F401 — path bootstrap

from engine_protocol.adapter import (AUX_DIRS, AUX_KEPT_DIRS, AUX_LEGACY_DIRS,
                                     aux_dir, aux_root, clear_stale_link,
                                     drop_preview, preview_stride)


class AuxRootTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._saved = {k: os.environ.get(k)
                       for k in ("LOCALMUSICGEN_AUX_CACHE", "HF_HOME")}
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_the_env_override_wins(self) -> None:
        """The worker always sets this; a test that read the real one would
        write into the user's model SSD."""
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.tmp.name
        os.environ["HF_HOME"] = "/somewhere/else/huggingface"
        self.assertEqual(aux_root(), self.tmp.name)

    def test_without_the_override_it_falls_back_beside_hf_home(self) -> None:
        os.environ.pop("LOCALMUSICGEN_AUX_CACHE", None)
        os.environ["HF_HOME"] = os.path.join(self.tmp.name, "library", "hf")
        self.assertEqual(aux_root(), os.path.join(self.tmp.name, "library"))

    def test_an_empty_override_is_not_an_override(self) -> None:
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = ""
        os.environ["HF_HOME"] = os.path.join(self.tmp.name, "library", "hf")
        self.assertEqual(aux_root(), os.path.join(self.tmp.name, "library"))

    def test_aux_dir_creates_its_directory_under_the_override(self) -> None:
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.tmp.name
        d = aux_dir("yue2")
        self.assertEqual(d, os.path.join(self.tmp.name, "yue2"))
        self.assertTrue(os.path.isdir(d))

    def test_aux_dir_is_idempotent(self) -> None:
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.tmp.name
        self.assertEqual(aux_dir("msst"), aux_dir("msst"))

    def test_an_unlisted_aux_dir_is_refused(self) -> None:
        """An unlisted directory is one the library cannot count, move or
        clear — which is the whole bug AUX_DIRS exists to have fixed."""
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.tmp.name
        with self.assertRaises(AssertionError):
            aux_dir("not-a-real-aux-dir")

    def test_a_retired_aux_dir_cannot_be_revived(self) -> None:
        """AUX_LEGACY_DIRS are counted and cleared but never written again;
        `magenta-home` went when Magenta RT 2 became an ordinary HF
        download (2026-09-16)."""
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.tmp.name
        for name in AUX_LEGACY_DIRS:
            with self.assertRaises(AssertionError):
                aux_dir(name)

    def test_the_users_own_directories_are_not_adapter_caches(self) -> None:
        """AUX_KEPT_DIRS hold files no clear may take; no adapter writes one,
        so `aux_dir` must refuse them too."""
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.tmp.name
        for name in AUX_KEPT_DIRS:
            with self.assertRaises(AssertionError):
                aux_dir(name)

    def test_the_three_name_lists_do_not_overlap(self) -> None:
        self.assertEqual(set(AUX_DIRS) & set(AUX_LEGACY_DIRS), set())
        self.assertEqual(set(AUX_DIRS) & set(AUX_KEPT_DIRS), set())
        self.assertEqual(set(AUX_LEGACY_DIRS) & set(AUX_KEPT_DIRS), set())

    def test_aux_dirs_has_no_duplicates(self) -> None:
        self.assertEqual(len(AUX_DIRS), len(set(AUX_DIRS)))


class ClearStaleLinkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _path(self, name: str) -> str:
        return os.path.join(self.tmp.name, name)

    def test_a_dangling_link_is_removed(self) -> None:
        """The relocate case: the link still names the old library root."""
        link = self._path("checkpoint.pt")
        os.symlink(self._path("gone/checkpoint.pt"), link)
        self.assertTrue(os.path.islink(link))
        self.assertFalse(os.path.exists(link))   # the lie that caused the bug
        clear_stale_link(link)
        self.assertFalse(os.path.lexists(link))

    def test_a_live_link_is_kept(self) -> None:
        target = self._path("real.pt")
        with open(target, "w") as f:
            f.write("weights")
        link = self._path("checkpoint.pt")
        os.symlink(target, link)
        clear_stale_link(link)
        self.assertTrue(os.path.islink(link))

    def test_a_real_file_is_never_touched(self) -> None:
        path = self._path("checkpoint.pt")
        with open(path, "w") as f:
            f.write("weights")
        clear_stale_link(path)
        self.assertTrue(os.path.isfile(path))

    def test_an_absent_path_is_a_no_op(self) -> None:
        clear_stale_link(self._path("never-existed"))

    def test_a_real_directory_is_never_touched(self) -> None:
        d = self._path("staged")
        os.makedirs(d)
        clear_stale_link(d)
        self.assertTrue(os.path.isdir(d))


class PreviewStrideTest(unittest.TestCase):
    """Every preview is a real decode, so they are sampled, not streamed."""

    def test_an_unknown_total_gets_a_fixed_cadence(self) -> None:
        self.assertEqual(preview_stride(None), 8)
        self.assertEqual(preview_stride(0), 8)

    def test_a_few_step_sampler_pays_at_most_the_frame_budget(self) -> None:
        """Ceiling, not floor: 5 // 4 == 1 made a 6-step Stable Audio Open
        Small render pay six full decodes against six diffusion steps."""
        self.assertEqual(preview_stride(5, frames=4), 2)
        self.assertEqual(preview_stride(6, frames=4), 2)

    def test_a_long_render_does_not_pay_per_step(self) -> None:
        self.assertEqual(preview_stride(200, frames=4), 50)

    def test_a_single_step_still_gets_a_stride_of_one(self) -> None:
        self.assertEqual(preview_stride(1, frames=4), 1)

    def test_the_frame_budget_is_honoured(self) -> None:
        for total in (8, 20, 50, 200):
            stride = preview_stride(total, frames=4)
            self.assertLessEqual(total // stride, 4, f"total={total}")

    def test_a_zero_frame_budget_does_not_divide_by_zero(self) -> None:
        self.assertGreaterEqual(preview_stride(50, frames=0), 1)


class DropPreviewTest(unittest.TestCase):
    def test_the_default_sink_swallows_everything(self) -> None:
        """Adapters call preview_cb unconditionally; only the decode that
        feeds it is conditional."""
        self.assertIsNone(drop_preview(b"\x00\x01", 44100))
        self.assertIsNone(drop_preview(b"\x00\x01", 44100, 2, step=7))


if __name__ == "__main__":
    unittest.main()

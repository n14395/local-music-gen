"""`Registry` install state over a temp HF cache (audit M15).

Two bugs live here, and both reported a model as installed when its weights
were not usable:

* An interrupted relocate tombstones the destination
  (`engine_protocol.staging.INCOMPLETE_MARKER`). `is_installed` did not read
  it, so a snapshot tree of links into blobs that never arrived reported
  `installed` and the job died inside the worker.
* On an ExFAT library volume macOS keeps extended attributes in an
  AppleDouble `._<rev>` file beside the snapshot directory. The "latest
  snapshot" pick listed the folder and sorted by mtime, so the twin could
  win — a 4 KB file handed to workers as the snapshot (Magenta RT 2,
  2026-09-16).

`HF_HOME` is redirected into a temp dir for every test here: nothing touches
the real library volume, and nothing needs it mounted.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from _fixtures import EnvGuard, make_settings

from engine_protocol.staging import INCOMPLETE_MARKER
from supervisor.registry import Registry


class InstallStateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.library = os.path.join(self.tmp.name, "library")
        self.guard = EnvGuard(HF_HOME=self.library)
        self.guard.__enter__()
        self.addCleanup(self.guard.__exit__)
        self.settings = make_settings(self.tmp.name)
        self.registry = Registry(self.settings)
        self.model_id = self._single_repo_model()
        self.repo_id = self.registry.models[self.model_id]["hf_repos"][0][
            "repo_id"]
        self.repo = self._download(self.repo_id)

    def _single_repo_model(self) -> str:
        """A catalog entry with one unpatterned HF repo and no ModelScope
        half — the simplest shape the install check has."""
        for mid, m in sorted(self.registry.models.items()):
            repos = m.get("hf_repos") or []
            if (len(repos) == 1 and not repos[0].get("allow_patterns")
                    and not m.get("ms_repos")):
                return mid
        self.skipTest("no single-repo catalog entry to test with")

    def _download(self, repo_id: str) -> str:
        """A repo as a finished download leaves it: one snapshot revision
        holding a file."""
        repo = self.registry.repo_cache_dir(repo_id)
        snap = os.path.join(repo, "snapshots", "rev1")
        os.makedirs(snap)
        with open(os.path.join(snap, "config.json"), "w") as f:
            f.write("{}")
        return repo

    # MARK: the tombstone

    def test_a_downloaded_repo_reads_installed(self) -> None:
        self.registry.write_marker(self.model_id, 1)
        self.assertTrue(self.registry.is_installed(self.model_id))

    def test_a_tombstoned_repo_does_not(self) -> None:
        """M15: the snapshot tree is complete; the blobs it links into may
        never have arrived."""
        self.registry.write_marker(self.model_id, 1)
        with open(os.path.join(self.repo, INCOMPLETE_MARKER), "w") as f:
            f.write("partial\n")
        self.assertFalse(self.registry.is_installed(self.model_id))

    def test_a_tombstoned_repo_hands_no_snapshot_path_to_a_worker(self) -> None:
        with open(os.path.join(self.repo, INCOMPLETE_MARKER), "w") as f:
            f.write("partial\n")
        self.assertNotIn(self.repo_id,
                         self.registry.hf_snapshot_dirs(self.model_id))

    def test_repo_tombstoned_reads_the_marker_by_name(self) -> None:
        self.assertFalse(self.registry.repo_tombstoned(self.repo_id))
        with open(os.path.join(self.repo, INCOMPLETE_MARKER), "w") as f:
            f.write("partial\n")
        self.assertTrue(self.registry.repo_tombstoned(self.repo_id))

    def test_a_completed_download_clears_the_tombstone(self) -> None:
        """Without this the entry would offer a download that could never
        take."""
        with open(os.path.join(self.repo, INCOMPLETE_MARKER), "w") as f:
            f.write("partial\n")
        self.registry.write_marker(self.model_id, 1)
        self.assertFalse(self.registry.repo_tombstoned(self.repo_id))
        self.assertTrue(self.registry.is_installed(self.model_id))

    # MARK: the AppleDouble twin

    def test_an_appledouble_twin_beside_the_snapshot_is_not_the_snapshot(self) -> None:
        """It is newer than the directory, which is how it won."""
        snap = os.path.join(self.repo, "snapshots", "rev1")
        twin = os.path.join(self.repo, "snapshots", "._rev1")
        with open(twin, "wb") as f:
            f.write(b"\x00\x05\x16\x07" + b"\x00" * 60)
        later = os.path.getmtime(snap) + 60
        os.utime(twin, (later, later))
        self.registry.write_marker(self.model_id, 1)
        self.assertEqual(
            self.registry.hf_snapshot_dirs(self.model_id).get(self.repo_id),
            snap)

    def test_and_the_model_still_reads_installed_beside_its_twin(self) -> None:
        twin = os.path.join(self.repo, "snapshots", "._rev1")
        with open(twin, "wb") as f:
            f.write(b"\x00" * 64)
        snap = os.path.join(self.repo, "snapshots", "rev1")
        later = os.path.getmtime(snap) + 60
        os.utime(twin, (later, later))
        self.registry.write_marker(self.model_id, 1)
        self.assertTrue(self.registry.is_installed(self.model_id))

    def test_the_newest_real_revision_wins(self) -> None:
        older = os.path.join(self.repo, "snapshots", "rev0")
        os.makedirs(older)
        newer = os.path.join(self.repo, "snapshots", "rev1")
        os.utime(older, (0, 0))
        self.assertEqual(
            self.registry.hf_snapshot_dirs(self.model_id).get(self.repo_id),
            newer)

    # MARK: the marker itself

    def test_an_unmarked_model_is_not_installed_however_many_bytes_are_there(self) -> None:
        """Catalog entries share repos, so a model the user never touched can
        have gigabytes of its content already present."""
        self.assertFalse(self.registry.is_marked(self.model_id))
        self.assertFalse(self.registry.is_installed(self.model_id))

    def test_a_marker_over_no_snapshots_is_not_installed(self) -> None:
        """Weights can vanish underneath a marker — a manual cache cleanup.
        Trusting it sends jobs to a worker with no snapshots."""
        self.registry.write_marker(self.model_id, 1)
        import shutil
        shutil.rmtree(os.path.join(self.repo, "snapshots"))
        self.assertFalse(self.registry.is_installed(self.model_id))

    def test_marked_bytes_reads_back_what_the_download_recorded(self) -> None:
        self.registry.write_marker(self.model_id, 4242)
        self.assertEqual(self.registry.marked_bytes(self.model_id), 4242)

    def test_a_corrupt_marker_reports_zero_bytes_rather_than_raising(self) -> None:
        self.registry.write_marker(self.model_id, 1)
        with open(self.registry._marker_path(self.model_id), "w") as f:
            f.write("{not json")
        self.assertEqual(self.registry.marked_bytes(self.model_id), 0)

    def test_an_attempt_marker_is_what_makes_a_download_resumable(self) -> None:
        """Bytes on disk cannot answer "was *this* model's download started",
        which showed up as a bogus "Resume download"."""
        self.assertFalse(self.registry.was_attempted(self.model_id))
        self.registry.mark_attempted(self.model_id)
        self.assertTrue(self.registry.was_attempted(self.model_id))
        self.registry.clear_attempt(self.model_id)
        self.assertFalse(self.registry.was_attempted(self.model_id))

    def test_clearing_an_absent_attempt_is_not_an_error(self) -> None:
        self.registry.clear_attempt(self.model_id)

    def test_the_repo_cache_path_is_the_hub_layout(self) -> None:
        self.assertEqual(
            self.registry.repo_cache_dir("org/model"),
            os.path.join(self.library, "hub", "models--org--model"))

    def test_the_cache_dir_follows_hf_home(self) -> None:
        """An HF_HOME already in the environment wins — the verification
        suite relies on that for isolation."""
        self.assertEqual(self.settings.hf_cache_dir, self.library)


if __name__ == "__main__":
    unittest.main()

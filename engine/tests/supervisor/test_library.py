"""`LibraryManager` — the only engine code that deletes the user's weights.

Relocate, clear and verify, on a temp tree of fake repo folders. It had no
test at all before this, and the two things it does that nothing else does
are `shutil.rmtree` over a folder the app does not own outright and a copy
whose completion is what earns the source's deletion.

`HF_HOME` is redirected into a temp dir for every test: no real library
volume is read, written or required to be mounted. The operations are driven
synchronously — `_start` is replaced with a capture so the plan can be
inspected and its `run` invoked in-line instead of on a daemon thread.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import types
import unittest

from _fixtures import EnvGuard, FakeBus, make_settings

from engine_protocol.adapter import AUX_KEPT_DIRS
from engine_protocol.staging import INCOMPLETE_MARKER
from supervisor.library import (AUX_FOLDER_NAME, DirOnDisk, LibraryError,
                                LibraryManager, _clear_incomplete, dir_bytes,
                                _mark_incomplete, _nearest_existing,
                                _same_size, _tree_copied)
from supervisor.registry import Registry


class FakeEngineState:
    """What `LibraryManager` reaches for on `EngineState`."""

    def __init__(self, registry: Registry) -> None:
        self.registry = registry
        self.downloads = types.SimpleNamespace(list=lambda: [])
        self.queue = types.SimpleNamespace(any_live_job=lambda: False)
        self.deleted: list[str] = []

    def delete_model(self, model_id: str) -> None:
        self.deleted.append(model_id)
        self.registry.delete(model_id)


class LibraryTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.library = os.path.join(self.tmp.name, "library")
        self.aux = os.path.join(self.tmp.name, "aux")
        os.makedirs(self.library)
        os.makedirs(self.aux)
        self.guard = EnvGuard(HF_HOME=self.library,
                              LOCALMUSICGEN_AUX_CACHE=self.aux)
        self.guard.__enter__()
        self.addCleanup(self.guard.__exit__)
        self.settings = make_settings(self.tmp.name)
        self.registry = Registry(self.settings)
        self.bus = FakeBus()
        self.state = FakeEngineState(self.registry)
        self.manager = LibraryManager(self.registry, self.bus, self.state)
        self.model_ids = self._distinct_repo_models(2)

    def _distinct_repo_models(self, n: int) -> list[str]:
        """Catalog entries with one unpatterned HF repo each, no two sharing
        a repo and none sharing one with any other entry."""
        owners: dict[str, list[str]] = {}
        for mid, m in self.registry.models.items():
            for repo in m.get("hf_repos") or []:
                owners.setdefault(repo["repo_id"], []).append(mid)
        out = []
        for mid, m in sorted(self.registry.models.items()):
            repos = m.get("hf_repos") or []
            if (len(repos) == 1 and not repos[0].get("allow_patterns")
                    and not m.get("ms_repos")
                    and len(owners[repos[0]["repo_id"]]) == 1):
                out.append(mid)
            if len(out) == n:
                return out
        self.skipTest(f"fewer than {n} single-repo catalog entries")

    def _repo_id(self, model_id: str) -> str:
        return self.registry.models[model_id]["hf_repos"][0]["repo_id"]

    def _download(self, model_id: str, *, marked: bool = True,
                  payload: bytes = b"x" * 1024) -> str:
        """A repo as a finished download leaves it: a blob, and a snapshot
        tree of symlinks into it."""
        repo = self.registry.repo_cache_dir(self._repo_id(model_id))
        blobs = os.path.join(repo, "blobs")
        snap = os.path.join(repo, "snapshots", "rev1")
        os.makedirs(blobs, exist_ok=True)
        os.makedirs(snap, exist_ok=True)
        blob = os.path.join(blobs, "deadbeef")
        with open(blob, "wb") as f:
            f.write(payload)
        link = os.path.join(snap, "model.safetensors")
        if not os.path.lexists(link):
            os.symlink(os.path.join("..", "..", "blobs", "deadbeef"), link)
        if marked:
            self.registry.write_marker(model_id, len(payload))
        return repo

    def _aux_dir(self, name: str = "yue2", payload: bytes = b"y" * 512) -> str:
        d = os.path.join(self.aux, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "weights.bin"), "wb") as f:
            f.write(payload)
        return d


# MARK: - reading


class DirBytesTest(LibraryTestCase):
    def test_a_symlink_is_not_counted_as_its_target(self) -> None:
        """A cached repo is blobs/ plus a snapshots/ tree of links into it;
        counting both reports a library half again as large as the disk."""
        repo = self._download(self.model_ids[0], payload=b"x" * 2048)
        self.assertEqual(dir_bytes(repo), 2048)

    def test_a_hard_linked_file_is_counted_once(self) -> None:
        d = os.path.join(self.tmp.name, "hard")
        os.makedirs(d)
        first = os.path.join(d, "a.bin")
        with open(first, "wb") as f:
            f.write(b"z" * 100)
        os.link(first, os.path.join(d, "b.bin"))
        self.assertEqual(dir_bytes(d), 100)

    def test_an_absent_directory_is_zero_not_an_error(self) -> None:
        self.assertEqual(dir_bytes(os.path.join(self.tmp.name, "nope")), 0)


class ReadingTest(LibraryTestCase):
    def test_only_repos_the_catalog_names_are_ours(self) -> None:
        """The HF cache is shared with every other tool on the machine; a
        folder full of repos we never asked for is the normal case."""
        self._download(self.model_ids[0])
        stranger = os.path.join(self.library, "hub", "models--someone--else")
        os.makedirs(stranger)
        with open(os.path.join(stranger, "big.bin"), "wb") as f:
            f.write(b"q" * 4096)
        found = {r.repo_id for r in self.manager.repos_on_disk()}
        self.assertEqual(found, {self._repo_id(self.model_ids[0])})

    def test_an_unmarked_repo_with_bytes_reads_partial(self) -> None:
        self._download(self.model_ids[0], marked=False)
        repos = self.manager.repos_on_disk()
        self.assertEqual([r.installed for r in repos], [False])
        self.assertEqual(repos[0].info()["state"], "partial")

    def test_a_marked_repo_reads_installed(self) -> None:
        self._download(self.model_ids[0])
        self.assertEqual(self.manager.repos_on_disk()[0].info()["state"],
                         "installed")

    def test_an_empty_repo_directory_is_not_counted(self) -> None:
        os.makedirs(self.registry.repo_cache_dir(
            self._repo_id(self.model_ids[0])))
        self.assertEqual(self.manager.repos_on_disk(), [])

    def test_aux_directories_are_scanned_by_name(self) -> None:
        """An unlisted directory there is not something we put in it."""
        self._aux_dir("yue2")
        os.makedirs(os.path.join(self.aux, "somebody-elses-cache"))
        with open(os.path.join(self.aux, "somebody-elses-cache", "f"),
                  "wb") as f:
            f.write(b"q" * 32)
        self.assertEqual([d.name for d in self.manager.aux_dirs_on_disk()],
                         ["yue2"])

    def test_the_users_own_directories_are_flagged_kept(self) -> None:
        """Re-downloading one of these needs the user's own API key and their
        memory of which capture they chose."""
        if not AUX_KEPT_DIRS:
            self.skipTest("no kept aux dirs declared")
        self._aux_dir(AUX_KEPT_DIRS[0])
        found = self.manager.aux_dirs_on_disk()
        self.assertEqual([(d.name, d.kept) for d in found],
                         [(AUX_KEPT_DIRS[0], True)])

    def test_info_splits_installed_from_partial_bytes(self) -> None:
        self._download(self.model_ids[0], payload=b"a" * 1000)
        self._download(self.model_ids[1], marked=False, payload=b"b" * 300)
        info = self.manager.info()
        self.assertEqual(info["installed_bytes"], 1000)
        self.assertEqual(info["partial_bytes"], 300)
        self.assertEqual(info["bytes"], 1300)
        self.assertEqual(info["partial_count"], 1)

    def test_info_totals_all_three_roots(self) -> None:
        self._download(self.model_ids[0], payload=b"a" * 1000)
        self._aux_dir("yue2", payload=b"y" * 500)
        info = self.manager.info()
        self.assertEqual(info["aux"]["bytes"], 500)
        self.assertEqual(info["total_bytes"], 1500)

    def test_info_says_whether_the_aux_root_sits_inside_the_library(self) -> None:
        """Without the flag a client subtracting ours from the folder would
        draw our own weights as another tool's."""
        self.assertFalse(self.manager.info()["aux"]["in_library_folder"])
        inside = os.path.join(self.library, AUX_FOLDER_NAME)
        os.makedirs(inside)
        with EnvGuard(LOCALMUSICGEN_AUX_CACHE=inside):
            self.assertTrue(self.manager.info()["aux"]["in_library_folder"])


class VerifyTest(LibraryTestCase):
    def test_a_marked_model_with_its_weights_reads_ok(self) -> None:
        self._download(self.model_ids[0])
        [finding] = [f for f in self.manager.verify()["models"]
                     if f["model_id"] == self.model_ids[0]]
        self.assertEqual(finding["state"], "ok")

    def test_a_marker_standing_over_nothing_reads_missing(self) -> None:
        """The install marker is a claim, not evidence — a manual cleanup of
        the cache folder leaves it standing over nothing."""
        repo = self._download(self.model_ids[0])
        shutil.rmtree(repo)
        [finding] = [f for f in self.manager.verify()["models"]
                     if f["model_id"] == self.model_ids[0]]
        self.assertEqual(finding["state"], "missing")
        self.assertEqual(finding["actual_bytes"], 0)

    def test_a_half_emptied_repo_reads_incomplete(self) -> None:
        repo = self._download(self.model_ids[0])
        shutil.rmtree(os.path.join(repo, "snapshots"))
        [finding] = [f for f in self.manager.verify()["models"]
                     if f["model_id"] == self.model_ids[0]]
        self.assertEqual(finding["state"], "incomplete")

    def test_a_repo_that_lost_most_of_its_bytes_reads_shrunk(self) -> None:
        repo = self._download(self.model_ids[0], payload=b"x" * 10_000)
        with open(os.path.join(repo, "blobs", "deadbeef"), "wb") as f:
            f.write(b"x" * 10)
        [finding] = [f for f in self.manager.verify()["models"]
                     if f["model_id"] == self.model_ids[0]]
        self.assertEqual(finding["state"], "shrunk")

    def test_a_small_shortfall_is_not_shrunk(self) -> None:
        """Not an equality test: a repo shared with a pattern-scoped sibling
        can legitimately measure a little differently afterwards."""
        repo = self._download(self.model_ids[0], payload=b"x" * 10_000)
        with open(os.path.join(repo, "blobs", "deadbeef"), "wb") as f:
            f.write(b"x" * 9_950)
        [finding] = [f for f in self.manager.verify()["models"]
                     if f["model_id"] == self.model_ids[0]]
        self.assertEqual(finding["state"], "ok")

    def test_an_unmarked_model_is_not_checked_at_all(self) -> None:
        self._download(self.model_ids[0], marked=False)
        checked = {f["model_id"] for f in self.manager.verify()["models"]}
        self.assertNotIn(self.model_ids[0], checked)

    def test_partial_repos_are_reported_beside_the_findings(self) -> None:
        self._download(self.model_ids[0], marked=False)
        report = self.manager.verify()
        self.assertEqual([r["repo_id"] for r in report["partial_repos"]],
                         [self._repo_id(self.model_ids[0])])

    def test_the_problem_count_matches_the_findings(self) -> None:
        self._download(self.model_ids[0])
        shutil.rmtree(self.registry.repo_cache_dir(
            self._repo_id(self.model_ids[0])))
        self._download(self.model_ids[1])
        report = self.manager.verify()
        self.assertEqual(report["problem_count"],
                         sum(1 for f in report["models"]
                             if f["state"] != "ok"))
        self.assertEqual(report["problem_count"], 1)


# MARK: - clear


class ClearTest(LibraryTestCase):
    def _op(self, total: int = 0) -> dict:
        return {"bytes_total": total, "bytes_done": 0, "fraction": 0.0,
                "message": ""}

    def test_an_unknown_scope_is_refused(self) -> None:
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_clear("everything")
        self.assertEqual((ctx.exception.status, ctx.exception.code),
                         (422, "VALIDATION"))

    def test_clearing_an_empty_library_is_refused(self) -> None:
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_clear("all")
        self.assertEqual((ctx.exception.status, ctx.exception.code),
                         (409, "LIBRARY_EMPTY"))

    def test_clearing_with_a_download_running_is_refused(self) -> None:
        """Refuse to rearrange the library out from under work in progress."""
        self._download(self.model_ids[0])
        self.state.downloads.list = lambda: [{"download_id": "dl_1"}]
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_clear("all")
        self.assertEqual(ctx.exception.code, "DOWNLOAD_ACTIVE")

    def test_clearing_with_a_live_job_is_refused(self) -> None:
        self._download(self.model_ids[0])
        self.state.queue.any_live_job = lambda: True
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_clear("all")
        self.assertEqual(ctx.exception.code, "ENGINE_BUSY")

    def test_an_installed_model_goes_through_delete_model(self) -> None:
        """delete_model clears the marker, drops the user entry if it was one,
        and collects the family's runtime venv once its last model goes —
        which a clear that only rmtree'd weights would leave behind."""
        repo = self._download(self.model_ids[0])
        repos = self.manager.repos_on_disk()
        self.manager._clear(self._op(), repos)
        self.assertEqual(self.state.deleted, [self.model_ids[0]])
        self.assertFalse(os.path.isdir(repo))

    def test_a_partial_repo_is_removed_and_its_attempt_cleared(self) -> None:
        """Otherwise the entry keeps offering "Resume download" over nothing."""
        repo = self._download(self.model_ids[0], marked=False)
        self.registry.mark_attempted(self.model_ids[0])
        self.manager._clear(self._op(), self.manager.repos_on_disk())
        self.assertFalse(os.path.isdir(repo))
        self.assertFalse(self.registry.was_attempted(self.model_ids[0]))
        self.assertEqual(self.state.deleted, [])

    def test_the_roots_we_own_outright_go_too(self) -> None:
        """A clear that left them would leave the largest single directory on
        some installs sitting behind a zero."""
        aux = self._aux_dir("msst-weights")
        dirs = [DirOnDisk(name="msst-weights", path=aux,
                          bytes=dir_bytes(aux))]
        self.manager._clear(self._op(), [], dirs)
        self.assertFalse(os.path.isdir(aux))

    def test_a_partial_scope_leaves_the_installed_models_alone(self) -> None:
        self._download(self.model_ids[0])
        self._download(self.model_ids[1], marked=False)
        captured = {}
        self.manager._start = lambda mode, run, plan: captured.update(
            mode=mode, run=run, plan=plan) or {}
        self.manager.start_clear("partial")
        self.assertEqual(captured["plan"]["repo_count"], 1)
        self.assertEqual(captured["plan"]["dir_count"], 0)

    def test_a_partial_scope_never_reaches_the_aux_root(self) -> None:
        """Aux directories have no partial state to reclaim: no marker, no
        notion of a finished download."""
        self._download(self.model_ids[0], marked=False)
        self._aux_dir("yue2")
        captured = {}
        self.manager._start = lambda mode, run, plan: captured.update(
            plan=plan) or {}
        self.manager.start_clear("partial")
        self.assertEqual(captured["plan"]["dir_count"], 0)

    def test_an_all_scope_spares_the_users_own_files(self) -> None:
        """Neither "delete them" nor "leave them" is a decision anyone means
        to make about a collection they curated."""
        if not AUX_KEPT_DIRS:
            self.skipTest("no kept aux dirs declared")
        kept = self._aux_dir(AUX_KEPT_DIRS[0])
        self._aux_dir("yue2")
        captured = {}
        self.manager._start = lambda mode, run, plan: captured.update(
            run=run, plan=plan) or {}
        self.manager.start_clear("all")
        captured["run"](self._op())
        self.assertTrue(os.path.isdir(kept))
        self.assertFalse(os.path.isdir(os.path.join(self.aux, "yue2")))

    def test_a_cancelled_clear_stops_and_says_so(self) -> None:
        """Half a library is a state the folder can genuinely be in; the
        honest answer to "stop" is to stop somewhere describable."""
        self._download(self.model_ids[0], marked=False)
        op = self._op()
        self.manager.cancel()
        self.manager._clear(op, self.manager.repos_on_disk())
        self.assertTrue(op["canceled"])
        self.assertTrue(os.path.isdir(self.registry.repo_cache_dir(
            self._repo_id(self.model_ids[0]))))


# MARK: - relocate


class RelocateValidationTest(LibraryTestCase):
    def test_an_unknown_disposition_is_refused(self) -> None:
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_relocate(os.path.join(self.tmp.name, "dest"),
                                        "incinerate")
        self.assertEqual((ctx.exception.status, ctx.exception.code),
                         (422, "VALIDATION"))

    def test_relocating_to_the_current_folder_is_refused(self) -> None:
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_relocate(self.library, "move")
        self.assertIn("already the library folder", str(ctx.exception))

    def test_a_destination_inside_the_old_folder_is_refused(self) -> None:
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_relocate(os.path.join(self.library, "inner"),
                                        "move")
        self.assertIn("cannot be inside the old one", str(ctx.exception))

    def test_a_destination_inside_the_aux_cache_is_refused(self) -> None:
        dest = os.path.join(self.aux, "inner")
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_relocate(dest, "move")
        self.assertIn("auxiliary cache", str(ctx.exception))

    @unittest.skipIf(os.geteuid() == 0, "root can write anywhere")
    def test_an_unwritable_destination_is_refused(self) -> None:
        locked = os.path.join(self.tmp.name, "locked")
        os.makedirs(locked)
        os.chmod(locked, 0o500)
        self.addCleanup(os.chmod, locked, 0o700)
        with self.assertRaises(LibraryError) as ctx:
            self.manager.start_relocate(os.path.join(locked, "dest"), "move")
        self.assertEqual((ctx.exception.status, ctx.exception.code),
                         (422, "VALIDATION"))

    def test_the_aux_root_follows_the_library_into_a_chosen_folder(self) -> None:
        dest = os.path.join(self.tmp.name, "dest")
        self.assertEqual(self.manager.aux_destination(dest),
                         os.path.join(dest, AUX_FOLDER_NAME))

    def test_the_aux_root_goes_back_to_the_data_dir_for_the_shared_cache(self) -> None:
        """A directory of ours would be litter in someone else's folder."""
        shared = os.path.expanduser("~/.cache/huggingface")
        self.assertEqual(self.manager.aux_destination(shared),
                         os.path.join(self.settings.data_dir, "aux-cache"))

    def test_the_plan_always_demands_a_restart(self) -> None:
        """The engine reads HF_HOME once at launch, so a relocate that fell
        over halfway needs the restart *more* than one that finished."""
        self._download(self.model_ids[0])
        captured = {}
        self.manager._start = lambda mode, run, plan: captured.update(
            plan=plan) or {}
        self.manager.start_relocate(os.path.join(self.tmp.name, "dest"),
                                    "leave")
        self.assertTrue(captured["plan"]["restart_required"])


class RelocateMoveTest(LibraryTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.dest = os.path.join(self.tmp.name, "dest")
        self.aux_dest = os.path.join(self.dest, AUX_FOLDER_NAME)

    def _op(self, total: int = 0) -> dict:
        return {"bytes_total": total, "bytes_done": 0, "fraction": 0.0,
                "message": ""}

    def _run_relocate(self, disposition: str) -> dict:
        captured: dict = {}
        self.manager._start = lambda mode, run, plan: captured.update(
            mode=mode, run=run, plan=plan) or {}
        self.manager.start_relocate(self.dest, disposition)
        op = self._op(captured["plan"]["bytes_total"])
        captured["run"](op)
        captured["op"] = op
        return captured

    def test_a_same_volume_move_renames_the_repo_across(self) -> None:
        """A rename is the whole move, instantly, with the blob/symlink
        structure intact."""
        src = self._download(self.model_ids[0])
        self._run_relocate("move")
        moved = os.path.join(self.dest, "hub", os.path.basename(src))
        self.assertTrue(os.path.isdir(moved))
        self.assertFalse(os.path.exists(src))

    def test_the_snapshot_symlinks_survive_the_move(self) -> None:
        src = self._download(self.model_ids[0])
        self._run_relocate("move")
        link = os.path.join(self.dest, "hub", os.path.basename(src),
                            "snapshots", "rev1", "model.safetensors")
        self.assertTrue(os.path.islink(link))
        self.assertTrue(os.path.exists(link))

    def test_the_aux_directories_travel_with_it(self) -> None:
        self._download(self.model_ids[0])
        self._aux_dir("yue2")
        self._run_relocate("move")
        self.assertTrue(os.path.isfile(
            os.path.join(self.aux_dest, "yue2", "weights.bin")))
        self.assertFalse(os.path.exists(os.path.join(self.aux, "yue2")))

    def test_the_move_reports_what_went(self) -> None:
        self._download(self.model_ids[0])
        captured = self._run_relocate("move")
        self.assertEqual(captured["op"]["moved_repo_ids"],
                         [self._repo_id(self.model_ids[0])])
        self.assertEqual(captured["op"]["skipped_repo_ids"], [])

    def test_leave_moves_nothing_but_the_users_own_files(self) -> None:
        """"Delete them" and "leave them" are decisions about weights that can
        be fetched again; a library that arrived without the user's captures
        would look empty."""
        if not AUX_KEPT_DIRS:
            self.skipTest("no kept aux dirs declared")
        src = self._download(self.model_ids[0])
        self._aux_dir(AUX_KEPT_DIRS[0])
        self._aux_dir("yue2")
        self._run_relocate("leave")
        self.assertTrue(os.path.isdir(src), "the repo was moved anyway")
        self.assertTrue(os.path.isdir(os.path.join(self.aux, "yue2")))
        self.assertTrue(os.path.isdir(
            os.path.join(self.aux_dest, AUX_KEPT_DIRS[0])))

    def test_delete_removes_the_old_folder_s_models(self) -> None:
        src = self._download(self.model_ids[0])
        self._run_relocate("delete")
        self.assertFalse(os.path.exists(src))
        self.assertEqual(self.state.deleted, [self.model_ids[0]])

    def test_a_pre_existing_destination_is_merged_by_copy(self) -> None:
        """The destination can already hold some of this directory from an
        earlier stint in that folder; per-directory is what makes that a
        merge rather than a collision."""
        src = self._download(self.model_ids[0])
        target = os.path.join(self.dest, "hub", os.path.basename(src))
        os.makedirs(target)
        self._run_relocate("move")
        self.assertTrue(os.path.isfile(os.path.join(target, "blobs",
                                                    "deadbeef")))
        self.assertTrue(os.path.islink(os.path.join(
            target, "snapshots", "rev1", "model.safetensors")))
        self.assertFalse(os.path.exists(src))

    def _cancel_once_the_copy_starts(self) -> None:
        """Land the cancel inside `_copy_tree` rather than before the loop.

        `_move` checks the flag once per repo, so a cancel set beforehand
        simply moves nothing; the partial-destination path only exists for a
        cancel that arrives while a tree is being walked. `_progress` is the
        first thing `relocate()` calls for each directory, which makes it the
        hook.
        """
        original = self.manager._progress

        def progress_then_cancel(op, done, message):
            original(op, done, message)
            self.manager.cancel()
        self.manager._progress = progress_then_cancel

    def test_a_cancel_mid_copy_tombstones_the_destination(self) -> None:
        """Cancelled mid-copy: the destination is partial and the source is
        still the only whole copy, so it must survive."""
        src = self._download(self.model_ids[0])
        target = os.path.join(self.dest, "hub", os.path.basename(src))
        os.makedirs(target)
        self._cancel_once_the_copy_starts()
        self.manager._move(self._op(), self.manager.repos_on_disk(),
                           self.dest)
        self.assertTrue(os.path.isdir(src), "the source was deleted anyway")
        self.assertTrue(os.path.exists(os.path.join(target,
                                                    INCOMPLETE_MARKER)))

    def test_a_cancel_before_the_first_repo_moves_nothing(self) -> None:
        """Nothing was started, so there is nothing partial to tombstone."""
        src = self._download(self.model_ids[0])
        op = self._op()
        self.manager.cancel()
        self.manager._move(op, self.manager.repos_on_disk(), self.dest)
        self.assertTrue(os.path.isdir(src))
        self.assertEqual(op["moved_repo_ids"], [])
        self.assertTrue(op["canceled"])

    def test_a_tombstoned_destination_reads_as_not_installed(self) -> None:
        """The tombstone is the handshake with `Registry.is_installed` and
        the adapters' staging guards — the point of writing it."""
        src = self._download(self.model_ids[0])
        target = os.path.join(self.dest, "hub", os.path.basename(src))
        os.makedirs(target)
        self._cancel_once_the_copy_starts()
        self.manager._move(self._op(), self.manager.repos_on_disk(),
                           self.dest)
        with EnvGuard(HF_HOME=self.dest):
            registry = Registry(make_settings(self.tmp.name))
            self.assertTrue(registry.repo_tombstoned(
                self._repo_id(self.model_ids[0])))
            self.assertFalse(registry.is_installed(self.model_ids[0]))


class TreeCopiedTest(LibraryTestCase):
    """`_tree_copied` is what stands between a finished copy and `rmtree` of
    the source: some trees here exist nowhere else, so deletion has to be
    earned, not assumed."""

    def setUp(self) -> None:
        super().setUp()
        self.src = os.path.join(self.tmp.name, "src")
        self.dst = os.path.join(self.tmp.name, "dst")
        for d in (self.src, self.dst):
            os.makedirs(os.path.join(d, "blobs"))
            with open(os.path.join(d, "blobs", "a.bin"), "wb") as f:
                f.write(b"a" * 64)
            os.symlink(os.path.join("blobs", "a.bin"),
                       os.path.join(d, "link"))

    def test_an_identical_tree_is_copied(self) -> None:
        self.assertTrue(_tree_copied(self.src, self.dst))

    def test_a_missing_file_is_not(self) -> None:
        os.unlink(os.path.join(self.dst, "blobs", "a.bin"))
        self.assertFalse(_tree_copied(self.src, self.dst))

    def test_a_short_file_is_not(self) -> None:
        with open(os.path.join(self.dst, "blobs", "a.bin"), "wb") as f:
            f.write(b"a" * 8)
        self.assertFalse(_tree_copied(self.src, self.dst))

    def test_a_link_pointing_somewhere_else_is_not(self) -> None:
        os.unlink(os.path.join(self.dst, "link"))
        os.symlink("/elsewhere", os.path.join(self.dst, "link"))
        self.assertFalse(_tree_copied(self.src, self.dst))

    def test_a_link_copied_as_a_file_is_not(self) -> None:
        """Copying the snapshot tree as files would duplicate every blob and
        double the size of the library on arrival."""
        os.unlink(os.path.join(self.dst, "link"))
        with open(os.path.join(self.dst, "link"), "wb") as f:
            f.write(b"a" * 64)
        self.assertFalse(_tree_copied(self.src, self.dst))


class MarkerHelperTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_the_tombstone_is_written_and_cleared(self) -> None:
        _mark_incomplete(self.tmp.name)
        marker = os.path.join(self.tmp.name, INCOMPLETE_MARKER)
        self.assertTrue(os.path.exists(marker))
        _clear_incomplete(self.tmp.name)
        self.assertFalse(os.path.exists(marker))

    def test_clearing_an_absent_tombstone_is_not_an_error(self) -> None:
        _clear_incomplete(self.tmp.name)

    def test_tombstoning_an_absent_directory_is_not_an_error(self) -> None:
        _mark_incomplete(os.path.join(self.tmp.name, "nope"))

    def test_same_size_is_false_for_an_absent_file(self) -> None:
        self.assertFalse(_same_size(os.path.join(self.tmp.name, "nope"), 0))

    def test_nearest_existing_walks_up_to_a_real_path(self) -> None:
        """`disk_usage` needs a real path, and a library folder configured but
        never yet created is an ordinary state."""
        deep = os.path.join(self.tmp.name, "a", "b", "c")
        self.assertEqual(_nearest_existing(deep), self.tmp.name)

    def test_nearest_existing_returns_an_existing_path_unchanged(self) -> None:
        self.assertEqual(_nearest_existing(self.tmp.name), self.tmp.name)


if __name__ == "__main__":
    unittest.main()

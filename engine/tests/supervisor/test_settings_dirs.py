"""`Settings.ensure_dirs` — coming up with the library drive unplugged (M5).

The library roots are the ones that can sit on another volume, so they are
the ones that can be missing. This used to take the engine down before it
ever answered: with the library drive unmounted,
`makedirs('/Volumes/<drive>/…')` raises PermissionError (errno 13, not 2 —
/Volumes is root-owned), the traceback escaped `run()` before the handshake
file was written, and the app crash-restarted four times into a Settings
screen that needs a live engine to draw — the one screen that could have
repointed the folder.

The unavailable root here is a chmod-0500 directory in a temp tree, which
raises the same PermissionError without needing a volume to unmount.
"""

from __future__ import annotations

import contextlib
import io
import os
import tempfile
import unittest

from _fixtures import EnvGuard, make_settings


@unittest.skipIf(os.geteuid() == 0, "root can write into a 0500 directory")
class UnavailableRootTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._cleanup)
        self.locked = os.path.join(self.tmp.name, "unplugged")
        os.makedirs(self.locked)
        os.chmod(self.locked, 0o500)
        self.library = os.path.join(self.locked, "library")
        self.settings = None

    def _cleanup(self) -> None:
        os.chmod(self.locked, 0o700)
        fd = getattr(self.settings, "_lock_fd", None)
        if fd is not None:
            with contextlib.suppress(OSError):
                os.close(fd)
        self.tmp.cleanup()

    def _ensure(self, aux: str | None = None) -> str:
        """Run ensure_dirs with the library pointed at the locked tree."""
        with EnvGuard(HF_HOME=self.library, LOCALMUSICGEN_AUX_CACHE=aux):
            self.settings = make_settings(self.tmp.name)
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.settings.ensure_dirs()
            return stderr.getvalue()

    def test_an_absent_library_root_is_reported_not_fatal(self) -> None:
        """M5: the engine must still come up and answer, so the Settings
        screen that could repoint the folder can be drawn."""
        self._ensure()
        self.assertEqual([p for p, _ in self.settings.unavailable_roots],
                         [self.library])

    def test_the_report_carries_the_reason(self) -> None:
        self._ensure()
        _path, reason = self.settings.unavailable_roots[0]
        self.assertTrue(reason)
        self.assertIsInstance(reason, str)

    def test_the_engine_still_constructs_its_own_dirs(self) -> None:
        """Nothing works without these, so a failure there is still fatal —
        but an absent *library* must not stop them being made."""
        self._ensure()
        for d in (self.settings.data_dir, self.settings.output_dir,
                  self.settings.envs_dir, self.settings.logs_dir,
                  self.settings.uploads_dir):
            self.assertTrue(os.path.isdir(d), d)

    def test_the_warning_also_goes_to_stderr(self) -> None:
        """The app tails this stream; a client that connects after startup
        misses an event emitted before it subscribed."""
        out = self._ensure()
        self.assertIn(self.library, out)
        self.assertIn("unavailable", out)

    def test_one_missing_drive_is_one_warning(self) -> None:
        """After a relocate the aux root lives inside the library folder, and
        naming both would tell the user twice about the same unplugged
        disk."""
        self._ensure(aux=os.path.join(self.library, "localmusic-aux"))
        self.assertEqual(len(self.settings.unavailable_roots), 1)


class HealthyStartTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._cleanup)
        self.settings = None

    def _cleanup(self) -> None:
        fd = getattr(self.settings, "_lock_fd", None)
        if fd is not None:
            with contextlib.suppress(OSError):
                os.close(fd)
        self.tmp.cleanup()

    def _ensure(self):
        with EnvGuard(HF_HOME=os.path.join(self.tmp.name, "library"),
                      LOCALMUSICGEN_AUX_CACHE=None):
            self.settings = make_settings(self.tmp.name)
            self.settings.ensure_dirs()
        return self.settings

    def test_a_healthy_start_reports_no_unavailable_roots(self) -> None:
        self.assertEqual(self._ensure().unavailable_roots, [])

    def test_every_root_exists_afterwards(self) -> None:
        s = self._ensure()
        for d in (s.hf_cache_dir, s.ms_cache_dir, s.aux_cache_dir,
                  s.uploads_dir, s.logs_dir, s.envs_dir):
            self.assertTrue(os.path.isdir(d), d)

    def test_startup_purges_transient_uploads(self) -> None:
        """Jobs are in-memory, so upload ids cannot usefully outlive the
        engine."""
        stale = os.path.join(self.tmp.name, "data", "uploads", "up_old")
        os.makedirs(stale)
        with open(os.path.join(stale, "audio.wav"), "w") as f:
            f.write("x")
        s = self._ensure()
        self.assertEqual(os.listdir(s.uploads_dir), [])

    def test_startup_collects_previews_a_cancel_left_behind(self) -> None:
        """A cancel deliberately leaves the last frame — the app may still be
        copying it out for "Keep partial" — so they are collected next start
        instead."""
        job_dir = os.path.join(self.tmp.name, "out", "job_1")
        os.makedirs(job_dir)
        preview = os.path.join(job_dir, "preview-3.wav")
        keep = os.path.join(job_dir, "take-1.wav")
        for p in (preview, keep):
            with open(p, "w") as f:
                f.write("x")
        self._ensure()
        self.assertFalse(os.path.exists(preview))
        self.assertTrue(os.path.exists(keep))

    def test_the_hf_and_aux_roots_are_published_to_the_environment(self) -> None:
        """Every hub download (supervisor or worker) and every adapter's own
        download goes through the app's cache dirs."""
        with EnvGuard(HF_HOME=os.path.join(self.tmp.name, "library"),
                      LOCALMUSICGEN_AUX_CACHE=None):
            self.settings = make_settings(self.tmp.name)
            self.settings.ensure_dirs()
            self.assertEqual(os.environ["HF_HOME"],
                             self.settings.hf_cache_dir)
            self.assertEqual(os.environ["LOCALMUSICGEN_AUX_CACHE"],
                             self.settings.aux_cache_dir)

    def test_a_second_engine_on_the_same_data_dir_refuses_to_start(self) -> None:
        """A second engine's startup purge used to rmtree the first's live
        uploads — hit live during the 2026-09 audit (audit H6)."""
        first = self._ensure()
        second = make_settings(self.tmp.name)
        with self.assertRaises(SystemExit) as ctx:
            second.ensure_dirs()
        self.assertIn(first.data_dir, str(ctx.exception))

    def test_the_memory_guard_honours_its_env_override(self) -> None:
        """0 disables it; without the override it is 90 % of physical RAM,
        which a test must not depend on."""
        s = make_settings(self.tmp.name)
        with EnvGuard(LOCALMUSICGEN_MEM_GUARD_BYTES="123456"):
            self.assertEqual(s.mem_guard_bytes, 123456)
        with EnvGuard(LOCALMUSICGEN_MEM_GUARD_BYTES="0"):
            self.assertEqual(s.mem_guard_bytes, 0)

    def test_the_modelscope_root_stays_in_the_data_dir(self) -> None:
        """Engine-owned rather than shared, so wiping the data dir is still a
        clean slate — and no relocate moves it."""
        s = make_settings(self.tmp.name)
        self.assertTrue(s.ms_cache_dir.startswith(s.data_dir + os.sep))


if __name__ == "__main__":
    unittest.main()

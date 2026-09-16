"""Per-family runtime provisioning (audit M14).

uv creates `.venv/bin/python` before it installs anything, so a sync that is
cancelled or fails part-way leaves a husk: a venv with a python, no packages
and no marker. `is_provisioned` takes a marker-less venv at its word —
because that is what a runtime built before markers existed looks like — so
the husk read "installed" forever: the Install-runtime affordance
disappeared, the download path skipped provisioning, and the next job died
inside the worker with ModuleNotFoundError.

The fake uv here reproduces exactly that: it makes the python and exits
non-zero. No network, no real uv, no packages.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest

from _fixtures import EnvGuard

from supervisor import envs

FAKE_UV_HUSK = "#!/bin/sh\nmkdir -p .venv/bin\ntouch .venv/bin/python\nexit 1\n"
FAKE_UV_OK = "#!/bin/sh\nmkdir -p .venv/bin\ntouch .venv/bin/python\nexit 0\n"
FAKE_UV_NOTHING = "#!/bin/sh\nexit 1\n"

# The three fake uvs are written once for the module rather than once per
# test: macOS scans each newly created executable on its first exec, and
# twenty-odd scans is most of this file's runtime.
_UV_DIR: tempfile.TemporaryDirectory | None = None
_UV_PATHS: dict[str, str] = {}


def setUpModule() -> None:
    global _UV_DIR
    _UV_DIR = tempfile.TemporaryDirectory()
    for name, script in (("husk", FAKE_UV_HUSK), ("ok", FAKE_UV_OK),
                         ("nothing", FAKE_UV_NOTHING)):
        path = os.path.join(_UV_DIR.name, f"fake-uv-{name}")
        with open(path, "w") as f:
            f.write(script)
        os.chmod(path, 0o755)
        _UV_PATHS[script] = path


def tearDownModule() -> None:
    if _UV_DIR is not None:
        _UV_DIR.cleanup()


class EnvsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.fam = os.path.join(self.root, "fam")
        os.makedirs(self.fam)
        with open(os.path.join(self.fam, "pyproject.toml"), "w") as f:
            f.write("[project]\nname = 'fam'\n")
        self.guard = EnvGuard(LOCALMUSICGEN_ADAPTERS_DIR=self.root,
                              LOCALMUSICGEN_UV=self._uv(FAKE_UV_HUSK))
        self.guard.__enter__()
        self.addCleanup(self.guard.__exit__)

    def _uv(self, script: str) -> str:
        return _UV_PATHS[script]

    def _use(self, script: str) -> None:
        os.environ["LOCALMUSICGEN_UV"] = self._uv(script)

    # MARK: the husk

    def test_a_failed_sync_raises(self) -> None:
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam")

    def test_a_failed_first_sync_leaves_no_husk_venv(self) -> None:
        """M14: the venv did not exist before this call, so it goes with it."""
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam")
        self.assertFalse(os.path.exists(os.path.join(self.fam, ".venv")))

    def test_so_the_family_does_not_report_a_runtime(self) -> None:
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam")
        self.assertFalse(envs.is_provisioned("fam"))

    def test_a_failed_re_sync_keeps_the_runtime_that_was_already_there(self) -> None:
        """A stale runtime that fails to re-sync is still a working runtime,
        and deleting that would be the worse outcome."""
        os.makedirs(os.path.join(self.fam, ".venv", "bin"))
        open(os.path.join(self.fam, ".venv", "bin", "python"), "w").close()
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam")
        self.assertTrue(os.path.exists(envs.python_for("fam")))

    def test_a_sync_that_never_makes_a_python_is_a_provision_error(self) -> None:
        self._use(FAKE_UV_NOTHING)
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam")
        self.assertFalse(os.path.exists(os.path.join(self.fam, ".venv")))

    def test_a_family_with_no_project_is_refused(self) -> None:
        """A model whose family ships no adapter project must not be given a
        button that would only ever fail."""
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("no-such-family")

    def test_the_uv_process_is_handed_to_the_caller(self) -> None:
        """The download manager kills a provisioning step the user cancelled;
        a first install pulls a torch-sized tree and can run for minutes."""
        seen = []
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam", on_proc=seen.append)
        self.assertEqual(len(seen), 1)
        self.assertIsNotNone(seen[0].poll())

    def test_progress_is_reported_before_the_work_starts(self) -> None:
        said = []
        with self.assertRaises(envs.ProvisionError):
            envs.ensure("fam", progress=said.append)
        self.assertEqual(said, ["Installing fam runtime…"])

    # MARK: a successful sync

    def test_a_successful_sync_returns_the_venv_python(self) -> None:
        self._use(FAKE_UV_OK)
        self.assertEqual(envs.ensure("fam"), envs.python_for("fam"))

    def test_a_successful_sync_writes_the_marker(self) -> None:
        self._use(FAKE_UV_OK)
        envs.ensure("fam")
        with open(envs.marker_path("fam")) as f:
            marker = json.load(f)
        self.assertIn("lock", marker)
        self.assertIn("installed_at", marker)

    def test_a_synced_family_reports_a_runtime(self) -> None:
        self._use(FAKE_UV_OK)
        envs.ensure("fam")
        self.assertTrue(envs.is_provisioned("fam"))

    # MARK: install state

    def test_no_venv_is_not_provisioned(self) -> None:
        self.assertFalse(envs.is_provisioned("fam"))

    def test_a_marker_less_venv_is_taken_at_its_word(self) -> None:
        """Those are real runtimes built before markers existed; demanding a
        reinstall of every one on upgrade would be a worse lie."""
        os.makedirs(os.path.join(self.fam, ".venv", "bin"))
        open(envs.python_for("fam"), "w").close()
        self.assertTrue(envs.is_provisioned("fam"))

    def test_a_marker_that_no_longer_matches_the_lock_is_stale(self) -> None:
        """Reporting it installed would put the multi-minute `uv sync` back in
        the middle of the user's first generation."""
        os.makedirs(os.path.join(self.fam, ".venv", "bin"))
        open(envs.python_for("fam"), "w").close()
        with open(envs.marker_path("fam"), "w") as f:
            json.dump({"lock": "a-digest-from-another-release"}, f)
        self.assertFalse(envs.is_provisioned("fam"))

    def test_a_corrupt_marker_is_taken_at_the_venv_s_word(self) -> None:
        os.makedirs(os.path.join(self.fam, ".venv", "bin"))
        open(envs.python_for("fam"), "w").close()
        with open(envs.marker_path("fam"), "w") as f:
            f.write("{not json")
        self.assertTrue(envs.is_provisioned("fam"))

    def test_the_marker_lives_inside_the_venv_so_it_dies_with_it(self) -> None:
        self.assertTrue(envs.marker_path("fam").startswith(
            envs.venv_dir("fam") + os.sep))

    def test_has_project_answers_for_a_family_that_ships_one(self) -> None:
        self.assertTrue(envs.has_project("fam"))
        self.assertFalse(envs.has_project("no-such-family"))

    def test_remove_reports_whether_there_was_anything_to_remove(self) -> None:
        self.assertFalse(envs.remove("fam"))
        os.makedirs(os.path.join(self.fam, ".venv", "bin"))
        open(envs.python_for("fam"), "w").close()
        self.assertTrue(envs.remove("fam"))
        self.assertFalse(os.path.exists(envs.venv_dir("fam")))

    def test_the_adapters_root_env_override_wins(self) -> None:
        """Packaged builds point this at a writable copy under Application
        Support; without it a test would sync the real adapter tree."""
        self.assertEqual(envs.adapters_root(), self.root)
        self.assertEqual(envs.family_dir("fam"), self.fam)


if __name__ == "__main__":
    unittest.main()

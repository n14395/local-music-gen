"""The pre-download disk check measures the right volume (audit M18).

It used to measure `data_dir`. The app-support folder is on the boot disk
while the library is wherever the user put it (an external SSD here), so the
old check refused downloads that would have fit and waved through ones that
died part-way once the SSD was the full one.

`shutil.disk_usage` is faked and its argument recorded: the assertion is the
*path it was asked about*, which is the whole of the bug.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest

from _fixtures import EnvGuard, FakeBus, make_settings

from supervisor.downloader import DownloadError, DownloadManager
from supervisor.library import _nearest_existing
from supervisor.registry import Registry


class DiskCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.library = os.path.join(self.tmp.name, "library")
        os.makedirs(self.library)
        self.guard = EnvGuard(HF_HOME=self.library)
        self.guard.__enter__()
        self.addCleanup(self.guard.__exit__)
        self.settings = make_settings(self.tmp.name)
        os.makedirs(self.settings.ms_cache_dir, exist_ok=True)
        self.registry = Registry(self.settings)
        self.bus = FakeBus()
        self.manager = DownloadManager(self.registry, self.bus, lambda: None)
        # `_pump` dispatches a real download thread; every test here stops at
        # (or before) the enqueue.
        self.manager._pump = lambda: None
        self.model_id = next(iter(sorted(self.registry.models)))
        self.asked: list[str] = []
        self._real_disk_usage = shutil.disk_usage
        self.addCleanup(self._restore_disk_usage)

    def _restore_disk_usage(self) -> None:
        shutil.disk_usage = self._real_disk_usage

    def _fake_disk_usage(self, free: int):
        real = self._real_disk_usage

        def fake(path):
            self.asked.append(path)
            usage = real("/")
            return type(usage)(usage.total, usage.total - free, free)
        shutil.disk_usage = fake

    def test_the_check_measures_the_library_volume(self) -> None:
        """M18: not `data_dir`, which is on the boot disk."""
        self._fake_disk_usage(free=0)
        with self.assertRaises(DownloadError):
            self.manager.start(self.model_id)
        self.assertEqual(self.asked, [_nearest_existing(self.library)])

    def test_the_check_does_not_measure_the_data_dir(self) -> None:
        self._fake_disk_usage(free=0)
        with self.assertRaises(DownloadError):
            self.manager.start(self.model_id)
        for path in self.asked:
            self.assertFalse(path.startswith(self.settings.data_dir), path)

    def test_a_full_library_volume_refuses_with_insufficient_disk(self) -> None:
        self._fake_disk_usage(free=0)
        with self.assertRaises(DownloadError) as ctx:
            self.manager.start(self.model_id)
        self.assertEqual(ctx.exception.code, "INSUFFICIENT_DISK")
        self.assertIn(self.model_id, str(ctx.exception))
        self.assertIn(self.library, str(ctx.exception))

    def test_a_refused_download_records_no_attempt(self) -> None:
        """An attempt marker is what makes an entry offer "Resume download";
        a download that never started must not."""
        self._fake_disk_usage(free=0)
        with self.assertRaises(DownloadError):
            self.manager.start(self.model_id)
        self.assertFalse(self.registry.was_attempted(self.model_id))
        self.assertEqual(self.manager.tasks, {})

    def test_room_on_the_library_volume_lets_the_download_through(self) -> None:
        self._fake_disk_usage(free=1 << 60)
        download_id = self.manager.start(self.model_id)
        self.assertTrue(download_id.startswith("dl_"))
        self.assertTrue(self.registry.was_attempted(self.model_id))

    def test_the_headroom_is_twenty_percent_over_the_declared_size(self) -> None:
        """`disk_bytes * 1.2`: a download that exactly fits leaves nothing for
        the blobs staged beside the snapshot."""
        need = self.registry.models[self.model_id]["requirements"]["disk_bytes"]
        self._fake_disk_usage(free=int(need * 1.1))
        with self.assertRaises(DownloadError):
            self.manager.start(self.model_id)
        self._fake_disk_usage(free=int(need * 1.3) + 1)
        self.manager.start(self.model_id)

    def test_a_modelscope_half_is_measured_on_its_own_root(self) -> None:
        """ModelScope weights live in the data dir and the HF ones do not, so
        the two roots can be different volumes."""
        model = dict(self.registry.models[self.model_id])
        model["id"] = "fake-ms-model"
        model["ms_repos"] = [{"repo_id": "org/ms-model"}]
        self.registry.models["fake-ms-model"] = model
        self._fake_disk_usage(free=1 << 60)
        self.manager.start("fake-ms-model")
        self.assertEqual(
            self.asked,
            [_nearest_existing(self.library),
             _nearest_existing(self.settings.ms_cache_dir)])

    def test_a_second_start_for_the_same_model_joins_the_first(self) -> None:
        self._fake_disk_usage(free=1 << 60)
        first = self.manager.start(self.model_id)
        self.assertEqual(self.manager.start(self.model_id), first)

    def test_a_queued_download_announces_itself_on_arrival(self) -> None:
        """`_pump` only emits for the downloads it starts, so without this one
        waiting its turn produces no event at all."""
        self._fake_disk_usage(free=1 << 60)
        self.manager.start(self.model_id)
        self.assertEqual([d["model_id"]
                          for d in self.bus.named("download.progress")],
                         [self.model_id])

    def test_a_runtime_only_install_records_no_attempt(self) -> None:
        """Nothing about the weights is being touched, and an interrupted
        runtime install must not leave the model reading "partial"."""
        family = self.registry.models[self.model_id]["family"]
        from supervisor import envs
        if not envs.has_project(family):
            self.skipTest(f"family {family} ships no adapter project here")
        self.manager.start_runtime(self.model_id)
        self.assertFalse(self.registry.was_attempted(self.model_id))
        self.assertEqual(self.asked, [], "a runtime install measured disk")

    def test_a_family_with_no_runtime_package_is_refused(self) -> None:
        model = dict(self.registry.models[self.model_id])
        model["id"] = "fake-familyless"
        model["family"] = "no-such-family"
        self.registry.models["fake-familyless"] = model
        with self.assertRaises(DownloadError) as ctx:
            self.manager.start_runtime("fake-familyless")
        self.assertEqual(ctx.exception.code, "NO_RUNTIME")


if __name__ == "__main__":
    unittest.main()

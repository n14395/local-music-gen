"""Memory relief: what goes when the guard trips (audit 08-I2).

macOS will not OOM-kill a runaway Metal allocator, so the guard only warns —
and before this there was no response to memory pressure at all. Act first,
warn second: an idle warm worker is memory nobody is using, and dropping one
is strictly better than telling the user to pick a smaller model.

The workers here are fakes with `idle_since`, which is the whole of what the
policy reads. Built without `__init__` for the reason
`scripts/check_supervisor.py` gives.
"""

from __future__ import annotations

import json
import queue
import threading
import unittest

from _fixtures import FakeBus, fake_worker, make_queue

from supervisor.logmirror import LogMirror
from supervisor.worker import Worker


class RelieveMemoryPressureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.killed: list[str] = []
        self.bus = FakeBus()
        self.q = make_queue(bus=self.bus)
        self.q.lock = threading.RLock()
        self.culprit = self._w("dsp", "dsp-mixdown", idle_since=None)
        self.idle = self._w("analysis", "analysis-essentia", idle_since=100.0)
        self.busy = self._w("msst", "msst-sep", idle_since=None)
        self.resident = self._w("acestep", "acestep-v1", idle_since=0.0)
        self.q.small_workers = {"dsp": self.culprit, "analysis": self.idle,
                                "msst": self.busy}
        self.q.worker = self.resident

    def _w(self, family, model_id, idle_since):
        return fake_worker(family, model_id, idle_since=idle_since,
                           killed=self.killed)

    def test_an_idle_pool_member_is_dropped(self) -> None:
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertIn("analysis-essentia", freed)
        self.assertNotIn("analysis", self.q.small_workers)

    def test_an_idle_unpinned_resident_is_dropped(self) -> None:
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertIn("acestep-v1", freed)
        self.assertIsNone(self.q.worker)

    def test_the_worker_that_tripped_the_guard_is_never_dropped(self) -> None:
        """It is the one doing the work the user is waiting for."""
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertNotIn("dsp-mixdown", freed)
        self.assertIs(self.q.small_workers.get("dsp"), self.culprit)

    def test_a_worker_mid_job_is_never_dropped(self) -> None:
        """`idle_since` is None for exactly as long as a worker is working."""
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertNotIn("msst-sep", freed)
        self.assertIs(self.q.small_workers.get("msst"), self.busy)

    def test_the_resident_running_the_active_job_is_never_dropped(self) -> None:
        """`self.active.worker`, not the resident slot: a small job can be
        running while an unrelated big model sits resident, and vice versa."""
        import types
        self.resident.idle_since = 0.0
        self.q.active = types.SimpleNamespace(worker=self.resident)
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertNotIn("acestep-v1", freed)
        self.assertIs(self.q.worker, self.resident)

    def test_a_pinned_resident_model_is_never_evicted(self) -> None:
        """The idle loop would reload it within the second, and a reload loop
        under memory pressure is worse than the pressure."""
        self.q.pinned_model_id = "acestep-v1"
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertNotIn("acestep-v1", freed)
        self.assertIs(self.q.worker, self.resident)

    def test_everything_reported_freed_is_actually_killed(self) -> None:
        freed = self.q.relieve_memory_pressure(self.culprit)
        self.assertEqual(sorted(self.killed), sorted(freed))

    def test_the_titlebar_is_told_the_resident_went(self) -> None:
        """An eviction announces itself where a displacement does not — the
        titlebar must stop claiming this model is loaded."""
        self.q.relieve_memory_pressure(self.culprit)
        self.assertIn({"state": "stopped", "model_id": "acestep-v1",
                       "family": "acestep"}, self.bus.named("worker.state"))

    def test_nothing_idle_frees_nothing_and_kills_nothing(self) -> None:
        q = make_queue(bus=FakeBus())
        q.lock = threading.RLock()
        culprit = self._w("dsp", "dsp-mixdown", idle_since=None)
        q.small_workers = {"dsp": culprit}
        self.assertEqual(q.relieve_memory_pressure(culprit), [])
        self.assertEqual(self.killed, [])


class MemoryWarningTest(unittest.TestCase):
    """The other half of 08-I2: the warning has to name what was unloaded,
    or a render that quietly lost its warm workers looks like one that did
    not."""

    def _worker(self, freed: list[str] | None, limit: int = 1 << 30) -> Worker:
        w = object.__new__(Worker)
        w.family = "fakefam"
        w.bus = FakeBus()
        w.log_mirror = LogMirror()
        w._current_job_id = "job_1"
        w.mem_limit = limit
        w._mem_warned = False
        w.mem_bytes = 0
        w.backend = None
        w.working_set_bytes = None
        w.messages = queue.Queue()
        w.on_memory_pressure = (lambda _self: list(freed)) if freed is not None \
            else None
        w._log_write = lambda _data: None
        return w

    def _drive(self, worker: Worker, mem_bytes: int) -> None:
        line = json.dumps({"t": "mem", "bytes": mem_bytes,
                           "backend": "mps", "working_set_bytes": 1 << 34})
        worker.proc = type("P", (), {"stdout": iter([line])})()
        worker._read_stdout()

    def test_crossing_the_level_warns_once(self) -> None:
        w = self._worker(freed=[])
        self._drive(w, 2 << 30)
        self.assertEqual(len(w.bus.named("engine.warning")), 1)

    def test_the_warning_names_what_was_unloaded(self) -> None:
        w = self._worker(freed=["analysis-essentia", "acestep-v1"])
        self._drive(w, 2 << 30)
        message = w.bus.named("engine.warning")[0]["message"]
        self.assertIn("analysis-essentia", message)
        self.assertIn("acestep-v1", message)
        self.assertIn("unloaded", message)

    def test_a_warning_with_nothing_to_unload_says_nothing_about_it(self) -> None:
        w = self._worker(freed=[])
        self._drive(w, 2 << 30)
        self.assertNotIn("unloaded", w.bus.named("engine.warning")[0]["message"])

    def test_the_running_job_is_told_as_well_as_the_titlebar(self) -> None:
        w = self._worker(freed=["analysis-essentia"])
        self._drive(w, 2 << 30)
        self.assertEqual([d["job_id"] for d in w.bus.named("job.log")],
                         ["job_1"])

    def test_below_the_level_nothing_is_said(self) -> None:
        w = self._worker(freed=[])
        self._drive(w, 1 << 20)
        self.assertEqual(w.bus.named("engine.warning"), [])

    def test_relief_that_raises_does_not_take_the_reader_thread_down(self) -> None:
        """This runs on the stdout reader thread, and a reader thread that
        dies takes the job's only end-of-stream signal with it."""
        w = self._worker(freed=None)
        w.on_memory_pressure = lambda _self: (_ for _ in ()).throw(
            RuntimeError("relief blew up"))
        self._drive(w, 2 << 30)
        self.assertEqual(len(w.bus.named("engine.warning")), 1)
        self.assertIsNone(w.messages.get_nowait())   # the EOF sentinel

    def test_a_memory_message_is_consumed_not_queued(self) -> None:
        """Nobody drains the message queue between jobs."""
        w = self._worker(freed=[])
        self._drive(w, 1 << 20)
        self.assertIsNone(w.messages.get_nowait())   # only the EOF sentinel

    def test_a_backend_with_no_byte_count_does_not_reset_the_last_one(self) -> None:
        w = self._worker(freed=[])
        w.mem_bytes = 12345
        line = json.dumps({"t": "mem", "backend": "cpu"})
        w.proc = type("P", (), {"stdout": iter([line])})()
        w._read_stdout()
        self.assertEqual(w.mem_bytes, 12345)
        self.assertEqual(w.backend, "cpu")

    def test_the_warning_re_arms_only_below_85_percent(self) -> None:
        """Hysteresis, so a spiky allocator does not flood the stream."""
        w = self._worker(freed=[])
        self._drive(w, 2 << 30)
        self._drive(w, int((1 << 30) * 0.9))     # still high: no re-arm
        self.assertTrue(w._mem_warned)
        self._drive(w, int((1 << 30) * 0.5))     # well below: re-armed
        self.assertFalse(w._mem_warned)
        self._drive(w, 2 << 30)
        self.assertEqual(len(w.bus.named("engine.warning")), 2)


if __name__ == "__main__":
    unittest.main()

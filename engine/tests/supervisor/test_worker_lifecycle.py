"""`Worker.kill()` and what the runner lets go of afterwards (audit 08-B10).

`subprocess` only reaps late, via `Popen.__del__`, and these Popen objects
stay referenced for as long as something holds the `Worker` — so every
displaced or expired worker used to leave a zombie for the rest of the
session. And the `Worker` itself (its Popen, its log handle, its message
queue) used to be held on the job's history row for up to JOB_HISTORY_CAP
jobs at a time.

The child here is `/bin/sleep`, not a model: no venv, no weights, no GPU.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import threading
import time
import unittest

from _fixtures import FakeBus, FakeRegistry, fake_worker, make_queue

from supervisor.worker import Worker


def _sleeping_worker(family: str = "fakefam") -> Worker:
    """A real `Worker` around a real child, built without `__init__`.

    The constructor spawns `engine_protocol.worker_main` in a family venv and
    starts two reader threads; `kill()` touches exactly two attributes.
    """
    worker = object.__new__(Worker)
    worker.family = family
    worker.proc = subprocess.Popen(["/bin/sleep", "30"],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   start_new_session=True)
    worker._log = open(os.devnull, "wb", buffering=0)
    return worker


class WorkerKillTest(unittest.TestCase):
    def setUp(self) -> None:
        self.worker = _sleeping_worker()
        self.addCleanup(self._reap)

    def _reap(self) -> None:
        if self.worker.proc.poll() is None:      # pragma: no cover — safety
            self.worker.proc.kill()
            self.worker.proc.wait(timeout=5)

    def test_kill_reaps_the_child_rather_than_leaving_a_zombie(self) -> None:
        """08-B10: `poll()` answers None for a zombie too, so the assertion
        that matters is that it does NOT after kill()."""
        self.assertIsNone(self.worker.proc.poll())
        self.worker.kill()
        self.assertIsNotNone(self.worker.proc.poll())

    def test_kill_closes_the_log_handle(self) -> None:
        self.worker.kill()
        self.assertTrue(self.worker._log.closed)

    def test_is_alive_flips_with_the_child(self) -> None:
        self.assertTrue(self.worker.is_alive())
        self.worker.kill()
        self.assertFalse(self.worker.is_alive())

    def test_kill_is_idempotent(self) -> None:
        """"Real unload is process death; kill() is always safe" — including
        the second time, which the queue does on every expiry sweep."""
        self.worker.kill()
        self.worker.kill()
        self.assertIsNotNone(self.worker.proc.poll())

    def test_footprint_is_none_once_the_worker_is_gone(self) -> None:
        """A reaped pid can be reused; reading a stranger's footprint would
        be worse than reporting nothing."""
        self.worker.kill()
        self.assertIsNone(self.worker.footprint_bytes())

    def test_the_whole_process_group_goes_with_it(self) -> None:
        """`start_new_session` exists so kill() can take down anything the
        worker spawned — acestep.cpp, YuE and whisper.cpp all keep the model
        in a child process."""
        worker = object.__new__(Worker)
        worker.family = "fakefam"
        worker.proc = subprocess.Popen(
            ["/bin/sh", "-c", "/bin/sleep 30 & echo $!; wait"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, start_new_session=True)
        worker._log = open(os.devnull, "wb", buffering=0)
        grandchild = int(worker.proc.stdout.readline().strip())
        self.addCleanup(lambda: worker.proc.poll() is None
                        and worker.proc.kill())
        worker.kill()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:                                     # pragma: no cover
            self.fail(f"grandchild {grandchild} outlived the process group")


class _StopRunner(Exception):
    """Sentinel: ends `_run_forever` after the one job it was given."""


class RunnerReleasesWorkerTest(unittest.TestCase):
    """The runner's `finally` block, driven with a fake scheduler.

    `_next_job` and `_run_job` are replaced so nothing is loaded and nothing
    is rendered; the code under test is everything the loop does *after* a
    job settles.
    """

    def _drive(self, job, *, small=None):
        q = make_queue(registry=FakeRegistry(), bus=FakeBus())
        q.lock = threading.RLock()
        if small:
            q.small_workers.update(small)
        q.active = job
        handed = [job]

        def next_job():
            if handed:
                return handed.pop()
            raise _StopRunner
        q._next_job = next_job
        q._run_job = lambda _job: None
        with self.assertRaises(_StopRunner):
            q._run_forever()
        return q

    def test_a_settled_job_lets_go_of_its_worker(self) -> None:
        """08-B10: held for the life of the history row, a dead Worker kept
        its Popen, its log handle and its message queue alive for up to
        JOB_HISTORY_CAP jobs."""
        from supervisor.jobqueue import Job
        job = Job("grp_1", "fake-model", "p", None, 30.0, 1, {})
        job.worker = fake_worker()
        self._drive(job)
        self.assertIsNone(job.worker)

    def test_the_active_slot_is_cleared_when_the_job_settles(self) -> None:
        from supervisor.jobqueue import Job
        job = Job("grp_1", "fake-model", "p", None, 30.0, 1, {})
        job.worker = fake_worker()
        q = self._drive(job)
        self.assertIsNone(q.active)

    def test_the_small_worker_that_ran_starts_its_idle_clock(self) -> None:
        """`idle_since` is both the pool's LRU key and its TTL clock; a
        worker that never starts it is never reaped."""
        from supervisor.jobqueue import Job
        job = Job("grp_1", "fake-model", "p", None, 30.0, 1, {})
        worker = fake_worker("dsp", "dsp-mixdown")
        job.worker = worker
        self._drive(job, small={"dsp": worker})
        self.assertIsNotNone(worker.idle_since)

    def test_a_worker_evicted_mid_job_does_not_get_its_clock_reset(self) -> None:
        """Identity-checked: the pool slot may hold someone else by now."""
        from supervisor.jobqueue import Job
        job = Job("grp_1", "fake-model", "p", None, 30.0, 1, {})
        ran = fake_worker("dsp", "dsp-mixdown")
        replacement = fake_worker("dsp", "dsp-other", idle_since=None)
        job.worker = ran
        self._drive(job, small={"dsp": replacement})
        self.assertIsNone(ran.idle_since)


if __name__ == "__main__":
    unittest.main()

"""Cancel, in each of the states a job can be cancelled from (audit M13).

`_next_job` hands a job to the runner while its status still reads "queued"
— it only becomes "loading" inside `_run_job` — so a cancel landing in that
window took the "still queued" branch, told the client "canceled", and left
every later checkpoint reading a flag nobody had set: the model loaded and
the take rendered to the end anyway.
"""

from __future__ import annotations

import time
import types
import unittest

from _fixtures import FakeBus, FakeRegistry, fake_worker, make_queue

from supervisor.jobqueue import CANCEL_GRACE_S, Job, SubmitError


class CancelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.bus = FakeBus()
        self.queue = make_queue(registry=FakeRegistry(), bus=self.bus)

    def _job(self, status: str = "queued", queued: bool = True) -> Job:
        job = Job("grp_1", "fake-model", "a warm pad", None, 30.0, 1, {})
        job.status = status
        self.queue.jobs[job.id] = job
        if queued:
            self.queue.order.append(job.id)
        return job

    def test_a_cancel_while_queued_sets_the_flag(self) -> None:
        """M13: the flag, not just the status. Every later checkpoint reads
        it, and the job may already be in the runner's hand."""
        job = self._job()
        self.queue.cancel(job.id)
        self.assertTrue(job.cancel_requested)

    def test_a_cancel_while_queued_marks_it_canceled(self) -> None:
        job = self._job()
        self.queue.cancel(job.id)
        self.assertEqual(job.status, "canceled")

    def test_a_cancel_while_queued_takes_it_out_of_the_run_order(self) -> None:
        job = self._job()
        self.queue.cancel(job.id)
        self.assertEqual(self.queue.order, [])

    def test_a_cancel_while_queued_announces_itself(self) -> None:
        job = self._job()
        self.queue.cancel(job.id)
        self.assertEqual(self.bus.named("job.canceled"),
                         [{"job_id": job.id}])

    def test_a_canceled_job_records_when_it_settled(self) -> None:
        """History eviction keys on it; None would sort it out first."""
        job = self._job()
        self.queue.cancel(job.id)
        self.assertIsNotNone(job.terminal_monotonic)

    def test_a_cancel_mid_render_asks_the_worker_and_starts_the_clock(self) -> None:
        job = self._job(status="generating", queued=False)
        job.worker = fake_worker()
        before = time.monotonic()
        self.queue.cancel(job.id)
        self.assertTrue(job.cancel_requested)
        self.assertEqual(job.worker.cancels, 1)
        self.assertIsNotNone(job.cancel_deadline)
        self.assertGreaterEqual(job.cancel_deadline, before + CANCEL_GRACE_S)

    def test_a_cancel_mid_render_does_not_settle_the_job_itself(self) -> None:
        """The request is cooperative; the worker reports the cancel."""
        job = self._job(status="generating", queued=False)
        job.worker = fake_worker()
        self.queue.cancel(job.id)
        self.assertEqual(job.status, "generating")

    def test_the_grace_clock_starts_even_with_no_worker_to_ask(self) -> None:
        """A job in provisioning has no worker yet, and the deadline is what
        makes the cancel land at all."""
        job = self._job(status="loading", queued=False)
        self.queue.cancel(job.id)
        self.assertIsNotNone(job.cancel_deadline)
        self.assertTrue(self.queue.cancel_wake.is_set())

    def test_a_cancel_asks_the_job_s_own_worker_not_the_resident_slot(self) -> None:
        """A small job runs in the transient slot while an unrelated model
        sits resident; cancelling the resident would kill the wrong render."""
        resident = fake_worker("acestep", "acestep-v1")
        transient = fake_worker("dsp", "dsp-mixdown")
        self.queue.worker = resident
        job = self._job(status="generating", queued=False)
        job.worker = transient
        self.queue.cancel(job.id)
        self.assertEqual(transient.cancels, 1)
        self.assertEqual(resident.cancels, 0)

    def test_a_cancel_during_provisioning_kills_the_uv_install(self) -> None:
        """A first install pulls a torch-sized tree and can run for minutes —
        far too long to leave running after the user has said stop."""
        killed = []
        job = self._job(status="loading", queued=False)
        job.env_proc = types.SimpleNamespace(poll=lambda: None,
                                             kill=lambda: killed.append(True))
        self.queue.cancel(job.id)
        self.assertEqual(killed, [True])

    def test_an_already_finished_uv_install_is_not_killed_again(self) -> None:
        killed = []
        job = self._job(status="loading", queued=False)
        job.env_proc = types.SimpleNamespace(poll=lambda: 0,
                                             kill=lambda: killed.append(True))
        self.queue.cancel(job.id)
        self.assertEqual(killed, [])

    def test_cancelling_an_unknown_job_is_a_404(self) -> None:
        with self.assertRaises(SubmitError) as ctx:
            self.queue.cancel("job_nothing")
        self.assertEqual((ctx.exception.status, ctx.exception.code),
                         (404, "NOT_FOUND"))

    def test_cancelling_a_terminal_job_is_a_409(self) -> None:
        for status in ("succeeded", "failed", "canceled"):
            job = self._job(status=status, queued=False)
            with self.assertRaises(SubmitError) as ctx:
                self.queue.cancel(job.id)
            self.assertEqual((ctx.exception.status, ctx.exception.code),
                             (409, "JOB_NOT_CANCELABLE"), status)


if __name__ == "__main__":
    unittest.main()

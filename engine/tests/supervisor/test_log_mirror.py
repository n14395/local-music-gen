"""`LogMirror` and the worker stderr path it sits on (contract §6).

One ACE-Step render printed 17,476 lines of stderr — 2,614 tqdm redraws and
7,416 checkpoint tensor names — and every one of those was an SSE event on
the wire. Two rules: a bar redraw is a frame, not a line, and everything
else is rate limited *audibly*, because a cap that hides its own existence
makes a quiet render and a truncated one look the same.

Ported from `scripts/check_supervisor.py`, which is where this logic was
first pinned.
"""

from __future__ import annotations

import unittest

from _fixtures import FakeBus

from supervisor.logmirror import LogMirror
from supervisor.worker import Worker

BAR = " 76%|███████▌  | 38/50 [00:06<00:01,  8.74it/s]"


class LogMirrorTest(unittest.TestCase):
    def test_a_progress_bar_redraw_is_not_mirrored(self) -> None:
        self.assertEqual(LogMirror().offer(BAR, 0.0), [])

    def test_prose_that_merely_mentions_a_percentage_is_mirrored(self) -> None:
        """The pattern is anchored on `%|`, immediately before the bar."""
        m = LogMirror()
        self.assertEqual(m.offer("cache hit rate was 76% this run", 0.0),
                         ["cache hit rate was 76% this run"])

    def test_a_blank_line_is_not_a_line(self) -> None:
        self.assertEqual(LogMirror().offer("   ", 0.0), [])

    def test_an_ordinary_line_passes(self) -> None:
        self.assertEqual(LogMirror().offer("loading weights", 0.0),
                         ["loading weights"])

    def test_a_line_is_stripped(self) -> None:
        self.assertEqual(LogMirror().offer("  hello\n", 0.0), ["hello"])

    def test_the_cap_bites_within_one_window(self) -> None:
        m = LogMirror(lines_per_second=3)
        self.assertEqual(m.offer("a", 0.0), ["a"])
        m.offer("b", 0.1)
        m.offer("c", 0.2)
        self.assertEqual(m.offer("d", 0.3), [])
        self.assertEqual(m.offer("e", 0.4), [])

    def test_the_next_window_says_what_was_dropped(self) -> None:
        """A truncated render and a quiet one must not look the same."""
        m = LogMirror(lines_per_second=3)
        for i, line in enumerate("abcde"):
            m.offer(line, i * 0.1)
        self.assertEqual(m.offer("f", 1.5),
                         ["… 2 more lines not shown (see the worker log)", "f"])

    def test_the_note_does_not_repeat_once_the_flood_stops(self) -> None:
        m = LogMirror(lines_per_second=3)
        for i, line in enumerate("abcde"):
            m.offer(line, i * 0.1)
        m.offer("f", 1.5)
        self.assertEqual(m.offer("g", 2.6), ["g"])

    def test_one_dropped_line_is_singular(self) -> None:
        m = LogMirror(lines_per_second=1)
        m.offer("a", 0.0)
        m.offer("b", 0.1)
        self.assertEqual(m.offer("c", 1.5)[0],
                         "… 1 more line not shown (see the worker log)")

    def test_a_reset_forgets_the_previous_jobs_suppression(self) -> None:
        """A render that opened by reporting the *previous* render's
        suppressed lines would be a bug nobody would think to look for."""
        m = LogMirror(lines_per_second=1)
        m.offer("x", 0.0)
        m.offer("y", 0.1)
        m.reset()
        self.assertEqual(m.offer("z", 5.0), ["z"])

    def test_flush_pays_what_is_owed_at_end_of_stream(self) -> None:
        """A burst that is the last thing a worker prints — a stack trace on
        the way out — would otherwise be capped in silence."""
        m = LogMirror(lines_per_second=1)
        m.offer("a", 0.0)
        m.offer("b", 0.1)
        m.offer("c", 0.2)
        self.assertEqual(m.flush(),
                         ["… 2 more lines not shown (see the worker log)"])

    def test_flush_with_nothing_owed_says_nothing(self) -> None:
        m = LogMirror()
        m.offer("a", 0.0)
        self.assertEqual(m.flush(), [])

    def test_flush_is_not_owed_twice(self) -> None:
        m = LogMirror(lines_per_second=1)
        m.offer("a", 0.0)
        m.offer("b", 0.1)
        m.flush()
        self.assertEqual(m.flush(), [])

    def test_a_render_that_prints_slowly_is_never_touched(self) -> None:
        m = LogMirror()
        emitted = [line for i in range(200)
                   for line in m.offer(f"line {i}", i * 0.5)]
        self.assertEqual(len(emitted), 200)


class WorkerStderrTest(unittest.TestCase):
    """`_read_stderr` in situ, against a fake process.

    Constructed without `__init__` on purpose: the real one spawns a
    subprocess, and the six attributes this method touches are the whole of
    its world.
    """

    def _worker(self, lines: list[str], job_id: str | None = "job_1"):
        w = object.__new__(Worker)
        w.bus = FakeBus()
        w.log_mirror = LogMirror()
        w._current_job_id = job_id
        w.proc = type("P", (), {"stderr": iter(lines)})()
        w.written = []
        w._log_write = w.written.append
        return w

    def test_the_log_file_gets_everything_bar_frames_included(self) -> None:
        """The file is the record; the mirror is a summary of it for a pane
        ten lines tall."""
        lines = [BAR] + [f"step {i}/40" for i in range(40)]
        w = self._worker(lines)
        w._read_stderr()
        self.assertEqual(len(w.written), len(lines))

    def test_the_mirror_drops_the_bar_frame(self) -> None:
        w = self._worker([BAR, "loading weights"])
        w._read_stderr()
        mirrored = [d["line"] for d in w.bus.named("job.log")]
        self.assertEqual(mirrored, ["loading weights"])

    def test_the_mirror_caps_a_burst(self) -> None:
        w = self._worker([f"step {i}/40" for i in range(40)])
        w._read_stderr()
        mirrored = [d["line"] for d in w.bus.named("job.log")]
        self.assertLessEqual(len(mirrored), LogMirror().lines_per_second + 1)

    def test_the_app_is_told_it_was_capped_even_at_end_of_stream(self) -> None:
        """The burst is the last thing this worker says, so nothing later can
        carry the note — end of stream has to."""
        w = self._worker([f"step {i}/40" for i in range(40)])
        w._read_stderr()
        mirrored = [d["line"] for d in w.bus.named("job.log")]
        self.assertIn("not shown", mirrored[-1])
        self.assertIn("32 more lines", mirrored[-1])

    def test_stderr_between_jobs_still_reaches_the_file(self) -> None:
        w = self._worker(["loading weights"], job_id=None)
        w._read_stderr()
        self.assertEqual(len(w.written), 1)

    def test_but_it_belongs_to_no_job_so_it_is_not_mirrored(self) -> None:
        w = self._worker(["loading weights"], job_id=None)
        w._read_stderr()
        self.assertEqual(w.bus.events, [])

    def test_a_new_job_resets_the_budget(self) -> None:
        w = self._worker([f"step {i}/40" for i in range(40)])
        w._read_stderr()
        w.current_job_id = "job_2"
        self.assertEqual(w.log_mirror._suppressed, 0)

    def test_a_mirrored_line_is_truncated_for_the_wire(self) -> None:
        w = self._worker(["x" * 900])
        w._read_stderr()
        self.assertEqual(len(w.bus.named("job.log")[0]["line"]), 500)

    def test_a_reader_that_dies_still_drains_the_pipe(self) -> None:
        """An abandoned stderr fills its 64 KB buffer and whoever is writing
        to fd 2 blocks in write() forever, which hung the render with no
        timeout and no way to tell why."""
        drained = []

        class Exploding:
            def __iter__(self):
                return self

            def __next__(self):
                raise OSError("pipe went away")

            def read(self, n):
                drained.append(n)
                return "" if len(drained) > 1 else "x" * n

        w = self._worker([])
        w.proc = type("P", (), {"stderr": Exploding()})()
        w._read_stderr()
        self.assertTrue(drained)
        self.assertTrue(any(b"stderr reader died" in line
                            for line in w.written))


if __name__ == "__main__":
    unittest.main()

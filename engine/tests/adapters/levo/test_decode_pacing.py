"""LeVo's Flow1dVAE decode: pacing a child's tqdm bars into one honest bar.

Covers 10-B11. The decode is the longer half of a render (~6 s of wall time
per song second) and upstream's chunker runs one 10-step ODE bar per window,
each restarting at zero — reported raw that is a sawtooth, and reported once
it is a bar parked at 0.55 for minutes. A cancel in the middle must also
reap the child, or the decoder keeps the GPU for the rest of the session.

Nothing is spawned: `pump_decoder` is handed a fake child whose stdout is a
captured transcript.
"""

import contextlib
import io
import sys
import unittest

from _fixtures import (CancelledNow, FakeProc, NeverCancelled, Progress,
                       ode_bar, transcript)
from adapter_levo.adapter import instrumental_lyrics, pump_decoder
from engine_protocol.adapter import CancelledError


def pump(proc, windows, progress, cancel=None):
    """Run the pacing loop with the child's echo swallowed.

    The loop mirrors the decoder's output to this process's stdout, which is
    the render card's log; a test must not print it.
    """
    with contextlib.redirect_stdout(io.StringIO()):
        pump_decoder(proc, windows, progress,
                     cancel if cancel is not None else NeverCancelled())


class PacingTests(unittest.TestCase):
    def test_a_replayed_transcript_paces_one_label_per_window(self):
        """10-B11: three windows, three window labels, in order."""
        progress = Progress()
        pump(FakeProc(transcript(3)), 3, progress)
        self.assertEqual(sorted(set(progress.windows)), [1, 2, 3])
        labels = [c["message"] for c in progress.calls]
        self.assertTrue(all("window" in m for m in labels), labels)
        # Each window's label appears before the next window's first one.
        first_seen = [progress.windows.index(w) for w in (1, 2, 3)]
        self.assertEqual(first_seen, sorted(first_seen))

    def test_the_fractions_never_fall_back(self):
        """10-B11: a bar that falls back reads as a restart."""
        progress = Progress()
        pump(FakeProc(transcript(3)), 3, progress)
        self.assertEqual(progress.fractions, sorted(progress.fractions))

    def test_the_decode_ends_at_the_ceiling(self):
        """10-B11: the decode owns 0.55…0.95; the mastering half follows."""
        progress = Progress()
        pump(FakeProc(transcript(3)), 3, progress)
        self.assertAlmostEqual(progress.fractions[-1], 0.95, places=6)
        self.assertGreaterEqual(progress.fractions[0], 0.55)

    def test_a_plain_checkpoint_shard_line_is_ignored(self):
        """10-B11: `Loading checkpoint shards: 1/2` with no bar drawn
        matches neither tqdm pattern, so it never reaches the pacer."""
        progress = Progress()
        pump(FakeProc(transcript(2, plain_shards=2)), 2, progress)
        self.assertEqual(sorted(set(progress.windows)), [1, 2])
        self.assertEqual(progress.fractions, sorted(progress.fractions))
        self.assertAlmostEqual(progress.fractions[-1], 0.95, places=6)

    def test_a_checkpoint_shard_bar_does_not_consume_a_decode_window(self):
        """10-B11: a different bar family starts the window count at it,
        rather than being counted as a decode window of its own."""
        progress = Progress()
        pump(FakeProc(transcript(2, shards=2)), 2, progress)
        self.assertEqual(sorted(set(progress.windows)), [1, 2])

    # FINDING (10-B11, not fixed): a checkpoint-shard bar rendered as real
    # tqdm — `Loading checkpoint shards:  50%|█████| 1/2 [00:00<00:00]`,
    # which is what transformers prints — is paced as if it were a decode
    # window. `total != last_total` resets `done` but the fraction is still
    # `(done + step / total) / windows`, so two shards drive the bar to
    # 0.6167 then 0.6833 and the decode's first redraw drops it back to
    # 0.55. Observed: [0.6166666666666667, 0.6833333333333333, 0.55, …].
    # That is exactly the sawtooth "a bar that falls back means the next act
    # began" is meant to prevent, on the act BEFORE the decode.
    def test_a_checkpoint_shard_bar_does_not_push_the_decode_bar_backwards(
            self):
        progress = Progress()
        pump(FakeProc(transcript(2, shards=2)), 2, progress)
        self.assertEqual(progress.fractions, sorted(progress.fractions))

    def test_every_report_names_the_window_total(self):
        progress = Progress()
        pump(FakeProc(transcript(2)), 2, progress)
        for call in progress.calls:
            self.assertEqual(call["steps"], 2)
            self.assertIn("/2", call["message"])

    def test_the_window_count_never_runs_past_the_total(self):
        """More bars than windows must not report window 5 of 3.

        `windows` is computed from upstream's padding arithmetic and is an
        estimate, so a run can outlast it. The count clamps at the last
        window, which means the bar re-climbs that window rather than
        claiming windows that do not exist — and it still ends at 0.95.
        """
        progress = Progress()
        pump(FakeProc(transcript(5)), 3, progress)
        self.assertLessEqual(max(progress.windows), 3)
        self.assertAlmostEqual(progress.fractions[-1], 0.95, places=6)
        # Never above the ceiling, never below the decode's own floor.
        self.assertTrue(all(0.55 <= f <= 0.95 for f in progress.fractions))

    def test_lines_that_are_not_bars_are_ignored(self):
        progress = Progress()
        noise = "loading the vae\nwarming up\n" + ode_bar(10) + "\n"
        pump(FakeProc(noise), 1, progress)
        self.assertEqual(len(progress.calls), 1)


class CancelTests(unittest.TestCase):
    def test_a_cancel_reaps_the_decoder(self):
        """10-B11: an unreaped decoder keeps the GPU for the session."""
        proc = FakeProc(transcript(3))
        with self.assertRaises(CancelledError):
            pump(proc, 3, Progress(), cancel=CancelledNow())
        self.assertEqual(proc.kills, 1)
        self.assertGreaterEqual(proc.waits, 1)

    def test_a_cancel_raised_by_progress_also_reaps_the_decoder(self):
        """10-B11: progress_cb itself raises on a cancelled job, so the loop
        can leave without ever testing `cancel.cancelled`."""
        proc = FakeProc(transcript(3))
        with self.assertRaises(CancelledError):
            pump(proc, 3, Progress(raise_at=4))
        self.assertEqual(proc.kills, 1)
        self.assertGreaterEqual(proc.waits, 1)

    def test_a_child_that_already_exited_is_not_killed_again(self):
        proc = FakeProc(transcript(1))
        proc.wait()          # it finished on its own
        with self.assertRaises(CancelledError):
            pump(proc, 1, Progress(raise_at=1))
        self.assertEqual(proc.kills, 0)

    def test_a_finished_decode_leaves_the_child_alone(self):
        proc = FakeProc(transcript(2))
        pump(proc, 2, Progress())
        self.assertEqual(proc.kills, 0)
        self.assertEqual(proc.waits, 0)


class InstrumentalLyricsTests(unittest.TestCase):
    """No lyrics is a request, not a mistake: upstream's format has purely
    instrumental section tags, so an empty box becomes a wordless piece."""

    def test_the_tags_are_upstreams_own_and_bracket_the_piece(self):
        got = instrumental_lyrics(60.0)
        self.assertTrue(got.startswith("[intro-short]"))
        self.assertTrue(got.endswith("[outro-short]"))
        self.assertIn("[inst-long]", got)

    def test_a_longer_piece_gets_more_instrumental_blocks(self):
        short = instrumental_lyrics(30.0).count("[inst-long]")
        long = instrumental_lyrics(180.0).count("[inst-long]")
        self.assertLess(short, long)

    def test_a_very_short_piece_still_has_one_block(self):
        self.assertEqual(instrumental_lyrics(1.0).count("[inst-long]"), 1)
        self.assertEqual(instrumental_lyrics(0.0).count("[inst-long]"), 1)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

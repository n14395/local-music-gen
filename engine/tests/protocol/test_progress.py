"""`engine_protocol.progress` — tqdm interception for the CLI-driving adapters.

tqdm redraws its bar with carriage returns on one long line, so a readline()
loop sees nothing until the bar finishes. Several families sat silent through
their longest phase because of it (audit §5). `iter_progress_lines` splits on
both `\\r` and `\\n`; `parse_tqdm` pulls the counts out.
"""

from __future__ import annotations

import io
import unittest

import _fixtures  # noqa: F401 — path bootstrap

from engine_protocol.progress import (iter_progress_lines, parse_percent,
                                      parse_tqdm)

# A real capture: three redraws of one bar separated by \r, then a newline.
TQDM_REDRAWS = (
    "  0%|          | 0/50 [00:00<?, ?it/s]\r"
    " 24%|██▍       | 12/50 [00:01<00:04,  8.74it/s]\r"
    "100%|██████████| 50/50 [00:05<00:00,  9.13it/s]\n"
)


class ParseTqdmTest(unittest.TestCase):
    def test_a_bar_frame_yields_step_and_total(self) -> None:
        self.assertEqual(
            parse_tqdm(" 24%|██▍       | 12/50 [00:01<00:04,  8.74it/s]"),
            (12, 50))

    def test_a_labelled_bar_yields_its_counts(self) -> None:
        """10-B11: LeVo's decoder emits `Loading checkpoint shards` beside its
        own bars, and it is a real tqdm line with real counts."""
        self.assertEqual(
            parse_tqdm("Loading checkpoint shards:  50%|█████     | 1/2 "
                       "[00:01<00:01,  1.20s/it]"),
            (1, 2))

    def test_the_plain_form_without_a_bar_still_parses(self) -> None:
        self.assertEqual(parse_tqdm("9/20 [00:05<00:06]"), (9, 20))

    def test_a_finished_bar_reports_step_equal_to_total(self) -> None:
        self.assertEqual(
            parse_tqdm("100%|██████████| 50/50 [00:05<00:00,  9.13it/s]"),
            (50, 50))

    def test_a_zero_total_is_refused(self) -> None:
        """A division by this would take the render down with it."""
        self.assertIsNone(parse_tqdm("|  0/0 [00:00<?, ?it/s]"))

    def test_a_step_past_the_total_is_refused(self) -> None:
        self.assertIsNone(parse_tqdm("| 51/50 [00:05<00:00]"))

    def test_ordinary_prose_is_not_progress(self) -> None:
        self.assertIsNone(parse_tqdm("loading checkpoint from disk"))
        self.assertIsNone(parse_tqdm("step 3 of 4"))


class ParsePercentTest(unittest.TestCase):
    def test_a_bare_percentage_becomes_a_fraction(self) -> None:
        self.assertAlmostEqual(parse_percent("decoding… 76% done"), 0.76)

    def test_an_impossible_percentage_is_refused(self) -> None:
        self.assertIsNone(parse_percent("176% done"))

    def test_a_line_with_no_percentage_is_none(self) -> None:
        self.assertIsNone(parse_percent("decoding"))


class IterProgressLinesTest(unittest.TestCase):
    def test_carriage_return_redraws_arrive_as_they_happen(self) -> None:
        """The bug: a `\\r`-redrawn bar reached a readline() loop as one giant
        line once it was over, so the phase it measured looked silent."""
        lines = list(iter_progress_lines(io.StringIO(TQDM_REDRAWS)))
        self.assertEqual(len(lines), 3)
        self.assertEqual([parse_tqdm(line) for line in lines],
                         [(0, 50), (12, 50), (50, 50)])

    def test_blank_frames_between_redraws_are_dropped(self) -> None:
        lines = list(iter_progress_lines(io.StringIO("a\r\n\r\n  \r\nb\n")))
        self.assertEqual(lines, ["a", "b"])

    def test_a_tail_with_no_terminator_is_still_yielded(self) -> None:
        """A process killed mid-bar closes the pipe without a newline; the
        last thing it said is the most worth having."""
        lines = list(iter_progress_lines(io.StringIO("first\rhalf a line")))
        self.assertEqual(lines, ["first", "half a line"])

    def test_an_empty_stream_yields_nothing(self) -> None:
        self.assertEqual(list(iter_progress_lines(io.StringIO(""))), [])

    def test_a_mixed_stream_keeps_prose_and_bars_in_order(self) -> None:
        stream = io.StringIO("loading model\n" + TQDM_REDRAWS + "done\n")
        lines = list(iter_progress_lines(stream))
        self.assertEqual(lines[0], "loading model")
        self.assertEqual(lines[-1], "done")
        self.assertEqual([parse_tqdm(line) for line in lines[1:-1]],
                         [(0, 50), (12, 50), (50, 50)])


if __name__ == "__main__":
    unittest.main()

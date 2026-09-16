"""abc_convert: the tidying a notation model's raw reply needs.

Covers audit items M46, 10-B3 and 10-B4 — the three ways this module used to
turn a model's answer into something the app then showed as notation:
prose filed as ABC, body notes rewritten into header fields, and the
unconditional `X:1` that made the first two possible.
"""

import os
import sys
import tempfile
import unittest

from adapter_notation import abc_convert

# A real three-line tune: header, body, and nothing else.
TUNE = "X:1\nM:4/4\nL:1/8\nK:G\nGABc dedB|GABc d2 g2|"


class CleanTests(unittest.TestCase):
    def test_prose_reply_cleans_to_empty(self):
        """M46: a sentence about music is not a tune.

        `normalise` used to prepend `X:1` to anything non-empty, so the
        "nothing tune-shaped here" guard in `clean` was dead code and the
        sentence was stored as the take's ABC.
        """
        self.assertEqual(
            abc_convert.clean("I would write a cheerful waltz in G major."),
            "")

    def test_empty_reply_cleans_to_empty(self):
        """M46: nothing in, nothing out — not a bare `X:1`."""
        self.assertEqual(abc_convert.clean(""), "")
        self.assertEqual(abc_convert.clean("   \n  "), "")

    def test_three_line_tune_round_trips(self):
        """M46: a well-formed tune survives cleaning unchanged."""
        got = abc_convert.clean(TUNE)
        self.assertEqual(got, TUNE)

    def test_preamble_before_the_tune_is_dropped(self):
        """M46: models open with a sentence; music21 cannot parse past it."""
        got = abc_convert.clean("Here is a jig in G:\n\n" + TUNE)
        self.assertEqual(got, TUNE)

    def test_fenced_block_is_unwrapped(self):
        """M46: a markdown fence with a language tag still yields the tune."""
        got = abc_convert.clean("Sure!\n```abc\n" + TUNE + "\n```\nEnjoy.")
        self.assertEqual(got, TUNE)


class NormaliseTests(unittest.TestCase):
    def test_body_notes_are_not_turned_into_header_fields(self):
        """10-B3: `C2 D2 E2 F2` is a bar of music, not the field `C:`.

        The repair that rewrites `L1/8` into `L:1/8` fired on body lines too,
        because the header was only ever terminated by `K:` — and this
        dialect is exactly the one that omits `K:`.
        """
        text = "X:1\nM:4/4\nL:1/8\nC2 D2 E2 F2|G4 z4|"
        got = abc_convert.normalise(text)
        self.assertIn("C2 D2 E2 F2|", got)
        self.assertNotIn("C:2 D2 E2 F2", got)

    def test_header_ends_at_the_first_non_field_line(self):
        """10-B3: a tune with no `K:` still has a header that ends."""
        text = "L1/8\nM:4/4\nGABc dedB|"
        got = abc_convert.normalise(text).splitlines()
        self.assertIn("L:1/8", got)
        self.assertIn("GABc dedB|", got)

    def test_field_run_together_with_its_value_is_repaired(self):
        """10-B4: text-to-music writes `L1/8` with no colon."""
        got = abc_convert.normalise("X:1\nL1/8\nK:G\nGABc|")
        self.assertIn("L:1/8", got.splitlines())

    def test_tempo_folded_into_the_metre_is_split_off(self):
        """10-B4: `M:6/8=150` is a metre and a tempo no reader accepts."""
        got = abc_convert.normalise("X:1\nM:6/8=150\nK:G\nGAB|")
        self.assertIn("M:6/8", got.splitlines())
        self.assertNotIn("M:6/8=150", got)

    def test_prose_never_gains_a_reference_number(self):
        """M46/10-B4: the `X:1` that used to be prepended unconditionally."""
        prose = "I would write a cheerful waltz in G major."
        self.assertEqual(abc_convert.normalise(prose), prose)

    def test_a_tune_without_a_reference_number_gains_one(self):
        """10-B4: every tune needs `X:`, and no model reliably writes one."""
        got = abc_convert.normalise("M:4/4\nK:G\nGABc|")
        self.assertTrue(got.startswith("X:1\n"), got)


class ForMidiTests(unittest.TestCase):
    def test_text_annotations_are_stripped_only_for_the_conversion(self):
        """music21 dies on `"^A"`; the stored notation keeps it."""
        text = 'X:1\nK:G\n"^gently"GABc|'
        self.assertNotIn('"^gently"', abc_convert.for_midi(text))
        self.assertIn('"^gently"', abc_convert.clean(text))

    def test_chord_symbols_survive(self):
        """A chord symbol has no placement prefix and is legal for music21."""
        self.assertIn('"G"', abc_convert.for_midi('X:1\nK:G\n"G"GABc|'))


class ToMidiTests(unittest.TestCase):
    def test_a_tune_converts_and_reports_its_note_count(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "tune.mid")
            notes = abc_convert.to_midi(TUNE, out)
            self.assertEqual(notes, 14)
            self.assertTrue(os.path.exists(out))
            # The .part staging file must not survive the rename.
            self.assertEqual(os.listdir(d), ["tune.mid"])

    def test_notation_with_no_notes_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "tune.mid")
            with self.assertRaises(ValueError):
                abc_convert.to_midi("X:1\nM:4/4\nL:1/8\nK:G\n", out)
            self.assertFalse(os.path.exists(out))


class LooksLikeAbcTests(unittest.TestCase):
    def test_a_tune_is_notation_and_a_sentence_is_not(self):
        self.assertTrue(abc_convert.looks_like_abc(TUNE))
        self.assertFalse(
            abc_convert.looks_like_abc("a cheerful waltz in G major"))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

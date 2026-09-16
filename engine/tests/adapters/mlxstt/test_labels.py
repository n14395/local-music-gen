"""Qwen2-Audio's tag replies, cleaned into labels.

Covers 11-B11. The strip used to look at the first line while the split ran
over the whole answer, keeping the piece after the LAST colon anywhere in it
— so "Genres: techno, house\\nNote: fairly upbeat" came back as the single
tag "fairly upbeat".

Pure string work: no model, no audio, no MLX.
"""

import sys
import unittest

from adapter_mlxstt.qwen2audio import _clamp, _labels


class LabelTests(unittest.TestCase):
    def test_only_the_leading_label_of_the_first_line_is_stripped(self):
        """11-B11: the genres survive, and the trailing note does not eat
        them. The note itself comes through as a third tag — that is the
        current behaviour, not an accident of this fixture."""
        self.assertEqual(
            _labels("Genres: techno, house\nNote: fairly upbeat"),
            ["techno", "house", "note: fairly upbeat"])

    def test_a_chatty_preamble_still_yields_genres(self):
        """11-B11: instruction-following at this size is good, not perfect;
        a reply opening "Sure! Here are the genres:" must not become a tag
        called "sure"."""
        self.assertEqual(
            _labels("Sure! Here are the genres: techno, house, minimal"),
            ["techno", "house", "minimal"])

    def test_a_bare_comma_separated_reply_is_taken_as_written(self):
        """11-B11: the shape the prompt actually asks for."""
        self.assertEqual(_labels("techno, house"), ["techno", "house"])

    def test_a_numbered_list_loses_its_numbering(self):
        """11-B11: "1. techno" is a genre, not a genre called "1. techno"."""
        self.assertEqual(_labels("1. techno\n2. house\n3. minimal"),
                         ["techno", "house", "minimal"])

    def test_labels_are_lowercased_and_deduplicated(self):
        self.assertEqual(_labels("Techno, techno, House"),
                         ["techno", "house"])

    def test_a_sentence_too_long_to_be_a_label_is_dropped(self):
        long = "x" * 40
        self.assertEqual(_labels(f"techno, {long}"), ["techno"])

    def test_at_most_five_labels_come_back(self):
        self.assertEqual(len(_labels("a, b, c, d, e, f, g")), 5)

    def test_an_empty_reply_yields_nothing(self):
        self.assertEqual(_labels(""), [])
        self.assertEqual(_labels("   \n  "), [])

    def test_trailing_punctuation_is_trimmed(self):
        """Commas and newlines separate; anything else is only trimmed off
        the ends of a label."""
        self.assertEqual(_labels("techno, house."), ["techno", "house"])
        self.assertEqual(_labels("- techno\n- house"), ["techno", "house"])
        self.assertEqual(_labels("• techno, • house"), ["techno", "house"])


class ClampTests(unittest.TestCase):
    def test_a_value_outside_the_range_is_pulled_in(self):
        self.assertEqual(_clamp(-1, 0.7, 0.0, 1.5), 0.0)
        self.assertEqual(_clamp(9, 0.7, 0.0, 1.5), 1.5)

    def test_something_that_is_not_a_number_takes_the_default(self):
        self.assertEqual(_clamp(None, 0.7, 0.0, 1.5), 0.7)
        self.assertEqual(_clamp("warm", 0.7, 0.0, 1.5), 0.7)

    def test_a_legal_zero_survives(self):
        """0.0 is the low end of a real dial, not an absent value."""
        self.assertEqual(_clamp(0.0, 0.7, 0.0, 1.5), 0.0)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

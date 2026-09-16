"""MIDI → ABC: the serialiser this codebase owns (music21 cannot emit ABC).

A notation sketch is still a document someone reads, so the header has to be
well-formed ABC and the body has to be barred. Durations are the fiddly half:
every length is a Fraction of the unit note length, and every one written
has to be a value an engraver can draw — the app's notation viewer was the
first thing to engrave this output, and it answered a transcription with 229
"Duration not representable" warnings before `_pieces` existed.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from fractions import Fraction

from _fixtures import write_midi, write_scale_midi

from adapter_anticipation.abc_out import (UNIT, _clean, _length, _pieces,
                                           midi_to_abc)


def body_of(abc: str) -> str:
    """Everything after the `K:` line, joined — the music, whatever the
    header's length. Indexing a fixed line number was how these tests
    silently read an empty body for years."""
    lines = abc.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("K:"):
            return " ".join(lines[index + 1:])
    return ""


def key_line_of(abc: str) -> str:
    """The `K:` line, wherever the optional `T:` and `N:` lines put it."""
    return next((line for line in abc.splitlines() if line.startswith("K:")),
                "")


class LengthTest(unittest.TestCase):
    """A note value as a multiple of L: — "" is the common case, not a bug."""

    def test_one_unit_is_written_as_nothing(self) -> None:
        self.assertEqual(_length(Fraction(1)), "")

    def test_a_whole_multiple_is_a_bare_number(self) -> None:
        self.assertEqual(_length(Fraction(2)), "2")

    def test_a_fraction_of_the_unit_keeps_its_denominator(self) -> None:
        self.assertEqual(_length(Fraction(1, 4)), "/4")

    def test_a_dotted_value_is_a_ratio(self) -> None:
        self.assertEqual(_length(Fraction(3, 2)), "3/2")


class PiecesTest(unittest.TestCase):
    """A duration in quarter-lengths, as the note values that add up to it
    in units of L:. One piece is the common case; more means ties."""

    def test_one_unit_is_one_piece(self) -> None:
        self.assertEqual(_pieces(UNIT), [Fraction(1)])

    def test_a_dotted_value_is_one_piece(self) -> None:
        # A dotted quarter: three eighths.
        self.assertEqual(_pieces(Fraction(3, 2)), [Fraction(3)])

    def test_five_eighths_is_a_half_note_tied_to_an_eighth(self) -> None:
        # `E,,,5` used to be written as one note; no note is five eighths.
        self.assertEqual(_pieces(Fraction(5, 2)), [Fraction(4), Fraction(1)])

    def test_five_sixteenths_is_a_quarter_tied_to_a_sixteenth(self) -> None:
        self.assertEqual(_pieces(Fraction(5, 4)), [Fraction(2), Fraction(1, 2)])

    def test_seven_eighths_prefers_a_dotted_half_over_a_double_dot(self) -> None:
        self.assertEqual(_pieces(Fraction(7, 2)), [Fraction(6), Fraction(1)])

    def test_a_triplet_length_snaps_to_the_nearest_single_value(self) -> None:
        # A triplet quarter (4/3 units) has no bracket to live in here, so it
        # becomes a dotted eighth rather than a chain of ties chasing 4/3.
        self.assertEqual(_pieces(Fraction(2, 3)), [Fraction(3, 2)])

    def test_nothing_is_written_below_a_32nd(self) -> None:
        self.assertEqual(_pieces(Fraction(1, 16)), [Fraction(1, 4)])

    def test_zero_and_unreadable_lengths_are_skipped(self) -> None:
        self.assertEqual(_pieces(0), [])
        self.assertEqual(_pieces(None), [])


class MidiToAbcTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.midi = write_scale_midi(os.path.join(self.tmp.name, "tune.mid"))

    def test_a_tiny_tune_round_trips_to_a_full_abc_header(self) -> None:
        lines = midi_to_abc(self.midi, "Tiny Tune").splitlines()
        self.assertEqual(lines[0], "X:1")
        self.assertEqual(lines[1], "T:Tiny Tune")
        self.assertEqual(lines[2], "M:4/4")
        self.assertEqual(lines[3], "L:1/8")
        self.assertTrue(lines[4].startswith("K:"))

    def test_the_body_is_barred(self) -> None:
        self.assertIn("|", body_of(midi_to_abc(self.midi)))

    def test_the_notes_survive_in_order(self) -> None:
        body = body_of(midi_to_abc(self.midi))
        self.assertIn("C2 D2 E2 F2", body)

    def test_a_melody_around_middle_c_keeps_the_treble_clef(self) -> None:
        key_line = key_line_of(midi_to_abc(self.midi))
        self.assertNotIn("clef", key_line)

    def test_a_bass_line_takes_the_bass_clef(self) -> None:
        # A transcribed bass on a treble clef was a thicket of ledger lines.
        low = write_scale_midi(os.path.join(self.tmp.name, "bass.mid"),
                               pitches=(36, 38, 40, 41, 43, 45, 47, 48))
        key_line = key_line_of(midi_to_abc(low))
        self.assertTrue(key_line.endswith(" clef=bass"), key_line)

    def test_a_length_no_note_can_carry_is_written_as_tied_notes(self) -> None:
        # Five sixteenths: a quarter tied to a sixteenth, never `C5/2`.
        path = write_midi(os.path.join(self.tmp.name, "five.mid"),
                          [(60, 0, 1.25)])
        body = body_of(midi_to_abc(path))
        self.assertIn("C2-C/2", body)
        self.assertNotIn("5/2", body)

    def test_a_note_across_the_barline_is_split_and_tied(self) -> None:
        # Three quarters, then a half note that starts on beat four.
        path = write_midi(os.path.join(self.tmp.name, "across.mid"),
                          [(60, 0, 1), (62, 1, 1), (64, 2, 1), (67, 3, 2)])
        body = body_of(midi_to_abc(path))
        self.assertIn("G2- | G2", body)

    def test_a_file_with_no_notes_yields_nothing(self) -> None:
        """An empty sketch is one missing artifact, never a failed job."""
        empty = write_scale_midi(os.path.join(self.tmp.name, "empty.mid"),
                                 pitches=())
        self.assertEqual(midi_to_abc(empty), "")

    def test_an_unreadable_file_never_raises(self) -> None:
        junk = os.path.join(self.tmp.name, "junk.mid")
        with open(junk, "wb") as f:
            f.write(b"not a midi file")
        self.assertEqual(midi_to_abc(junk), "")

    def test_a_multiline_title_is_flattened(self) -> None:
        self.assertEqual(_clean("two\nlines  here"), "two lines here")


if __name__ == "__main__":
    unittest.main()

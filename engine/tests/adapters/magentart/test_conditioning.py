"""Magenta RT 2: the note/drum conditioning mask and the guidance scales.

Covers audit 09-B1 / M43 (a melody MIDI used to zero-fill both channels, which
silenced the drums for the whole render and every frame past the melody) and
09-B4 (`_scale`: `0.0 or 3.0` is 3.0, so "ignore the notes" rendered at hard
note-following).
"""

from __future__ import annotations

import os
import tempfile
import unittest

from _fixtures import FakeMRT, install_fake_runtime, noop_progress, write_midi

install_fake_runtime()

from adapter_magentart.adapter import (DRUM_MASKED, MagentaRTAdapter,  # noqa: E402
                                       PITCH_HELD, PITCH_MASKED, PITCH_OFF,
                                       PITCH_ONSET, _roll_from_midi)
from engine_protocol.adapter import CancelToken  # noqa: E402


class RollFromMidiTest(unittest.TestCase):
    """09-B1/M43 — what a MIDI says, and what it deliberately does not say."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _midi(self, notes, drums=()) -> str:
        return write_midi(os.path.join(self.tmp.name, "in.mid"), notes, drums)

    def test_pitched_midi_leaves_the_drum_channel_masked(self) -> None:
        """09-B1: a piano-only MIDI must not say "no drum" for the take."""
        roll, drums = _roll_from_midi(self._midi([(60, 0.0, 1.0)]), 300)
        self.assertIsNotNone(roll)
        self.assertIsNone(drums)

    def test_melody_shorter_than_the_take_masks_the_tail(self) -> None:
        """M43: past the last note nothing was said — not "every pitch off"."""
        roll, _drums = _roll_from_midi(self._midi([(60, 0.0, 1.0)]), 300)
        self.assertTrue((roll[200] == PITCH_MASKED).all())

    def test_onset_then_hold_inside_the_melody_span(self) -> None:
        """09-B1: the model's own vocabulary — 2 onset, 1 held, 0 off."""
        roll, _drums = _roll_from_midi(self._midi([(60, 0.0, 1.0)]), 300)
        self.assertEqual(roll[0][60], PITCH_ONSET)
        self.assertEqual(roll[10][60], PITCH_HELD)
        self.assertEqual(roll[10][61], PITCH_OFF)

    def test_drum_only_midi_leaves_the_pianoroll_masked(self) -> None:
        """09-B1, the other way round: percussion says nothing about pitch."""
        roll, drums = _roll_from_midi(self._midi([], drums=[(0.0, 0.5)]), 300)
        self.assertIsNone(roll)
        self.assertIsNotNone(drums)
        self.assertEqual(int(drums[200]), DRUM_MASKED)


class ConditioningWindowTest(unittest.TestCase):
    """The chunk loop, run for real against a fake streaming model."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = MagentaRTAdapter("magentart-test", {}, self.tmp.name, {})
        self.mrt = FakeMRT()
        self.adapter.mrt = self.mrt

    def _render(self, params: dict) -> None:
        out = os.path.join(self.tmp.name, "take.wav")
        self.adapter.generate("a prompt", None, params, out, noop_progress,
                              CancelToken())

    def test_window_past_the_melody_is_masked_not_silenced(self) -> None:
        """M43: the last chunk of a 2 s take over a 0.4 s melody."""
        midi = write_midi(os.path.join(self.tmp.name, "m.mid"),
                          [(60, 0.0, 0.4)])
        self._render({"duration_s": 2.0, "melody_midi": midi, "seed": 7})
        last = self.mrt.calls[-1]["conditioning"]["pianoroll_with_onsets"]
        self.assertEqual(last, [PITCH_MASKED] * 128)

    def test_a_piano_midi_never_sends_the_drum_channel(self) -> None:
        """09-B1: on `drums: auto` a MIDI without percussion leaves it alone."""
        midi = write_midi(os.path.join(self.tmp.name, "m.mid"),
                          [(60, 0.0, 0.4)])
        self._render({"duration_s": 1.0, "melody_midi": midi, "seed": 7})
        for call in self.mrt.calls:
            self.assertNotIn("drum_pianoroll", call["conditioning"])

    def test_zero_notes_guidance_survives(self) -> None:
        """09-B4: `_scale` keeps a legal 0.0 instead of reading it as unset."""
        self._render({"duration_s": 1.0, "notes_guidance": 0.0,
                      "drums_guidance": 0.0, "seed": 7})
        self.assertEqual(self.mrt.calls[0]["cfg_scales"]["notes"], 0.0)
        self.assertEqual(self.mrt.calls[0]["cfg_scales"]["drums"], 0.0)

    def test_absent_guidance_still_defaults(self) -> None:
        """09-B4's other half: None (not 0.0) is what "unset" means."""
        self._render({"duration_s": 1.0, "seed": 7})
        self.assertEqual(self.mrt.calls[0]["cfg_scales"]["notes"], 3.0)


if __name__ == "__main__":
    unittest.main()

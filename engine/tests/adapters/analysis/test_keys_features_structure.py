"""Analysis: key estimation, the compact features, and structure segmentation.

All three ride the analyze payload the app draws from, and all three are pure
array code — so they can be driven with synthetic input and no model.
"""

from __future__ import annotations

import unittest

import numpy as np

from adapter_analysis import features, keys, structure

SR = 22050


def _tone_bed(seconds: float = 6.0) -> np.ndarray:
    """A deterministic, harmonically busy signal — not silence, not noise."""
    t = np.arange(int(seconds * SR), dtype=np.float32) / SR
    signal = np.zeros_like(t)
    for index, freq in enumerate((110.0, 220.0, 330.0, 440.0)):
        signal += (0.2 / (index + 1)) * np.sin(2 * np.pi * freq * t)
    # a pulse every half second, so there is something for beats to sit on
    signal[::SR // 2] += 0.5
    return signal.astype(np.float32)


class EstimateKeyTest(unittest.TestCase):
    def test_a_pure_c_major_chroma_reads_as_c_major(self) -> None:
        chroma = keys.MAJOR.reshape(12, 1)
        result = keys.estimate_key(np.zeros(1, dtype=np.float32), SR,
                                   chroma_matrix=chroma)
        self.assertEqual(result["key"], "C major")
        self.assertEqual(result["tonic"], "C")
        self.assertEqual(result["camelot"], "8B")

    def test_a_transposed_profile_follows_the_tonic(self) -> None:
        chroma = np.roll(keys.MINOR, 9).reshape(12, 1)   # A minor
        result = keys.estimate_key(np.zeros(1, dtype=np.float32), SR,
                                   chroma_matrix=chroma)
        self.assertEqual(result["key"], "A minor")
        self.assertEqual(result["camelot"], "8A")

    def test_an_empty_chroma_declines_to_guess(self) -> None:
        result = keys.estimate_key(np.zeros(1, dtype=np.float32), SR,
                                   chroma_matrix=np.zeros((12, 4)))
        self.assertIsNone(result["key"])
        self.assertEqual(result["confidence"], 0.0)


class FeaturesTest(unittest.TestCase):
    def test_beat_chroma_quantises_one_vector_per_beat(self) -> None:
        chroma = np.abs(np.random.default_rng(0).standard_normal((12, 400)))
        beats = [i * 0.5 for i in range(8)]
        out = features.beat_chroma(chroma, beats, SR, hop_length=512)
        self.assertEqual(len(out), len(beats))
        self.assertTrue(all(len(v) == 12 for v in out))
        self.assertTrue(all(0 <= x <= 255 for v in out for x in v))

    def test_beat_chroma_needs_two_beats(self) -> None:
        self.assertEqual(features.beat_chroma(np.ones((12, 10)), [0.0], SR), [])

    def test_band_energy_is_a_normalised_octave_profile(self) -> None:
        bands = features.band_energy(_tone_bed(1.0), SR)
        self.assertEqual(len(bands), features.BAND_COUNT)
        self.assertAlmostEqual(sum(bands), 1.0, places=3)


class StructureTest(unittest.TestCase):
    DURATION = 4.0
    BEATS = [round(i * 0.25, 3) for i in range(16)]

    @classmethod
    def setUpClass(cls) -> None:
        # One segmentation for the whole class: it is the expensive call in
        # this file (chroma + MFCC + an eigendecomposition) and every test
        # below asks a different question of the same answer.
        cls.sections = structure.segments(_tone_bed(cls.DURATION), SR,
                                          cls.BEATS, cls.DURATION)

    def test_too_few_beats_is_one_section(self) -> None:
        """Nothing to segment is answered honestly, not with invented form."""
        out = structure.segments(_tone_bed(2.0), SR, [0.0, 1.0], 2.0)
        self.assertEqual(out, [{"start_s": 0.0, "end_s": 2.0, "group": "A"}])

    def test_segmentation_terminates_and_covers_the_take(self) -> None:
        self.assertTrue(self.sections)
        self.assertEqual(self.sections[0]["start_s"], 0.0)
        self.assertEqual(self.sections[-1]["end_s"], round(self.DURATION, 3))

    def test_segments_are_ordered_and_do_not_overlap(self) -> None:
        for earlier, later in zip(self.sections, self.sections[1:]):
            self.assertLessEqual(earlier["end_s"], later["start_s"])
        for section in self.sections:
            self.assertLess(section["start_s"], section["end_s"])

    def test_every_section_carries_a_group_letter(self) -> None:
        """Unlabeled repetition groups (A/B/A form) are the contract."""
        for section in self.sections:
            self.assertRegex(section["group"], r"^[A-Z]$")


if __name__ == "__main__":
    unittest.main()

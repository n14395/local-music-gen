"""The MIDI render's gain knob (the transcription twin of render_midi).

Audit §3 — normalize-then-hard-clip made any positive gain pure distortion,
and the first fix (a hard cap at full scale) moved +12 dB by 0.9 dB and
nothing else: the whole upper half of the slider did nothing.
"""

from __future__ import annotations

import unittest

import numpy as np

from adapter_transcription.render_midi import (CEILING, CEILING_MAX, PEAK_TARGET,
                                           apply_gain)


def _rms(audio: np.ndarray) -> float:
    return float(np.sqrt((audio.astype(np.float64) ** 2).mean()))


def _render(peak: float = 0.3) -> np.ndarray:
    t = np.linspace(0.0, 1.0, 4096, dtype=np.float32)
    tone = peak * np.sin(2 * np.pi * 8.0 * t)
    return np.stack([tone, tone], axis=1)


class GainKneeTest(unittest.TestCase):
    def test_unity_gain_peak_normalises(self) -> None:
        out = apply_gain(_render(), 0.0)
        self.assertAlmostEqual(float(np.abs(out).max()), PEAK_TARGET, places=4)

    def test_negative_gain_stays_exactly_linear(self) -> None:
        out = apply_gain(_render(), -6.0)
        self.assertAlmostEqual(float(np.abs(out).max()),
                               PEAK_TARGET * 10.0 ** (-6.0 / 20.0), places=4)

    def test_a_hot_gain_saturates_instead_of_clipping(self) -> None:
        """Never a hard-clipped edge, and never past the asymptote."""
        out = apply_gain(_render(), 12.0)
        hot = float(np.abs(out).max())
        self.assertGreater(hot, CEILING)
        self.assertLessEqual(hot, CEILING_MAX + 1e-6)

    def test_the_upper_half_of_the_slider_still_does_something(self) -> None:
        """The regression the first fix introduced: a dead knob.

        The peak is pinned at the asymptote either way, so the audible
        difference lives in the body of the signal — which is exactly what a
        hard cap on the combined scale threw away.
        """
        six = _rms(apply_gain(_render(), 6.0))
        twelve = _rms(apply_gain(_render(), 12.0))
        self.assertGreater(twelve, six)

    def test_silence_is_left_alone(self) -> None:
        out = apply_gain(np.zeros((1024, 2), dtype=np.float32), 12.0)
        self.assertEqual(float(np.abs(out).max()), 0.0)


if __name__ == "__main__":
    unittest.main()

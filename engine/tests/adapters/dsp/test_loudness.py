"""The mixdown's reported loudness is measured, not restated.

11-B13 — `meta["lufs"]` used to echo `target_lufs`, which the -1 dBTP limiter
then pulled the mix below, and it kept claiming the target even when
`_normalize_loudness` gave up silently on input shorter than the gating block.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
import warnings

import numpy as np
import soundfile as sf

from adapter_dsp.adapter import (DEFAULT_LUFS, DSPAdapter, _measure_loudness,
                                 _normalize_loudness)
from engine_protocol.adapter import CancelToken

SR = 44100


def _noop(fraction, message, **kwargs) -> None:
    pass


def _noise(seconds: float, amplitude: float = 0.05) -> np.ndarray:
    rng = np.random.default_rng(0)
    return (rng.standard_normal((int(seconds * SR), 2))
            * amplitude).astype(np.float32)


class MeasureLoudnessTest(unittest.TestCase):
    """11-B13 — the two ways the measurement refuses."""

    def test_a_buffer_shorter_than_the_gating_block_is_unmeasurable(self) -> None:
        self.assertIsNone(_measure_loudness(_noise(0.1), SR))

    def test_silence_is_unmeasurable(self) -> None:
        self.assertIsNone(
            _measure_loudness(np.zeros((SR * 2, 2), dtype=np.float32), SR))

    def test_a_normalised_mix_measures_where_it_was_put(self) -> None:
        measured = _measure_loudness(_normalize_loudness(_noise(3.0), SR,
                                                         -20.0), SR)
        self.assertIsNotNone(measured)
        self.assertAlmostEqual(measured, -20.0, places=1)


class MixMetaTest(unittest.TestCase):
    """11-B13 — what the mix task reports about the file it wrote."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, "track.wav")
        sf.write(self.src, _noise(3.0), SR, format="WAV", subtype="PCM_16")
        self.adapter = DSPAdapter("dsp-test", {}, self.tmp.name, {})

    def _mix(self, **params):
        spec = {"target": {"sample_rate": SR},
                "tracks": [{"role": "a", "source": self.src}]}
        with warnings.catch_warnings():
            # pyloudnorm warns about clipped samples; the limiter is what the
            # mix task has for that, and the warning is not the behaviour here.
            warnings.simplefilter("ignore")
            return self.adapter.run_task(
                "mix", {"mix_spec": json.dumps(spec), **params},
                self.tmp.name, _noop, CancelToken())

    def test_a_limited_mix_reports_the_level_it_actually_has(self) -> None:
        """The -1 dBTP limiter pulls a hot target down; the meta must follow."""
        result = self._mix(target_lufs=-2.0, normalize=True, limiter=True)
        self.assertIsNotNone(result.meta["lufs"])
        self.assertLess(result.meta["lufs"], -2.5)

    def test_the_reported_level_is_the_written_files_level(self) -> None:
        result = self._mix(target_lufs=-2.0, normalize=True, limiter=True)
        audio, rate = sf.read(result.artifacts[0].path, dtype="float32",
                              always_2d=True)
        self.assertAlmostEqual(result.meta["lufs"],
                               _measure_loudness(audio, rate), places=1)

    def test_no_loudness_key_when_the_job_did_not_normalise(self) -> None:
        result = self._mix(normalize=False, limiter=False)
        self.assertNotIn("lufs", result.meta)

    def test_the_default_target_is_not_what_gets_reported(self) -> None:
        """11-B13's shape: the number must not be the request."""
        result = self._mix(target_lufs=-2.0, normalize=True, limiter=True)
        self.assertNotEqual(result.meta["lufs"], -2.0)
        self.assertNotEqual(result.meta["lufs"], DEFAULT_LUFS)


if __name__ == "__main__":
    unittest.main()

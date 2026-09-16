"""seed-vc v2: which of the two conversion paths a job actually takes.

`convert_timbre` never runs the autoregressive stage — the CFM re-voices the
source while its timing and delivery are left exactly as they were, which is
the right tool for a sung line. Measured 2026-09-04: the *other* path only
reaches the AR when `convert_style` or `anonymization_only` is set, so with
both off the two modes are the same computation and return byte-identical
audio. The mode is a real choice only next to those two flags — and when it
is chosen alongside them, the adapter has to say that they are being ignored
rather than drop them silently.

Nothing is converted: `subprocess.Popen` is replaced and the wav the
conversion would have written is written by the test.
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from unittest import mock

from adapter_seedvc import adapter as seedvc
from adapter_seedvc.adapter import SeedVCAdapter
from engine_protocol.adapter import CancelToken


class FakeProc:
    def __init__(self, returncode: int = 0) -> None:
        self.stderr = io.StringIO("")
        self.returncode = returncode

    def poll(self):
        return self.returncode

    def wait(self):
        return self.returncode

    def kill(self):
        pass


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


class ConvertTests(unittest.TestCase):
    version = 2

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(self.out_dir)
        self.src = os.path.join(self.tmp.name, "source.wav")
        self.ref = os.path.join(self.tmp.name, "voice.wav")
        import soundfile as sf
        for path in (self.src, self.ref):
            sf.write(path, [0.0] * 800, 16000, format="WAV",
                     subtype="PCM_16")

        self.bootstraps: list[str] = []

        def popen(cmd, **kwargs):
            self.bootstraps.append(cmd[2])
            # The conversion writes its wav before the process exits.
            sf.write(os.path.join(self.out_dir, "converted_v2.wav"),
                     [0.0] * 800, 16000, format="WAV", subtype="PCM_16")
            return FakeProc()

        patch = mock.patch.object(seedvc.subprocess, "Popen", popen)
        patch.start()
        self.addCleanup(patch.stop)
        self.adapter = SeedVCAdapter("seedvc-v2", {}, self.tmp.name,
                                     {"version": self.version})
        self.adapter.repo = self.tmp.name

    def convert(self, **params) -> str:
        """Run one conversion; returns anything it printed to stderr."""
        merged = {"source_audio": self.src, "reference_audio": self.ref,
                  **params}
        noise = io.StringIO()
        with contextlib.redirect_stderr(noise):
            self.adapter.run_task("convert-voice", merged, self.out_dir,
                                  progress, CancelToken())
        return noise.getvalue()

    @property
    def bootstrap(self) -> str:
        return self.bootstraps[-1]

    def test_voice_only_takes_the_timbre_path(self):
        self.convert(mode="timbre")
        self.assertIn("vc.convert_timbre(", self.bootstrap)
        self.assertNotIn("convert_voice_with_streaming", self.bootstrap)

    def test_the_default_mode_takes_the_streaming_path(self):
        self.convert()
        self.assertIn("vc.convert_voice_with_streaming(", self.bootstrap)
        self.assertNotIn("vc.convert_timbre(", self.bootstrap)

    def test_copy_style_alongside_voice_only_is_said_out_loud(self):
        """The flags belong to the stage this mode exists to skip; say so
        rather than drop them."""
        said = self.convert(mode="timbre", convert_style=True)
        self.assertIn("Voice only", said)
        self.assertIn("ignored", said)
        self.assertIn("vc.convert_timbre(", self.bootstrap)

    def test_anonymize_alongside_voice_only_is_said_out_loud(self):
        said = self.convert(mode="timbre", anonymize=True)
        self.assertIn("ignored", said)

    def test_voice_only_on_its_own_says_nothing(self):
        """With both flags off the two modes are the same computation —
        there is nothing being ignored, so nothing to warn about."""
        self.assertEqual(self.convert(mode="timbre"), "")

    def test_the_flags_reach_the_streaming_path_when_the_mode_allows(self):
        self.convert(convert_style=True, anonymize=True)
        self.assertIn("convert_style=True", self.bootstrap)
        self.assertIn("anonymization_only=True", self.bootstrap)

    def test_the_cfm_shim_only_rides_the_timbre_path(self):
        """Upstream's convert_timbre does not run at this pin; the shim is
        adapted at the call boundary rather than in their tree."""
        self.convert(mode="timbre")
        self.assertIn("_cfm_shim", self.bootstrap)
        self.convert()
        self.assertNotIn("_cfm_shim", self.bootstrap)

    def test_the_shim_refuses_a_sampling_flag_rather_than_dropping_it(self):
        self.convert(mode="timbre")
        self.assertIn("has no sway/amo sampling", self.bootstrap)

    def test_a_guidance_rate_of_zero_survives(self):
        """0.0 is the legal "guidance off" end of both sliders; `or`
        silently rewrote it to 0.7 (audit §2)."""
        self.convert(similarity_cfg_rate=0.0, intelligibility_cfg_rate=0.0)
        self.assertIn("intelligebility_cfg_rate=0.0", self.bootstrap)
        self.assertIn("similarity_cfg_rate=0.0", self.bootstrap)

    def test_an_absent_guidance_rate_takes_the_default(self):
        self.convert()
        self.assertIn("similarity_cfg_rate=0.7", self.bootstrap)

    def test_the_seed_is_set_inside_the_process_that_samples(self):
        """Neither route took a seed, so every conversion was a fresh draw
        and no two runs of the same settings matched."""
        self.convert(seed=99)
        self.assertIn("torch.manual_seed(99)", self.bootstrap)

    def test_the_step_count_is_clamped(self):
        self.convert(diffusion_steps=999)
        self.assertIn("diffusion_steps=100", self.bootstrap)
        self.convert(diffusion_steps=1)
        self.assertIn("diffusion_steps=4", self.bootstrap)


class V1ConvertTests(unittest.TestCase):
    """The v1 route has no mode at all — it is a CLI behind a bootstrap."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(self.out_dir)
        self.src = os.path.join(self.tmp.name, "source.wav")
        self.ref = os.path.join(self.tmp.name, "voice.wav")
        import soundfile as sf
        for path in (self.src, self.ref):
            sf.write(path, [0.0] * 800, 16000, format="WAV",
                     subtype="PCM_16")

        self.bootstraps: list[str] = []

        def popen(cmd, **kwargs):
            self.bootstraps.append(cmd[2])
            sf.write(os.path.join(self.out_dir, "out.wav"), [0.0] * 800,
                     16000, format="WAV", subtype="PCM_16")
            return FakeProc()

        patch = mock.patch.object(seedvc.subprocess, "Popen", popen)
        patch.start()
        self.addCleanup(patch.stop)
        self.adapter = SeedVCAdapter("seedvc-v1", {}, self.tmp.name,
                                     {"version": 1})
        self.adapter.repo = self.tmp.name

    def convert(self, **params) -> None:
        merged = {"source_audio": self.src, "reference_audio": self.ref,
                  **params}
        with contextlib.redirect_stderr(io.StringIO()):
            self.adapter.run_task("convert-voice", merged, self.out_dir,
                                  progress, CancelToken())

    @property
    def bootstrap(self) -> str:
        return self.bootstraps[-1]

    def test_a_cfg_rate_of_zero_survives(self):
        """0.0 is the legal "guidance off" end of the slider; `or` rewrote
        it to 0.7 (audit §2)."""
        self.convert(cfg_rate=0.0)
        self.assertIn("'--inference-cfg-rate', '0.0'", self.bootstrap)

    def test_an_absent_cfg_rate_takes_the_default(self):
        self.convert()
        self.assertIn("'--inference-cfg-rate', '0.7'", self.bootstrap)

    def test_sing_mode_drives_the_f0_flags(self):
        self.convert(sing_mode=True)
        self.assertIn("'--f0-condition', 'True'", self.bootstrap)
        self.assertIn("'--auto-f0-adjust', 'True'", self.bootstrap)

    def test_a_pitch_shift_turns_the_auto_adjust_off(self):
        self.convert(sing_mode=True, pitch_shift_st=3)
        self.assertIn("'--auto-f0-adjust', 'False'", self.bootstrap)
        self.assertIn("'--semi-tone-shift', '3'", self.bootstrap)

    def test_the_seed_is_set_inside_the_process_that_samples(self):
        self.convert(seed=99)
        self.assertIn("torch.manual_seed(99)", self.bootstrap)

    def test_mps_is_hidden_before_their_model_code_loads(self):
        """A -c bootstrap rather than the CLI directly: only code inside the
        process can hide MPS before the torch-2.4 autocast crash."""
        self.convert()
        self.assertIn("torch.backends.mps.is_available = (lambda: False)",
                      self.bootstrap)


class GuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = SeedVCAdapter("seedvc-v2", {}, self.tmp.name,
                                     {"version": 2})
        self.adapter.repo = self.tmp.name

    def test_a_missing_source_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.adapter.run_task("convert-voice", {}, self.tmp.name,
                                  progress, CancelToken())
        self.assertIn("source_audio", str(caught.exception))

    def test_a_missing_reference_asks_for_a_recording(self):
        src = os.path.join(self.tmp.name, "s.wav")
        with open(src, "wb") as f:
            f.write(b"\0")
        with self.assertRaises(RuntimeError) as caught:
            self.adapter.run_task("convert-voice", {"source_audio": src},
                                  self.tmp.name, progress, CancelToken())
        self.assertIn("reference_audio", str(caught.exception))

    def test_an_unsupported_task_falls_through_to_the_base_class(self):
        with self.assertRaises(NotImplementedError):
            self.adapter.run_task("separate", {}, self.tmp.name, progress,
                                  CancelToken())


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

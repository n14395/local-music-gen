"""YingMusic's run config: nothing is substituted into the bootstrap.

Covers 10-B8. The run arguments carry three user-supplied strings (the
lyrics, the reference text and what the reference says), and `MODEL_PY` used
to be replaced *after* the argv list had been spliced in — so lyrics
containing the literal "MODEL_PY" rewrote the argv literal and the
subprocess died with a NameError, reported to the user as "YingMusic
failed: …". The template is now a constant and everything else travels as
JSON.

Nothing is spawned and nothing is fetched: `subprocess.Popen` is replaced
and the singer's output wav is written by the test.
"""

import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

from adapter_yingmusic import adapter as ym
from adapter_yingmusic.adapter import BOOTSTRAP, YingMusicAdapter
from engine_protocol.adapter import CancelToken

# The three strings that used to be spliced into source code.
POISON = {"lyrics_text": "MODEL_PY", "reference_text": "ARGV",
          "melody_hint": "SRC_DIR"}


class FakeProc:
    def __init__(self, stderr: str = "") -> None:
        self.stderr = io.StringIO(stderr)
        self.returncode = 0
        self.kills = 0

    def poll(self):
        return self.returncode

    def wait(self):
        return self.returncode

    def kill(self):
        self.kills += 1


def progress(fraction, message, *, phase=None, step=None, steps=None):
    pass


class RunConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.out_dir = os.path.join(self.root, "out")
        os.makedirs(self.out_dir)
        self.work = os.path.join(self.root, "work")
        # A checkout with the two files load() staged.
        self.repo = os.path.join(self.root, "YingMusic-Singer")
        os.makedirs(os.path.join(self.repo, "src", "singer", "decoder"))
        for name in ("src/singer/model.py",
                     "src/singer/decoder/modules.py"):
            with open(os.path.join(self.repo, name), "w") as f:
                f.write("# upstream\n")
        # The user's own recordings.
        self.ref = os.path.join(self.root, "voice.wav")
        self.midi = os.path.join(self.root, "melody.mid")
        for path in (self.ref, self.midi):
            with open(path, "wb") as f:
                f.write(b"\0")

        self.launched: list[list[str]] = []

        def popen(cmd, **kwargs):
            self.launched.append(list(cmd))
            # The singer writes its take before it exits.
            self.write_take()
            return FakeProc()

        patch = mock.patch.object(ym.subprocess, "Popen", popen)
        patch.start()
        self.addCleanup(patch.stop)

        self.adapter = YingMusicAdapter("yingmusic-singer",
                                        {"GiantAILab/YingMusic": "/snap"},
                                        self.work, {})
        self.adapter.repo = self.repo

    def write_take(self) -> None:
        import soundfile as sf
        sf.write(os.path.join(self.out_dir, "sung.wav"),
                 [0.0] * 160, 16000, format="WAV", subtype="PCM_16")

    def sing(self, **params):
        merged = {"lyrics_text": "la", "reference_audio": self.ref,
                  "reference_text": "hello", "melody_midi": self.midi,
                  **params}
        return self.adapter.run_task("sing", merged, self.out_dir,
                                     progress, CancelToken())

    def config(self) -> dict:
        with open(os.path.join(self.work, "yingmusic-run.json")) as f:
            return json.load(f)

    def test_lyrics_naming_the_template_placeholders_round_trip_unchanged(self):
        """10-B8: MODEL_PY / ARGV / SRC_DIR are just text now."""
        self.sing(lyrics_text=POISON["lyrics_text"],
                  reference_text=POISON["reference_text"])
        argv = self.config()["argv"]
        self.assertEqual(argv[argv.index("--lyrics") + 1], "MODEL_PY")
        self.assertEqual(
            argv[argv.index("--timbre_audio_content") + 1], "ARGV")

    def test_a_lyric_sheet_full_of_placeholders_survives_intact(self):
        """10-B8: several at once, in one string, with the real newlines."""
        sheet = "MODEL_PY\nARGV\nSRC_DIR\nBOOTSTRAP"
        self.sing(lyrics_text=sheet)
        argv = self.config()["argv"]
        self.assertEqual(argv[argv.index("--lyrics") + 1], sheet)

    def test_the_bootstrap_is_byte_identical_to_the_constant(self):
        """10-B8: no substitution happens against the template at all."""
        self.sing(lyrics_text="MODEL_PY ARGV SRC_DIR")
        cmd = self.launched[0]
        self.assertEqual(cmd[1], "-c")
        self.assertEqual(cmd[2], BOOTSTRAP)

    def test_the_run_config_carries_the_paths_the_bootstrap_reads(self):
        """The template reads `src_dir`, `model_py` and `argv` from JSON."""
        self.sing()
        cfg = self.config()
        self.assertEqual(set(cfg), {"src_dir", "model_py", "argv"})
        self.assertEqual(cfg["src_dir"], os.path.join(self.repo, "src"))
        self.assertEqual(cfg["model_py"],
                         os.path.join(self.repo, "src", "singer", "model.py"))
        self.assertEqual(self.launched[0][3],
                         os.path.join(self.work, "yingmusic-run.json"))

    def test_a_drawn_seed_is_reported_back(self):
        """10-B8/B10: upstream pins DEFAULT_SEED=2025, so every 'random'
        retake of the same inputs was bit-identical."""
        result = self.sing()
        seed = result.meta["seed_used"]
        self.assertIsInstance(seed, int)
        argv = self.config()["argv"]
        self.assertEqual(argv[argv.index("--seed") + 1], str(seed))

    def test_an_explicit_seed_is_honoured(self):
        result = self.sing(seed=1234)
        self.assertEqual(result.meta["seed_used"], 1234)
        argv = self.config()["argv"]
        self.assertEqual(argv[argv.index("--seed") + 1], "1234")

    def test_the_nfe_step_count_is_clamped(self):
        for asked, want in ((0, 8), (1, 4), (999, 64), (16, 16)):
            with self.subTest(asked=asked):
                result = self.sing(nfe_steps=asked)
                self.assertEqual(result.meta["nfe_steps"], want)

    def test_a_melody_recording_is_used_when_there_is_no_midi(self):
        result = self.sing(melody_midi=None, source_audio=self.ref)
        argv = self.config()["argv"]
        self.assertIn("--melody_audio_path", argv)
        self.assertNotIn("--midi_file", argv)
        self.assertEqual(result.artifacts[0].label, "sung")


class GuardTests(unittest.TestCase):
    """Every missing input names what the user has to supply."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ref = os.path.join(self.tmp.name, "voice.wav")
        with open(self.ref, "wb") as f:
            f.write(b"\0")
        self.adapter = YingMusicAdapter("yingmusic-singer", {},
                                        self.tmp.name, {})
        self.adapter.repo = self.tmp.name

    def sing(self, params):
        return self.adapter.run_task("sing", params, self.tmp.name,
                                     progress, CancelToken())

    def test_missing_lyrics_are_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.sing({})
        self.assertIn("lyrics_text", str(caught.exception))

    def test_a_missing_reference_recording_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.sing({"lyrics_text": "la"})
        self.assertIn("reference_audio", str(caught.exception))

    def test_a_missing_reference_text_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.sing({"lyrics_text": "la", "reference_audio": self.ref})
        self.assertIn("reference_text", str(caught.exception))

    def test_a_missing_melody_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            self.sing({"lyrics_text": "la", "reference_audio": self.ref,
                       "reference_text": "hi"})
        self.assertIn("melody", str(caught.exception))

    def test_an_unsupported_task_falls_through_to_the_base_class(self):
        with self.assertRaises(NotImplementedError):
            self.adapter.run_task("separate", {}, self.tmp.name, progress,
                                  CancelToken())


class LangSegmentPatchTests(unittest.TestCase):
    def test_the_patch_defines_every_setter_the_package_imports(self):
        """LangSegment 0.2.0's __init__ imports four setters its module
        never defines; upstream is deleted, so the adapter supplies them."""
        for name in ("setLangfilters", "getLangfilters", "setfilters",
                     "getfilters"):
            self.assertIn(f"def {name}(", ym.LANGSEGMENT_PATCH)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

"""DiffRhythm2 (ASLP-lab): full-song lyrics→song via block-cache flow
matching — up to 3½ minutes of structured song from timestamped lyrics, with
the style set by a text prompt OR a reference clip.

Runs the pinned upstream CLI in a subprocess of this venv, with the two
mac-port shims applied by a bootstrap before their code loads:
  - fp16→fp32 coercion (their inference hard-codes torch.float16, which CPU
    rejects against fp32 weights; `.half()` must become `.float()`, not a
    no-op — integer tensors pass through it),
  - PHONEMIZER_ESPEAK_LIBRARY pointed at Homebrew's espeak-ng (phonemizer
    cannot find the dylib on its own).

Weights resolve via `--repo-id` through the HF cache the supervisor already
filled; the MuQ style encoder auto-fetches on the first run (route B).
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

REPO_ID = "ASLP-lab/DiffRhythm2"
REPO_COMMIT = "7804f821b797b4f276090e1a9dcd37e97d9915d5"
REPO_TARBALL = (f"https://github.com/ASLP-lab/DiffRhythm2/archive/"
                f"{REPO_COMMIT}.tar.gz")
ESPEAK_DYLIB = "/opt/homebrew/opt/espeak-ng/lib/libespeak-ng.dylib"

BOOTSTRAP = """
import os, sys, runpy, torch
def _fix(kind):
    orig = kind.to
    def to(self, *a, **kw):
        a = tuple(torch.float32 if x is torch.float16 else x for x in a)
        if kw.get("dtype") is torch.float16:
            kw["dtype"] = torch.float32
        return orig(self, *a, **kw)
    kind.to = to
    kind.half = lambda self, *aa, **kk: self.float()
for kind in (torch.Tensor, torch.nn.Module):
    _fix(kind)
sys.argv = ARGV
runpy.run_path("inference.py", run_name="__main__")
"""


class DiffRhythm2Adapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None

    def _cache_dir(self) -> str:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        d = os.path.join(base, "diffrhythm2")
        os.makedirs(d, exist_ok=True)
        return d

    def load(self, progress_cb: ProgressCb) -> None:
        if not os.path.exists(ESPEAK_DYLIB):
            raise RuntimeError(
                "espeak-ng is required for the lyrics front-end: "
                "`brew install espeak-ng` and try again")
        cache = self._cache_dir()
        repo = os.path.join(cache, f"DiffRhythm2-{REPO_COMMIT}")
        if not os.path.isdir(repo):
            progress_cb(None, "fetching DiffRhythm2 code (pinned snapshot, "
                              "first use only)")
            tar_path = os.path.join(cache, "repo.tar.gz")
            with urllib.request.urlopen(REPO_TARBALL, timeout=300) as resp, \
                    open(tar_path, "wb") as f:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            with tarfile.open(tar_path) as tar:
                tar.extractall(cache, filter="data")
            os.unlink(tar_path)
        self.repo = repo
        progress_cb(None, "DiffRhythm2 ready (the MuQ style encoder fetches "
                          "on the first render)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.repo is not None
        duration_s = min(210.0, float(params.get("duration_s") or 60.0))
        steps = max(4, min(32, int(params.get("steps") or 8)))
        cfg = float(params.get("guidance_scale") or 2.0)

        work = tempfile.mkdtemp(prefix="dr2-")
        lrc_path = os.path.join(work, "lyrics.lrc")
        with open(lrc_path, "w") as f:
            f.write(lyrics or "[00:00.00]la la la")
        style_path = params.get("style_audio")
        style = (style_path if style_path and os.path.isfile(style_path)
                 else (prompt or "Pop, catchy, clean production"))
        jsonl = os.path.join(work, "input.jsonl")
        with open(jsonl, "w") as f:
            json.dump({"song_name": "take", "style_prompt": style,
                       "lyrics": lrc_path}, f)
            f.write("\n")
        out_dir = os.path.join(work, "out")
        os.makedirs(out_dir, exist_ok=True)

        argv = ["inference.py", "--repo-id", REPO_ID,
                "--input-jsonl", jsonl, "--output-dir", out_dir,
                "--steps", str(steps), "--cfg-strength", str(cfg),
                "--max-secs", str(duration_s)]
        fake_stereo = params.get("fake_stereo")
        if fake_stereo is not None and not bool(fake_stereo):
            # Their argparse uses type=bool, where every non-empty string is
            # truthy — the empty string is the only spelling of False.
            argv += ["--fake-stereo", ""]
        env = {**os.environ, "PHONEMIZER_ESPEAK_LIBRARY": ESPEAK_DYLIB}
        code = BOOTSTRAP.replace("ARGV", repr(argv))

        progress_cb(None, "rendering (CPU flow matching — minutes, not "
                          "seconds; ~11 s of compute per second of song)")
        proc = subprocess.Popen([sys.executable, "-c", code], cwd=self.repo,
                                env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        tail: list[str] = []
        while proc.poll() is None:
            if cancel.cancelled:
                proc.kill()
                proc.wait()
                raise CancelledError()
            line = proc.stderr.readline() if proc.stderr else ""
            if line:
                tail.append(line.strip())
                tail = tail[-30:]
        if proc.returncode != 0:
            raise RuntimeError("DiffRhythm2 failed: " + " / ".join(tail[-4:]))

        produced = sorted(glob.glob(os.path.join(out_dir, "*.mp3"))
                          + glob.glob(os.path.join(out_dir, "*.wav")))
        if not produced:
            raise RuntimeError("DiffRhythm2 produced no audio")
        audio, sr = sf.read(produced[0], dtype="float32", always_2d=True)
        tmp = out_path + ".part"
        sf.write(tmp, audio, sr, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(audio.shape[0] / sr, 3),
            sample_rate=int(sr),
            seed_used=None)

    def unload(self) -> None:
        pass

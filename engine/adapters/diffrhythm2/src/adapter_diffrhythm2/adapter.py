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

Device: upstream's CLI picks CUDA-or-CPU and never considers MPS, so load()
retargets its one device line at LOCALMUSICGEN_DEVICE (idempotent text patch on
the pinned snapshot) and generate() sets that from settings.device. The MPS
route stays fp32 — the coercion shim applies on every device, which is the
proven-safe numerics; true fp16 there is known further work. The compute
path is MPS-clean (SDPA attention — their flex-attention flag is forced off
upstream — euler flow matching, pure-torch BigVGAN); the MuQ style encoder
is the one unvouched piece, so MPS runs set PYTORCH_ENABLE_MPS_FALLBACK=1.

Weights resolve via `--repo-id` through the HF cache the supervisor already
filled; the MuQ style encoder auto-fetches on the first run (route B).
"""

from __future__ import annotations

import glob
import json
import os
import secrets
import subprocess
import sys
import tempfile

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir)
from engine_protocol.progress import iter_progress_lines, parse_tqdm
from engine_protocol.staging import fetch_tarball_tree, staged

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
torch.manual_seed(SEED)
sys.argv = ARGV
runpy.run_path("inference.py", run_name="__main__")
"""


class DiffRhythm2Adapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None
        self.device = str(self.settings.get("device") or "cpu")

    def load(self, progress_cb: ProgressCb) -> None:
        if not os.path.exists(ESPEAK_DYLIB):
            raise RuntimeError(
                "espeak-ng is required for the lyrics front-end: "
                "`brew install espeak-ng` and try again")
        cache = aux_dir("diffrhythm2")
        repo = os.path.join(cache, f"DiffRhythm2-{REPO_COMMIT}")
        if not staged(repo, "inference.py", "diffrhythm2/__init__.py",
                      "g2p/g2p/vocab.json"):
            progress_cb(None, "fetching DiffRhythm2 code (pinned snapshot, "
                              "first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache,
                               f"DiffRhythm2-{REPO_COMMIT}")
        self._retarget_device(repo)
        self.repo = repo
        progress_cb(None, "DiffRhythm2 ready (the MuQ style encoder fetches "
                          "on the first render)")

    @staticmethod
    def _retarget_device(repo: str) -> None:
        """Point the CLI's cuda-else-cpu device line at LOCALMUSICGEN_DEVICE.
        A text patch on the pinned snapshot, not a torch monkeypatch:
        transformers isinstance-checks torch.device, so wrapping the class
        breaks it. Idempotent; unset env keeps upstream behavior exactly."""
        path = os.path.join(repo, "inference.py")
        with open(path) as f:
            src = f.read()
        if "LOCALMUSICGEN_DEVICE" in src:
            return
        old = ("device = torch.device('cuda' if torch.cuda.is_available() "
               "else 'cpu')")
        if old not in src:
            raise RuntimeError("the pinned inference.py no longer carries "
                              "the expected device line — refusing to guess")
        new = ("device = torch.device(os.environ.get('LOCALMUSICGEN_DEVICE') "
               "or ('cuda' if torch.cuda.is_available() else 'cpu'))")
        with open(path, "w") as f:
            f.write(src.replace(old, new, 1))

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
            # [inst] is the model's own instrumental tag; the old
            # "[00:00.00]la la la" fallback got the timestamp *sung*
            # (nothing parses LRC times here — audit §3).
            f.write(lyrics or "[inst]")
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

        # Their CLI has no --seed, and the render happens in a child process,
        # so the seed is set inside the bootstrap that starts it — the same
        # place the fp16 shims go. Reported back as `seed_used`, which was a
        # flat None before this.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)

        argv = ["inference.py", "--repo-id", REPO_ID,
                "--input-jsonl", jsonl, "--output-dir", out_dir,
                "--steps", str(steps), "--cfg-strength", str(cfg),
                "--max-secs", str(duration_s)]
        fake_stereo = params.get("fake_stereo")
        if fake_stereo is not None and not bool(fake_stereo):
            # Their argparse uses type=bool, where every non-empty string is
            # truthy — the empty string is the only spelling of False.
            argv += ["--fake-stereo", ""]
        env = {**os.environ, "PHONEMIZER_ESPEAK_LIBRARY": ESPEAK_DYLIB,
               "LOCALMUSICGEN_DEVICE": self.device}
        if self.device == "mps":
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        code = (BOOTSTRAP.replace("ARGV", repr(argv))
                         .replace("SEED", str(seed)))

        progress_cb(None, "rendering (GPU flow matching — MPS, fp32)"
                          if self.device == "mps" else
                          "rendering (CPU flow matching — minutes, not "
                          "seconds; ~11 s of compute per second of song)")
        proc = subprocess.Popen([sys.executable, "-c", code], cwd=self.repo,
                                env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        tail: list[str] = []
        assert proc.stderr is not None
        # The upstream tqdm bar was already on this stderr — split on \r so
        # its in-place redraws surface as real per-step progress instead of
        # one message for the whole render (audit §5).
        for line in iter_progress_lines(proc.stderr):
            if cancel.cancelled:
                proc.kill()
                proc.wait()
                raise CancelledError()
            tail.append(line)
            tail = tail[-30:]
            got = parse_tqdm(line)
            if got:
                step, total = got
                progress_cb(min(0.98, step / total),
                            f"flow matching — step {step}/{total}",
                            step=step, steps=total)
        proc.wait()
        if cancel.cancelled:
            raise CancelledError()
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
            seed_used=seed)

    def unload(self) -> None:
        pass

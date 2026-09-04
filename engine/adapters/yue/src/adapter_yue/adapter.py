"""YuE (experimental): lyrics-to-song via the upstream repo's infer.py subprocess.

There is no Metal port of YuE; on Apple Silicon this runs on CPU/MPS-fallback and
takes HOURS per song. It ships for honesty — the catalog flags it "experimental" and
the UI warns loudly. The upstream repo is cloned at a pinned SHA on first load, into
the aux cache (`aux_dir("yue")`) like every other fetched research checkout; its
inference/ tree expects the xcodec_mini_infer checkout inside it, which we symlink
from the downloaded snapshot.
"""

from __future__ import annotations

import os
import random
import re
import shutil
import subprocess
import sys

from engine_protocol.progress import iter_progress_lines
from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb, aux_dir)

YUE_REPO = "https://github.com/multimodal-art-projection/YuE"
YUE_SHA = "9f1394bae1d8d218fea750c1413c2d9d731c7310"

STAGE1_REPO = "m-a-p/YuE-s1-7B-anneal-en-cot"
STAGE2_REPO = "m-a-p/YuE-s2-1B-general"
XCODEC_REPO = "m-a-p/xcodec_mini_infer"


class YuEAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo_dir = ""
        self.proc: subprocess.Popen | None = None

    def load(self, progress_cb: ProgressCb) -> None:
        # The aux cache, like every other fetched research checkout (seed-vc,
        # songbloom, diffrhythm2). This used to live in `vendor/` inside the
        # source tree, which cost twice: the clone carries its own `.git`, so
        # it was recorded in the app repo as an accidental gitlink and then
        # broke `git status` outright once the xcodec symlink below existed
        # (git refuses a submodule path that is a symlink); and `build.sh`
        # needed a special exclude to keep rsync from copying the whole clone —
        # and its absolute symlink — into the .app, where it broke signing.
        # Out here it is what it always was: downloaded data, in the directory
        # for downloaded data, relocatable with the rest of the library.
        base = aux_dir("yue")
        self.repo_dir = os.path.join(base, "YuE")
        if not os.path.exists(os.path.join(self.repo_dir, "inference")):
            progress_cb(None, "cloning YuE repository")
            os.makedirs(base, exist_ok=True)
            subprocess.run(["git", "clone", YUE_REPO, self.repo_dir],
                           check=True, capture_output=True, timeout=600)
            subprocess.run(["git", "checkout", YUE_SHA], cwd=self.repo_dir,
                           check=True, capture_output=True)

        xcodec_link = os.path.join(self.repo_dir, "inference", "xcodec_mini_infer")
        xcodec_snapshot = self.model_paths.get(XCODEC_REPO)
        if xcodec_snapshot:
            # The clone leaves an EMPTY directory here — xcodec_mini_infer is a
            # submodule and nothing initialises it — and an `exists` check reads
            # that placeholder as "already linked", so the symlink was never
            # made and `infer.py` died on `No module named 'models'` before the
            # first token. This entry could not have rendered once. (Found
            # 2026-09-03, the first time YuE was actually run.)
            if os.path.islink(xcodec_link):
                os.unlink(xcodec_link)
            elif os.path.isdir(xcodec_link) and not os.path.exists(
                    os.path.join(xcodec_link, "models")):
                try:
                    os.rmdir(xcodec_link)          # only ever the empty husk
                except OSError as e:
                    raise RuntimeError(
                        f"{xcodec_link} exists but carries no `models/` and "
                        f"could not be removed ({e}) — delete it and retry"
                    ) from None
            if not os.path.exists(xcodec_link):
                os.symlink(xcodec_snapshot, xcodec_link)
        self._teach_infer_sdpa()
        progress_cb(None, "YuE ready (expect hours per song on Apple Silicon)")

    def _teach_infer_sdpa(self) -> None:
        """Both model loads in infer.py hardcode `flash_attention_2`.

        There is no flash-attn wheel for macOS, so transformers raises
        ImportError at the first `from_pretrained` — before a single token.
        Together with the empty submodule directory above, this is why the YuE
        entry had never produced audio on this machine. `sdpa` is torch's own
        fused attention and the correct substitute here.

        Patched in the cloned checkout, idempotent, re-applied on every load
        (a re-clone would otherwise silently restore the blocker)."""
        path = os.path.join(self.repo_dir, "inference", "infer.py")
        if not os.path.exists(path):
            return
        with open(path) as f:
            src = f.read()
        if "LOCALMUSIC-SDPA" in src:
            return
        needle = 'attn_implementation="flash_attention_2"'
        if needle not in src:
            raise RuntimeError("YuE's infer.py no longer carries the expected "
                               "attention line — refusing to guess")
        src = src.replace(
            needle,
            'attn_implementation="sdpa"  # LOCALMUSIC-SDPA: no flash-attn on macOS')
        with open(path, "w") as f:
            f.write(src)

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        duration_s = float(params.get("duration_s", 60.0))
        run_dir = os.path.join(os.path.dirname(out_path), "yue-run")
        os.makedirs(run_dir, exist_ok=True)
        genre_txt = os.path.join(run_dir, "genre.txt")
        lyrics_txt = os.path.join(run_dir, "lyrics.txt")
        with open(genre_txt, "w") as f:
            f.write(prompt.strip() + "\n")
        with open(lyrics_txt, "w") as f:
            f.write((lyrics or "[verse]\nla la la\n").strip() + "\n")

        # ~30 s of song per segment, so the ceiling here has to reach the
        # catalog's max_s or the slider lies: at min(4, …) a 180 s request
        # rendered about 120 s and nothing said why. 6 segments covers the
        # advertised range.
        segments = max(1, min(6, int(duration_s // 30)))
        # infer.py defaults --seed to 42, so an unset seed made every
        # "random" take of the same inputs byte-identical (audit §2). Draw
        # one and report it.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else random.randrange(2**31)
        cmd = [sys.executable, "infer.py",
               "--stage1_model", self.model_paths.get(STAGE1_REPO, STAGE1_REPO),
               "--stage2_model", self.model_paths.get(STAGE2_REPO, STAGE2_REPO),
               "--genre_txt", genre_txt,
               "--lyrics_txt", lyrics_txt,
               "--run_n_segments", str(segments),
               "--stage2_batch_size", "2",
               "--output_dir", run_dir,
               "--seed", str(seed),
               "--max_new_tokens", "3000"]

        # In-context learning: a reference recording the model listens to
        # before it writes. This is YuE's own style-transfer route — the same
        # shape as SongBloom's style_audio — and it is what its paper means by
        # ICL: the excerpt is tokenised into the same codebook the model
        # generates in, so the reference is *prior context*, not a separate
        # conditioning channel.
        #
        # The window matters and is not cosmetic: upstream's own guidance is a
        # 30-second excerpt, and the excerpt should be a musically
        # representative passage — a chorus, not an intro that has not started
        # yet.
        prompt_audio = params.get("style_audio")
        if prompt_audio and os.path.isfile(prompt_audio):
            start = max(0.0, float(params.get("prompt_start_s") or 0.0))
            end = float(params.get("prompt_end_s") or (start + 30.0))
            if end <= start:
                raise RuntimeError(
                    "the reference window ends before it starts — set the "
                    "end later than the start")
            cmd += ["--use_audio_prompt",
                    "--audio_prompt_path", prompt_audio,
                    "--prompt_start_time", f"{start:g}",
                    "--prompt_end_time", f"{end:g}"]
        # mps_flush/sitecustomize.py is auto-imported by the subprocess at startup;
        # it wraps transformers generate() to flush the MPS allocator every 25
        # tokens — without it the KV-cache concat pattern grows the footprint
        # quadratically and a 3000-token stage-1 pass would swap-death the Mac.
        flush_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "mps_flush")
        python_path = flush_dir + (
            os.pathsep + os.environ["PYTHONPATH"]
            if os.environ.get("PYTHONPATH") else "")
        env = {**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1",
               "PYTHONPATH": python_path}
        proc = subprocess.Popen(cmd, cwd=os.path.join(self.repo_dir, "inference"),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=env)
        self.proc = proc
        assert proc.stdout is not None
        # Three coarse acts: stage-1 LM, stage-2 refine, vocoder/mix. Each
        # runs its own 0→100 % bars, which used to be reported raw — a
        # sawtooth that read as a restart every act (audit §5). A bar that
        # falls back sharply means the next act began.
        acts, act = 3, 0
        last_pct = 0.0
        try:
            # \r-aware: the inner tqdm bars redraw in place and a plain
            # line iterator sat silent for tens of minutes inside stage-1
            # segments (audit §5).
            for line in iter_progress_lines(proc.stdout):
                if cancel.cancelled:
                    proc.kill()
                    raise CancelledError()
                # infer.py's stdout is captured because this worker's own
                # stdout is the JSONL protocol channel — so without this
                # the only family that reports hours of work says nothing
                # at all. stderr is the mirror the render card reads.
                print(line, file=sys.stderr, flush=True)
                match = re.search(r"(\d+)%", line)
                if match:
                    pct = min(100, int(match.group(1))) / 100
                    if pct + 0.3 < last_pct and act < acts - 1:
                        act += 1
                    last_pct = pct
                    progress_cb(min(0.98, (act + pct) / acts), line[:200])
                else:
                    progress_cb(None, line[:200])
            proc.wait()
        finally:
            self.proc = None
        if proc.returncode != 0:
            raise RuntimeError(f"YuE infer.py exited with {proc.returncode}")

        produced = self._find_output(run_dir)
        if not produced:
            raise RuntimeError("YuE finished but produced no mixed audio file")
        tmp = out_path + ".part"
        shutil.move(produced, tmp)
        os.replace(tmp, out_path)

        import soundfile as sf
        info = sf.info(out_path)
        return GenerateResult(wav_path=out_path, duration_s=info.duration,
                              sample_rate=info.samplerate, seed_used=seed)

    @staticmethod
    def _find_output(run_dir: str) -> str | None:
        """YuE writes mixed output under <output_dir>; prefer the final mix."""
        candidates: list[tuple[float, str]] = []
        for root, _dirs, files in os.walk(run_dir):
            for f in files:
                if f.endswith((".wav", ".mp3")) and "mix" in f.lower():
                    p = os.path.join(root, f)
                    candidates.append((os.path.getmtime(p), p))
        if not candidates:
            for root, _dirs, files in os.walk(run_dir):
                for f in files:
                    if f.endswith(".wav"):
                        p = os.path.join(root, f)
                        candidates.append((os.path.getmtime(p), p))
        return max(candidates)[1] if candidates else None

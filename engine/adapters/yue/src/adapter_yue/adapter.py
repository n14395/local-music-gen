"""YuE (experimental): lyrics-to-song via the upstream repo's infer.py subprocess.

There is no Metal port of YuE; on Apple Silicon this runs on CPU/MPS-fallback and
takes HOURS per song. It ships for honesty — the catalog flags it "experimental" and
the UI warns loudly. The upstream repo is cloned at a pinned SHA on first load; its
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
                                     ModelAdapter, ProgressCb)

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
        # vendor/ lives next to the adapter venv, outside any GC'd scratch space
        base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "..", "vendor")
        base = os.path.abspath(base)
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
            if os.path.islink(xcodec_link):
                os.unlink(xcodec_link)
            if not os.path.exists(xcodec_link):
                os.symlink(xcodec_snapshot, xcodec_link)
        progress_cb(None, "YuE ready (expect hours per song on Apple Silicon)")

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

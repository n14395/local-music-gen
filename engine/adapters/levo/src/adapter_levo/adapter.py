# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""LeVo 2 (Tencent SongGeneration-v2): lyrics + description to a full 48 kHz
stereo song, via the community MLX port — the only Apple Silicon route.

Upstream is a salvage job: Tencent's official GitHub 404s and their HF repo
went private (2026-09), so the LM weights come from the mlx-community
conversions and the decoder assets from the paper author's mirror
(lglg666/SongGeneration-Runtime). The port (ailuntx/SongGeneration-MLX,
pinned) splits the work exactly as this adapter runs it:

  1. Token LM on MLX, in-process in this venv — `load_model` +
     `generate_tokens`, one `sample_next` per 40 ms pattern step, which the
     adapter wraps for counted progress and cancellation.
  2. Audio decode through the OFFICIAL PyTorch Flow1dVAE bridge
     (`scripts/decode_tokens_official.py`), proven on MPS by the port
     author. Its stack (torch 2.6 / transformers 4.37 / diffusers 0.27)
     conflicts with mlx-lm's, so — like upstream's own two-venv README —
     it runs as a subprocess out of a decoder venv this adapter provisions
     beside the family venv on first load with the port's exact requirement
     files.

The vendored official source tree ships in the port's tarball; the runtime
weights (septoken tokenizer, VAE) land as an HF snapshot and are symlinked
in as `<tree>/runtime`, which is precisely where the decode script's
path-ladder looks for `./ckpt/...` entries.
"""

from __future__ import annotations

import math
import os
import random
import secrets
import subprocess

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir, clear_stale_link,
                                     release_accelerator_memory)
from engine_protocol.progress import iter_progress_lines, parse_tqdm
from engine_protocol.staging import fetch_tarball_tree, staged

REPO_COMMIT = "bb2ff7d86ae66d17e4a82e7bcd95c00a1f5a2b77"
REPO_TARBALL = (f"https://github.com/ailuntx/SongGeneration-MLX/archive/"
                f"{REPO_COMMIT}.tar.gz")
LM_NEEDLE = "songgeneration-v2"       # mlx-community conversion
RUNTIME_NEEDLE = "songgeneration-runtime"  # lglg666 decoder-asset mirror
MAX_DUR_S = 270.0                     # cfg.max_dur in the v2 checkpoints


def instrumental_lyrics(duration_s: float) -> str:
    """A tag-only structure for a wordless take.

    Upstream's own format: `[intro-*]`, `[inst-*]` and `[outro-*]` sections
    are documented as carrying no lyrics, and a song may be nothing but
    them. The tags are guidance, not a clock — the token budget set from
    `duration` is what actually ends the take — so this only needs to be
    roughly proportioned, one [inst-long] block per half minute or so.
    """
    n = max(1, round(duration_s / 30))
    return " ; ".join(["[intro-short]"] + ["[inst-long]"] * n
                      + ["[outro-short]"])


def pump_decoder(proc, windows: int, progress_cb: ProgressCb,
                 cancel: CancelToken) -> None:
    """Pace the Flow1dVAE decode bar from the decoder child's own output.

    upstream's code2sound pads the token stream to 750·k + 250 frames at a
    1000-frame window on a 750-frame hop and runs k windows, each one its
    own 10-step ODE bar that restarts at zero — so a falling step count is
    the next window starting, and a changed total is a different bar family
    entirely (the checkpoint-shard loader that runs before the decode).

    Reads the child to EOF. Kills and reaps it on any exception, including
    the CancelledError `progress_cb` raises on a cancelled job — an unreaped
    decoder keeps the GPU for the rest of the session.
    """
    assert proc.stdout is not None
    done, last_step, last_total = 0, 0, 0
    # The highest fraction reported so far. Never reported below: a bar that
    # falls back reads as "the next act began", and the decode is the last
    # act of a render.
    reported = 0.55
    try:
        # \r-aware like the YuE adapter: the decoder's tqdm bars redraw
        # in place and a plain line iterator would sit silent.
        for line in iter_progress_lines(proc.stdout):
            if cancel.cancelled:
                proc.kill()
                proc.wait()      # or the child is left a zombie
                raise CancelledError()
            print(line, flush=True)
            # Every bar update is also a cancel checkpoint. Without this
            # the longer half of the render reported one message and the
            # bar sat at 0.55 for minutes.
            bar = parse_tqdm(line)
            if not bar:
                continue
            if "checkpoint shards" in line.lower():
                # transformers' shard loader renders a real tqdm bar before
                # the decode starts. Paced as a window it climbed the bar to
                # ~70 % and the first decode redraw dropped it back to 55 %
                # (found by the engine's own tests, 2026-09-16). It is still
                # a cancel checkpoint, just not a decode step.
                progress_cb(None, "loading the Flow1dVAE decoder")
                continue
            step, total = bar
            if total != last_total:
                # A different bar family; start the window count at it.
                done, last_total = 0, total
            elif step < last_step:
                done = min(done + 1, windows - 1)
            last_step = step
            frac = (done + step / total) / windows
            reported = max(reported, min(0.95, 0.55 + 0.4 * frac))
            progress_cb(reported,
                        f"decoding with Flow1dVAE — window "
                        f"{done + 1}/{windows}",
                        step=done + 1, steps=windows)
    except BaseException:
        # progress_cb itself raises CancelledError on a cancelled job, so
        # the loop can exit without passing the branch above — and an
        # unreaped decoder keeps the GPU for the rest of the session.
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        raise


class LeVoAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.tokenizer = None
        self.repo_dir = ""
        self.decoder_python = ""
        self.proc: subprocess.Popen | None = None

    def _snapshot(self, needle: str) -> str:
        for repo, path in self.model_paths.items():
            if needle in repo.lower():
                return path
        raise RuntimeError(f"no '{needle}' snapshot in model_paths")

    def _stage_repo(self, progress_cb: ProgressCb) -> None:
        cache = aux_dir("levo")
        self.repo_dir = os.path.join(cache, f"SongGeneration-MLX-{REPO_COMMIT}")
        if not staged(self.repo_dir,
                      "scripts/decode_tokens_official.py",
                      "third_party/SongGeneration/codeclm/models/builders.py"):
            progress_cb(None, "fetching the SongGeneration-MLX port "
                              "(first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache,
                               f"SongGeneration-MLX-{REPO_COMMIT}")
        # The decode script resolves "./ckpt/..." against <tree>/ and then
        # <tree>/runtime/ — the runtime snapshot's layout (ckpt/,
        # third_party/) is exactly the latter.
        link = os.path.join(self.repo_dir, "third_party", "SongGeneration",
                            "runtime")
        target = self._snapshot(RUNTIME_NEEDLE)
        clear_stale_link(link)
        if os.path.islink(link) and os.path.realpath(link) != \
                os.path.realpath(target):
            os.unlink(link)
        if not os.path.exists(link):
            os.symlink(target, link)

    def _ensure_decoder(self, progress_cb: ProgressCb) -> str:
        """The PyTorch decoder venv, provisioned once beside the family venv.

        Beside — not in the aux cache, where it was first pointed: the aux
        cache rides the external library volume, whose filesystem broke wheel
        extraction outright (numba's AppleDouble ``._numba`` entry failed to
        open), and a venv is a runtime like `.venv` itself, not relocatable
        library data. The family dir is writable in both layouts (the source
        tree in dev, the Application Support copy in packaged builds).

        Keyed to the port commit: a new pin means new requirement files, and
        a venv built for the old ones must not be trusted with them.
        """
        family_dir = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))))
        venv = os.path.join(family_dir, ".venv-decoder")
        python = os.path.join(venv, "bin", "python")
        marker = os.path.join(venv, ".provisioned")
        try:
            with open(marker) as f:
                if f.read().strip() == REPO_COMMIT and os.path.exists(python):
                    return python
        except OSError:
            pass
        uv = os.environ.get("LOCALMUSICGEN_UV", "uv")
        tree = os.path.join(self.repo_dir, "third_party", "SongGeneration")
        # Python 3.10, not newer: requirements_nodeps pins hydra-core 1.0.7
        # (fairseq lineage), whose dataclasses cannot even import under the
        # stricter 3.11+ mutable-default check.
        progress_cb(None, "building the LeVo decoder runtime (first use "
                          "only — several GB of wheels, takes minutes)")
        subprocess.run([uv, "venv", "--python", "3.10", venv], check=True,
                       capture_output=True, text=True, timeout=600)
        # The port's exact recipe: requirements.txt resolved normally,
        # requirements_nodeps.txt with --no-deps (fairseq-lineage extras
        # whose own dependency trees must not be walked), soundfile and
        # filelock on top (generate_septoken imports filelock; the decode
        # script writes through soundfile).
        for extra, req in ((["soundfile", "filelock"], "requirements.txt"),
                           (["--no-deps"], "requirements_nodeps.txt")):
            cmd = [uv, "pip", "install", "--python", python,
                   "-r", os.path.join(tree, req)] + extra
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
            assert proc.stdout is not None
            for line in iter_progress_lines(proc.stdout):
                # Liveness and a cancel checkpoint through a multi-minute
                # install; progress_cb raises CancelledError when the load
                # was cancelled, which leaves no marker — the next load
                # simply provisions again.
                progress_cb(None, f"decoder runtime: {line[:120]}")
            if proc.wait() != 0:
                raise RuntimeError(f"decoder venv install failed ({req}); "
                                   "see the log above")
        with open(marker, "w") as f:
            f.write(REPO_COMMIT)
        return python

    def load(self, progress_cb: ProgressCb) -> None:
        self._stage_repo(progress_cb)
        self.decoder_python = self._ensure_decoder(progress_cb)

        progress_cb(None, "loading the SongGeneration-v2 token LM on MLX")
        from songgeneration_mlx.model import load_model

        self.model, self.tokenizer, _meta = load_model(
            self._snapshot(LM_NEEDLE))
        progress_cb(None, "LeVo ready (MLX tokens + PyTorch decoder bridge)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.model is not None
        import mlx.core as mx
        import numpy as np
        from songgeneration_mlx.model import generate_tokens

        duration_s = min(MAX_DUR_S, float(params.get("duration_s") or 60.0))
        lyrics = (lyrics or "").strip()
        if not lyrics:
            # No lyrics is a request, not a mistake: SongGeneration's format
            # has purely-instrumental section tags, so an empty box becomes
            # a wordless piece shaped by the prompt alone.
            lyrics = instrumental_lyrics(duration_s)
            progress_cb(None, f"no lyrics — rendering an instrumental "
                              f"({lyrics})")
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        # mx.random.categorical draws from MLX's global stream; the others
        # are cheap insurance for library internals.
        mx.random.seed(seed)
        random.seed(seed)
        np.random.seed(seed)

        # Pattern steps ≈ timesteps + codebook delays; close enough for an
        # honest bar.
        frame_rate = float(self.model.config.frame_rate)
        total = max(1, int(duration_s * frame_rate))
        progress_cb(0.0, "writing music", step=0, steps=total)

        orig_sample = self.model.sample_next
        n = 0

        def counted(*a, **kw):
            nonlocal n
            if cancel.cancelled:
                raise CancelledError()
            out = orig_sample(*a, **kw)
            n += 1
            if n % 25 == 0:
                progress_cb(min(0.55, 0.55 * n / total),
                            f"writing music — step {n}/~{total}",
                            step=min(n, total), steps=total)
            return out

        self.model.sample_next = counted
        try:
            tokens = generate_tokens(
                self.model, self.tokenizer,
                lyrics=lyrics.strip(),
                description=(prompt or "").strip() or "pop",
                duration=duration_s,
                top_k=int(params.get("top_k") or 50),
                temperature=float(params.get("temperature") or 0.9))
        finally:
            self.model.sample_next = orig_sample
        if cancel.cancelled:
            raise CancelledError()

        npz = os.path.join(self.work_dir, "levo-tokens.npz")
        token_array = np.array(tokens)
        np.savez(npz, tokens=token_array)
        raw = os.path.join(self.work_dir, "levo-decode.wav")
        if os.path.exists(raw):
            os.unlink(raw)

        # The decoder bridge: ~6 s of wall time per song second on the port
        # author's Apple Silicon measurements — the longer half of a render.
        # The decode is paced across upstream's chunker: code2sound pads the
        # token stream to 750·k + 250 frames at a 1000-frame window on a
        # 750-frame hop and runs k windows (generate_septoken, pinned), each
        # one its own 10-step ODE bar that restarts at zero.
        frames = int(token_array.shape[-1])
        windows = max(1, math.ceil((max(frames, 1000) - 250) / 750))
        progress_cb(0.55, "decoding with Flow1dVAE (the slow half — "
                          "10 diffusion steps per chunk)",
                    step=0, steps=windows)
        env = {**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1"}
        proc = subprocess.Popen(
            [self.decoder_python,
             os.path.join(self.repo_dir, "scripts",
                          "decode_tokens_official.py"),
             "--repo", os.path.join(self.repo_dir, "third_party",
                                    "SongGeneration"),
             "--mlx-model", self._snapshot(LM_NEEDLE),
             "--tokens", npz, "--output", raw, "--device", "mps"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            env=env)
        self.proc = proc
        try:
            pump_decoder(proc, windows, progress_cb, cancel)
        finally:
            self.proc = None
        if proc.wait() != 0:
            raise RuntimeError("the LeVo decoder bridge failed; see the log")
        if not os.path.exists(raw):
            # Gotcha rule: fire on empty results, not just exceptions.
            raise RuntimeError("the LeVo decoder wrote no audio")

        audio, sr = sf.read(raw, dtype="float32", always_2d=True)
        tmp = out_path + ".part"
        sf.write(tmp, audio, sr, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(audio.shape[0] / sr, 3),
            sample_rate=int(sr),
            seed_used=seed)

    def unload(self) -> None:
        # A render that ended by exception can leave the decoder child alive,
        # and it owns the GPU the next model wants.
        proc, self.proc = self.proc, None
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()
        self.model = None
        self.tokenizer = None
        # The token LM is MLX and in-process: dropping the reference leaves
        # its buffers in MLX's cache until the allocator is told.
        release_accelerator_memory()

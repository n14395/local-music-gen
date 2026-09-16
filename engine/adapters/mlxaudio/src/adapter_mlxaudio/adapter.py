"""MiniMax Music 3 via mlx-audio's native MLX implementation.

Runs the mlx-community quantized conversions (mxfp8 ~15 GB, mxfp4 ~9 GB) instead
of the 57 GB torch/diffusers weights — the practical Apple Silicon route. Pure
MLX: no torch in this venv.

Reported phases are `lm_decode` → `diffusion` → `master`, matching the
`capabilities.pipeline` the generation entries of this family declare (the
tokensplice mix model declares none). Both counted phases come from the hooks
below, so their steps are real calls. The codec decode is not hooked and is not
reported — the fraction bands are estimates, the step counts are not.
"""

from __future__ import annotations

import os
import secrets
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb,
                                     release_accelerator_memory)

# Progress split between the two heavy stages (measured on M1 Max: the AR stage
# and the flow-matching DiT take roughly 60/40 of the wall time).
AR_END = 0.60
DIT_END = 0.97


class MLXAudioAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None

    def _snapshot(self) -> str:
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        if self.settings.get("engine") == "tokensplice":
            from mlx_audio.codec.models.encodec import Encodec

            progress_cb(None, "loading EnCodec (MLX)")
            self.model, _processor = Encodec.from_pretrained(self._snapshot())
            progress_cb(None, "EnCodec ready")
            return
        from mlx_audio.music import load as load_music

        progress_cb(None, "loading MLX weights")
        # Path (not str) skips mlx-audio's hub resolution: the engine already
        # downloaded the snapshot.
        self.model = load_music(Path(self._snapshot()))
        progress_cb(None, "MiniMax Music 3 (MLX) ready")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.model is not None
        duration_s = float(params.get("duration_s", 90.0))
        steps = max(1, min(30, int(params.get("steps", 30))))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2**31)
        # Guidance is a constant upstream — `_run_flow` passes
        # `guidance_scale=DIT_CFG_SCALE` and `generate()` offers no way in — so
        # it arrives through the same hook that counts the steps. None means
        # "leave upstream's 1.7 alone".
        cfg = params.get("cfg_scale")
        cfg = float(cfg) if cfg is not None else None
        # The checkpoint contract requires lyrics; the official way to ask for
        # an instrumental track is the [instrumental] tag.
        lyrics_text = lyrics.strip() if lyrics and lyrics.strip() else "[instrumental]"

        result = self._run_hooked(prompt, lyrics_text, duration_s, steps, seed,
                                  cfg, progress_cb, cancel)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(1.0, "writing audio", phase="master")
        wav = np.asarray(result.audio, dtype=np.float32)  # (samples, channels)
        sample_rate = int(result.sample_rate)
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=seed)

    def _run_hooked(self, prompt: str, lyrics: str, duration_s: float,
                    steps: int, seed: int, cfg: float | None,
                    progress_cb: ProgressCb, cancel: CancelToken):
        """Generate with per-frame / per-step progress and cooperative cancel.

        mlx-audio exposes no callbacks, so hook the two module-level seams its
        generate() resolves at call time: `ar.ar_one_frame` (once per AR frame)
        and `minimax_music3.denoise_chunk` (once per DiT window; its transformer
        argument is wrapped for per-step ticks). Raising here keeps the worker
        — and the loaded model — alive, unlike a SIGKILL cancel.

        The denoise hook does double duty: `_run_flow` hard-codes
        `guidance_scale=DIT_CFG_SCALE` at the call site, so intercepting that
        call is the only place a guidance setting can reach the DiT at all.
        """
        from mlx_audio.music.models.minimax_music3 import ar as ar_mod
        from mlx_audio.music.models.minimax_music3 import (minimax_music3 as
                                                           mm3_mod)

        frame_rate = float(self.model.config.frame_rate)
        max_frames = max(1, int(duration_s * frame_rate))
        ar_frames = 0
        true_frames = 0  # the AR stage may stop before max_frames (end token)
        dit_calls = 0
        dit_total = None  # known once the AR stage has decided the real length

        original_ar = ar_mod.ar_one_frame
        original_frames = mm3_mod.generate_frame_hiddens
        original_denoise = mm3_mod.denoise_chunk

        def ar_one_frame(*args, **kwargs):
            nonlocal ar_frames
            if cancel.cancelled:
                raise CancelledError()
            if kwargs.get("emit_frame", True):
                ar_frames += 1
                if ar_frames % 10 == 0:
                    # `done` is a real frame count, but `max_frames` is the
                    # requested duration — a ceiling the AR stage often stops
                    # short of on an end token (see `true_frames` above). A
                    # total that will not be reached makes the stage freeze at
                    # 80%, so the phase reports the step alone.
                    done = min(ar_frames, max_frames)
                    progress_cb(AR_END * done / max_frames,
                                f"language model: frame {done}",
                                phase="lm_decode", step=done)
            return original_ar(*args, **kwargs)

        def generate_frame_hiddens(*args, **kwargs):
            nonlocal true_frames
            hiddens = original_frames(*args, **kwargs)
            true_frames = int(hiddens.shape[1])
            return hiddens

        def denoise_chunk(transformer, *args, **kwargs):
            nonlocal dit_total
            if cfg is not None:
                # Before the pass count below reads it: at 1.0 the sampler runs
                # one forward per step instead of two, which halves the DiT
                # stage — a real change to what the counter is counting, not
                # only to how the audio sounds.
                kwargs["guidance_scale"] = cfg
            if dit_total is None:
                chunks = len(mm3_mod._chunk_starts(true_frames or ar_frames))
                guidance = kwargs.get("guidance_scale", mm3_mod.DIT_CFG_SCALE)
                passes = 1 if guidance == 1.0 else 2
                dit_total = max(1, chunks * steps * passes)

            def counting_transformer(*t_args, **t_kwargs):
                nonlocal dit_calls
                dit_calls += 1
                if cancel.cancelled:
                    raise CancelledError()
                if dit_calls % 4 == 0:
                    done = min(dit_calls, dit_total)
                    secs = (true_frames or ar_frames) / frame_rate
                    progress_cb(AR_END + (DIT_END - AR_END) * done / dit_total,
                                f"denoising {secs:.0f}s of audio: "
                                f"step {done}/{dit_total}",
                                phase="diffusion", step=done, steps=dit_total)
                return transformer(*t_args, **t_kwargs)

            return original_denoise(counting_transformer, *args, **kwargs)

        ar_mod.ar_one_frame = ar_one_frame
        mm3_mod.generate_frame_hiddens = generate_frame_hiddens
        mm3_mod.denoise_chunk = denoise_chunk
        try:
            progress_cb(0.0, "generating")
            return next(self.model.generate(text=prompt, lyrics=lyrics,
                                            duration=duration_s, steps=steps,
                                            seed=seed))
        finally:
            ar_mod.ar_one_frame = original_ar
            mm3_mod.generate_frame_hiddens = original_frames
            mm3_mod.denoise_chunk = original_denoise
            mx.clear_cache()

    def run_task(self, task, params, out_dir, progress_cb, cancel):
        if task == "mix" and self.settings.get("engine") == "tokensplice":
            from . import tokensplice

            assert self.model is not None
            return tokensplice.run(self.model, params, out_dir, progress_cb,
                                   cancel)
        return super().run_task(task, params, out_dir, progress_cb, cancel)

    def unload(self) -> None:
        self.model = None
        release_accelerator_memory()

"""MiniMax Music 3 via diffusers' experimental ModularPipeline API.

Very heavy: ~57 GB of weights (Qwen-8B LM + 2.7B DiT + codecs), catalog-gated to
48 GB+ Macs. fp16 on MPS by default (M1/M2 have no native bf16); override with
settings.dtype = "bfloat16" on M3+ if fp16 misbehaves.

Reported phases are `lm_decode` → `diffusion` → `vocoder` → `master`, matching
the `capabilities.pipeline` this model's catalog entry declares. All three
counted phases come from the forward hooks below, so their step numbers are real
calls, not estimates — and the no-hook fallback path reports no phase at all.
"""

from __future__ import annotations

import gc
import os

import numpy as np
import soundfile as sf
import torch

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb)


class MiniMaxAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.pipe = None
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"

    def _snapshot(self) -> str:
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        from diffusers import ModularPipeline

        dtype = getattr(torch, str(self.settings.get("dtype", "float16")))
        progress_cb(None, "building modular pipeline")
        pipe = ModularPipeline.from_pretrained(self._snapshot())
        progress_cb(None, f"loading components ({dtype}) — this can take minutes")
        pipe.load_components(dtype=dtype)
        pipe.to(self.device)
        # The vocoder's weight-norm conv stack overflows in fp16 on MPS and
        # produces an all-NaN waveform; it is tiny, so run it in fp32 (the decode
        # block casts latents to the vocoder's dtype).
        vocoder = getattr(pipe, "vocoder", None)
        if vocoder is not None and dtype != torch.float32:
            vocoder.to(torch.float32)
        self.pipe = pipe
        progress_cb(None, f"MiniMax Music 3 on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.pipe is not None
        duration_s = float(params.get("duration_s", 90.0))
        # Both knobs were declared and never read (audit §2): every render
        # ran the pipeline defaults — 30 steps, guidance 1.7 — whatever the
        # sliders said. 30/1.7 stay the catalog defaults so a default render
        # sounds exactly as it always has.
        steps = max(4, min(150, int(params.get("steps") or 30)))
        cfg = params.get("cfg_scale")
        guider = getattr(self.pipe, "guider", None)
        if cfg is not None and guider is not None \
                and hasattr(guider, "guidance_scale"):
            guider.guidance_scale = float(cfg)
        seed = params.get("seed")
        generator = torch.Generator("cpu")
        if seed is not None:
            generator = generator.manual_seed(int(seed))

        if cancel.cancelled:
            raise CancelledError()
        audio = self._run_pipeline(prompt, lyrics, duration_s, steps,
                                   generator, progress_cb, cancel)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(1.0, "writing audio", phase="master")
        sample_rate = int(getattr(self.pipe, "sampling_rate", 44100))
        # the pipeline returns (channels, samples), numpy on MPS, tensor elsewhere
        if torch.is_tensor(audio):
            audio = audio.detach().float().cpu().numpy()
        wav = np.asarray(audio, dtype=np.float32).T
        peak = float(np.abs(wav).max())
        if peak > 1.0:
            wav = wav / peak * 0.95
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=int(seed) if seed is not None else None)

    def _run_pipeline(self, prompt: str, lyrics: str | None, duration_s: float,
                      steps: int, generator: torch.Generator,
                      progress_cb: ProgressCb, cancel: CancelToken):
        """Run the modular pipeline with a hook on the LM's inner forward.

        The pipeline's autoregressive stage calls `language_model.model(...)` once
        per audio frame with a growing KV cache. On MPS the per-step cache concat
        makes the allocator footprint grow quadratically with frames (freed blocks
        are never reused for the next, larger request) — measured at ~66 GB by 600
        tokens on MusicGen; at 8B scale it would hit swap far sooner. The hooks
        return freed blocks to the OS every 10 calls, and double as the only
        available progress/cancel checkpoints (the pipeline has no step
        callback): LM 0–65%, DiT denoise 65–95%, vocoder 95–100%. Cooperative
        cancel raising here keeps the worker (and the loaded model) alive.
        """
        # The pipeline rejects empty lyrics; the model card's way to ask for an
        # instrumental track is the official [Instrumental] section tag.
        lyrics_text = lyrics.strip() if lyrics and lyrics.strip() else "[instrumental]"

        lm = getattr(self.pipe, "language_model", None)
        inner = getattr(lm, "model", None)
        if inner is None:
            progress_cb(None, "generating (no LM hook point; coarse progress only)")
            return self.pipe(prompt=prompt, lyrics=lyrics_text,
                             audio_duration=duration_s,
                             num_inference_steps=steps, generator=generator,
                             output="audios")[0]

        transformer = getattr(self.pipe, "transformer", None)
        vocoder = getattr(self.pipe, "vocoder", None)
        frame_rate = float(getattr(self.pipe, "frame_rate", 25.0))
        max_frames = max(1, int(duration_s * frame_rate))
        # Denoise geometry (mirrors the pipeline's before_denoise/denoise blocks):
        # 200-frame windows with a 100-frame hop, 60 Euler steps per window, and
        # two transformer passes per step (conditional + unconditional guidance).
        # The window count depends on how many frames the LM actually emits — with
        # sparse lyrics (e.g. bare "[instrumental]") it may end the song well
        # before the requested duration, which is model behavior, not a stall.
        # dit_steps is no longer a mirrored upstream constant: it is the
        # num_inference_steps this render actually requests below.
        chunk_frames, chunk_hop, dit_steps, dit_passes = 200, 100, steps, 2
        lm_calls = 0
        dit_calls = 0
        voc_calls = 0
        lm_frames = max_frames  # refined once the LM hands off to the DiT
        chunks = 1
        original_lm = inner.forward
        original_dit = transformer.forward if transformer is not None else None
        original_voc = vocoder.forward if vocoder is not None else None

        def lm_forward(*args, **kwargs):
            nonlocal lm_calls
            lm_calls += 1
            if cancel.cancelled:
                raise CancelledError()
            if lm_calls % 10 == 0:
                if self.device == "mps":
                    torch.mps.empty_cache()
                # `lm_calls` counts forward passes, not frames — dit_forward
                # below subtracts 2 from it for exactly that reason — and
                # `max_frames` is the requested duration, which the LM may end
                # well short of. Neither is a step count, so the phase is
                # reported without one and the band carries the position.
                done = min(lm_calls, max_frames)
                progress_cb(0.65 * done / max_frames,
                            f"language model: {done} of at most {max_frames} frames",
                            phase="lm_decode")
            return original_lm(*args, **kwargs)

        def dit_forward(*args, **kwargs):
            nonlocal dit_calls, lm_frames, chunks
            if dit_calls == 0:
                # prefill + audio_start advance account for two extra LM calls
                lm_frames = max(1, min(lm_calls - 2, max_frames))
                chunks = (1 if lm_frames <= chunk_frames
                          else len(range(0, lm_frames - chunk_hop, chunk_hop)))
            dit_calls += 1
            if cancel.cancelled:
                raise CancelledError()
            if dit_calls % 10 == 0:
                if self.device == "mps":
                    torch.mps.empty_cache()
                # dit_steps is the requested num_inference_steps now, so the
                # total is real and can be reported (the old mirrored 60
                # described twice the work and pinned the stage at 50%).
                total = chunks * dit_steps
                step = min(dit_calls // dit_passes, total)
                progress_cb(0.65 + 0.3 * step / total,
                            f"denoising {lm_frames / frame_rate:.0f}s of audio",
                            phase="diffusion", step=step, steps=total)
            return original_dit(*args, **kwargs)

        def voc_forward(*args, **kwargs):
            nonlocal voc_calls
            voc_calls += 1
            if cancel.cancelled:
                raise CancelledError()
            # `chunks` is only refined inside dit_forward, which is hooked
            # conditionally — with a pipeline exposing a vocoder but no
            # transformer it stays 1 and this would count 1/1, 2/1, 3/1.
            progress_cb(min(0.99, 0.95 + 0.04 * voc_calls / max(1, chunks)),
                        f"decoding audio (chunk {voc_calls})",
                        phase="vocoder")
            return original_voc(*args, **kwargs)

        inner.forward = lm_forward
        if original_dit is not None:
            transformer.forward = dit_forward
        if original_voc is not None:
            vocoder.forward = voc_forward
        try:
            progress_cb(0.0, "generating")
            return self.pipe(prompt=prompt, lyrics=lyrics_text,
                             audio_duration=duration_s,
                             num_inference_steps=dit_steps,
                             generator=generator, output="audios")[0]
        finally:
            inner.forward = original_lm
            if original_dit is not None:
                transformer.forward = original_dit
            if original_voc is not None:
                vocoder.forward = original_voc
            if self.device == "mps":
                torch.mps.empty_cache()

    def unload(self) -> None:
        self.pipe = None
        gc.collect()
        if self.device == "mps":
            torch.mps.empty_cache()

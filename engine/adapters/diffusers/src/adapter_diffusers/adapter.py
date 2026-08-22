"""Generic diffusers audio pipeline adapter (user-added models).

Handles StableAudioPipeline, AudioLDM2Pipeline, AudioLDMPipeline, MusicLDMPipeline.
trust_remote_code is never passed — the supervisor refuses such repos upfront.

Reported phases are `prompt_encode` → `diffusion` → `master`, matching the
`capabilities.pipeline` this family's catalog entries declare. Pipelines that
accept no step callback still report the diffusion phase, without step counts.

Supports streaming previews (contract 5.6) by running the pipeline's own final
decode on the latents the step callback already receives and currently throws
away. Unlike Stable Audio's sampler these are the *noisy* latents — no diffusers
scheduler exposes its clean prediction to a callback — so an early frame sounds
like noise. That is genuinely where the render is at that step, not an
approximation of it, which is the only claim a preview may make.
"""

from __future__ import annotations

import gc
import inspect
import os
import sys

import numpy as np
import soundfile as sf
import torch

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb, preview_stride)

SAMPLE_RATES = {
    "StableAudioPipeline": 44100,
    "AudioLDM2Pipeline": 16000,
    "AudioLDMPipeline": 16000,
    "MusicLDMPipeline": 16000,
}


def _pcm16(wav: np.ndarray) -> bytes:
    """(channels, samples) float → interleaved little-endian PCM16."""
    interleaved = np.clip(np.asarray(wav, dtype=np.float32).T, -1.0, 1.0)
    return (interleaved * 32767.0).astype("<i2").tobytes()


class DiffusersAudioAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.pipe = None
        self.pipe_class = ""
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"

    def _snapshot(self) -> str:
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        from diffusers import DiffusionPipeline

        progress_cb(None, "loading pipeline")
        pipe = DiffusionPipeline.from_pretrained(
            self._snapshot(), torch_dtype=torch.float32)
        self.pipe_class = type(pipe).__name__
        pipe.to(self.device)
        # The pipeline's own tqdm bar goes. It redraws per step with a
        # carriage return, and the worker reads its pipe in text mode, so
        # every redraw reached the event stream looking like a fresh line —
        # 117 of them for one 50-step render, which was this family's entire
        # contribution to the render card's log. The step counts arrive as
        # progress events instead, and now as one line each.
        pipe.set_progress_bar_config(disable=True)
        self.pipe = pipe
        progress_cb(None, f"{self.pipe_class} on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.pipe is not None
        duration_s = float(params.get("duration_s", 10.0))
        steps = int(params.get("steps", 50))
        seed = params.get("seed")
        generator = None
        if seed is not None:
            generator = torch.Generator("cpu").manual_seed(int(seed))

        sample_rate = SAMPLE_RATES.get(self.pipe_class, 16000)
        # off unless the job asked: each preview is a full VAE decode
        preview_every = preview_stride(steps) if params.get("preview") else 0

        def step_callback(*args, **_kwargs):
            if cancel.cancelled:
                raise CancelledError()
            # old style: (step, timestep, latents); new: (pipe, step, t, cb_kwargs)
            new_style = len(args) >= 4 and isinstance(args[3], dict)
            step = args[1] if new_style else args[0]
            progress_cb(min(1.0, (step + 1) / steps), f"step {step + 1}/{steps}",
                        phase="diffusion", step=step + 1, steps=steps)
            if preview_every and (step + 1) % preview_every == 0:
                latents = args[3].get("latents") if new_style else args[2]
                self._preview(latents, sample_rate, duration_s, step + 1)
            # new-style callbacks must return the callback_kwargs dict
            return args[3] if new_style else None

        kwargs = {
            "prompt": prompt,
            "num_inference_steps": steps,
            "guidance_scale": float(params.get("guidance_scale", 3.5)),
            "negative_prompt": str(params.get("negative_prompt", "")) or None,
            "generator": generator,
        }
        accepted = set(inspect.signature(self.pipe.__call__).parameters)
        if "audio_end_in_s" in accepted:       # StableAudio
            kwargs["audio_end_in_s"] = duration_s
        if "audio_length_in_s" in accepted:    # AudioLDM/MusicLDM
            kwargs["audio_length_in_s"] = duration_s
        if "callback_on_step_end" in accepted:
            kwargs["callback_on_step_end"] = step_callback
        elif "callback" in accepted:
            kwargs["callback"] = step_callback
            kwargs["callback_steps"] = 1
        kwargs = {k: v for k, v in kwargs.items() if k in accepted and v is not None}

        progress_cb(None, "encoding prompt", phase="prompt_encode")
        if not ({"callback_on_step_end", "callback"} & set(kwargs)):
            # no step hook on this pipeline: name the phase, invent no counts
            progress_cb(None, f"diffusing ({steps} steps, no per-step hook)",
                        phase="diffusion")
        result = self.pipe(**kwargs)
        if cancel.cancelled:
            raise CancelledError()

        audio = np.asarray(result.audios[0], dtype=np.float32)
        if audio.ndim == 2 and audio.shape[0] <= 8:   # (channels, samples)
            audio = audio.T
        peak = float(np.abs(audio).max())
        if peak > 1.0:
            audio = audio / peak * 0.95
        keep = min(len(audio), int(duration_s * sample_rate))
        audio = audio[:keep]

        progress_cb(1.0, "writing audio", phase="master")
        tmp = out_path + ".part"
        sf.write(tmp, audio, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(audio) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=int(seed) if seed is not None else None)

    def _preview(self, latents, sample_rate: int, duration_s: float,
                 step: int) -> None:
        """Run the pipeline's own final decode on the latents it is holding.

        Two shapes, both taken verbatim from the pipeline's `__call__` so the
        preview is decoded the way the take will be: Stable Audio's Oobleck VAE
        gives audio directly, while the AudioLDM/MusicLDM family decodes a mel
        spectrogram that then goes through the vocoder.

        Never fatal: a preview that fails leaves the render running.
        """
        if latents is None or self.pipe is None:
            return
        try:
            with torch.no_grad():
                if hasattr(self.pipe, "mel_spectrogram_to_waveform"):
                    scale = getattr(self.pipe.vae.config, "scaling_factor", 1.0)
                    mel = self.pipe.vae.decode(latents / scale).sample
                    audio = self.pipe.mel_spectrogram_to_waveform(mel)
                else:
                    audio = self.pipe.vae.decode(latents).sample
            wav = np.asarray(audio[0].to(torch.float32).cpu().numpy())
            if wav.ndim == 1:                       # mel family: mono
                wav = wav[np.newaxis, :]
            wav = wav[:, :max(1, int(duration_s * sample_rate))]
            self.preview_cb(_pcm16(wav), sample_rate, channels=wav.shape[0],
                            step=step)
        except Exception as e:  # noqa: BLE001 — a preview must never fail a render
            print(f"preview decode failed at step {step}: {e}", file=sys.stderr)

    def unload(self) -> None:
        self.pipe = None
        gc.collect()
        if self.device == "mps":
            torch.mps.empty_cache()

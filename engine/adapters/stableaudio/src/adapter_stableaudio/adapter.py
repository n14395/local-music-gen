"""Stable Audio Open (Small) via stable-audio-tools on MPS.

Loads from the local snapshot (model_config.json + weights) so no network or HF token
is needed at load time — the gated download already happened through the supervisor.
Progress uses generate_diffusion_cond's callback when the installed version supports
it; otherwise progress is coarse and SIGKILL remains the cancel backstop.

Reported phases are `prompt_encode` → `diffusion` → `master`, matching the
`capabilities.pipeline` this family's catalog entries declare. The autoencoder
decode runs inside generate_diffusion_cond after the last sampler callback, so
there is nothing the adapter could honestly call a `vocoder` phase.

Supports streaming previews (contract 5.6): the sampler hands its callback
`denoised`, the predicted CLEAN latent, so decoding it yields the take as it
actually stands at that step rather than a guess at it.
"""

from __future__ import annotations

import gc
import json
import os
import sys

import numpy as np
import soundfile as sf
import torch

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb, preview_stride)


def _pcm16(wav: np.ndarray) -> bytes:
    """(channels, samples) float → interleaved little-endian PCM16."""
    interleaved = np.clip(np.asarray(wav, dtype=np.float32).T, -1.0, 1.0)
    return (interleaved * 32767.0).astype("<i2").tobytes()


class StableAudioAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.config: dict = {}
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"

    def _snapshot(self) -> str:
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        from stable_audio_tools.models.factory import create_model_from_config
        from stable_audio_tools.models.utils import load_ckpt_state_dict

        snapshot = self._snapshot()
        progress_cb(None, "reading model config")
        with open(os.path.join(snapshot, "model_config.json")) as f:
            self.config = json.load(f)

        weights = None
        for name in ("model.safetensors", "model.ckpt"):
            candidate = os.path.join(snapshot, name)
            if os.path.exists(candidate):
                weights = candidate
                break
        if weights is None:
            raise FileNotFoundError(f"no model weights found in {snapshot}")

        progress_cb(None, "building model")
        model = create_model_from_config(self.config)
        progress_cb(None, "loading weights")
        model.load_state_dict(load_ckpt_state_dict(weights), strict=False)
        model = model.to(torch.float32).to(self.device)
        model.eval()
        self.model = model
        progress_cb(None, f"model on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        from stable_audio_tools.inference.generation import generate_diffusion_cond

        assert self.model is not None
        duration_s = float(params.get("duration_s", 5.0))
        steps = int(params.get("steps", 8))
        cfg_scale = float(params.get("cfg_scale", 1.0))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else -1

        sample_rate = int(self.config["sample_rate"])
        sample_size = int(self.config["sample_size"])
        conditioning = [{"prompt": prompt,
                         "seconds_total": duration_s}]

        # off unless the job asked: each preview is a full autoencoder decode
        preview_every = preview_stride(steps) if params.get("preview") else 0

        def sampler_callback(info: dict) -> None:
            if cancel.cancelled:
                raise CancelledError()
            i = info.get("i", 0)
            progress_cb(min(1.0, (i + 1) / steps), f"step {i + 1}/{steps}",
                        phase="diffusion", step=i + 1, steps=steps)
            if preview_every and (i + 1) % preview_every == 0:
                self._preview(info.get("denoised"), sample_rate, duration_s,
                              i + 1)

        kwargs = dict(model=self.model, steps=steps, cfg_scale=cfg_scale,
                      conditioning=conditioning, sample_size=sample_size,
                      seed=seed, device=self.device)

        # audio-to-audio: diffuse from a noised version of a reference clip
        # instead of pure noise ("Reimagine a Loop"). init_noise_level is the
        # tool's own knob: higher = further from the source.
        init_path = params.get("init_audio")
        if init_path:
            init_wav, init_sr = sf.read(init_path, dtype="float32",
                                        always_2d=True)
            kwargs["init_audio"] = (int(init_sr),
                                    torch.from_numpy(init_wav.T))
            kwargs["init_noise_level"] = float(
                params.get("init_noise_level", 1.0))
        # conditioning (T5 + duration embeddings) runs first inside the call
        progress_cb(None, "encoding prompt", phase="prompt_encode")
        try:
            progress_cb(0.0, f"diffusion 0/{steps}", phase="diffusion",
                        step=0, steps=steps)
            audio = generate_diffusion_cond(callback=sampler_callback, **kwargs)
        except TypeError:
            # older stable-audio-tools without a callback parameter: the phase
            # is still known, the step count is not, so it goes without one
            progress_cb(None, "diffusing (this build reports no steps)",
                        phase="diffusion")
            audio = generate_diffusion_cond(**kwargs)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(1.0, "writing audio", phase="master")
        wav = audio[0].to(torch.float32).cpu().numpy()      # (channels, samples)
        wav = wav / max(1e-9, np.abs(wav).max()) * 0.95
        wav = wav.T                                          # (samples, channels)
        keep = min(len(wav), int(duration_s * sample_rate))
        wav = wav[:keep]
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=seed if seed >= 0 else None)

    def _preview(self, latent, sample_rate: int, duration_s: float,
                 step: int) -> None:
        """Publish the partial take behind `denoised`.

        Trimmed to the requested duration like the final write is: the sampler
        works on a padded `sample_size`, and the padding decodes to garbage that
        nobody should hear. Level is left alone — the take gets peak-normalised
        at the end, and doing it per frame would make the preview swing in
        loudness for reasons that have nothing to do with the music.

        Never fatal: a preview that fails leaves the render running.
        """
        if latent is None:
            return
        try:
            with torch.no_grad():
                dtype = next(self.model.pretransform.parameters()).dtype
                audio = self.model.pretransform.decode(latent.to(dtype))
            wav = audio[0].to(torch.float32).cpu().numpy()   # (channels, samples)
            wav = wav[:, :max(1, int(duration_s * sample_rate))]
            self.preview_cb(_pcm16(wav), sample_rate, channels=wav.shape[0],
                            step=step)
        except Exception as e:  # noqa: BLE001 — a preview must never fail a render
            print(f"preview decode failed at step {step}: {e}", file=sys.stderr)

    def unload(self) -> None:
        self.model = None
        gc.collect()
        if self.device == "mps":
            torch.mps.empty_cache()

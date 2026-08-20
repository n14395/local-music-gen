"""Stable Audio 3 Small via the official stable-audio-3 library.

Loads entirely from the local HF snapshot (config + weights + the bundled
t5gemma text encoder subfolder), bypassing the library's name-registry
downloader — the supervisor already fetched everything. Runs on CPU by
default: the small model is designed for it (~6 s for 120 s of audio) and
the MPS path is unproven for this stack; override with settings.device.

Modes (one audio input used per job, priority order):
  inpaint_audio + inpaint_start_s/inpaint_end_s  → regenerate a region
  extend_audio                                   → continuation past the end
  init_audio + init_noise_level                  → audio-to-audio restyle
  none                                           → text-to-audio

Reported phases are `prompt_encode` → `diffusion` → `master`, matching the
`capabilities.pipeline` this family's catalog entries declare. The autoencoder
decode happens inside sa.generate() after the last sampler callback, so there is
no `vocoder` phase the adapter could honestly announce.

Supports streaming previews (contract 5.6) the same way Stable Audio Open does:
the sampler's callback carries `denoised`, the predicted clean latent, and the
pretransform decodes it into real audio for the take as it stands. This is the
same decode the upstream interface runs to draw its own preview spectrograms.
"""

from __future__ import annotations

import gc
import json
import os
import sys

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb, preview_stride)


def _pcm16(wav: np.ndarray) -> bytes:
    """(channels, samples) float → interleaved little-endian PCM16."""
    interleaved = np.clip(np.asarray(wav, dtype=np.float32).T, -1.0, 1.0)
    return (interleaved * 32767.0).astype("<i2").tobytes()

MAX_DURATION_S = 120.0
# an extension shorter than this isn't audible as a continuation
MIN_EXTEND_TAIL_S = 5.0


class StableAudio3Adapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.sa = None
        self.sample_rate = 44100

    def _snapshot(self) -> str:
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        import torch
        from stable_audio_3.loading_utils import load_diffusion_cond
        from stable_audio_3.model import StableAudioModel

        snapshot = self._snapshot()
        device = self.settings.get("device", "cpu")

        progress_cb(None, "reading model config")
        with open(os.path.join(snapshot, "model_config.json")) as f:
            model_config = json.load(f)

        # Point the t5gemma conditioner at the snapshot's bundled subfolder so
        # nothing touches the network at load time (model_path wins over
        # repo_id/model_name inside T5GemmaConditioner).
        local_t5 = os.path.join(snapshot, "t5gemma-b-b-ul2")
        if os.path.isdir(local_t5):
            conditioning = model_config.get("model", {}).get("conditioning", {})
            for info in conditioning.get("configs", []):
                if info.get("type") == "t5gemma":
                    cfg = info.setdefault("config", {})
                    cfg.pop("repo_id", None)
                    cfg.pop("subfolder", None)
                    cfg["model_path"] = local_t5

        progress_cb(None, "loading weights (text encoder + DiT + autoencoder)")
        with torch.inference_mode():
            model = load_diffusion_cond(
                model_config, os.path.join(snapshot, "model.safetensors"),
                device=device, model_half=False)
        model.use_lora = False
        model.lora_names = []
        self.sa = StableAudioModel(model, model_config, device, False)
        self.sample_rate = int(
            getattr(self.sa.model, "sample_rate", 0)
            or model_config.get("sample_rate", 44100))
        progress_cb(None, f"Stable Audio 3 ready on {device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        import torch

        assert self.sa is not None
        duration_s = min(MAX_DURATION_S, float(params.get("duration_s", 30.0)))
        steps = max(1, min(50, int(params.get("steps", 8))))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else -1

        kwargs: dict = {
            "prompt": prompt,
            "duration": duration_s,
            "steps": steps,
            "cfg_scale": float(params.get("cfg_scale", 1.0)),
            "seed": seed,
        }
        negative = (params.get("negative_prompt") or "").strip()
        if negative:
            kwargs["negative_prompt"] = negative

        def load_clip(key: str):
            path = params.get(key)
            if not path:
                return None
            wav, sr = sf.read(path, dtype="float32", always_2d=True)
            return int(sr), torch.from_numpy(wav.T)

        inpaint = load_clip("inpaint_audio")
        extend = load_clip("extend_audio")
        init = load_clip("init_audio")

        if inpaint is not None:
            src_dur = inpaint[1].shape[1] / inpaint[0]
            start = float(params.get("inpaint_start_s") or 0.0)
            end_raw = params.get("inpaint_end_s")
            end = float(end_raw) if end_raw is not None else src_dur
            kwargs["inpaint_audio"] = inpaint
            kwargs["inpaint_mask_start_seconds"] = max(0.0, start)
            kwargs["inpaint_mask_end_seconds"] = min(end, src_dur)
            kwargs["duration"] = min(MAX_DURATION_S, src_dur)
            mode = "inpainting"
        elif extend is not None:
            src_dur = extend[1].shape[1] / extend[0]
            if src_dur >= MAX_DURATION_S - MIN_EXTEND_TAIL_S:
                raise RuntimeError(
                    f"source is {src_dur:.0f}s — continuation needs it under "
                    f"{MAX_DURATION_S - MIN_EXTEND_TAIL_S:.0f}s (120s total cap)")
            # continuation = inpaint everything past the source's end
            kwargs["inpaint_audio"] = extend
            kwargs["inpaint_mask_start_seconds"] = src_dur
            kwargs["duration"] = max(duration_s,
                                     min(MAX_DURATION_S,
                                         src_dur + MIN_EXTEND_TAIL_S))
            mode = "continuing"
        elif init is not None:
            kwargs["init_audio"] = init
            kwargs["init_noise_level"] = float(
                params.get("init_noise_level", 1.0))
            mode = "reimagining"
        else:
            mode = "generating"

        total_steps = steps
        # off unless the job asked: each preview is a full autoencoder decode
        preview_every = preview_stride(steps) if params.get("preview") else 0

        def callback(info: dict) -> None:
            if cancel.cancelled:
                raise CancelledError()
            i = int(info.get("i", 0))
            progress_cb(min(0.95, (i + 1) / total_steps),
                        f"{mode}: step {i + 1}/{total_steps}",
                        phase="diffusion", step=i + 1, steps=total_steps)
            if preview_every and (i + 1) % preview_every == 0:
                self._preview(info.get("denoised"),
                              float(kwargs["duration"]), i + 1)

        progress_cb(0.02, f"{mode} ({steps} steps)", phase="prompt_encode")
        try:
            audio = self.sa.generate(callback=callback, **kwargs)
        except TypeError:
            # sampler without callback passthrough: the phase is still known,
            # the step count is not, so it goes without one
            progress_cb(None, f"{mode} (this build reports no steps)",
                        phase="diffusion")
            audio = self.sa.generate(**kwargs)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(0.97, "writing audio", phase="master")
        wav = audio[0].to(torch.float32).cpu().numpy().T   # (samples, channels)
        np.clip(wav, -1.0, 1.0, out=wav)
        tmp = out_path + ".part"
        sf.write(tmp, wav, self.sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / self.sample_rate,
                              sample_rate=self.sample_rate,
                              seed_used=seed if seed >= 0 else None)

    def _preview(self, latent, duration_s: float, step: int) -> None:
        """Publish the partial take behind `denoised`. Level is left alone: the
        final write only clips too, so a preview and its take are on one scale.

        Trimmed to the effective duration, because `generate()` pads the latent
        by `duration_padding_sec` (6 s) and truncates only the FINAL result — so
        an untrimmed frame both sounds wrong at the end and claims a length the
        take will not have. "Keep partial" writes that length into the Library.

        Never fatal: a preview that fails leaves the render running.
        """
        import torch

        if latent is None or self.sa is None:
            return
        pretransform = getattr(self.sa.model, "pretransform", None)
        if pretransform is None:
            # Without the autoencoder there is no audio here, only a latent.
            # Shipping it would put a synthesised waveform on the wire under
            # the name of the model's own output — and "Keep partial" would
            # write it into the Library as a song.
            return
        try:
            with torch.inference_mode():
                audio = pretransform.decode(latent)
            wav = audio[0].to(torch.float32).cpu().numpy()   # (channels, samples)
            wav = wav[:, :max(1, int(duration_s * self.sample_rate))]
            self.preview_cb(_pcm16(wav), self.sample_rate,
                            channels=wav.shape[0], step=step)
        except Exception as e:  # noqa: BLE001 — a preview must never fail a render
            print(f"preview decode failed at step {step}: {e}", file=sys.stderr)

    def unload(self) -> None:
        self.sa = None
        gc.collect()

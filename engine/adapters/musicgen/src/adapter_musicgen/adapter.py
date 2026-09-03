"""MusicGen via transformers on MPS.

fp32 on purpose: fp16 MusicGen on MPS is known to produce NaNs/artifacts in some ops,
and small/medium fit in fp32 comfortably. Progress and cancellation ride on a
StoppingCriteria that counts generated tokens (50 Hz EnCodec frame rate).

Reported phases are `prompt_encode` → `lm_decode` → `master`, matching the
`capabilities.pipeline` this family's catalog entries declare. There is no
`vocoder` phase: EnCodec decoding happens inside `generate()`, after the last
token callback, so the adapter never sees it start.

Streaming previews (contract 5.6) exist on the MLX backend only, where the
vendored decode loop is ours and the token buffer is in scope. The transformers
path would have to rebuild the delay-pattern mask from inside a StoppingCriteria
to interpret its `input_ids`, against internals `generate()` keeps to itself and
does not version — so it declares no preview support rather than shipping a
reconstruction that silently rots into decoding the wrong tokens.
"""

from __future__ import annotations

import os
import sys

import json

import numpy as np
import soundfile as sf
import torch
from transformers import (AutoProcessor, MusicgenForConditionalGeneration,
                          MusicgenMelodyForConditionalGeneration)
from transformers.generation import StoppingCriteria, StoppingCriteriaList

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb, preview_stride)

FRAME_RATE = 50  # EnCodec tokens per second of audio


def _pcm16(wav: np.ndarray) -> bytes:
    """(channels, samples) float → interleaved little-endian PCM16."""
    interleaved = np.clip(np.asarray(wav, dtype=np.float32).T, -1.0, 1.0)
    return (interleaved * 32767.0).astype("<i2").tobytes()


class _ProgressCriteria(StoppingCriteria):
    def __init__(self, total_tokens: int, progress_cb: ProgressCb,
                 cancel: CancelToken) -> None:
        self.total = total_tokens
        self.progress_cb = progress_cb
        self.cancel = cancel
        self.start_len: int | None = None

    def __call__(self, input_ids: torch.LongTensor, scores, **kwargs) -> bool:
        if self.cancel.cancelled:
            raise CancelledError()
        if self.start_len is None:
            self.start_len = input_ids.shape[-1]
        done = input_ids.shape[-1] - self.start_len
        if done % 25 == 0:  # every ~0.5 s of audio
            # The MPS caching allocator cannot reuse blocks freed by the KV
            # cache's per-step concat (each request is slightly larger), so the
            # footprint grows quadratically with tokens — ~66 GB by 600 tokens —
            # unless the freed blocks are returned to the OS. Flushing here
            # holds it flat (~3 GB) and costs no measurable time.
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
            frac = min(1.0, done / max(1, self.total))
            self.progress_cb(frac, f"{done}/{self.total} tokens",
                             phase="lm_decode", step=done, steps=self.total)
        return False


class MusicGenAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.processor = None
        self.mlx_model = None
        self.is_melody = False
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"

    @property
    def use_mlx(self) -> bool:
        return self.settings.get("backend") == "mlx"

    def _snapshot(self) -> str:
        # single-repo family: the only entry in model_paths
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        path = self._snapshot()
        if self.use_mlx:
            # Same snapshot, different runtime: the MLX decoder is much faster
            # than fp32 transformers on MPS for autoregressive decode.
            from .mlx_backend import MusicGen as MLXMusicGen

            progress_cb(None, "loading model weights (MLX)")
            self.mlx_model = MLXMusicGen.from_snapshot(path)
            progress_cb(None, "model on MLX")
            return
        progress_cb(None, "loading processor")
        self.processor = AutoProcessor.from_pretrained(path)
        progress_cb(None, "loading model weights")
        # melody-conditioned checkpoints use a distinct architecture class
        with open(f"{path}/config.json") as f:
            archs = json.load(f).get("architectures") or []
        self.is_melody = "MusicgenMelodyForConditionalGeneration" in archs
        cls = (MusicgenMelodyForConditionalGeneration
               if self.is_melody
               else MusicgenForConditionalGeneration)
        self.model = cls.from_pretrained(path, torch_dtype=torch.float32)
        self.model.to(self.device)
        self.model.eval()
        progress_cb(None, f"model on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        if self.use_mlx:
            return self._generate_mlx(prompt, params, out_path, progress_cb,
                                      cancel)
        assert self.model is not None and self.processor is not None
        duration_s = float(params.get("duration_s", 10.0))
        seed = params.get("seed")
        if seed is not None:
            torch.manual_seed(int(seed))

        # No count to report: everything up to the first token callback is
        # tokenisation plus the T5 encode inside generate(), and neither yields
        # steps. Naming the phase we are entering is all this can honestly say.
        progress_cb(None, "encoding prompt", phase="prompt_encode")
        melody_path = params.get("melody_audio")
        if melody_path and self.is_melody:
            melody = self._load_melody(str(melody_path))
            inputs = self.processor(
                audio=melody, sampling_rate=self._melody_rate(),
                text=[prompt], padding=True, return_tensors="pt")
        else:
            inputs = self.processor(text=[prompt], padding=True,
                                    return_tensors="pt")
        inputs = {k: v.to(self.device) for k, v in inputs.items()}

        max_new_tokens = max(FRAME_RATE, int(duration_s * FRAME_RATE))
        criteria = StoppingCriteriaList([
            _ProgressCriteria(max_new_tokens, progress_cb, cancel)])

        with torch.no_grad():
            audio = self.model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                do_sample=True,
                guidance_scale=float(params.get("guidance_scale", 3.0)),
                temperature=float(params.get("temperature", 1.0)),
                top_k=int(params.get("top_k", 250)),
                stopping_criteria=criteria,
            )

        progress_cb(1.0, "writing audio", phase="master")
        sample_rate = int(self.model.config.audio_encoder.sampling_rate)
        # All channels, (T, C): [0, 0] threw away channel 1 and shipped the
        # five stereo entries as mono (audit B6). Mono models still write a
        # 1-D array through the squeeze.
        wav = audio[0].to(torch.float32).cpu().numpy().T
        if wav.ndim == 2 and wav.shape[1] == 1:
            wav = wav[:, 0]
        wav = np.clip(wav, -1.0, 1.0)
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=int(seed) if seed is not None else None)

    def _generate_mlx(self, prompt: str, params: dict, out_path: str,
                      progress_cb: ProgressCb,
                      cancel: CancelToken) -> GenerateResult:
        import mlx.core as mx

        assert self.mlx_model is not None
        duration_s = float(params.get("duration_s", 10.0))
        seed = params.get("seed")
        if seed is not None:
            mx.random.seed(int(seed))
        max_steps = max(FRAME_RATE, int(duration_s * FRAME_RATE))

        def step_callback(step: int, total: int) -> None:
            if cancel.cancelled:
                raise CancelledError()
            if step % 25 == 0:  # every ~0.5 s of audio
                progress_cb(min(1.0, step / max(1, total)),
                            f"{step}/{total} tokens",
                            phase="lm_decode", step=step, steps=total)

        # off unless the job asked: each preview is a full EnCodec decode of
        # everything generated so far
        preview_every = preview_stride(max_steps) if params.get("preview") else 0

        progress_cb(None, "encoding prompt", phase="prompt_encode")
        try:
            audio = self.mlx_model.generate(
                prompt,
                max_steps=max_steps,
                top_k=int(params.get("top_k", 250)),
                temp=float(params.get("temperature", 1.0)),
                guidance_coef=float(params.get("guidance_scale", 3.0)),
                callback=step_callback,
                preview=self._preview_mlx,
                preview_every=preview_every,
            )
        finally:
            mx.clear_cache()

        progress_cb(1.0, "writing audio", phase="master")
        sample_rate = int(self.mlx_model.sampling_rate)
        wav = np.asarray(audio, dtype=np.float32)
        if wav.ndim == 2 and wav.shape[1] == 1:
            wav = wav[:, 0]
        wav = np.clip(wav, -1.0, 1.0)
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=int(seed) if seed is not None else None)

    def _preview_mlx(self, audio, step: int) -> None:
        """Publish a partial take decoded from the tokens so far. Mono: the MLX
        backend refuses stereo checkpoints at load, so there is only ever one
        channel here.

        Never fatal: a preview that fails leaves the render running.
        """
        try:
            wav = np.asarray(audio, dtype=np.float32)
            if wav.ndim == 2 and wav.shape[1] == 1:
                wav = wav[:, 0]
            self.preview_cb(_pcm16(wav[np.newaxis, :]),
                            int(self.mlx_model.sampling_rate), channels=1,
                            step=step)
        except Exception as e:  # noqa: BLE001 — a preview must never fail a render
            print(f"preview decode failed at step {step}: {e}", file=sys.stderr)

    def _melody_rate(self) -> int:
        return int(self.processor.feature_extractor.sampling_rate)

    def _load_melody(self, path: str) -> np.ndarray:
        """Reference audio → mono float32 at the chroma extractor's rate.
        The mix is used directly (no demucs separation); chroma is coarse
        enough that this works well in practice."""
        wav, sr = sf.read(path, dtype="float32", always_2d=True)
        wav = wav.mean(axis=1)
        target = self._melody_rate()
        if sr != target:
            import torchaudio
            wav = torchaudio.functional.resample(
                torch.from_numpy(wav), sr, target).numpy()
        return wav

    def unload(self) -> None:
        self.model = None
        self.processor = None
        if self.mlx_model is not None:
            self.mlx_model = None
            import mlx.core as mx
            mx.clear_cache()
        if self.device == "mps":
            torch.mps.empty_cache()

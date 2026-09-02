"""Magenta RealTime 2 on MLX — the most Mac-native generator of the 2026
triage (4 s of audio in ~6 s including model load, 1.7 GB peak).

Weights are Google's own distribution: the `mrt` CLI that ships with the
package fetches resources (MusicCoCa + SpectroStream, ~1.3 GB) and the
exported .mlxfn model (~450 MB) from GCS into MAGENTA_HOME. The adapter
points MAGENTA_HOME inside the engine cache and runs those exact commands at
first load (route B) — MAGENTA_HOME is read when magenta_rt is imported, so
it is set before any import of the package.

Generation is chunked (the model is a streaming design, 25 frames/s, with
explicit state chaining), which is what gives this adapter real per-chunk
progress and cancel — rare among the generate families.
"""

from __future__ import annotations

import os
import subprocess
import sys

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir)

FRAMES_PER_S = 25
CHUNK_FRAMES = 50  # 2 s per generate() call: fine-grained cancel + progress


class MagentaRTAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.mrt = None
        self.size = str(self.settings.get("size") or "mrt2_small")

    def _ensure_assets(self, progress_cb: ProgressCb) -> None:
        root = os.path.join(aux_dir("magenta-home"), "magenta-rt-v2")
        resources = os.path.join(root, "resources")
        model_dir = os.path.join(root, "models", self.size)
        resource_files = (
            os.path.join(resources, "musiccoca", filename)
            for filename in (
                "text_encoder.tflite",
                "audio_preprocessor.tflite",
                "music_encoder.tflite",
                "pretrained_vector_quantizer.tflite",
            )
        )
        spectrostream_files = (
            os.path.join(resources, "spectrostream", filename)
            for filename in (
                "decoder.safetensors",
                "encoder.safetensors",
                "quantizer.safetensors",
                "spectrostream_encoder.mlxfn",
            )
        )
        model_files = (
            os.path.join(model_dir, f"{self.size}.mlxfn"),
            os.path.join(model_dir, f"{self.size}_state.safetensors"),
        )
        mrt_cli = os.path.join(os.path.dirname(sys.executable), "mrt")
        env = {**os.environ, "MAGENTA_HOME": aux_dir("magenta-home")}
        # `mrt models init` has two independent resource directories. A
        # partially interrupted fetch leaves the parent nonempty but cannot
        # embed text or decode generated audio.
        if not all(os.path.isfile(path) and os.path.getsize(path) > 0
                   for path in (*resource_files, *spectrostream_files)):
            progress_cb(None, "fetching Magenta RT resources "
                              "(~1.3 GB, first use only)")
            subprocess.run([mrt_cli, "models", "init"], env=env, check=True,
                           capture_output=True)
        # The MLX export needs its separate recurrent state file. An older
        # downloader left only the .mlxfn behind, so a nonempty directory is
        # not sufficient evidence that this model is usable.
        if not all(os.path.isfile(path) and os.path.getsize(path) > 0
                   for path in model_files):
            progress_cb(None, f"fetching the {self.size} model "
                               "(first use only)")
            subprocess.run([mrt_cli, "models", "download", self.size],
                           env=env, check=True, capture_output=True)

    def load(self, progress_cb: ProgressCb) -> None:
        # Read at magenta_rt import time — must be set before the import.
        os.environ["MAGENTA_HOME"] = aux_dir("magenta-home")
        self._ensure_assets(progress_cb)

        progress_cb(None, "loading Magenta RT 2 (MLX)")
        from magenta_rt import MagentaRT2StdMlxfn

        self.mrt = MagentaRT2StdMlxfn(size=self.size)
        progress_cb(None, "realtime engine ready")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.mrt is not None
        from magenta_rt.config import MUSICCOCA

        duration_s = float(params.get("duration_s") or 10.0)
        temperature = float(params.get("temperature") or 1.3)
        top_k = int(params.get("top_k") or 40)
        cfg_scales = {"musiccoca": float(params.get("guidance_scale") or 3.0),
                      "notes": 1.0, "drums": 1.0}

        def style_input(path_key: str, text: str | None):
            """A Waveform for an audio param, else the text, else None."""
            path = params.get(path_key)
            if path and os.path.isfile(path):
                from magenta_rt import audio as mrt_audio

                wav, sr = sf.read(path, dtype="float32", always_2d=True)
                return mrt_audio.Waveform(wav, sr)
            return text if text and text.strip() else None

        progress_cb(None, "embedding the style")
        style = style_input("style_audio", prompt) or "instrumental music"
        embedding = self.mrt.embed_style(style, use_mapper=True)
        # A second style makes this a morph: MusicCoCa embeddings are plain
        # vectors that interpolate linearly, so each 2 s chunk is conditioned
        # a step further along the line from A to B.
        style_b = style_input("style_audio_b",
                              str(params.get("prompt_b") or ""))
        embedding_b = (self.mrt.embed_style(style_b, use_mapper=True)
                       if style_b is not None else None)
        conditioning = {MUSICCOCA.key: embedding}

        total_frames = max(FRAMES_PER_S, int(duration_s * FRAMES_PER_S))
        n_chunks = max(1, -(-total_frames // CHUNK_FRAMES))
        pieces: list[np.ndarray] = []
        state = None
        sample_rate = 48000
        done = 0
        index = 0
        while done < total_frames:
            if cancel.cancelled:
                raise CancelledError()
            if embedding_b is not None:
                t = index / (n_chunks - 1) if n_chunks > 1 else 1.0
                conditioning = {
                    MUSICCOCA.key: (1.0 - t) * embedding + t * embedding_b}
            chunk = min(CHUNK_FRAMES, total_frames - done)
            waveform, state = self.mrt.generate(
                conditioning=conditioning, cfg_scales=cfg_scales,
                temperature=temperature, top_k=top_k,
                frames=chunk, state=state)
            sample_rate = int(waveform.sample_rate)
            pieces.append(np.asarray(waveform.samples, dtype=np.float32))
            done += chunk
            index += 1
            progress_cb(done / total_frames,
                        "morphing" if embedding_b is not None
                        else "streaming",
                        phase="lm_decode", step=done, steps=total_frames)

        progress_cb(None, "saving", phase="master")
        samples = np.concatenate(pieces, axis=0)
        tmp = out_path + ".part"
        sf.write(tmp, samples, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(samples.shape[0] / sample_rate, 3),
            sample_rate=sample_rate,
            seed_used=None)

    def unload(self) -> None:
        self.mrt = None
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:  # noqa: BLE001 — unload must never raise
            pass

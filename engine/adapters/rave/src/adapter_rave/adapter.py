# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""RAVE timbre transfer: audio in, the model's voice out (task `timbre`).

Each catalog entry is one IRCAM TorchScript file (settings.rave_model names
it) fetched from their model API at first use — CC-BY-NC weights, downloaded
from origin on purpose, never re-hosted. Genuinely realtime: 12 s of audio
resynthesised in 1.35 s on CPU (measured).

Model gotchas handled here, learned in triage: channel counts vary (the
percussion model outputs stereo), and most files carry no sample-rate
attribute at all — probe `sr`/`sampling_rate`/`sample_rate` and default to
44100.
"""

from __future__ import annotations

import os
import urllib.request

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)

MODEL_URL = "https://play.forum.ircam.fr/rave-vst-api/get_model/{name}"

# Long inputs run in chunks so cancel has somewhere to land; RAVE is causal
# enough at these sizes that seams are inaudible against its own character.
CHUNK_S = 30.0


class RaveAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.model_sr = 44100
        self.name = str(self.settings.get("rave_model") or "percussion")

    def load(self, progress_cb: ProgressCb) -> None:
        import torch

        path = os.path.join(aux_dir("rave-models"), f"{self.name}.ts")
        if not os.path.exists(path):
            progress_cb(None, f"fetching the {self.name} model from IRCAM "
                              f"(first use only)")
            part = path + ".part"
            with urllib.request.urlopen(MODEL_URL.format(name=self.name),
                                        timeout=300) as resp, \
                    open(part, "wb") as f:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            os.replace(part, path)

        progress_cb(None, f"loading {self.name} (TorchScript)")
        self.model = torch.jit.load(path, map_location="cpu")
        self.model_sr = 44100
        for attr in ("sr", "sampling_rate", "sample_rate"):
            value = getattr(self.model, attr, None)
            if value is not None:
                self.model_sr = int(value)
                break
        progress_cb(None, f"{self.name} ready ({self.model_sr} Hz)")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "timbre models transform existing audio — submit a timbre task")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "timbre":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.model is not None
        import soxr
        import torch

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")

        progress_cb(0.05, "reading the audio")
        data, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = data.mean(axis=1)
        if sr != self.model_sr:
            mono = soxr.resample(mono, sr, self.model_sr)

        # A second source turns the pass into a latent morph: both signals
        # are encoded, the latents interpolated, and the mix decoded — a
        # blend in the model's own space, not a crossfade.
        mono_b = None
        blend = 0.0
        src_b = params.get("source_audio_b")
        if src_b and os.path.isfile(src_b):
            data_b, sr_b = sf.read(src_b, dtype="float32", always_2d=True)
            mono_b = data_b.mean(axis=1)
            if sr_b != self.model_sr:
                mono_b = soxr.resample(mono_b, sr_b, self.model_sr)
            n = min(len(mono), len(mono_b))
            mono, mono_b = mono[:n], mono_b[:n]
            # `or` swallowed the legal 0.0 (all source A) into the 0.5
            # default (audit §2).
            b = params.get("blend")
            blend = min(1.0, max(0.0, 0.5 if b is None else float(b)))

        # Streaming exports carry cached conv state between calls — that is
        # what makes contiguous chunks seamless, and also what would leak
        # one job's tail into the next (audit §3). Start clean when the
        # export offers a reset.
        reset = getattr(self.model, "reset", None)
        if callable(reset):
            try:
                reset()
            except Exception:  # noqa: BLE001 — a reset is best-effort
                pass

        chunk = int(CHUNK_S * self.model_sr)
        # Align chunks to the export's latent hop (a power of two ≤ 4096):
        # an unaligned tail makes each chunk round/pad differently and the
        # seams drift (audit §3).
        chunk -= chunk % 4096
        pieces: list[np.ndarray] = []
        total = max(1, (len(mono) + chunk - 1) // chunk)
        with torch.no_grad():
            for i in range(total):
                if cancel.cancelled:
                    raise CancelledError()
                x = torch.from_numpy(
                    mono[i * chunk: (i + 1) * chunk]).reshape(1, 1, -1)
                if mono_b is None:
                    y = self.model(x)
                else:
                    xb = torch.from_numpy(
                        mono_b[i * chunk: (i + 1) * chunk]).reshape(1, 1, -1)
                    z = self.model.encode(x)
                    zb = self.model.encode(xb)
                    y = self.model.decode((1.0 - blend) * z + blend * zb)
                pieces.append(y.squeeze(0).numpy())
                progress_cb(0.1 + 0.8 * (i + 1) / total,
                            (f"morphing through {self.name}" if mono_b
                             is not None else
                             f"re-voicing through {self.name}"))

        progress_cb(0.95, "saving")
        wav = np.concatenate(pieces, axis=-1).T  # (samples, channels)
        label = f"timbre-{self.name}"
        final = os.path.join(out_dir, f"{label}.wav")
        tmp = final + ".part"
        sf.write(tmp, wav, self.model_sr, format="WAV", subtype="PCM_16")
        os.replace(tmp, final)
        return TaskResult(
            artifacts=[Artifact(kind="stem", label=label, path=final,
                                format="wav", sample_rate=self.model_sr,
                                duration_s=round(wav.shape[0] / self.model_sr,
                                                 3))],
            meta={"engine": "rave", "model": self.name})

    def unload(self) -> None:
        self.model = None

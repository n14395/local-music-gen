"""Token Splice Playground: EnCodec codebook recombination (experimental).

Splices the coarse RVQ codebooks of song A with the fine codebooks of song B
and decodes the hybrid token stream. The vendored MLX EnCodec's RVQ decode is
a per-layer embedding sum, so mixed-provenance codes decode without any model
surgery. Deliberately glitchy — this is a creative toy, labeled as such in
the catalog.
"""

from __future__ import annotations

import json
import os

import mlx.core as mx
import numpy as np
import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     ProgressCb, TaskResult)

BANDWIDTH = 6.0          # 8 codebooks on the 24 kHz model — a rich split range


def _load_mono(path: str, target_sr: int) -> np.ndarray:
    from mlx_audio.utils import resample_audio

    audio, sr = sf.read(path, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)
    if sr != target_sr:
        mono = np.asarray(resample_audio(mono, orig_sample_rate=sr,
                                         sample_rate=target_sr),
                          dtype=np.float32)
    return mono


def run(model, params: dict, out_dir: str, progress_cb: ProgressCb,
        cancel: CancelToken) -> TaskResult:
    spec = json.loads(params["splice_spec"])
    a_path, b_path = spec["a"], spec["b"]
    coarse_from = spec.get("coarse_from", "a")
    split = max(1, int(spec.get("split_codebook", 2)))

    def check() -> None:
        if cancel.cancelled:
            raise CancelledError()

    sr = int(model.sampling_rate)
    progress_cb(0.05, "loading audio")
    a = _load_mono(a_path, sr)
    b = _load_mono(b_path, sr)
    n = min(len(a), len(b))
    if n < sr // 2:
        raise ValueError("sources must overlap by at least half a second")
    a, b = a[:n], b[:n]
    check()

    def encode(mono: np.ndarray, frac: float, name: str):
        progress_cb(frac, f"encoding {name} into tokens")
        x = mx.array(mono)[None, :, None]           # (batch, samples, channels)
        mask = mx.ones((1, n), dtype=mx.bool_)
        codes, scales = model.encode(x, padding_mask=mask, bandwidth=BANDWIDTH)
        mx.eval(codes)
        return codes, scales

    a_codes, a_scales = encode(a, 0.2, "A")
    check()
    b_codes, b_scales = encode(b, 0.45, "B")
    check()

    num_q = int(a_codes.shape[2])
    split = min(split, num_q - 1)
    coarse, fine = (a_codes, b_codes) if coarse_from == "a" else (b_codes, a_codes)
    spliced = mx.concatenate([coarse[:, :, :split, :], fine[:, :, split:, :]],
                             axis=2)

    progress_cb(0.7, f"decoding hybrid tokens (split at codebook {split})")
    scales = a_scales if coarse_from == "a" else b_scales
    decoded = model.decode(spliced, scales,
                           padding_mask=mx.ones((1, n), dtype=mx.bool_))
    audio = np.asarray(decoded[0]).reshape(-1)[:n]
    mx.clear_cache()
    check()

    peak = float(np.abs(audio).max())
    if peak > 1e-6:
        audio = audio / max(peak, 0.95) * 0.95

    progress_cb(0.95, "writing audio")
    final = os.path.join(out_dir, "splice.wav")
    sf.write(final + ".part", audio.astype(np.float32), sr,
             format="WAV", subtype="PCM_16")
    os.replace(final + ".part", final)
    return TaskResult(
        artifacts=[Artifact(kind="audio", label="splice", path=final,
                            format="wav", sample_rate=sr,
                            duration_s=round(len(audio) / sr, 3))],
        meta={"split_codebook": split, "num_codebooks": num_q,
              "coarse_from": coarse_from})

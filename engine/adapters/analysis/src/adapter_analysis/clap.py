"""CLAP timbre embedding (analysis-clap variant, laion/larger_clap_music).

One L2-normalized 512-dim vector per asset: cosine similarity between stored
vectors is the scorer's timbral term. Long audio is summarized by mean-pooling
up to three 10 s windows (start / middle / end) — cheap and stable.
"""

from __future__ import annotations

import numpy as np

WINDOW_S = 10.0
CLAP_SR = 48_000

_model = None
_processor = None
_device = None


def _load(snapshot: str):
    global _model, _processor, _device
    if _model is not None:
        return
    import torch
    from transformers import ClapModel, ClapProcessor

    _processor = ClapProcessor.from_pretrained(snapshot)
    model = ClapModel.from_pretrained(snapshot)
    model.eval()
    _device = "mps" if torch.backends.mps.is_available() else "cpu"
    try:
        model = model.to(_device)
    except Exception:  # noqa: BLE001 — CPU is seconds per track
        _device = "cpu"
    _model = model


def embed(mono: np.ndarray, sr: int, snapshot: str) -> list[float]:
    global _device
    import soxr
    import torch

    _load(snapshot)
    if sr != CLAP_SR:
        mono = soxr.resample(mono, sr, CLAP_SR)
    win = int(WINDOW_S * CLAP_SR)
    if len(mono) <= win:
        windows = [mono]
    else:
        mid = (len(mono) - win) // 2
        windows = [mono[:win], mono[mid:mid + win], mono[-win:]]

    vecs = []
    for w in windows:
        inputs = _processor(audios=[np.asarray(w, dtype=np.float32)],
                            sampling_rate=CLAP_SR, return_tensors="pt")
        inputs = {k: v.to(_device) for k, v in inputs.items()}
        with torch.no_grad():
            try:
                feats = _model.get_audio_features(**inputs)
            except Exception:  # noqa: BLE001 — MPS kernel gaps: retry on CPU
                _device = "cpu"
                _model.to("cpu")
                inputs = {k: v.to("cpu") for k, v in inputs.items()}
                feats = _model.get_audio_features(**inputs)
        vecs.append(feats[0].float().cpu().numpy())

    pooled = np.mean(vecs, axis=0)
    norm = float(np.linalg.norm(pooled))
    if norm > 1e-9:
        pooled = pooled / norm
    return [round(float(v), 6) for v in pooled]

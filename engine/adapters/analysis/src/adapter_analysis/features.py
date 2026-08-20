"""Compact spectral features for mashup-compatibility scoring: beat-synchronous
chroma (harmonic overlap across bar offsets) and octave-band energy profile
(spectral complementarity). Both ride the analysis payload additively."""

from __future__ import annotations

import numpy as np

CHROMA_BEAT_CAP = 400          # long songs stride-downsample to stay compact
BAND_BASE_HZ = 60.0
BAND_COUNT = 8


def beat_chroma(chroma_matrix: np.ndarray, beats: list[float], sr: int,
                hop_length: int = 512) -> list[list[int]]:
    """One 12-vector per beat (0–255 quantized), strided to ≤ CHROMA_BEAT_CAP."""
    if chroma_matrix.size == 0 or len(beats) < 2:
        return []
    frames = np.clip((np.asarray(beats) * sr / hop_length).astype(int),
                     0, max(0, chroma_matrix.shape[1] - 1))
    bounds = np.concatenate([frames, [chroma_matrix.shape[1]]])
    stride = max(1, int(np.ceil(len(beats) / CHROMA_BEAT_CAP)))
    out: list[list[int]] = []
    for i in range(0, len(beats), stride):
        a = int(bounds[i])
        b = int(bounds[min(i + stride, len(beats))])
        b = max(b, a + 1)
        v = chroma_matrix[:, a:b].mean(axis=1)
        peak = float(v.max())
        if peak <= 0:
            out.append([0] * 12)
        else:
            out.append([int(x) for x in np.round(255.0 * v / peak)])
    return out


def band_energy(y: np.ndarray, sr: int) -> list[float]:
    """Octave-band mean energies from BAND_BASE_HZ upward, normalized to sum 1."""
    import librosa

    n_fft = 2048
    S = np.abs(librosa.stft(y, n_fft=n_fft)) ** 2
    if S.size == 0:
        return []
    freqs = librosa.fft_frequencies(sr=sr, n_fft=n_fft)
    mean_spec = S.mean(axis=1)
    edges = BAND_BASE_HZ * (2.0 ** np.arange(BAND_COUNT + 1))
    bands = []
    for lo, hi in zip(edges, edges[1:]):
        mask = (freqs >= lo) & (freqs < min(hi, sr / 2))
        bands.append(float(mean_spec[mask].mean()) if mask.any() else 0.0)
    total = sum(bands)
    if total <= 0:
        return [0.0] * BAND_COUNT
    return [round(b / total, 5) for b in bands]

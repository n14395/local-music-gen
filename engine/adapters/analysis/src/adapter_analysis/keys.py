"""Key estimation: averaged chroma correlated against Krumhansl-Schmuckler
profiles, plus the Camelot wheel mapping used for mashup-compatibility UI."""

from __future__ import annotations

import numpy as np

# Krumhansl-Schmuckler key profiles (Krumhansl 1990)
MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                  2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                  2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
PITCHES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

CAMELOT_MAJOR = {"C": "8B", "G": "9B", "D": "10B", "A": "11B", "E": "12B",
                 "B": "1B", "F#": "2B", "C#": "3B", "G#": "4B", "D#": "5B",
                 "A#": "6B", "F": "7B"}
CAMELOT_MINOR = {"A": "8A", "E": "9A", "B": "10A", "F#": "11A", "C#": "12A",
                 "G#": "1A", "D#": "2A", "A#": "3A", "F": "4A", "C": "5A",
                 "G": "6A", "D": "7A"}


def estimate_key(y: np.ndarray, sr: int,
                 chroma_matrix: np.ndarray | None = None) -> dict:
    """-> {key, tonic, mode, camelot, confidence}. Confidence is the
    correlation margin between the best and second-best candidate (0..~0.5);
    typical confusions (relative major/minor) are Camelot-adjacent, so
    downstream compatibility scoring degrades gracefully. Pass chroma_matrix
    to reuse a chroma_cqt already computed by the caller."""
    import librosa

    if chroma_matrix is None:
        chroma_matrix = librosa.feature.chroma_cqt(y=y, sr=sr)
    chroma = chroma_matrix.mean(axis=1)
    if not np.any(chroma):
        return {"key": None, "tonic": None, "mode": None, "camelot": None,
                "confidence": 0.0}
    scores: list[tuple[float, int, str]] = []
    for mode, profile in (("major", MAJOR), ("minor", MINOR)):
        for tonic in range(12):
            r = float(np.corrcoef(np.roll(profile, tonic), chroma)[0, 1])
            scores.append((r, tonic, mode))
    scores.sort(reverse=True)
    (best_r, tonic, mode), (second_r, _t2, _m2) = scores[0], scores[1]
    name = PITCHES[tonic]
    camelot = (CAMELOT_MAJOR if mode == "major" else CAMELOT_MINOR)[name]
    return {"key": f"{name} {mode}", "tonic": name, "mode": mode,
            "camelot": camelot,
            "confidence": round(max(0.0, best_r - second_r), 4)}

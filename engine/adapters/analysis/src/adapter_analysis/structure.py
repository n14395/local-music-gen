"""Structure segmentation: the librosa Laplacian recipe (McFee & Ellis 2014),
beat-synchronized, with scipy k-means (no sklearn dependency). Returns
unlabeled repetition groups (A/B/A form) — semantic labels (verse/chorus)
would come from a dedicated model later."""

from __future__ import annotations

import numpy as np

MIN_BEATS = 16
N_GROUPS = 5          # cap on distinct section groups
MIN_SECTION_BEATS = 8  # merge sections shorter than ~2 bars


def segments(y: np.ndarray, sr: int, beats: list[float],
             duration_s: float) -> list[dict]:
    if len(beats) < MIN_BEATS:
        return [{"start_s": 0.0, "end_s": round(duration_s, 3), "group": "A"}]
    import librosa
    import scipy.cluster.vq
    import scipy.ndimage
    import scipy.sparse.csgraph

    beat_frames = librosa.time_to_frames(np.asarray(beats), sr=sr)
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    beat_frames = np.clip(beat_frames, 0, chroma.shape[1] - 1)
    csync = librosa.util.sync(chroma, beat_frames, aggregate=np.median)

    rec = librosa.segment.recurrence_matrix(csync, width=3, mode="affinity",
                                            sym=True)
    df = librosa.segment.timelag_filter(scipy.ndimage.median_filter)
    rec = df(rec, size=(1, 7))

    mfcc = librosa.feature.mfcc(y=y, sr=sr)
    msync = librosa.util.sync(mfcc, beat_frames)
    path_distance = np.sum(np.diff(msync, axis=1) ** 2, axis=0)
    sigma = np.median(path_distance) or 1.0
    path_sim = np.exp(-path_distance / sigma)
    path = np.diag(path_sim, k=1) + np.diag(path_sim, k=-1)

    deg_path = np.sum(path, axis=1)
    deg_rec = np.sum(rec, axis=1)
    mu = deg_path.dot(deg_path + deg_rec) / max(1e-9, np.sum(
        (deg_path + deg_rec) ** 2))
    affinity = mu * rec + (1 - mu) * path

    lap = scipy.sparse.csgraph.laplacian(affinity, normed=True)
    _evals, evecs = np.linalg.eigh(lap)
    k = min(N_GROUPS, evecs.shape[1])
    basis = evecs[:, :k]
    norms = np.linalg.norm(basis, axis=1, keepdims=True)
    basis = basis / np.maximum(norms, 1e-9)
    _centroids, labels = scipy.cluster.vq.kmeans2(basis, k, minit="++",
                                                  seed=0)

    # beat-index label runs -> sections, merging runs shorter than the minimum
    out: list[dict] = []
    run_start = 0
    for i in range(1, len(labels) + 1):
        if i < len(labels) and labels[i] == labels[run_start]:
            continue
        if out and (i - run_start) < MIN_SECTION_BEATS:
            run_start = i  # absorb the stub into the previous section
            if out:
                out[-1]["end_beat"] = i
            continue
        out.append({"start_beat": run_start, "end_beat": i,
                    "label": int(labels[run_start])})
        run_start = i

    # stable group letters in order of first appearance
    letters: dict[int, str] = {}
    sections = []
    for s in out:
        group = letters.setdefault(
            s["label"], chr(ord("A") + (len(letters) % 26)))
        start_s = beats[s["start_beat"]] if s["start_beat"] < len(beats) else beats[-1]
        end_s = (beats[s["end_beat"]]
                 if s["end_beat"] < len(beats) else duration_s)
        sections.append({"start_s": round(float(start_s), 3),
                         "end_s": round(float(end_s), 3), "group": group})
    if sections:
        sections[0]["start_s"] = 0.0
        sections[-1]["end_s"] = round(duration_s, 3)
    return sections or [{"start_s": 0.0, "end_s": round(duration_s, 3),
                         "group": "A"}]

"""LP-MusicCaps: a music captioner, ten seconds at a time.

The model was trained on 10-second windows and writes one sentence about
each. A three-minute track is therefore not one caption but eighteen, and
the interesting decision is what to do with them: this samples windows
evenly across the whole track and joins the distinct ones, so the result
describes the piece rather than whichever ten seconds happened to be first.
"""

from __future__ import annotations

from engine_protocol.adapter import CancelledError

SAMPLE_RATE = 16_000
WINDOW_S = 10
# Enough to cover an arrangement's changes without turning a caption into a
# paragraph of near-duplicates. Six windows is ~1 s of inference on this Mac.
MAX_WINDOWS = 6


def load(checkpoint: str, bart_snapshot: str):
    import torch

    from .vendor.lpmc.bart import BartCaptionModel

    model = BartCaptionModel(max_length=128, bart_type=bart_snapshot)
    payload = torch.load(checkpoint, map_location="cpu", weights_only=False)
    state = payload.get("state_dict", payload)
    # Checkpoints saved under DistributedDataParallel carry a "module."
    # prefix the plain model does not have.
    if any(k.startswith("module.") for k in state):
        state = {k[len("module."):] if k.startswith("module.") else k: v
                 for k, v in state.items()}
    model.load_state_dict(state)
    model.eval()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    try:
        model = model.to(device)
    except Exception:  # noqa: BLE001 — CPU works, slowly
        device = "cpu"
        model = model.to("cpu")
    return {"model": model, "device": device}


def caption(bundle: dict, src: str, num_beams: int, progress_cb,
            cancel) -> tuple[str, list[str]]:
    """One paragraph about the track, plus the per-window sentences."""
    import numpy as np
    import soundfile as sf
    import soxr
    import torch

    model = bundle["model"]
    device = bundle["device"]

    progress_cb(0.05, "loading audio")
    audio, sr = sf.read(src, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        mono = soxr.resample(mono, sr, SAMPLE_RATE)
    if cancel.cancelled:
        raise CancelledError()

    windows = _windows(mono)
    sentences: list[str] = []
    for index, window in enumerate(windows):
        if cancel.cancelled:
            raise CancelledError()
        progress_cb(round(0.1 + 0.85 * index / len(windows), 3),
                    f"listening: window {index + 1} of {len(windows)}")
        tensor = torch.from_numpy(np.ascontiguousarray(window)).unsqueeze(0)
        with torch.no_grad():
            try:
                out = model.generate(samples=tensor.to(device),
                                     num_beams=num_beams)
            except Exception:  # noqa: BLE001 — MPS kernel gaps: retry on CPU
                bundle["device"] = "cpu"
                model.to("cpu")
                out = model.generate(samples=tensor.to("cpu"),
                                     num_beams=num_beams)
        for line in out:
            text = str(line).strip()
            if text:
                sentences.append(text)

    return _join(sentences), sentences


def _windows(mono):
    """Up to `MAX_WINDOWS` ten-second windows, spread across the track.

    Evenly spaced rather than consecutive: the first minute of a six-minute
    piece is not the piece, and a caption built only from it says so with
    unearned confidence.
    """
    import numpy as np

    size = WINDOW_S * SAMPLE_RATE
    if len(mono) <= size:
        padded = np.zeros(size, dtype="float32")
        padded[:len(mono)] = mono
        return [padded]
    count = min(MAX_WINDOWS, max(1, len(mono) // size))
    if count == 1:
        return [mono[:size]]
    starts = np.linspace(0, len(mono) - size, count).astype(int)
    return [mono[start:start + size] for start in starts]


def _join(sentences: list[str]) -> str:
    """The distinct sentences, in order, as one paragraph.

    Windows of the same song often produce the same sentence; repeating it
    six times would read as a stutter rather than as emphasis.
    """
    seen: set[str] = set()
    kept: list[str] = []
    for sentence in sentences:
        key = sentence.lower().rstrip(".")
        if key in seen:
            continue
        seen.add(key)
        kept.append(sentence if sentence.endswith(".") else sentence + ".")
    return " ".join(kept)

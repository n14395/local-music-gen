"""A HeartMuLa pipeline made of fakes. No weights, no GPU, no heartlib.

The adapter drives `preprocess` / `_forward` / `codec.detokenize` itself and
wraps two hot methods on the way through — `mula.generate_frame` for the LM
and `codec.flow_matching.inference_codes` for the decode. Both wrappers are
looked up on the object at call time, so a fake that calls its own attribute
picks up whatever the adapter installed, which is exactly what these tests
need to observe.
"""

from __future__ import annotations

import torch


class Progress:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def __call__(self, fraction, message, *, phase=None, step=None,
                 steps=None) -> None:
        self.calls.append({"fraction": fraction, "message": message,
                           "step": step, "steps": steps})

    def messages(self, needle: str) -> list[str]:
        return [c["message"] for c in self.calls if needle in c["message"]]

    def fractions(self, needle: str) -> list[float]:
        return [c["fraction"] for c in self.calls
                if needle in c["message"] and c["fraction"] is not None]


class CancelAfter:
    """A cancel token that flips once it has been asked `n` times."""

    def __init__(self, n: int) -> None:
        self.n = n
        self.asks = 0

    @property
    def cancelled(self) -> bool:
        self.asks += 1
        return self.asks > self.n


class FakeMula:
    def __init__(self, frames: int) -> None:
        self.frames = frames
        self.calls = 0

    def generate_frame(self, *a, **kw):
        self.calls += 1
        return None


class FakeFlow:
    def __init__(self) -> None:
        self.calls = 0

    def inference_codes(self, *a, **kw):
        self.calls += 1
        return None


class FakeCodec:
    """`detokenize` runs `windows` flow-matching passes, as upstream does."""

    def __init__(self, windows: int, samples: int = 4800) -> None:
        self.flow_matching = FakeFlow()
        self.windows = windows
        self.samples = samples

    def detokenize(self, frames):
        for _ in range(self.windows):
            self.flow_matching.inference_codes(frames)
        return torch.zeros(2, self.samples)


def codes_for_windows(windows: int) -> int:
    """The frame count whose upstream padding lands on exactly `windows`.

    `_decode_windows` pads to `hop * k + ovlp` with hop 320 and ovlp 52, so
    that expression run forwards is the shortest stream giving `k` windows.
    """
    return 320 * windows + 52


class FakePipe:
    def __init__(self, *, lm_frames: int = 50, windows: int = 5) -> None:
        self.mula = FakeMula(lm_frames)
        self.codec = FakeCodec(windows)
        self.codec_device = torch.device("cpu")
        self.lm_frames = lm_frames
        self.codes = codes_for_windows(windows)
        self.preprocess_kwargs: dict = {}
        self.forward_kwargs: dict = {}

    def preprocess(self, inputs, **kwargs):
        self.preprocess_kwargs = dict(kwargs)
        self.inputs = inputs
        return {"ids": torch.zeros(1, 4, dtype=torch.long)}

    def _forward(self, model_inputs, **kwargs):
        self.forward_kwargs = dict(kwargs)
        for _ in range(self.lm_frames):
            self.mula.generate_frame(model_inputs)
        # (batch, codebooks, frames) — only the last axis is read.
        return {"frames": torch.zeros(1, 8, self.codes, dtype=torch.long)}

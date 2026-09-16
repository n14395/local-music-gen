"""A stand-in for an audiocraft MusicGen/MAGNeT handle.

Records every `set_generation_params` call, because the audit finding this
family carries (09-B2/M44) is entirely about the arguments of the second one.
"""

from __future__ import annotations

import numpy as np
import soundfile as sf
import torch


class FakeModel:
    frame_rate = 50.0

    def __init__(self, sample_rate: int = 8000, seconds: float = 55.0) -> None:
        self.sample_rate = sample_rate
        self.seconds = seconds
        self.params: list[dict] = []
        self.calls: list[str] = []
        self.progress_cb = "unset"

    # what the adapter drives ------------------------------------------------
    def set_generation_params(self, **kwargs) -> None:
        self.params.append(kwargs)

    def set_custom_progress_callback(self, cb) -> None:
        self.progress_cb = cb

    def set_style_conditioner_params(self, **kwargs) -> None:
        self.params.append({"style": kwargs})

    def _audio(self):
        # (batch, channels, samples), the shape audiocraft returns
        return torch.zeros(1, 1, int(self.seconds * self.sample_rate))

    def generate(self, descriptions, progress=False):
        self.calls.append("generate")
        return self._audio()

    def generate_continuation(self, prompt, prompt_rate, descriptions,
                              progress=False):
        self.calls.append("generate_continuation")
        return self._audio()

    def generate_with_chroma(self, descriptions, melody, melody_rate,
                             progress=False):
        self.calls.append("generate_with_chroma")
        return self._audio()


def write_wav(path: str, seconds: float, sample_rate: int = 8000,
              channels: int = 1) -> str:
    t = np.arange(int(seconds * sample_rate), dtype=np.float32) / sample_rate
    tone = 0.2 * np.sin(2 * np.pi * 220.0 * t)
    data = np.tile(tone[:, None], (1, channels))
    sf.write(path, data, sample_rate, format="WAV", subtype="PCM_16")
    return path


def noop_progress(fraction, message, **kwargs) -> None:
    pass

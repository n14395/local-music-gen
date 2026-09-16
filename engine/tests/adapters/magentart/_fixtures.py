"""Fakes for the Magenta RT 2 adapter: no MLX, no weights, no GPU.

`generate()` reaches for three things that are not this adapter's code —
`magenta_rt.config`'s conditioning keys, `mlx.core`'s RNG and the loaded
`MagentaRT2StdMlxfn` handle. All three are injected here so the chunk loop,
which is the code the audit found wrong, can be run for real.
"""

from __future__ import annotations

import sys
import types

import numpy as np


class _Key:
    def __init__(self, key: str) -> None:
        self.key = key


def install_fake_runtime() -> None:
    """Put `magenta_rt.config` and `mlx.core` in sys.modules."""
    if "magenta_rt.config" not in sys.modules:
        config = types.ModuleType("magenta_rt.config")
        config.MUSICCOCA = _Key("musiccoca")
        config.PIANOROLL_WITH_ONSETS = _Key("pianoroll_with_onsets")
        config.DRUM_PIANOROLL = _Key("drum_pianoroll")
        package = types.ModuleType("magenta_rt")
        package.config = config
        sys.modules["magenta_rt"] = package
        sys.modules["magenta_rt.config"] = config
    if "mlx.core" not in sys.modules:
        mlx = types.ModuleType("mlx")
        core = types.ModuleType("mlx.core")
        core.random = types.SimpleNamespace(seed=lambda _s: None)
        mlx.core = core
        sys.modules["mlx"] = mlx
        sys.modules["mlx.core"] = core


SAMPLE_RATE = 48000
SAMPLES_PER_FRAME = SAMPLE_RATE // 25


class FakeWaveform:
    def __init__(self, frames: int) -> None:
        self.sample_rate = SAMPLE_RATE
        self.samples = np.zeros((frames * SAMPLES_PER_FRAME, 2),
                                dtype=np.float32)


class FakeMRT:
    """Records what each chunk was conditioned on."""

    _model = None          # no input_configs: _require_conditioning stands down

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def embed_style(self, style, use_mapper=True):
        return np.ones(4, dtype=np.float32)

    def generate(self, *, conditioning, cfg_scales, temperature, top_k,
                 frames, state):
        self.calls.append({
            "conditioning": {k: (list(v) if isinstance(v, list) else v)
                             for k, v in conditioning.items()},
            "cfg_scales": dict(cfg_scales),
            "frames": frames,
        })
        return FakeWaveform(frames), (state or 0) + 1


def noop_progress(fraction, message, **kwargs) -> None:
    pass


def write_midi(path: str, notes, drums=()) -> str:
    """A MIDI file from (pitch, start, end) tuples plus drum hits."""
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    if notes:
        inst = pretty_midi.Instrument(program=0)
        for pitch, start, end in notes:
            inst.notes.append(pretty_midi.Note(velocity=100, pitch=pitch,
                                               start=start, end=end))
        pm.instruments.append(inst)
    if drums:
        kit = pretty_midi.Instrument(program=0, is_drum=True)
        for start, end in drums:
            kit.notes.append(pretty_midi.Note(velocity=100, pitch=36,
                                              start=start, end=end))
        pm.instruments.append(kit)
    pm.write(path)
    return path

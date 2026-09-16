"""Fakes and tiny inputs for the transcription family's pure helpers."""

from __future__ import annotations


class FakeResponse:
    """What `urllib.request.urlopen` returns, minus the socket."""

    def __init__(self, blocks, content_length: int | None = None) -> None:
        self.blocks = list(blocks)
        self.headers = {}
        if content_length is not None:
            self.headers["Content-Length"] = str(content_length)

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *exc) -> bool:
        return False

    def read(self, _size: int) -> bytes:
        return self.blocks.pop(0) if self.blocks else b""


MB = b"\0" * (1 << 20)


def write_scale_midi(path: str, pitches=(60, 62, 64, 65, 67, 69, 71, 72),
                     beat_s: float = 0.5) -> str:
    """Eight quarter notes at 120 BPM — two bars of 4/4."""
    import pretty_midi

    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0)
    for index, pitch in enumerate(pitches):
        inst.notes.append(pretty_midi.Note(velocity=100, pitch=pitch,
                                           start=index * beat_s,
                                           end=index * beat_s + beat_s))
    pm.instruments.append(inst)
    pm.write(path)
    return path


def write_midi(path: str, notes, bpm: float = 120.0) -> str:
    """Notes as (pitch, start_beat, length_beats) triples, in 4/4 at `bpm`.

    `write_scale_midi` writes the even eight-note case; this is for lengths
    the ABC writer has to work at — five sixteenths, a note across the bar.
    """
    import pretty_midi

    beat_s = 60.0 / bpm
    pm = pretty_midi.PrettyMIDI(initial_tempo=bpm)
    inst = pretty_midi.Instrument(program=0)
    for pitch, start, length in notes:
        inst.notes.append(pretty_midi.Note(
            velocity=100, pitch=pitch, start=start * beat_s,
            end=(start + length) * beat_s))
    pm.instruments.append(inst)
    pm.write(path)
    return path

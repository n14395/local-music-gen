"""MIDI → ABC notation, via music21.

A notation *sketch*, and the copy in the app says so. Transcribed MIDI has no
barlines the transcriber did not infer, no key signature it did not guess, and
quantisation errors that a human engraver would silently fix; ABC written from
it inherits all three. What it is good for is what ABC is good for — reading
the shape of a tune as text, editing it by hand, and handing it to a model
that composes in notation.
"""

from __future__ import annotations

import os

# Beyond this many notes the conversion stops being a sketch and starts being
# a wall — and music21's quantisation gets slower than the transcription that
# produced the file. A truncated tune says so in its header.
MAX_NOTES = 2000


def midi_to_abc(midi_path: str, title: str = "") -> str:
    """The tune as ABC, or "" when music21 cannot make sense of it.

    Never raises: a track that will not convert is one missing artifact on an
    otherwise good transcription, and failing the whole job over the notation
    of one stem would throw away the notes as well.
    """
    try:
        from music21 import converter

        score = converter.parse(midi_path, quantizePost=True)
    except Exception:  # noqa: BLE001 — see the docstring
        return ""

    try:
        notes = len(score.flatten().notes)
        if notes == 0:
            return ""
        if notes > MAX_NOTES:
            score = _truncate(score, MAX_NOTES)
        if title:
            score.metadata = score.metadata or _metadata()
            score.metadata.title = title
        abc = _write_abc(score)
    except Exception:  # noqa: BLE001
        return ""
    if notes > MAX_NOTES:
        abc = (f"% truncated to the first {MAX_NOTES} notes of {notes}\n"
               + abc)
    return abc


def _metadata():
    from music21 import metadata

    return metadata.Metadata()


def _truncate(score, limit: int):
    from music21 import stream

    kept = stream.Score()
    seen = 0
    for part in score.parts:
        new_part = stream.Part()
        for element in part.flatten().notesAndRests:
            new_part.append(element)
            if element.isNote or element.isChord:
                seen += 1
                if seen >= limit:
                    break
        kept.append(new_part)
        if seen >= limit:
            break
    return kept


def _write_abc(score) -> str:
    """music21's ABC writer, read back as text.

    It writes to a temp file of its own choosing, so the file is read and
    removed here rather than left in the user's temp directory.
    """
    path = score.write("abc")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    finally:
        try:
            os.remove(path)
        except OSError:
            pass

"""ABC notation → MIDI, and the tidying a model's raw output needs first.

The conversion is the point at which notation becomes something the rest of
the app can use: a `midi` artifact lands as a notes part, and the SoundFont
renderer turns it into audio. When it fails the text is still real, so the
caller keeps the ABC and says why there is no MIDI.
"""

from __future__ import annotations

import os
import re

# An ABC tune starts at its X: reference number. Models routinely open with a
# sentence of preamble ("Here is a jig in D:"), and music21 will not parse
# past it, so the tune is cut out rather than handed over whole.
_HEADER = re.compile(r"^X:\s*\d+", re.MULTILINE)


def clean(text: str) -> str:
    """The ABC inside whatever the model wrote.

    Drops markdown fences and any preamble before the first `X:` header. A
    reply with no header at all is returned trimmed — it will fail to parse,
    and the caller reports that honestly rather than guessing at a header.
    """
    body = (text or "").strip()
    if "```" in body:
        blocks = [b for b in body.split("```")
                  if "X:" in b or "K:" in b]
        if blocks:
            body = blocks[0]
            # Fenced blocks often open with a language tag on its own line.
            if body.lstrip().lower().startswith("abc"):
                body = body.lstrip()[3:]
    match = _HEADER.search(body)
    if match:
        body = body[match.start():]
    return body.strip()


def to_midi(abc_text: str, out_path: str) -> int:
    """Write `abc_text` as a MIDI file. Returns the note count.

    Raises on anything music21 cannot parse — the caller turns that into
    `meta.midi_error` and keeps the text artifact.
    """
    from music21 import converter

    score = converter.parse(abc_text, format="abc")
    notes = len(score.flatten().notes)
    if notes == 0:
        raise ValueError("the notation contains no notes")
    tmp = out_path + ".part"
    score.write("midi", fp=tmp)
    os.replace(tmp, out_path)
    return notes


def looks_like_abc(text: str) -> bool:
    """Whether a string is notation rather than a description of one.

    Used to decide what a prompt *is*: the ABC cards hand this adapter a tune
    to continue, while the plain compose card hands it a sentence.
    """
    return bool(_HEADER.search(text or "")) or "\nK:" in (text or "")

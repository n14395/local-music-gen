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
    """Well-formed ABC from whatever the model wrote.

    Drops markdown fences and any preamble, then normalises the dialect —
    see `normalise`. A reply with nothing tune-shaped in it comes back empty
    and the caller reports that rather than inventing a tune.
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
    return normalise(body.strip())


# The header fields a tune actually opens with. Used only above the `K:`
# line, where every line is a field by definition — below it, `B3` is a note.
_FIELDS = "XTCOAMLQPZNGHRBDFSUVW"


def normalise(text: str) -> str:
    """Repair the dialects these models write in.

    text-to-music, in particular, emits headers like `L1/8` (no colon) and
    `M:6/8=150` (a tempo folded into the metre), and omits the `X:` reference
    number entirely. Every one of those is a tune no ABC reader will accept,
    including the `music21` parse that turns it into MIDI — but the *music*
    underneath is fine, so it is repaired rather than rejected.
    """
    if not text:
        return ""
    lines = text.split("\n")
    out: list[str] = []
    in_header = True
    for line in lines:
        stripped = line.strip()
        if in_header and stripped:
            # A field letter run straight into its value: `L1/8` → `L:1/8`.
            if len(stripped) > 1 and stripped[0].upper() in _FIELDS \
                    and stripped[1] != ":" and not stripped[1].isalpha() \
                    and "|" not in stripped:
                stripped = f"{stripped[0]}:{stripped[1:]}"
            # A tempo hidden in the metre: `M:6/8=150` → `M:6/8`.
            if stripped[:2].upper() == "M:" and "=" in stripped:
                stripped = stripped.split("=", 1)[0].rstrip()
            if stripped[:2].upper() == "K:":
                in_header = False
        out.append(stripped if in_header or stripped else line)
        if not in_header:
            # Everything from here is body; keep it exactly as written.
            out[-1] = stripped if stripped else line
    body = "\n".join(out).strip()
    if not _HEADER.search(body):
        # Every tune needs a reference number, and no model reliably writes
        # one. Prepended rather than demanded, because its absence says
        # nothing about whether the notation itself is good.
        body = "X:1\n" + body
    return body


# ABC's text annotations: a quoted string whose first character places it
# relative to the staff (^ above, _ below, < left, > right, @ absolute).
# Chord symbols — "D", "A7" — have no such prefix and are left alone.
_ANNOTATION = re.compile(r'"[\^_<>@][^"]*"')


def for_midi(abc_text: str) -> str:
    """The tune with anything music21 cannot read stripped out.

    Only annotations so far: `music21` tries to parse every quoted string as
    a chord symbol and dies on `"^A"` with "Cannot make a step out of '^'".
    They are removed here rather than in `clean`, because they are perfectly
    legal ABC that other tools render — the *stored* notation keeps
    everything the model wrote, and only the conversion sees this.
    """
    return _ANNOTATION.sub("", abc_text or "")


def to_midi(abc_text: str, out_path: str) -> int:
    """Write `abc_text` as a MIDI file. Returns the note count.

    Raises on anything music21 cannot parse — the caller turns that into
    `meta.midi_error` and keeps the text artifact.
    """
    from music21 import converter

    score = converter.parse(for_midi(abc_text), format="abc")
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

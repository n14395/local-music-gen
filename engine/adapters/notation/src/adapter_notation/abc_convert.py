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

# The structural fields that make a string a tune rather than a sentence about
# one. `X:` is not in here on purpose: it is the one field this module invents,
# so counting it would make everything tune-shaped by construction.
_TUNE_FIELD = re.compile(r"^[KML]:", re.MULTILINE | re.IGNORECASE)

# A header line: a field letter, a colon, and its value. `+:` is ABC 2.1's
# continuation of the field above it.
_FIELD_LINE = re.compile(r"^[A-Za-z+]:")


def _carries_notation(text: str) -> bool:
    """Whether a normalised body is notation and not prose about notation."""
    return bool(_HEADER.search(text or "") or _TUNE_FIELD.search(text or ""))


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
    body = normalise(body.strip())
    if not _carries_notation(body):
        # `normalise` used to prepend `X:1` to anything non-empty, so this
        # guard could never fire and a prose reply ("I would write a cheerful
        # waltz in G major.") was filed as ABC: `abc.json` stored the sentence
        # as its text, the preview showed it, and only `meta.midi_error` hinted
        # that anything was wrong.
        return ""
    return body


# The header fields a tune actually opens with. Used only while the header
# scan is still running, where every line is a field by definition — in the
# body, `B3` is a note.
_FIELDS = "XTCOAMLQPZNGHRBDFSUVW"


def normalise(text: str) -> str:
    """Repair the dialects these models write in.

    text-to-music, in particular, emits headers like `L1/8` (no colon) and
    `M:6/8=150` (a tempo folded into the metre), and omits the `X:` reference
    number entirely. Every one of those is a tune no ABC reader will accept,
    including the `music21` parse that turns it into MIDI — but the *music*
    underneath is fine, so it is repaired rather than rejected.

    Text that carries no notation at all is returned as it came, without the
    invented `X:1` — see `_carries_notation`. That is how `clean` can tell
    prose from a tune.
    """
    if not text:
        return ""
    lines = text.split("\n")
    out: list[str] = []
    in_header = True
    for line in lines:
        stripped = line.strip()
        if in_header and stripped and not stripped.startswith("%"):
            # A field letter run straight into its value: `L1/8` → `L:1/8`.
            # Only when what follows is a single run with no spaces in it:
            # `_FIELDS` contains C D F G A B, which are also note letters, so
            # `C2 D2 E2 F2` used to be rewritten as the field `C:2 D2 E2 F2`
            # — and the corrupted text was what got stored and shown, not just
            # what failed to convert.
            if len(stripped) > 1 and stripped[0].upper() in _FIELDS \
                    and stripped[1] != ":" and not stripped[1].isalpha() \
                    and "|" not in stripped \
                    and not re.search(r"\s", stripped[1:]):
                stripped = f"{stripped[0]}:{stripped[1:]}"
            if not _FIELD_LINE.match(stripped):
                # The header ends at the first line that is not field-shaped,
                # not only at `K:`. `K:` was the only terminator, so a tune
                # that omitted it (the very dialect this function exists for)
                # put its entire body through the repair above.
                in_header = False
            else:
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
    if not _carries_notation(body):
        # Nothing to number. This used to prepend `X:1` unconditionally, which
        # made every non-empty reply look like a tune and left `clean`'s "the
        # model wrote nothing that reads as ABC" guard dead code.
        return body
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

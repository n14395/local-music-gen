"""MIDI → ABC notation.

A notation *sketch*, and the copy in the app says so. Transcribed MIDI has no
barlines the transcriber did not infer, no key signature it did not guess, and
quantisation errors a human engraver would silently fix; ABC written from it
inherits all three. What it is good for is what ABC is good for — reading the
shape of a tune as text, editing it by hand, and handing it to a model that
composes in notation.

music21 parses the MIDI and works out metre and key, but it has **no ABC
writer** (`ConverterABC` registers no output extensions — it reads ABC and
cannot emit it), so the serialiser below is ours. It covers what transcribed
music actually contains: notes, rests, chords, ties, accidentals and
barlines. It does not attempt tuplets, voices, ornaments, lyrics or
repeats — a transcriber does not produce them, and guessing would make the
sketch look more authoritative than it is.
"""

from __future__ import annotations

from fractions import Fraction

# Beyond this many notes the sketch stops being readable and music21's
# quantisation gets slower than the transcription that produced the file.
MAX_NOTES = 2000

# The unit note length the body is written in (ABC's `L:` field). An eighth
# note suits transcribed material: most durations come out as small whole
# numbers rather than as fractions.
UNIT = Fraction(1, 2)          # in quarter-lengths

_STEP_TO_ABC = {"C": "C", "D": "D", "E": "E", "F": "F", "G": "G", "A": "A",
                "B": "B"}


def midi_to_abc(midi_path: str, title: str = "") -> str:
    """The tune as ABC, or "" when it cannot be read.

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
        truncated = notes > MAX_NOTES
        return _serialise(score, title=title, limit=MAX_NOTES if truncated
                          else None, total=notes)
    except Exception:  # noqa: BLE001
        return ""


def _serialise(score, title: str, limit: int | None, total: int) -> str:
    """The whole tune: header, then bar-separated body."""
    from music21 import meter

    flat = score.flatten()
    signature = flat.getElementsByClass(meter.TimeSignature).first()
    metre = signature.ratioString if signature else "4/4"
    key_name = _key_of(score)

    lines = ["X:1"]
    if title:
        lines.append(f"T:{_clean(title)}")
    if limit:
        lines.append(f"N:sketch — first {limit} of {total} notes")
    lines.append(f"M:{metre}")
    # `L:` is a note *value*, and UNIT is in quarter-lengths: a unit of 1/2
    # quarter-length is an eighth note, which ABC writes as 1/8.
    unit_value = UNIT / 4
    lines.append(f"L:{unit_value.numerator}/{unit_value.denominator}")
    lines.append(f"K:{key_name}")
    lines.extend(_body(score, limit))
    return "\n".join(lines).strip()


def _key_of(score) -> str:
    """The key as ABC names it, or C when music21 cannot decide.

    Read from the file's own key signature when it has one — a transcriber
    usually writes none — and analysed only as a fallback, because the
    analysis is slow and, on a monophonic stem, frequently wrong.
    """
    from music21 import key as m21key

    found = score.flatten().getElementsByClass(m21key.KeySignature).first()
    if isinstance(found, m21key.Key):
        tonic = found.tonic.name.replace("-", "b").replace("#", "#")
        return tonic + ("m" if found.mode == "minor" else "")
    if found is not None:
        try:
            as_key = found.asKey()
            tonic = as_key.tonic.name.replace("-", "b")
            return tonic + ("m" if as_key.mode == "minor" else "")
        except Exception:  # noqa: BLE001
            pass
    return "C"


def _body(score, limit: int | None) -> list[str]:
    """Bars of notes, four to a line."""
    measures = _measures(score)
    bars: list[str] = []
    written = 0
    for measure in measures:
        tokens: list[str] = []
        for element in measure:
            if limit is not None and written >= limit:
                break
            token = _token(element)
            if token:
                tokens.append(token)
                if element.isNote or element.isChord:
                    written += 1
        if tokens:
            bars.append(" ".join(tokens))
        if limit is not None and written >= limit:
            break
    if not bars:
        return []
    lines = []
    for start in range(0, len(bars), 4):
        lines.append(" | ".join(bars[start:start + 4]) + " |")
    return lines


def _measures(score):
    """The score as a flat list of measures, whatever shape it arrived in.

    Transcribed MIDI often has no measures at all, so one is made; a file
    that does have them keeps its own.
    """
    from music21 import stream

    part = score.parts.first() if score.parts else score
    flat = part.flatten().notesAndRests.stream()
    # Quantise before writing. Transcribed onsets land wherever the audio put
    # them, and unquantised durations serialise as `A17/2` and `z10/3` —
    # technically valid ABC that no one can read. Sixteenths and triplet
    # eighths are the grid transcribed music actually sits on.
    try:
        flat = flat.quantize(quarterLengthDivisors=(4, 3),
                             processOffsets=True, processDurations=True,
                             inPlace=False)
    except Exception:  # noqa: BLE001 — an unquantisable stream is written raw
        pass
    try:
        measured = flat.makeMeasures()
    except Exception:  # noqa: BLE001 — an unmeasurable stream is one long bar
        return [list(flat)]
    out = []
    for measure in measured.getElementsByClass(stream.Measure):
        out.append(list(measure.notesAndRests))
    return out or [list(flat)]


def _token(element) -> str:
    """One note, chord or rest, with its ABC duration."""
    length = _length(element.duration.quarterLength)
    if element.isRest:
        return f"z{length}"
    if element.isChord:
        pitches = "".join(_pitch(p) for p in element.pitches)
        token = f"[{pitches}]{length}"
    elif element.isNote:
        token = f"{_pitch(element.pitch)}{length}"
    else:
        return ""
    # A tie into the next note is a hyphen after this one.
    if getattr(element, "tie", None) is not None \
            and element.tie.type in ("start", "continue"):
        token += "-"
    return token


def _pitch(pitch) -> str:
    """ABC spelling: accidental, letter, octave marks.

    ABC's octaves are relative to middle C, which is a bare capital `C`;
    everything above it is lower case, everything below takes commas.
    """
    letter = _STEP_TO_ABC.get(pitch.step, "C")
    accidental = ""
    if pitch.accidental is not None and pitch.accidental.alter:
        alter = int(pitch.accidental.alter)
        accidental = ("^" if alter > 0 else "_") * min(abs(alter), 2)
    octave = pitch.octave if pitch.octave is not None else 4
    if octave >= 5:
        return accidental + letter.lower() + "'" * (octave - 5)
    return accidental + letter + "," * (4 - octave)


def _length(quarter_length) -> str:
    """A duration as a multiple of the unit note length.

    "" means exactly one unit (the common case, and ABC's default), "2" two
    of them, "/2" half of one, "3/2" a dotted unit.
    """
    try:
        ratio = Fraction(quarter_length).limit_denominator(64) / UNIT
    except (TypeError, ValueError, ZeroDivisionError):
        return ""
    if ratio == 1:
        return ""
    if ratio.denominator == 1:
        return str(ratio.numerator)
    if ratio.numerator == 1:
        return f"/{ratio.denominator}"
    return f"{ratio.numerator}/{ratio.denominator}"


def _clean(text: str) -> str:
    """A title ABC will not choke on: one line, no leading field character."""
    return " ".join(str(text).split())[:60]

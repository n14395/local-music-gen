"""Getting a JSON object back out of a 1.5B model.

A model this size obeys "reply with JSON and nothing else" most of the time,
not all of the time. The failures are boringly repetitive — a markdown fence, a
sentence of preamble, a trailing comma, a chatty line after the closing brace —
and every one of them is recoverable without another forward pass. So the order
is: extract, repair cheaply, and only then spend a second generation.

Nothing here guesses at *content*. If the object cannot be recovered, the caller
is told so and falls back to handing the app the raw text, which is still
useful: the user sees the model's words and edits them by hand. Inventing a
plausible-looking object would be worse than failing, because nothing
downstream could tell it apart from a real answer.
"""

from __future__ import annotations

import json
import re

_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL | re.IGNORECASE)
# Trailing comma before a closing brace/bracket — by far the most common
# malformation, and unambiguous to remove.
_TRAILING_COMMA = re.compile(r",(\s*[}\]])")
# Some chat models still emit a reasoning block even when not asked to.
_THINK = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def _balanced_object(text: str) -> str | None:
    """The first complete `{...}` in the text, respecting strings and escapes.

    A plain regex cannot do this: braces appear inside lyrics, inside prose, and
    inside the section tags this app uses everywhere. Scanning with a depth
    counter that knows when it is inside a string is the only way to find the
    real end of the object.
    """
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    # Unterminated: the model ran out of tokens mid-object. Closing it is a
    # guess about structure only, never about values, and it rescues the common
    # case of one truncated trailing field.
    if depth > 0:
        return text[start:] + "}" * depth
    return None


def extract(text: str) -> dict | None:
    """Best-effort recovery of one JSON object from model output."""
    if not text:
        return None
    text = _THINK.sub("", text).strip()
    candidates: list[str] = []
    fenced = _FENCE.search(text)
    if fenced:
        candidates.append(fenced.group(1).strip())
    balanced = _balanced_object(text)
    if balanced:
        candidates.append(balanced)
    candidates.append(text)

    for raw in candidates:
        for attempt in (raw, _TRAILING_COMMA.sub(r"\1", raw)):
            try:
                value = json.loads(attempt)
            except (ValueError, TypeError):
                continue
            if isinstance(value, dict):
                return value
            # A bare array where an object was asked for: wrap it rather than
            # discard it, under the key the kind most likely wanted. The caller
            # checks its required keys and will reject this if it is wrong.
            if isinstance(value, list):
                return {"items": value}
    return None


def satisfies(value: dict | None, required: tuple[str, ...],
              may_be_empty: tuple[str, ...] = ()) -> bool:
    """Whether a parsed object is worth returning to the app.

    Emptiness counts as absence: a model that emits `{"questions": []}` has
    not answered, and one repair attempt usually fixes it. The exception is a
    key the kind lists in `may_be_empty`, where empty *is* the answer — the
    interview signals "I know enough now" with an empty questions list, and
    calling that malformed used to buy a second cold generation and then report
    the finished interview as `ok: false`, dumping raw JSON where the app meant
    to say "press Write the description". Such a key must still be present, and
    an empty *string* still counts as absence there: the shape asks for a list,
    and `""` is a model that fell apart, not one that finished.
    """
    if not isinstance(value, dict):
        return False
    if not required:
        return bool(value)
    for key in required:
        got = value.get(key)
        if got is None:
            return False
        if key in may_be_empty and not isinstance(got, str):
            continue
        if isinstance(got, (str, list, dict)) and len(got) == 0:
            return False
    return True

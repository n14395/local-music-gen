# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""The jobs the assistant can be asked to do, and the shape each one returns.

One `assist` task carries a `kind`; this module turns that kind plus its input
into a prompt, and declares the JSON shape the answer must take. Keeping both
halves in one place is deliberate — the schema in the prompt and the schema the
parser enforces drift apart the moment they live in different files, and a
silent drift here looks to the user like "the assistant is broken".

Every kind returns a JSON *object* (never a bare array), because a 1.5B model
recovers from a malformed object far more often than from a malformed array,
and because an object leaves room to add fields later without changing what the
app already reads.

The app is the only consumer, and it treats every field as optional: a kind that
comes back missing half its keys still renders. That tolerance is the reason
this can run on a model small enough to sit in the warm pool.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable

from .dialects import Dialect, describe

# The house style, prepended to every kind. Short on purpose: at this size,
# every extra line of system prompt measurably erodes instruction-following on
# the line that actually matters.
_SYSTEM = (
    "You are a songwriting assistant inside a music-generation app. "
    "You help someone describe the music they want, in the exact form the "
    "chosen model understands. "
    "You reply with JSON and nothing else — no preamble, no markdown fences, "
    "no commentary after the closing brace."
)


@dataclass(frozen=True)
class Kind:
    id: str
    # Builds the user-facing half of the prompt from the task input.
    build: Callable[[dict, Dialect, list[str] | None], str]
    # A literal example of the expected object, shown to the model and used by
    # the repair pass. Values are illustrative, not defaults.
    shape: dict
    # Keys the app genuinely needs. A response missing all of them is treated
    # as a failure worth one repair attempt.
    required: tuple[str, ...] = ()
    # Required keys for which an empty value is a real answer, not a failure.
    # Without this the interview's documented exit — "return an empty questions
    # list" — was scored as malformed and reported to the app as `ok: false`.
    may_be_empty: tuple[str, ...] = ()
    # Kinds that write music text need the dialect block; kinds that reason
    # about the library or the app do not, and are cheaper without it.
    needs_dialect: bool = True
    max_tokens: int = 700


def _j(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)


def _brief(inp: dict) -> str:
    """The user's own words, however little of them there are."""
    bits = []
    for key, label in (("idea", "Their idea"), ("prompt", "Their description"),
                       ("notes", "Extra notes")):
        val = str(inp.get(key) or "").strip()
        if val:
            bits.append(f"{label}: {val}")
    return "\n".join(bits) or "They have not said anything specific yet."


# --- 1. Help me describe it -------------------------------------------------

def _interview(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    asked = inp.get("answers") or []
    lines = [
        "Ask the questions that would let you write a good description of the "
        "music this person wants.",
        _brief(inp),
    ]
    if asked:
        lines.append("They have already answered:")
        for a in asked:
            lines.append(f"  Q: {a.get('question')}\n  A: {a.get('answer')}")
        lines.append(
            "Ask only what is still genuinely missing. If you know enough to "
            "write the description, return an empty questions list.")
    else:
        lines.append(
            "Ask between three and five questions. Each must be answerable in "
            "a few words by someone who knows nothing about music production "
            "— no jargon, no talk of models or parameters. Offer example "
            "answers for each.")
    return "\n".join(lines)


def _interview_finish(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    lines = ["Write the final music description from these answers.",
             _brief(inp), "Their answers:"]
    for a in inp.get("answers") or []:
        lines.append(f"  Q: {a.get('question')}\n  A: {a.get('answer')}")
    lines.append(describe(d, lyric_tags=tags))
    return "\n".join(lines)


# --- 2. Flesh out my idea ---------------------------------------------------

def _flesh_out(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    return "\n".join([
        "Turn this rough idea into a full description for the model.",
        _brief(inp),
        "Keep everything they actually said — you are enriching their idea, "
        "not replacing it. Add the instrumentation, mood and production "
        "detail they left implicit.",
        describe(d, lyric_tags=tags),
        "Also list, in `added`, the specific things you added that they did "
        "not say, so they can strike any you disagree with.",
    ])


# --- 3. Write the lyrics with me --------------------------------------------

def _lyrics(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    have = str(inp.get("lyrics") or "").strip()
    lines = ["Write lyrics for this song.", _brief(inp)]
    if have:
        lines.append(f"They have started:\n{have}\nContinue and complete it "
                     "in the same voice, keeping their lines intact.")
    theme = str(inp.get("theme") or "").strip()
    if theme:
        lines.append(f"Theme: {theme}")
    structure = inp.get("structure") or []
    if structure:
        lines.append("Follow this structure: " + ", ".join(str(s) for s in structure))
    lines.append(describe(d, lyric_tags=tags))
    lines.append(
        "Put each section tag on a line of its own, followed by that "
        "section's lines. Return the whole thing as one string in `lyrics`, "
        "with real newlines.")
    return "\n".join(lines)


# --- 4. Which model should I use --------------------------------------------

def _pick_model(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    lines = [
        "Recommend which model this person should use.",
        _brief(inp),
        "The models available to them, as JSON:",
        _j(inp.get("models") or []),
        "Pick the best fit and up to two alternatives. Judge only by what "
        "each model can do — `tags`, `tasks`, whether it does lyrics — and by "
        "whether it is installed. If the best fit is not installed, say so "
        "and name its size, then also give the best installed option. "
        "Use each model's `id` verbatim in your answer.",
    ]
    return "\n".join(lines)


# --- 5. Plan the song first -------------------------------------------------

def _plan_song(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    dur = inp.get("duration_s")
    lines = ["Sketch the shape of this song, section by section.", _brief(inp)]
    if dur:
        lines.append(f"It should run about {int(dur)} seconds in total.")
    lines.append(
        "Give each section a tag, a rough length in seconds, and one line "
        "saying what happens musically. The lengths must add up to roughly "
        "the total. Order them as the song plays.")
    if tags:
        lines.append("Use these tags: " + " ".join(tags))
    return "\n".join(lines)


# --- 6. Say the job in your own words ---------------------------------------

def _route_intent(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    return "\n".join([
        "Work out which of this app's actions the person is asking for.",
        f"They said: {str(inp.get('request') or '').strip()}",
        "The available actions, as JSON:",
        _j(inp.get("actions") or []),
        "Choose the single best action and use its `id` verbatim. If their "
        "request contains a description of music, put it in `prompt`. If it "
        "names something to work on (a song, a stem), put that in `subject`. "
        "If nothing fits, set `action` to null and say why in `reason`. "
        "Never invent an action id that is not in the list.",
    ])


# --- 7. Surprise me with a brief --------------------------------------------

def _brief_kind(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    avoid = inp.get("avoid") or []
    lines = ["Invent a fresh, specific musical idea for someone who is stuck."]
    seed = str(inp.get("nudge") or "").strip()
    if seed:
        lines.append(f"Nudge them in this direction: {seed}")
    if avoid:
        lines.append("They have already seen, so do not repeat: "
                     + "; ".join(str(a) for a in avoid))
    lines.append(
        "Be concrete and a little unexpected — a specific pairing of sound "
        "and feeling, not a genre name. Then write it out as a description "
        "for the model.")
    lines.append(describe(d, lyric_tags=tags))
    return "\n".join(lines)


# --- 12. Sing it in another language ----------------------------------------

def _translate(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    return "\n".join([
        f"Translate these lyrics into {inp.get('language') or 'French'}.",
        str(inp.get("lyrics") or ""),
        "Keep every section tag exactly as it appears, on its own line. "
        "Match the syllable count of each line as closely as you can, so the "
        "translation still fits the melody — a singable near-translation "
        "beats a literal one. Return the whole thing in `lyrics`.",
    ])


# --- 13. Describe this song back to me --------------------------------------

def _describe_song(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    return "\n".join([
        "Describe this piece of music in plain language, for its own owner.",
        "What the app measured:",
        str(inp.get("digest") or "").strip() or "(nothing measured)",
        "Write two or three sentences someone non-technical would recognise "
        "their own song from. Mention tempo feel and mood in words, not "
        "numbers — the numbers are already on screen. Then, separately, "
        "write a `prompt`: the same music described as an instruction to a "
        "generation model.",
        describe(d, lyric_tags=tags),
    ])


# --- 14. More like this one -------------------------------------------------

def _more_like_this(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    return "\n".join([
        "Write descriptions for new music in the same vein as this piece.",
        "What the app measured about the original:",
        str(inp.get("digest") or "").strip() or "(nothing measured)",
        _brief(inp),
        f"Give {int(inp.get('count') or 3)} variations. Each should share the "
        "family resemblance — the feel, the instrumentation, the energy — "
        "while differing in one clear way. Say in `differs` what each one "
        "changes.",
        describe(d, lyric_tags=tags),
    ])


# --- 15. Fix what bothers me ------------------------------------------------

def _critique_fix(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    lines = [
        "Revise a music description to fix what the person disliked.",
        f"The description that produced the last result:\n"
        f"{str(inp.get('prompt') or '').strip()}",
        f"What they disliked: {str(inp.get('complaint') or '').strip()}",
    ]
    plan = str(inp.get("plan") or "").strip()
    if plan:
        lines.append(f"What the model decided last time:\n{plan}")
    digest = str(inp.get("digest") or "").strip()
    if digest:
        lines.append(f"What the app measured in the result:\n{digest}")
    lines.append(
        "Change only what their complaint implies — everything else must "
        "survive word for word. List each change in `changes` as a short "
        "before-and-after so they can see exactly what moved.")
    lines.append(describe(d, lyric_tags=tags))
    return "\n".join(lines)


# --- 16. Name and file it ---------------------------------------------------

def _name_and_tag(inp: dict, d: Dialect, tags: list[str] | None) -> str:
    return "\n".join([
        "Give this piece of music a title and some tags for a library.",
        _brief(inp),
        "What the app measured:",
        str(inp.get("digest") or "").strip() or "(nothing measured)",
        "The title should be short, evocative and specific — something a "
        "person would recognise in a list a year from now. Never use the "
        "words 'untitled', 'track' or 'generated'. Tags are lowercase, one or "
        "two words each: genre, mood, instrumentation, use.",
    ])


KINDS: dict[str, Kind] = {
    "interview": Kind(
        "interview", _interview,
        shape={"questions": [{"question": "What should it feel like?",
                              "examples": ["calm", "triumphant", "eerie"]}],
               "ready": False},
        required=("questions",), may_be_empty=("questions",),
        needs_dialect=False, max_tokens=600),
    "interview_finish": Kind(
        "interview_finish", _interview_finish,
        shape={"prompt": "…", "title": "…"},
        required=("prompt",)),
    "flesh_out": Kind(
        "flesh_out", _flesh_out,
        shape={"prompt": "…", "added": ["brushed drums", "tape saturation"]},
        required=("prompt",)),
    "lyrics": Kind(
        "lyrics", _lyrics,
        shape={"lyrics": "[verse]\n…\n\n[chorus]\n…", "title": "…"},
        required=("lyrics",), max_tokens=1100),
    "pick_model": Kind(
        "pick_model", _pick_model,
        shape={"best": {"id": "acestep-base", "why": "…", "installed": True},
               "alternatives": [{"id": "musicgen-small", "why": "…",
                                 "installed": False}]},
        required=("best",), needs_dialect=False),
    "plan_song": Kind(
        "plan_song", _plan_song,
        shape={"sections": [{"tag": "[intro]", "seconds": 8,
                             "what": "solo piano, no drums"}],
               "summary": "…"},
        required=("sections",), max_tokens=800),
    "route_intent": Kind(
        "route_intent", _route_intent,
        shape={"action": "karaoke", "prompt": None, "subject": "…",
               "confidence": 0.8, "reason": "…"},
        required=("action",), needs_dialect=False, max_tokens=400),
    "brief": Kind(
        "brief", _brief_kind,
        shape={"idea": "…", "prompt": "…", "title": "…"},
        required=("prompt",)),
    "translate_lyrics": Kind(
        "translate_lyrics", _translate,
        shape={"lyrics": "[verse]\n…", "language": "fr"},
        required=("lyrics",), max_tokens=1100),
    "describe_song": Kind(
        "describe_song", _describe_song,
        shape={"description": "…", "prompt": "…"},
        required=("description",)),
    "more_like_this": Kind(
        "more_like_this", _more_like_this,
        shape={"variations": [{"prompt": "…", "differs": "…"}]},
        required=("variations",), max_tokens=900),
    "critique_fix": Kind(
        "critique_fix", _critique_fix,
        shape={"prompt": "…",
               "changes": [{"from": "bright synth", "to": "muted rhodes"}]},
        required=("prompt",)),
    "name_and_tag": Kind(
        "name_and_tag", _name_and_tag,
        shape={"title": "…", "tags": ["dream pop", "hazy", "guitar"]},
        required=("title",), needs_dialect=False, max_tokens=300),
}


def build_messages(kind: Kind, inp: dict, dialect: Dialect,
                   lyric_tags: list[str] | None) -> list[dict]:
    """The chat messages for one assist call.

    The schema goes last, immediately before the model starts writing, because
    that is the instruction it is most likely to still be obeying by the time
    it emits its first token.
    """
    system = _SYSTEM
    if kind.needs_dialect:
        system += ("\n\nThe model they have chosen reads text like this:\n"
                   + describe(dialect, lyric_tags=lyric_tags))
    user = kind.build(inp, dialect, lyric_tags)
    user += ("\n\nReply with exactly this JSON shape, filled in:\n"
             + _j(kind.shape))
    return [{"role": "system", "content": system},
            {"role": "user", "content": user}]

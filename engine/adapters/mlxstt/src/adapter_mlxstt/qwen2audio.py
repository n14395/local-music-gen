# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Captions, answers and tags from Qwen2-Audio (MLX).

The flagship listener: an audio-language model that will describe a track,
answer a question about it, or name what it hears. All three are the same
call with a different instruction, which is why one module serves three
tasks.
"""

from __future__ import annotations

import re

from engine_protocol.adapter import CancelledError

from .textout import preview, write_payload

TARGET_SR = 16_000

CAPTION_PROMPT = (
    "Listen to this music and describe it in two or three sentences. "
    "Name the instruments you hear, the mood, the genre, and the tempo "
    "feel. Describe only what is audible."
)

# One pass per group rather than one prompt asking for all three: a 7B model
# asked for three lists returns two of them and an apology, and the group a
# label belongs to is worth knowing.
TAG_PROMPTS = {
    "genre": "List the musical genres of this track as a comma-separated "
             "list of two or three short labels. Reply with the labels only.",
    "mood": "List the moods of this music as a comma-separated list of two "
            "or three short adjectives. Reply with the adjectives only.",
    "instrument": "List the instruments you can hear as a comma-separated "
                  "list of up to five short names. Reply with the names only.",
}


def run(model, model_id: str, task: str, params: dict, out_dir: str,
        progress_cb, cancel) -> tuple[list[dict], dict]:
    import soundfile as sf
    import soxr

    src = params.get("source_audio")
    if not src:
        raise RuntimeError("source_audio missing")

    progress_cb(0.05, "loading audio")
    audio, sr = sf.read(src, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)
    if sr != TARGET_SR:
        mono = soxr.resample(mono, sr, TARGET_SR)
    if cancel.cancelled:
        raise CancelledError()

    max_tokens = max(32, min(1024, int(params.get("max_tokens") or 256)))
    temperature = _clamp(params.get("temperature"), 0.7, 0.0, 1.5)

    if task == "tag":
        return _tag(model, model_id, mono, out_dir, max_tokens, temperature,
                    progress_cb, cancel)

    question = str(params.get("question") or "").strip()
    prompt = question or CAPTION_PROMPT
    text = _ask(model, mono, prompt, max_tokens, temperature,
                progress_cb, cancel, band=(0.1, 0.95))

    progress_cb(0.97, "writing it down")
    payload = {"text_version": 1, "kind": "caption", "text": text,
               "question": question or None, "model": model_id,
               "engine": "qwen2audio"}
    path = write_payload(out_dir, "caption", payload)
    meta = {"text": payload, "caption_preview": preview(text)}
    if question:
        meta["question"] = question
    progress_cb(1.0, "done")
    return ([{"kind": "text", "label": "caption", "path": path,
              "format": "json"}], meta)


def _tag(model, model_id: str, mono, out_dir: str, max_tokens: int,
         temperature: float, progress_cb, cancel) -> tuple[list[dict], dict]:
    tags: list[dict] = []
    groups = list(TAG_PROMPTS.items())
    for index, (group, prompt) in enumerate(groups):
        low = 0.1 + 0.8 * index / len(groups)
        high = 0.1 + 0.8 * (index + 1) / len(groups)
        answer = _ask(model, mono, prompt, max_tokens, temperature,
                      progress_cb, cancel, band=(low, high),
                      label=f"naming the {group}")
        for label in _labels(answer):
            # No score: this model ranks nothing, and inventing a confidence
            # would make an LLM's guess look like the tagger's measurement.
            tags.append({"label": label, "score": None, "group": group})

    progress_cb(0.97, "writing the tags")
    payload = {"text_version": 1, "kind": "tags", "tags": tags,
               "model": model_id, "engine": "qwen2audio"}
    path = write_payload(out_dir, "tags", payload)
    progress_cb(1.0, "done")
    return ([{"kind": "text", "label": "tags", "path": path,
              "format": "json"}],
            {"text": payload, "top_tags": [t["label"] for t in tags[:6]]})


def _ask(model, mono, prompt: str, max_tokens: int, temperature: float,
         progress_cb, cancel, band: tuple[float, float],
         label: str = "writing") -> str:
    """One prompted pass, with per-token progress inside `band`.

    The ceiling matters: `max_tokens` is a limit, not a prediction, and a
    model that stops early would otherwise leave the bar parked at 40%. The
    fraction is clamped just short of the band's top so it never claims to
    have finished before the text is written.
    """
    low, high = band
    chunks: list[str] = []
    produced = 0
    try:
        stream = model.generate(mono, prompt=prompt, max_tokens=max_tokens,
                                temperature=temperature, stream=True)
        for response in stream:
            if cancel.cancelled:
                raise CancelledError()
            chunks.append(_text_of(response))
            produced += 1
            if produced % 8 == 0:
                span = high - low
                fraction = low + span * min(produced / max_tokens, 0.98)
                progress_cb(round(fraction, 3), label)
    except CancelledError:
        raise
    except (TypeError, ValueError, NotImplementedError):
        # Same fallback as the whisper path: the streaming seam is the part
        # most likely to move between mlx-audio revisions.
        progress_cb(round(low, 3), label)
        result = model.generate(mono, prompt=prompt, max_tokens=max_tokens,
                                temperature=temperature)
        chunks = [_text_of(result)]
    if cancel.cancelled:
        raise CancelledError()
    return "".join(chunks).strip()


def _text_of(response) -> str:
    for attribute in ("text", "segment"):
        value = getattr(response, attribute, None)
        if isinstance(value, str):
            return value
    return str(response) if isinstance(response, str) else ""


def _labels(answer: str) -> list[str]:
    """A model's comma-separated reply, cleaned into labels.

    Defensive on purpose: instruction-following at this size is good, not
    perfect, and a reply that opens with "Sure! Here are the genres:" should
    still yield genres rather than a tag called "sure".
    """
    # Only the leading label of the FIRST line. The condition used to look at
    # the first line while the split ran over the whole answer and kept the
    # piece after the LAST colon anywhere in it, so "Genres: techno, house\n
    # Note: fairly upbeat" came back as the single tag "fairly upbeat".
    text = re.sub(r"^[^:\n]{0,40}:", "", answer, count=1)
    parts: list[str] = []
    for raw in text.replace("\n", ",").split(","):
        label = raw.strip().strip(".;-•*").strip()
        # Numbered lists ("1. techno") and stray articles.
        label = label.lstrip("0123456789. ").strip()
        if not label or len(label) > 32:
            continue
        parts.append(label.lower())
    seen: set[str] = set()
    out: list[str] = []
    for label in parts:
        if label in seen:
            continue
        seen.add(label)
        out.append(label)
    return out[:5]


def _clamp(value, default: float, low: float, high: float) -> float:
    try:
        got = float(value)
    except (TypeError, ValueError):
        return default
    return max(low, min(high, got))

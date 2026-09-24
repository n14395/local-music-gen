# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Lyric transcription with Whisper (MLX).

Whisper is a speech model asked to do a music job, and it does it well on one
condition: give it a voice rather than a band. The card offers to separate the
vocal first for exactly that reason; this module transcribes whatever it is
handed and reports honestly on the result.
"""

from __future__ import annotations

from engine_protocol.adapter import CancelledError

from .textout import preview, write_payload

# Whisper's own working rate. Handing it audio at any other rate makes it
# resample internally, which is the same work done twice.
TARGET_SR = 16_000


def transcribe(model, model_id: str, params: dict, out_dir: str,
               progress_cb, cancel) -> tuple[list[dict], dict]:
    """Returns (artifact specs, meta) for the caller to wrap in a TaskResult."""
    import numpy as np
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

    language = (params.get("language") or "").strip() or None
    translate = bool(params.get("translate"))
    word_timestamps = bool(params.get("word_timestamps"))

    # Biasing the decode toward words we already expect to hear.
    #
    # Whisper conditions on a prefix of "previous text" it believes it has
    # already transcribed, which is the standard way to hand it a vocabulary:
    # names, invented words and the app's own generated lyrics all decode far
    # better when they have been seen once. `hotwords` is the same channel with
    # a list-shaped door — mlx-audio folds it into `initial_prompt` itself
    # (`merge_hotwords`) — so both are offered and either may be used alone.
    #
    # This is a bias, not a constraint: nothing forces the model to emit these
    # words, and a prompt describing music the audio does not contain makes the
    # transcript worse, not better.
    expected = (params.get("expected_words") or "").strip() or None
    hotwords = [word.strip()
                for word in (params.get("hotwords") or "").split(",")
                if word.strip()] or None

    # One decode, not two, and deliberately NOT the streaming seam.
    #
    # The pinned mlx-audio exposes `stream=True`, and teaching this module its
    # AlignAtt chunk shape was the obvious way to put a moving bar on a long
    # transcription. Measured on this machine (2026-09-03, warm model, 45 s of
    # music): one-shot 0.7 s versus streaming 14.0 s — **21× slower** — and the
    # stream yielded three chunks whose committed text was ' Bye', '.', '.'
    # while the same audio decoded in one pass gave whole sentences. The
    # streaming path is an incremental-latency tool, not a throughput one, and
    # at this revision its output is not usable as a transcript.
    #
    # So: decode once, and report the wait honestly with a null fraction (the
    # app draws its indeterminate spinner). A five-minute track costs a few
    # seconds here — the bar the streaming path would have bought is not worth
    # 21× the runtime. Cancel is coarse for the same reason: the decode is one
    # call, so a cancel lands when it returns (seconds), not mid-window.
    progress_cb(None, "translating the words" if translate
                else "listening for words")
    result = model.generate(mono, language=language,
                            task="translate" if translate else "transcribe",
                            return_timestamps=True,
                            word_timestamps=word_timestamps,
                            initial_prompt=expected, hotwords=hotwords)
    if cancel.cancelled:
        raise CancelledError()
    segments = _segments_of(result)
    text_parts = [s["text"] for s in segments]
    detected = _language_of(result) or language
    if not segments:
        # A decode with no per-line timings still has the whole transcript.
        whole = (getattr(result, "text", "") or "").strip()
        text_parts = [whole] if whole else []

    kept, dropped = _drop_hallucinations(segments)
    segments = kept
    if dropped and not kept:
        # Every line was a failed decode: Whisper ran its temperature ladder
        # out and still had no confidence, which is what it does when asked
        # to find words in music that has none. Reporting the invention would
        # be worse than reporting nothing.
        text_parts = []
    elif dropped:
        text_parts = [s["text"] for s in kept]

    text = "\n".join(part.strip() for part in text_parts if part.strip())
    progress_cb(0.97, "writing the words")
    payload = {"text_version": 1, "kind": "lyrics", "text": text,
               "language": detected, "segments": segments,
               "model": model_id, "engine": "whisper"}
    if translate:
        # The transcript is now English regardless of what was sung, and
        # `detected` still names the sung language. Saying so in the payload is
        # the only thing standing between a French song's English translation
        # and a stored document that claims to be its lyrics.
        payload["task"] = "translate"
    path = write_payload(out_dir, "lyrics", payload)
    words = sum(len(s.get("words") or ()) for s in segments)
    meta = {"text": payload, "language": detected,
            "segments": len(segments), "lyrics_preview": preview(text)}
    if words:
        meta["words"] = words
    progress_cb(1.0, "done" if text else "no words heard")
    return ([{"kind": "text", "label": "lyrics", "path": path,
              "format": "json"}], meta)


def _drop_hallucinations(segments: list[dict]) -> tuple[list[dict], int]:
    """Drop lines Whisper itself had no confidence in.

    Asked to find words in music that has none, Whisper does not return
    nothing — it invents, often in another language entirely. The signature
    is its own: the decode fell all the way down the temperature ladder
    (`temperature >= 1.0`, meaning every cooler attempt was rejected) and
    *still* came back under the log-probability threshold it uses to decide
    a decode failed (`avg_logprob < -1.0`). Both of those are Whisper's own
    numbers, reported per segment, so this is the model's judgement rather
    than a threshold invented here.

    Returns the kept segments and how many were dropped.
    """
    kept: list[dict] = []
    dropped = 0
    for segment in segments:
        confidence = segment.pop("_confidence", None)
        if confidence and confidence["temperature"] >= 1.0 \
                and confidence["avg_logprob"] < -1.0:
            dropped += 1
            continue
        kept.append(segment)
    return kept, dropped


def _segments_of(result) -> list[dict]:
    """Whisper's segments, in the payload's own shape.

    Tolerant by construction: `segments` is a list of dicts on the STTOutput
    dataclass today, and every key is read with a default because a missing
    timing is a line worth keeping without one.
    """
    raw = getattr(result, "segments", None) or []
    out: list[dict] = []
    for segment in raw:
        if not isinstance(segment, dict):
            continue
        text = str(segment.get("text") or "").strip()
        if not text:
            continue
        start = segment.get("start", segment.get("start_s"))
        end = segment.get("end", segment.get("end_s"))
        line = {"start_s": round(float(start or 0.0), 3),
                "end_s": round(float(end or start or 0.0), 3),
                "text": text}
        # Per-word timings, present only when the job asked for them (they cost
        # a second cross-attention pass per window). Same `_s` suffixes as the
        # line above rather than upstream's bare `start`/`end`, so one payload
        # does not carry two spellings of "seconds".
        if words := _words_of(segment):
            line["words"] = words
        # Whisper's own confidence, carried only as far as the filter above —
        # popped there, so it never reaches the payload the app stores.
        if "avg_logprob" in segment or "temperature" in segment:
            line["_confidence"] = {
                "avg_logprob": float(segment.get("avg_logprob") or 0.0),
                "temperature": float(segment.get("temperature") or 0.0)}
        out.append(line)
    return out


def _words_of(segment: dict) -> list[dict]:
    """One word with its own start and end, when word timing was asked for.

    Same tolerance as `_segments_of`: a word missing a timing is still a word,
    and the probability is dropped when absent rather than defaulted to a
    number nobody measured.
    """
    out: list[dict] = []
    for word in segment.get("words") or ():
        if not isinstance(word, dict):
            continue
        text = str(word.get("word") or "").strip()
        if not text:
            continue
        start = word.get("start")
        end = word.get("end")
        timed = {"start_s": round(float(start or 0.0), 3),
                 "end_s": round(float(end or start or 0.0), 3),
                 "text": text}
        if (probability := word.get("probability")) is not None:
            timed["confidence"] = round(float(probability), 3)
        out.append(timed)
    return out


# `_segments_of_streaming` lived here: the AlignAtt chunk shape
# (text/is_final/start_time/end_time) that `stream=True` yields at this
# revision. It is gone deliberately — see the measurement in transcribe():
# the streaming decode is 21× slower than one-shot and its committed text
# is unusable, so nothing should read that shape again.


def _language_of(result) -> str | None:
    language = getattr(result, "language", None)
    return str(language) if language else None

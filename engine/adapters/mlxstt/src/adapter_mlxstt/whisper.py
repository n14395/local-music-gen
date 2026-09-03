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
    duration_s = len(mono) / sr if sr else 0.0
    if sr != TARGET_SR:
        mono = soxr.resample(mono, sr, TARGET_SR)
    if cancel.cancelled:
        raise CancelledError()

    language = (params.get("language") or "").strip() or None
    progress_cb(0.1, "listening for words")

    # Streaming for the progress, not for the output: Whisper decodes a
    # 30-second window at a time, and a job with no fraction at all reads as
    # hung on a five-minute track. The fraction is decoded audio over total
    # audio, which is honest and monotonic — unlike a token count, whose
    # ceiling nobody knows until the model stops.
    segments: list[dict] = []
    text_parts: list[str] = []
    detected = language
    try:
        stream = model.generate(mono, language=language, task="transcribe",
                                return_timestamps=True, stream=True)
        for chunk in stream:
            if cancel.cancelled:
                raise CancelledError()
            for segment in (_segments_of(chunk)
                            or _segments_of_streaming(chunk)):
                segments.append(segment)
                text_parts.append(segment["text"])
                if duration_s > 0:
                    fraction = min(0.95, 0.1 + 0.85 * segment["end_s"]
                                   / duration_s)
                    progress_cb(round(fraction, 3), "transcribing")
            detected = _language_of(chunk) or detected
    except CancelledError:
        raise
    except (TypeError, ValueError, NotImplementedError):
        pass   # no streaming seam at this revision; the fallback below runs

    if cancel.cancelled:
        raise CancelledError()

    # The fallback is on the *result*, not only on an exception. A streaming
    # seam that exists but yields chunks in a shape this module does not
    # recognise would otherwise return an empty transcript from a model that
    # heard perfectly well — silent, and indistinguishable from an
    # instrumental. One-shot decoding is the path that always works.
    if not segments:
        progress_cb(None, "transcribing")
        result = model.generate(mono, language=language, task="transcribe",
                                return_timestamps=True)
        segments = _segments_of(result)
        text_parts = [s["text"] for s in segments]
        detected = _language_of(result) or detected
        if not segments:
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
    path = write_payload(out_dir, "lyrics", payload)
    meta = {"text": payload, "language": detected,
            "segments": len(segments), "lyrics_preview": preview(text)}
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
        # Whisper's own confidence, carried only as far as the filter above —
        # popped there, so it never reaches the payload the app stores.
        if "avg_logprob" in segment or "temperature" in segment:
            line["_confidence"] = {
                "avg_logprob": float(segment.get("avg_logprob") or 0.0),
                "temperature": float(segment.get("temperature") or 0.0)}
        out.append(line)
    return out


def _segments_of_streaming(result) -> list[dict]:
    """The AlignAtt streaming shape at this revision: one committed span per
    yield (`text`/`is_final`/`start_time`/`end_time`), no `.segments`. The
    old code did not recognise it, discarded the whole streamed pass, and
    decoded every track a second time (audit §3)."""
    if not getattr(result, "is_final", False):
        return []
    text = str(getattr(result, "text", "") or "").strip()
    if not text:
        return []
    start = float(getattr(result, "start_time", 0.0) or 0.0)
    end = float(getattr(result, "end_time", 0.0) or start)
    return [{"start_s": round(start, 3), "end_s": round(end, 3),
             "text": text}]


def _language_of(result) -> str | None:
    language = getattr(result, "language", None)
    return str(language) if language else None

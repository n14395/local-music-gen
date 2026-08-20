"""Literal recombination: deterministic mixdown of aligned parts.

Consumes the contract's `mix_spec` (docs/api-contract.md §5.4). All musical
analysis (beat grids, BPM, key) happens upstream — this worker only stretches,
shifts, places, sums, normalizes, and limits. Stretching is Rubber Band R3 via
pedalboard (GPL-3.0 — accepted for the engine per project decision); loading a
"model" is instant, so this family is also the cheap real-worker fixture for
the verification suite's task-path checks.
"""

from __future__ import annotations

import json
import os

import numpy as np
import soundfile as sf
import soxr

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

EDGE_FADE_S = 0.002       # de-click fade at chunk/section boundaries
DEFAULT_LUFS = -14.0


class DSPAdapter(ModelAdapter):
    def load(self, progress_cb: ProgressCb) -> None:
        progress_cb(None, "DSP toolchain ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError("the dsp family only runs task jobs")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "mix":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        spec = json.loads(params["mix_spec"])
        target = spec.get("target") or {}
        sr = int(target.get("sample_rate") or 44100)
        target_bpm = _maybe_float(target.get("bpm"))
        target_lufs = _maybe_float(params.get("target_lufs")) or DEFAULT_LUFS
        use_limiter = params.get("limiter", True)
        keep_tracks = bool(params.get("keep_tracks", False))
        tracks = [t for t in (spec.get("tracks") or []) if not t.get("mute")]
        if not tracks:
            raise ValueError("mix_spec contains no audible tracks")

        processed: list[tuple[str, int, np.ndarray]] = []
        for i, track in enumerate(tracks):
            if cancel.cancelled:
                raise CancelledError()
            role = str(track.get("role") or f"track-{i}")
            progress_cb(i / (len(tracks) + 1), f"aligning: {role}")
            audio = self._prepare_track(track, sr, target_bpm, cancel)
            offset_s = _maybe_float(track.get("offset_s")) or 0.0
            if offset_s < 0:
                # Clamping to zero would silently slide one track against every
                # other one — a misalignment the caller can never see. The
                # timeline owns the origin, so it shifts the whole arrangement.
                raise ValueError(
                    f"offset_s must be >= 0 (track '{role}' has {offset_s})")
            # Round in FRAMES, not seconds: rounding first quantized every
            # placement to a whole second (a bar at 124 BPM is 1.935 s).
            processed.append((role, int(round(offset_s * sr)), audio))

        progress_cb(len(tracks) / (len(tracks) + 1), "mixing down")
        end = max(off + len(a) for _r, off, a in processed)
        want = _maybe_float(target.get("duration_s"))
        if want:
            end = max(end, int(want * sr))
        mix = np.zeros((end, 2), dtype=np.float32)
        for _role, off, audio in processed:
            mix[off:off + len(audio)] += _stereo(audio)

        mix = _normalize_loudness(mix, sr, target_lufs)
        if use_limiter:
            from pedalboard import Limiter, Pedalboard
            mix = Pedalboard([Limiter(threshold_db=-1.0)])(mix.T, sr).T
        np.clip(mix, -1.0, 1.0, out=mix)

        artifacts = [self._write(out_dir, "mixdown", mix, sr, kind="audio")]
        if keep_tracks:
            for role, off, audio in processed:
                placed = np.zeros_like(mix)
                placed[off:off + len(audio)] = _stereo(audio)[:len(mix) - off]
                artifacts.append(self._write(out_dir, role, placed, sr,
                                             kind="stem"))
        meta = {"lufs": target_lufs, "duration_s": round(len(mix) / sr, 3)}
        if target_bpm:
            meta["tempo_bpm"] = target_bpm
        return TaskResult(artifacts=artifacts, meta=meta)

    # MARK: per-track pipeline

    def _prepare_track(self, track: dict, sr: int, target_bpm: float | None,
                       cancel: CancelToken) -> np.ndarray:
        audio, in_sr = sf.read(track["source"], dtype="float32", always_2d=True)
        section = track.get("section") or None
        downbeats = [float(d) for d in (track.get("source_downbeats") or [])]
        if section:
            start = max(0.0, _maybe_float(section.get("start_s")) or 0.0)
            stop = _maybe_float(section.get("end_s"))
            stop = stop if stop is not None else len(audio) / in_sr
            audio = audio[int(start * in_sr):int(stop * in_sr)]
            audio = _edge_fade(audio, in_sr)
            downbeats = [d - start for d in downbeats if start <= d <= stop]
        if in_sr != sr:
            audio = soxr.resample(audio, in_sr, sr)
        if cancel.cancelled:
            raise CancelledError()

        stretch = track.get("stretch") or {}
        mode = stretch.get("mode") or "none"
        shift = _maybe_float(track.get("pitch_shift_st")) or 0.0
        source_bpm = _maybe_float(track.get("source_bpm"))
        opts = {"high_quality": True,
                "transient_mode": stretch.get("transient_mode") or "smooth",
                "preserve_formants": stretch.get("preserve_formants", True)}

        if (mode == "beat" and downbeats and len(downbeats) >= 2
                and target_bpm and source_bpm):
            audio = _stretch_piecewise(audio, sr, downbeats, source_bpm,
                                       target_bpm, shift, opts, cancel)
        elif mode in ("beat", "uniform") and target_bpm and source_bpm:
            factor = target_bpm / source_bpm
            audio = _stretch(audio, sr, factor, shift, opts)
        elif abs(shift) > 1e-4:
            audio = _stretch(audio, sr, 1.0, shift, opts)

        # Fades ride on top of the 2 ms de-click, and are applied AFTER
        # stretching so their lengths are target-time seconds — the same time
        # base the caller placed the track in.
        audio = _apply_fades(audio, sr,
                             _maybe_float(track.get("fade_in_s")) or 0.0,
                             _maybe_float(track.get("fade_out_s")) or 0.0)

        gain = 10.0 ** ((_maybe_float(track.get("gain_db")) or 0.0) / 20.0)
        return (audio * gain).astype(np.float32)

    def _write(self, out_dir: str, label: str, audio: np.ndarray, sr: int,
               kind: str) -> Artifact:
        safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in label)
        path = os.path.join(out_dir, f"{safe}.wav")
        sf.write(path + ".part", audio, sr, subtype="PCM_16", format="WAV")
        os.replace(path + ".part", path)
        return Artifact(kind=kind, label=label, path=path, format="wav",
                        sample_rate=sr, duration_s=round(len(audio) / sr, 3))


# MARK: DSP helpers


def _maybe_float(v) -> float | None:
    return float(v) if v is not None else None


def _stereo(audio: np.ndarray) -> np.ndarray:
    if audio.ndim == 1:
        audio = audio[:, None]
    if audio.shape[1] == 1:
        return np.repeat(audio, 2, axis=1)
    return audio[:, :2]


def _edge_fade(audio: np.ndarray, sr: int) -> np.ndarray:
    n = min(len(audio) // 2, max(1, int(EDGE_FADE_S * sr)))
    if n <= 1:
        return audio
    audio = audio.copy()
    ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)[:, None]
    audio[:n] *= ramp
    audio[-n:] *= ramp[::-1]
    return audio


def _apply_fades(audio: np.ndarray, sr: int, fade_in_s: float,
                 fade_out_s: float) -> np.ndarray:
    """Linear amplitude ramps at the head and tail of a track.

    Linear rather than equal-power: the crossfades this produces are usually
    between two placements of the SAME source (a repeated section, a lapped
    duplicate), where linear ramps sum back to exactly the original level and
    equal-power would bulge by 3 dB.
    """
    if fade_in_s <= 0 and fade_out_s <= 0:
        return audio
    n = len(audio)
    if n == 0:
        return audio
    fade_in = min(max(0, int(fade_in_s * sr)), n)
    fade_out = min(max(0, int(fade_out_s * sr)), n)
    if fade_in + fade_out > n:      # overlapping ramps: share the clip
        scale = n / float(fade_in + fade_out)
        fade_in = int(fade_in * scale)
        fade_out = n - fade_in
    audio = audio.copy()
    if fade_in > 1:
        ramp = np.linspace(0.0, 1.0, fade_in, dtype=np.float32)[:, None]
        audio[:fade_in] *= ramp
    if fade_out > 1:
        ramp = np.linspace(1.0, 0.0, fade_out, dtype=np.float32)[:, None]
        audio[-fade_out:] *= ramp
    return audio


def _stretch(audio: np.ndarray, sr: int, factor: float, shift_st: float,
             opts: dict) -> np.ndarray:
    if abs(factor - 1.0) < 1e-4 and abs(shift_st) < 1e-4:
        return audio
    from pedalboard import time_stretch
    out = time_stretch(audio.T.astype(np.float32), sr, stretch_factor=factor,
                       pitch_shift_in_semitones=shift_st, **opts)
    return np.asarray(out).T


def _stretch_piecewise(audio: np.ndarray, sr: int, downbeats: list[float],
                       source_bpm: float, target_bpm: float, shift_st: float,
                       opts: dict, cancel: CancelToken) -> np.ndarray:
    """Per-bar stretching bounds drift to <1 bar and follows tempo wobble in
    the source. Bar length in the target grid is inferred from the source's
    median downbeat interval (beats/bar assumed constant)."""
    intervals = np.diff(downbeats)
    beats_per_bar = max(1, round(float(np.median(intervals)) * source_bpm / 60.0))
    bar_target_s = beats_per_bar * 60.0 / target_bpm
    global_factor = target_bpm / source_bpm

    cuts = [0.0] + [d for d in downbeats if 0.0 < d < len(audio) / sr] \
        + [len(audio) / sr]
    chunks = []
    for a, b in zip(cuts, cuts[1:]):
        if cancel.cancelled:
            raise CancelledError()
        chunk = audio[int(a * sr):int(b * sr)]
        if len(chunk) == 0:
            continue
        is_bar = any(abs(a - d) < 1e-6 for d in downbeats) and (b - a) < 2.5 * (
            60.0 * beats_per_bar / source_bpm)
        factor = (b - a) / bar_target_s if is_bar else global_factor
        chunks.append(_edge_fade(_stretch(chunk, sr, factor, shift_st, opts), sr))
    return np.concatenate(chunks) if chunks else audio


def _normalize_loudness(mix: np.ndarray, sr: int, target_lufs: float) -> np.ndarray:
    import pyloudnorm as pyln
    try:
        meter = pyln.Meter(sr)
        loudness = meter.integrated_loudness(mix.astype(np.float64))
        if np.isfinite(loudness):
            gained = pyln.normalize.loudness(mix.astype(np.float64), loudness,
                                             target_lufs)
            return gained.astype(np.float32)
    except ValueError:
        pass  # input shorter than the gating block — leave levels untouched
    return mix

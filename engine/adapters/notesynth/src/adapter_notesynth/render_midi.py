"""Offline MIDI rendering via TinySoundFont.

NOTE: a twin of this module lives in adapter_transcription (families have
isolated venvs, so sharing means duplication) — keep both in sync.

The Sequencer installs itself as the Synth's generate-callback, so
`synth.generate()` both advances scheduled MIDI events and renders audio —
never call `seq.process()` manually (it double-advances time). MuseScore
General's presets are conservatively attenuated, so we render with headroom
gain and peak-normalize afterwards.
"""

from __future__ import annotations

import hashlib
import os
import urllib.request

import numpy as np

from engine_protocol.adapter import aux_dir

SOUNDFONT_URL = ("https://ftp.osuosl.org/pub/musescore/soundfont/"
                 "MuseScore_General/MuseScore_General.sf3")
SOUNDFONT_NAME = "MuseScore_General.sf3"
SOUNDFONT_MIN_BYTES = 30_000_000       # real file is ~40 MB
# Pinned digest of the verified-good copy (also mirrored at
# hf.co/rtikw/localmusic-assets soundfonts/); the one non-HF download in the
# engine, so integrity is on us.
SOUNDFONT_SHA256 = ("5b85b6c2c61d10b2b91cddd41efcce7b"
                    "25cd31c8271d511c73afafbef20b6fa3")
CHUNK_SAMPLES = 8192
TAIL_S = 2.0
SILENCE_FLOOR = 10 ** (-60 / 20)       # -60 dBFS trim threshold
RENDER_GAIN_DB = 10.0
PEAK_TARGET = 0.9
MAX_RENDER_S = 900.0


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_soundfont(progress_cb=None) -> str:
    """Return the local SoundFont path, downloading it on first use.

    Corrupt files must not poison retries (the separation-family lesson), so
    both a cached copy and a fresh download are sha256-verified: a bad cached
    file is deleted and refetched in the same call; a bad download is deleted
    and reported."""
    path = os.path.join(aux_dir("localmusic-soundfonts"), SOUNDFONT_NAME)
    if os.path.exists(path) and os.path.getsize(path) >= SOUNDFONT_MIN_BYTES:
        if _sha256(path) == SOUNDFONT_SHA256:
            return path
    if os.path.exists(path):
        os.unlink(path)
    tmp = path + ".part"
    try:
        with urllib.request.urlopen(SOUNDFONT_URL, timeout=60) as resp, \
                open(tmp, "wb") as f:
            done = 0
            while True:
                block = resp.read(1 << 20)
                if not block:
                    break
                f.write(block)
                done += len(block)
                if progress_cb is not None:
                    progress_cb(None, f"fetching SoundFont ({done >> 20} MB)")
        if os.path.getsize(tmp) < SOUNDFONT_MIN_BYTES:
            raise OSError("SoundFont download truncated")
        if _sha256(tmp) != SOUNDFONT_SHA256:
            raise OSError("SoundFont failed its sha256 integrity check — "
                          "the download was corrupted, try again")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path


def render_midi(midi_path: str, soundfont_path: str, sample_rate: int = 44100,
                gain_db: float = 0.0, progress_cb=None,
                cancel=None) -> np.ndarray:
    """Render a Standard MIDI file to (frames, 2) float32, peak-normalized."""
    import tinysoundfont as tsf

    synth = tsf.Synth(gain=RENDER_GAIN_DB, samplerate=sample_rate)
    sfid = synth.sfload(soundfont_path)
    # Some writers (SwiftF0 among them) emit no program_change at all, which
    # leaves TSF channels presetless → silence. Preselect Grand Piano
    # everywhere (drum kit on ch 9); real ProgramChange events override.
    for chan in range(16):
        try:
            synth.program_select(chan, sfid, 0, 0, is_drums=(chan == 9))
        except Exception:  # noqa: BLE001 — a missing drum bank must not abort
            synth.program_select(chan, sfid, 0, 0)
    seq = tsf.Sequencer(synth)
    seq.midi_load(midi_path)

    out: list[np.ndarray] = []
    rendered = 0.0
    while not seq.is_empty() and rendered < MAX_RENDER_S:
        if cancel is not None and cancel.cancelled:
            from engine_protocol.adapter import CancelledError
            raise CancelledError()
        out.append(np.frombuffer(synth.generate(CHUNK_SAMPLES),
                                 dtype=np.float32).copy())
        rendered += CHUNK_SAMPLES / sample_rate
        if progress_cb is not None and len(out) % 32 == 0:
            progress_cb(None, f"rendering ({rendered:.0f}s)")
    for _ in range(int(TAIL_S * sample_rate / CHUNK_SAMPLES) + 1):
        out.append(np.frombuffer(synth.generate(CHUNK_SAMPLES),
                                 dtype=np.float32).copy())

    stereo = np.concatenate(out).reshape(-1, 2) if out else \
        np.zeros((1, 2), dtype=np.float32)

    # trim trailing silence below the floor (keep 0.25 s of breathing room)
    level = np.abs(stereo).max(axis=1)
    loud = np.nonzero(level > SILENCE_FLOOR * max(1e-9, level.max()))[0]
    if len(loud):
        stereo = stereo[:min(len(stereo), loud[-1] + int(0.25 * sample_rate))]

    # One combined scale — normalization and gain together, capped so the
    # result never exceeds full scale. The old order normalized to 0.9
    # FIRST and hard-clipped the gain on top, so any gain past ~1 dB was
    # guaranteed distortion while the help text promised a clean level
    # change (audit §3).
    peak = float(np.abs(stereo).max())
    if peak > 1e-6:
        scale = (PEAK_TARGET / peak) * (10.0 ** (gain_db / 20.0))
        stereo = stereo * min(scale, 0.999 / peak)
    return stereo.astype(np.float32)

"""Offline MIDI rendering via TinySoundFont.

NOTE: a twin of this module lives in adapter_notesynth (families have
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

from engine_protocol.adapter import CancelledError, aux_dir

# Two sources, tried in order. The osuosl mirror is MuseScore's own
# distribution and stays first for that reason; the second is our copy of the
# same file (same sha256, checked below either way). One host is a single point
# of failure for a download the whole notes-and-MIDI half of the app needs, and
# the mirror already existed — it simply was never reached for.
SOUNDFONT_URLS = (
    "https://ftp.osuosl.org/pub/musescore/soundfont/"
    "MuseScore_General/MuseScore_General.sf3",
    "https://huggingface.co/rtikw/localmusic-assets/resolve/main/"
    "soundfonts/MuseScore_General.sf3",
)
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
# Where the soft knee starts (twin of the notesynth module).
CEILING = 0.95
# Asymptote of the knee — the loudest a saturated sample can land. Kept just
# below full scale so a meter never reads the saturation as clipping.
CEILING_MAX = 0.995
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
    and reported.

    Sources are tried in order and the digest is checked whichever one
    answered, so falling back to the mirror cannot quietly install a different
    file."""
    path = os.path.join(aux_dir("localmusic-soundfonts"), SOUNDFONT_NAME)
    if os.path.exists(path) and os.path.getsize(path) >= SOUNDFONT_MIN_BYTES:
        if _sha256(path) == SOUNDFONT_SHA256:
            return path
    if os.path.exists(path):
        os.unlink(path)
    tmp = path + ".part"
    failures: list[str] = []
    for index, url in enumerate(SOUNDFONT_URLS):
        try:
            with urllib.request.urlopen(url, timeout=60) as resp, \
                    open(tmp, "wb") as f:
                done = 0
                while True:
                    block = resp.read(1 << 20)
                    if not block:
                        break
                    f.write(block)
                    done += len(block)
                    if progress_cb is not None:
                        progress_cb(None, "fetching SoundFont "
                                          f"({done >> 20} MB)"
                                          + (" from the mirror" if index
                                             else ""))
            if os.path.getsize(tmp) < SOUNDFONT_MIN_BYTES:
                raise OSError("download truncated")
            if _sha256(tmp) != SOUNDFONT_SHA256:
                raise OSError("failed its sha256 integrity check")
            os.replace(tmp, path)
            return path
        except BaseException as e:  # noqa: BLE001 — try the next source
            try:
                os.unlink(tmp)
            except OSError:
                pass
            # A cancel or a keyboard interrupt is not a source being down.
            # CancelledError subclasses Exception, so an isinstance check on
            # Exception used to let it through: a cancel here was recorded as a
            # dead source, the mirror was tried, and the job failed with
            # "could not fetch the SoundFont from any source — host: ; host: "
            # (str(CancelledError()) is empty).
            if isinstance(e, CancelledError) or not isinstance(e, Exception):
                raise
            failures.append(f"{url.split('/')[2]}: {e}")
    raise OSError("could not fetch the SoundFont from any source — "
                  + "; ".join(failures))


# General MIDI programs worth offering by name. The value is the GM program
# number the SoundFont is addressed with; the keys are what the catalog's
# instrument chooser sends. Deliberately a curated couple of dozen rather than
# all 128 — the full GM list is mostly variations nobody picks between, and a
# 128-item menu is not a control.
GM_PROGRAMS = {
    "grand_piano": 0, "electric_piano": 4, "harpsichord": 6, "music_box": 10,
    "vibraphone": 11, "marimba": 12, "drawbar_organ": 16, "church_organ": 19,
    "accordion": 21, "nylon_guitar": 24, "steel_guitar": 25,
    "jazz_guitar": 26, "clean_electric_guitar": 27, "overdriven_guitar": 29,
    "acoustic_bass": 32, "electric_bass": 33, "synth_bass": 38, "violin": 40,
    "cello": 42, "string_ensemble": 48, "choir": 52, "trumpet": 56,
    "trombone": 57, "alto_sax": 65, "flute": 73, "square_lead": 80,
    "saw_lead": 81, "warm_pad": 89, "sitar": 104, "steel_drums": 114,
}


def apply_gain(stereo: np.ndarray, gain_db: float) -> np.ndarray:
    """Peak-normalise to PEAK_TARGET, then apply `gain_db`.

    Kept in step with the notesynth twin (see this module's header): the old
    normalize-then-hard-clip pair made any positive gain pure distortion
    (audit §3), and a plain cap would have made the upper half of the slider
    inert instead. Linear below the ceiling, tanh knee above it.
    """
    peak = float(np.abs(stereo).max())
    if peak > 1e-6:
        stereo = stereo * (PEAK_TARGET / peak) * (10.0 ** (gain_db / 20.0))
        hot = float(np.abs(stereo).max())
        if hot > CEILING:
            # tanh maps the whole range into ±1 and is ~linear near zero, so
            # quiet passages keep their shape while peaks round off. Scaled so
            # the knee starts at CEILING rather than at 0.
            knee = CEILING
            over = np.abs(stereo) > knee
            stereo = np.where(
                over,
                np.sign(stereo) * (knee + (CEILING_MAX - knee)
                                   * np.tanh((np.abs(stereo) - knee)
                                             / max(1e-6, CEILING_MAX - knee))),
                stereo)
    return stereo.astype(np.float32)


def render_midi(midi_path: str, soundfont_path: str, sample_rate: int = 44100,
                gain_db: float = 0.0, instrument: str | None = None,
                progress_cb=None, cancel=None) -> np.ndarray:
    """Render a Standard MIDI file to (frames, 2) float32, peak-normalized.

    `instrument` is a key of GM_PROGRAMS, or None to play the file as written.
    """
    import tinysoundfont as tsf

    program = GM_PROGRAMS.get(instrument or "")
    if instrument and program is None:
        raise RuntimeError(f"unknown instrument '{instrument}'")

    synth = tsf.Synth(gain=RENDER_GAIN_DB, samplerate=sample_rate)
    sfid = synth.sfload(soundfont_path)
    # Some writers (SwiftF0 among them) emit no program_change at all, which
    # leaves TSF channels presetless → silence. Preselect a program everywhere
    # (drum kit on ch 9); real ProgramChange events override.
    default_program = program or 0
    for chan in range(16):
        try:
            synth.program_select(chan, sfid, 0, default_program,
                                 is_drums=(chan == 9))
        except Exception:  # noqa: BLE001 — a missing drum bank must not abort
            synth.program_select(chan, sfid, 0, default_program)
    seq = tsf.Sequencer(synth)
    if program is None:
        seq.midi_load(midi_path)
    else:
        # Preselecting is not enough to override: transcribers write an
        # explicit ProgramChange (pretty_midi emits one per instrument, which
        # is why everything arrived as Grand Piano), and that event would
        # simply undo the choice a bar in. So the events are loaded, rewritten
        # and scheduled. Channel 9 is left alone — it is the drum channel, and
        # a kit is not an instrument you can substitute a flute for.
        events = tsf.midi.load(midi_path)
        for event in events:
            if isinstance(event.action, tsf.midi.ProgramChange) \
                    and event.channel != 9:
                event.action.program = program
        seq.add(events)

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

    return apply_gain(stereo, gain_db)

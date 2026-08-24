"""Audio → MIDI transcription (task "transcribe"), four engines behind one
family: Basic Pitch (CoreML, per-stem), MT3 family via mt3-infer (full-mix
multi-instrument; the unlicensed mt3_pytorch backend is hard-excluded),
Transkun (piano), SwiftF0 (vocal melody). Every MIDI artifact ships with a
SoundFont-rendered `preview:<label>` audio artifact so parts are auditionable
immediately."""

from __future__ import annotations

import json
import os
import subprocess
import sys

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

from .render_midi import ensure_soundfont, render_midi

PREVIEW_SR = 44100
MAX_MT3_TRACKS = 12
MIN_TRACK_NOTES = 8
# the kunato mt3-pytorch backend has no license — never expose it
ALLOWED_MT3_BACKENDS = ("mr_mt3", "yourmt3")

# mt3_infer fetches YourMT3 via git-lfs (often not installed); the same file
# is plain-HTTPS fetchable from the HF Space, staged at the exact relative
# path mt3_infer expects inside MT3_CHECKPOINT_DIR so its downloader is
# skipped entirely.
YOURMT3_CONFIG = ("mc13_256_g4_all_v7_mt3f_sqr_rms_moe_wf4_n8k2_silu_rope"
                  "_rp_b36_nops")
YOURMT3_URL = ("https://huggingface.co/spaces/mimbres/YourMT3/resolve/main/"
               f"amt/logs/2024/{YOURMT3_CONFIG}/checkpoints/last.ckpt")
YOURMT3_MIN_BYTES = 500_000_000


def _stage_yourmt3(progress_cb: ProgressCb) -> None:
    import urllib.request

    ckpt_dir = os.environ["MT3_CHECKPOINT_DIR"]
    path = os.path.join(ckpt_dir, "yourmt3", YOURMT3_CONFIG, "last.ckpt")
    if os.path.exists(path) and os.path.getsize(path) >= YOURMT3_MIN_BYTES:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.unlink(path)
    tmp = path + ".part"
    try:
        with urllib.request.urlopen(YOURMT3_URL, timeout=60) as resp, \
                open(tmp, "wb") as f:
            done = 0
            while True:
                block = resp.read(1 << 20)
                if not block:
                    break
                f.write(block)
                done += len(block)
                if done % (16 << 20) < (1 << 20):
                    progress_cb(0.05, f"fetching YourMT3 ({done >> 20} MB)")
        if os.path.getsize(tmp) < YOURMT3_MIN_BYTES:
            raise OSError("YourMT3 download truncated")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class TranscriptionAdapter(ModelAdapter):
    def load(self, progress_cb: ProgressCb) -> None:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        # mt3-infer reads/writes checkpoints here when no explicit path is given
        os.environ.setdefault("MT3_CHECKPOINT_DIR",
                              os.path.join(base, "mt3-checkpoints"))
        progress_cb(None, "transcription toolkit ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError("transcription models only run task jobs")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "transcribe":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        engine = self.settings.get("engine", "basicpitch")

        progress_cb(0.05, "transcribing")
        if engine == "basicpitch":
            midis = self._basicpitch(src, params, out_dir, progress_cb)
        elif engine == "mt3":
            midis = self._mt3(src, out_dir, progress_cb, cancel)
        elif engine == "transkun":
            midis = self._transkun(src, out_dir, progress_cb)
        elif engine == "swiftf0":
            midis = self._swiftf0(src, out_dir, progress_cb)
        else:
            raise RuntimeError(f"unknown transcription engine '{engine}'")
        if cancel.cancelled:
            raise CancelledError()
        if not midis:
            raise RuntimeError("no notes detected in this audio")

        progress_cb(0.6, "preparing SoundFont")
        sf_path = ensure_soundfont(progress_cb)
        artifacts: list[Artifact] = []
        note_counts: dict[str, int] = {}
        for i, (label, midi_path, notes) in enumerate(midis):
            if cancel.cancelled:
                raise CancelledError()
            note_counts[label] = notes
            artifacts.append(Artifact(kind="midi", label=label,
                                      path=midi_path, format="mid"))
            progress_cb(0.6 + 0.35 * (i + 1) / len(midis),
                        f"rendering preview: {label}")
            audio = render_midi(midi_path, sf_path, sample_rate=PREVIEW_SR,
                                cancel=cancel)
            wav_path = os.path.join(out_dir, f"preview-{_safe(label)}.wav")
            sf.write(wav_path + ".part", audio, PREVIEW_SR, format="WAV",
                     subtype="PCM_16")
            os.replace(wav_path + ".part", wav_path)
            artifacts.append(Artifact(
                kind="audio", label=f"preview:{label}", path=wav_path,
                format="wav", sample_rate=PREVIEW_SR,
                duration_s=round(len(audio) / PREVIEW_SR, 3)))
        meta = {"engine": engine, "tracks": note_counts}
        if params.get("emit_abc"):
            # One text artifact per note track, labeled to pair with its midi
            # the way `preview:<label>` does. Written after the previews so a
            # notation failure can never cost the audio you can already hear.
            progress_cb(0.96, "writing notation (ABC)")
            from .abc_out import midi_to_abc

            wrote = []
            for label, midi_path, _notes in midis:
                abc = midi_to_abc(midi_path, title=label)
                if not abc:
                    continue
                payload = {"text_version": 1, "kind": "abc", "text": abc,
                           "model": self.model_id, "engine": engine}
                path = os.path.join(out_dir, f"abc-{_safe(label)}.json")
                tmp = path + ".part"
                with open(tmp, "w") as f:
                    json.dump(payload, f, ensure_ascii=False)
                os.replace(tmp, path)
                artifacts.append(Artifact(kind="text", label=f"abc:{label}",
                                          path=path, format="json"))
                wrote.append(label)
            meta["abc_tracks"] = wrote
            if not wrote:
                # Legal and worth saying: music21 could make nothing of these
                # notes, and the job still succeeded with the midi it cut.
                meta["abc_error"] = ("no track could be written as notation")
        return TaskResult(artifacts=artifacts, meta=meta)

    # MARK: engines — each returns [(label, midi_path, note_count)]

    def _basicpitch(self, src: str, params: dict, out_dir: str,
                    progress_cb: ProgressCb) -> list:
        from basic_pitch.inference import predict

        _output, pm, _events = predict(src)
        notes = sum(len(inst.notes) for inst in pm.instruments)
        if notes == 0:
            return []
        label = _safe(str(params.get("instrument_label") or "notes"))
        path = os.path.join(out_dir, f"{label}.mid")
        pm.write(path)
        return [(label, path, notes)]

    def _mt3(self, src: str, out_dir: str, progress_cb: ProgressCb,
             cancel: CancelToken) -> list:
        import pretty_midi
        import soxr as _soxr
        from mt3_infer import transcribe

        backend = self.settings.get("backend", "mr_mt3")
        if backend not in ALLOWED_MT3_BACKENDS:
            raise RuntimeError(f"mt3 backend '{backend}' is not allowed")
        checkpoint_path = None
        for snap in self.model_paths.values():
            candidate = os.path.join(snap, "mt3.pth")
            if os.path.exists(candidate):
                checkpoint_path = candidate
        if backend == "yourmt3":
            _stage_yourmt3(progress_cb)
        audio, in_sr = sf.read(src, dtype="float32", always_2d=True)
        mono = audio.mean(axis=1)
        if in_sr != 16000:
            mono = _soxr.resample(mono, in_sr, 16000)
        progress_cb(0.1, f"transcribing ({backend} — this can take a while)")
        try:
            midi = transcribe(mono, model=backend, sr=16000,
                              checkpoint_path=checkpoint_path, device="mps")
        except Exception:
            if cancel.cancelled:
                raise CancelledError() from None
            progress_cb(0.15, f"transcribing ({backend} on CPU)")
            midi = transcribe(mono, model=backend, sr=16000,
                              checkpoint_path=checkpoint_path, device="cpu")
        full = os.path.join(out_dir, "_full.mid")
        midi.save(full)

        pm = pretty_midi.PrettyMIDI(full)
        tracks = []
        for inst in pm.instruments:
            if len(inst.notes) < MIN_TRACK_NOTES:
                continue
            label = "drums" if inst.is_drum else _safe(
                inst.name.strip()
                or pretty_midi.program_to_instrument_name(inst.program))
            tracks.append((label, inst))
        tracks = tracks[:MAX_MT3_TRACKS]
        if not tracks:
            os.unlink(full)
            return []
        out = []
        seen: dict[str, int] = {}
        for label, inst in tracks:
            if label in seen:
                seen[label] += 1
                label = f"{label}-{seen[label]}"
            else:
                seen[label] = 1
            single = pretty_midi.PrettyMIDI()
            single.instruments.append(inst)
            path = os.path.join(out_dir, f"{label}.mid")
            single.write(path)
            out.append((label, path, len(inst.notes)))
        os.unlink(full)
        return out

    def _transkun(self, src: str, out_dir: str,
                  progress_cb: ProgressCb) -> list:
        import pretty_midi

        path = os.path.join(out_dir, "piano.mid")
        progress_cb(0.1, "transcribing (Transkun piano)")
        # transkun's stable surface is its CLI; the worker's process group
        # covers the child on cancel/kill
        subprocess.run([sys.executable, "-m", "transkun.transcribe",
                        src, path], check=True, capture_output=True)
        notes = sum(len(i.notes)
                    for i in pretty_midi.PrettyMIDI(path).instruments)
        return [("piano", path, notes)] if notes else []

    def _swiftf0(self, src: str, out_dir: str,
                 progress_cb: ProgressCb) -> list:
        from swift_f0 import SwiftF0, export_to_midi, segment_notes

        progress_cb(0.1, "detecting melody (SwiftF0)")
        result = SwiftF0(confidence_threshold=0.9).detect_from_file(src)
        notes = segment_notes(result)
        if not notes:
            return []
        path = os.path.join(out_dir, "melody.mid")
        export_to_midi(notes, path, track_name="Melody")
        return [("melody", path, len(notes))]


def _safe(label: str) -> str:
    cleaned = "".join(c if c.isalnum() or c in "-_ " else "-" for c in label)
    return (cleaned.strip().replace(" ", "-").lower() or "notes")

"""MIDI → audio rendering (task "render") through TinySoundFont + MuseScore
General (MIT). Weightless catalog entry: the ~40 MB SoundFont downloads to the
engine cache on first use."""

from __future__ import annotations

import os

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

from .render_midi import ensure_soundfont, render_midi


class NoteSynthAdapter(ModelAdapter):
    def load(self, progress_cb: ProgressCb) -> None:
        progress_cb(None, "note renderer ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError("the notesynth family only runs task jobs")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "render":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        midi_path = params.get("midi_file")
        if not midi_path or not os.path.isfile(midi_path):
            raise RuntimeError("midi_file missing")
        sample_rate = int(params.get("sample_rate", 44100))
        gain_db = float(params.get("gain_db", 0.0))

        progress_cb(0.05, "preparing SoundFont")
        sf_path = ensure_soundfont(progress_cb)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(0.2, "rendering notes")
        audio = render_midi(midi_path, sf_path, sample_rate=sample_rate,
                            gain_db=gain_db, progress_cb=None, cancel=cancel)

        progress_cb(0.9, "writing audio")
        final = os.path.join(out_dir, "render.wav")
        sf.write(final + ".part", audio, sample_rate, format="WAV",
                 subtype="PCM_16")
        os.replace(final + ".part", final)
        duration = round(len(audio) / sample_rate, 3)
        return TaskResult(
            artifacts=[Artifact(kind="audio", label="render", path=final,
                                format="wav", sample_rate=sample_rate,
                                duration_s=duration)],
            meta={"duration_s": duration})

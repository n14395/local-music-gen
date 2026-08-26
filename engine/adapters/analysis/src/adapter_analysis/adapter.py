"""Musical analysis: beats/downbeats (beat_this), BPM, key/Camelot, structure
sections, and integrated loudness — the metadata layer that powers part
badges and literal-recombine alignment.

The beat_this checkpoint ("final0", ~78 MB) is fetched by the package itself
into TORCH_HOME on first use (CPJKU hosting; no HF mirror exists with the
.ckpt format).  TODO(assets-mirror): once the user-owned HF mirror hosts
final0.ckpt, add it to the catalog entry and pass the snapshot path here.
"""

from __future__ import annotations

import json
import os

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

from . import features, keys, structure

# BTC's chord vocabulary is root:quality over exactly these 14 qualities
# (large voca; majmin uses the first two). Pitches are intervals over a
# root near C3 — a bed register that stays out of a melody's way.
_CHORD_ROOTS = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3,
                "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8,
                "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}
_CHORD_QUALITIES = {
    "": (0, 4, 7), "maj": (0, 4, 7), "min": (0, 3, 7),
    "dim": (0, 3, 6), "aug": (0, 4, 8),
    "sus2": (0, 2, 7), "sus4": (0, 5, 7),
    "maj6": (0, 4, 7, 9), "min6": (0, 3, 7, 9),
    "7": (0, 4, 7, 10), "maj7": (0, 4, 7, 11), "min7": (0, 3, 7, 10),
    "dim7": (0, 3, 6, 9), "hdim7": (0, 3, 6, 10),
    "minmaj7": (0, 3, 7, 11),
}


def _chord_pitches(symbol: str) -> list[int]:
    """MIDI pitches for a BTC chord symbol; [] for N (no chord) / X
    (unclear). An unrecognised quality degrades to the bare root rather
    than guessing a colour the model did not name."""
    if symbol in ("N", "X"):
        return []
    root, _, quality = symbol.partition(":")
    semitone = _CHORD_ROOTS.get(root.split("/")[0].strip())
    if semitone is None:
        return []
    intervals = _CHORD_QUALITIES.get(quality.split("/")[0].strip(), (0,))
    return [48 + semitone + i for i in intervals]


class AnalysisAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._audio2beats = None
        self._btc = None    # (model, mean, std, vocab) once the mode loads
        self._squim = None

    def load(self, progress_cb: ProgressCb) -> None:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        os.environ.setdefault("TORCH_HOME", os.path.join(base, "torch-cache"))
        progress_cb(None, "analysis toolkit ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError("analysis models only support task jobs")

    def _beats(self, mono: np.ndarray, sr: int,
               progress_cb: ProgressCb) -> tuple[list[float], list[float]]:
        import torch
        from beat_this.inference import Audio2Beats

        if self._audio2beats is None:
            device = "mps" if torch.backends.mps.is_available() else "cpu"
            checkpoint = self.settings.get("checkpoint", "final0")
            # The catalog snapshot (assets mirror) wins over beat_this's own
            # Nextcloud download: real install-state, resumable fetch.
            for snap in self.model_paths.values():
                cand = os.path.join(snap, "analysis", "beat_this-final0.ckpt")
                if os.path.exists(cand):
                    checkpoint = cand
                    break
            # a real fraction, not None: indeterminate coerces to 0.0 on the
            # wire, which would walk progress backwards. This helper runs from
            # inside the beat-tracking step, so it sits after that step's 0.15.
            progress_cb(0.2, "loading beat model (downloads on first use)")
            try:
                self._audio2beats = Audio2Beats(checkpoint_path=checkpoint,
                                                device=device, dbn=False)
            except Exception:
                # MPS kernels are unproven for this model; CPU is seconds/track
                self._audio2beats = Audio2Beats(checkpoint_path=checkpoint,
                                                device="cpu", dbn=False)
        beats, downbeats = self._audio2beats(mono, sr)
        return ([round(float(b), 4) for b in np.asarray(beats).ravel()],
                [round(float(b), 4) for b in np.asarray(downbeats).ravel()])

    def _clap_snapshot(self) -> str | None:
        """The CLAP snapshot among this entry's repos, if it has one."""
        if not self.model_paths:
            return None
        return next((p for r, p in self.model_paths.items()
                     if "clap" in r.lower()),
                    next(iter(self.model_paths.values())))

    def _cache_dir(self, name: str) -> str:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        d = os.path.join(base, name)
        os.makedirs(d, exist_ok=True)
        return d

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task == "tag":
            return self._run_tag(params, out_dir, progress_cb, cancel)
        if task == "transcribe" and self.settings.get("mode") == "chords":
            # The chords entry's second face: the same recognition, rendered
            # as a MIDI chord bed the parts library can play and stack.
            return self._run_chords_midi(params, out_dir, progress_cb, cancel)
        if task != "analyze":
            raise NotImplementedError(f"unsupported task '{task}'")
        # Specialist analyze modes: same family (their torch stack is this
        # venv), different question — the mode rides catalog settings the way
        # the separation family's engine switch does.
        mode = self.settings.get("mode")
        if mode == "chords":
            return self._run_chords(params, out_dir, progress_cb, cancel)
        if mode == "squim":
            return self._run_squim(params, out_dir, progress_cb, cancel)
        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        deep = bool(params.get("deep", True))

        def check() -> None:
            if cancel.cancelled:
                raise CancelledError()

        progress_cb(0.05, "loading audio")
        audio, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = audio.mean(axis=1)
        duration_s = len(mono) / sr
        check()

        progress_cb(0.15, "tracking beats")
        beats, downbeats = self._beats(mono, sr, progress_cb)
        tempo_bpm = None
        if len(beats) >= 2:
            intervals = np.diff(np.asarray(beats))
            median = float(np.median(intervals))
            if median > 0:
                tempo_bpm = round(60.0 / median, 2)
        check()

        progress_cb(0.5, "estimating key")
        import librosa
        chroma_matrix = librosa.feature.chroma_cqt(y=mono, sr=sr)
        key_info = keys.estimate_key(mono, sr, chroma_matrix=chroma_matrix)
        chroma = features.beat_chroma(chroma_matrix, beats, sr)
        band = features.band_energy(mono, sr)
        check()

        sections: list[dict] = []
        if deep:
            progress_cb(0.7, "analyzing structure")
            sections = structure.segments(mono, sr, beats, duration_s)
            check()

        clap_vec = None
        prompt_score = None
        prompt_text = str(params.get("prompt_text") or "").strip()
        snapshot = self._clap_snapshot()
        if self.settings.get("embed") == "clap" and snapshot:
            progress_cb(0.82, "computing timbre embedding (CLAP)")
            from . import clap
            clap_vec = clap.embed(mono, sr, snapshot)
            check()
            if prompt_text:
                # The same encoder, one more sentence: how close the audio
                # landed to the words that asked for it.
                progress_cb(0.86, "scoring against the prompt")
                from . import tagging
                prompt_score = tagging.prompt_score(clap_vec, prompt_text,
                                                    snapshot)
                check()

        progress_cb(0.9, "measuring loudness")
        lufs = None
        if duration_s >= 0.5:
            import pyloudnorm
            meter = pyloudnorm.Meter(sr)
            loudness = float(meter.integrated_loudness(audio))
            if np.isfinite(loudness):
                lufs = round(loudness, 2)

        payload = {"tempo_bpm": tempo_bpm, "beats": beats,
                   "downbeats": downbeats, "key": key_info["key"],
                   "camelot": key_info["camelot"],
                   "key_confidence": key_info["confidence"],
                   "sections": sections, "lufs": lufs,
                   "chroma": chroma, "band_energy": band,
                   "duration_s": round(duration_s, 3), "sample_rate": int(sr),
                   "analysis_version": 3 if clap_vec is not None else 2}
        if clap_vec is not None:
            payload["clap"] = clap_vec
        if prompt_score is not None:
            # The text is echoed beside the number: a score means nothing
            # without knowing what it was measured against, and it is what
            # lets a client skip re-scoring the same prompt.
            payload["clap_prompt_score"] = prompt_score
            payload["clap_prompt"] = prompt_text
        final = os.path.join(out_dir, "analysis.json")
        tmp = final + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, final)

        meta = {"tempo_bpm": tempo_bpm, "key": key_info["key"],
                "camelot": key_info["camelot"]}
        if prompt_score is not None:
            meta["clap_prompt_score"] = prompt_score
            meta["clap_prompt"] = prompt_text
        return TaskResult(
            artifacts=[Artifact(kind="analysis", label="analysis", path=final,
                                format="json")],
            meta=meta)

    def _recognize_chords(self, params: dict, progress_cb: ProgressCb,
                          cancel: CancelToken) -> tuple[list[dict], float]:
        """Load audio + BTC, return (segments, duration_s). Shared by the
        analyze (JSON payload) and transcribe (MIDI part) routes."""
        def check() -> None:
            if cancel.cancelled:
                raise CancelledError()

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        large_voca = str(self.settings.get("voca", "large")) == "large"

        from . import btc

        if getattr(self, "_btc", None) is None:
            cache = self._cache_dir("btc-chords")
            # The catalog entry ships both checkpoints in the assets-mirror
            # snapshot (rtikw/localmusic-assets, analysis/btc_model*.pt —
            # unmodified mirrors of the MIT files committed in the upstream
            # repo). Staging them into the cache under the names btc.load
            # expects means its GitHub download never fires.
            for snap in self.model_paths.values():
                for name in ("btc_model.pt", "btc_model_large_voca.pt"):
                    staged = os.path.join(snap, "analysis", name)
                    dst = os.path.join(cache, name)
                    if os.path.exists(staged) and not os.path.exists(dst):
                        try:
                            os.symlink(staged, dst)
                        except OSError:
                            pass
            progress_cb(0.05, "loading the chord model "
                              "(12 MB; downloads on first use)")
            self._btc = btc.load(cache, large_voca, progress_cb)
        check()

        progress_cb(0.1, "loading audio")
        audio, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = audio.mean(axis=1)
        check()

        segments = btc.recognize(self._btc, mono, sr, progress_cb, check)
        return segments, len(mono) / sr

    def _run_chords(self, params: dict, out_dir: str, progress_cb: ProgressCb,
                    cancel: CancelToken) -> TaskResult:
        """Chord segments via the vendored BTC transformer (see btc.py)."""
        segments, duration_s = self._recognize_chords(params, progress_cb,
                                                      cancel)
        large_voca = str(self.settings.get("voca", "large")) == "large"

        progress_cb(0.95, "writing the chord track")
        payload = {"chords_version": 1, "segments": segments,
                   "vocabulary": "large" if large_voca else "majmin",
                   "duration_s": round(duration_s, 3),
                   "model": self.model_id, "engine": "btc"}
        final = os.path.join(out_dir, "analysis.json")
        tmp = final + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, final)

        played = [s["chord"] for s in segments if s["chord"] not in ("N", "X")]
        preview = []
        for chord in played:
            if not preview or preview[-1] != chord:
                preview.append(chord)
        return TaskResult(
            artifacts=[Artifact(kind="analysis", label="chords", path=final,
                                format="json")],
            meta={"n_segments": len(segments),
                  "chords_preview": " ".join(preview[:12])})

    def _run_chords_midi(self, params: dict, out_dir: str,
                         progress_cb: ProgressCb,
                         cancel: CancelToken) -> TaskResult:
        """The recognised chords as a root-position MIDI chord bed.

        A part you can hear and stack, not a performance: each segment
        becomes one block chord held for its span. N and X segments are
        rests.
        """
        segments, _ = self._recognize_chords(params, progress_cb, cancel)

        progress_cb(0.95, "writing the chord part")
        import pretty_midi

        pm = pretty_midi.PrettyMIDI()
        inst = pretty_midi.Instrument(program=0, name="Chords")
        for seg in segments:
            for pitch in _chord_pitches(seg["chord"]):
                inst.notes.append(pretty_midi.Note(
                    velocity=80, pitch=pitch,
                    start=float(seg["start_s"]), end=float(seg["end_s"])))
        pm.instruments.append(inst)
        final = os.path.join(out_dir, "chords.mid")
        tmp = final + ".part"
        pm.write(tmp)
        os.replace(tmp, final)

        return TaskResult(
            artifacts=[Artifact(kind="midi", label="chords", path=final,
                                format="mid")],
            meta={"n_segments": len(segments), "n_notes": len(inst.notes)})

    def _run_squim(self, params: dict, out_dir: str, progress_cb: ProgressCb,
                   cancel: CancelToken) -> TaskResult:
        """Reference-free quality scores (torchaudio SQUIM objective).

        Trained on speech: the numbers rank takes of the same material
        usefully but are not absolute music-quality truth, and the payload
        says so.
        """
        def check() -> None:
            if cancel.cancelled:
                raise CancelledError()

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")

        import soxr
        import torch

        if getattr(self, "_squim", None) is None:
            progress_cb(0.05, "loading SQUIM (downloads on first use)")
            os.environ.setdefault("TORCH_HOME",
                                  self._cache_dir("torch-cache"))
            from torchaudio.pipelines import SQUIM_OBJECTIVE

            self._squim = SQUIM_OBJECTIVE.get_model()
            self._squim.eval()
        check()

        progress_cb(0.3, "loading audio")
        audio, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = audio.mean(axis=1)
        if sr != 16000:
            mono = soxr.resample(mono, sr, 16000)
        check()

        progress_cb(0.5, "scoring")
        with torch.no_grad():
            stoi, pesq, si_sdr = self._squim(
                torch.from_numpy(mono).float().unsqueeze(0))
        check()

        payload = {"quality_version": 1,
                   "stoi": round(float(stoi.item()), 4),
                   "pesq": round(float(pesq.item()), 3),
                   "si_sdr": round(float(si_sdr.item()), 2),
                   "caveat": "speech-trained; compare takes, don't grade art",
                   "model": self.model_id, "engine": "squim"}
        final = os.path.join(out_dir, "analysis.json")
        tmp = final + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, final)

        progress_cb(1.0, "done")
        return TaskResult(
            artifacts=[Artifact(kind="analysis", label="quality", path=final,
                                format="json")],
            meta={"stoi": payload["stoi"], "pesq": payload["pesq"],
                  "si_sdr": payload["si_sdr"]})

    def _run_tag(self, params: dict, out_dir: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> TaskResult:
        """Genre / mood / instrument labels, zero-shot against CLAP.

        No beat tracking, no key estimation, no structure: this task embeds
        the audio once and scores it against three vocabularies, which is a
        second or two rather than the analyze pass's tens of them.
        """
        def check() -> None:
            if cancel.cancelled:
                raise CancelledError()

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        snapshot = self._clap_snapshot()
        if not snapshot:
            raise RuntimeError("tagging needs the CLAP model snapshot")
        top_k = max(1, min(15, int(params.get("top_k") or 5)))

        progress_cb(0.05, "loading audio")
        audio, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = audio.mean(axis=1)
        check()

        progress_cb(0.1, "listening (CLAP)")
        from . import clap, tagging
        audio_vector = clap.embed(mono, sr, snapshot)
        check()

        tags = tagging.zero_shot(audio_vector, snapshot, top_k=top_k,
                                 progress_cb=progress_cb, check=check)

        progress_cb(0.95, "writing tags")
        payload = {"text_version": 1, "kind": "tags", "tags": tags,
                   "model": self.model_id, "engine": "clap-zeroshot"}
        final = os.path.join(out_dir, "tags.json")
        tmp = final + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, final)

        progress_cb(1.0, "done")
        # The whole payload rides meta as well as the file (contract 5.4), so
        # a client that keeps job results never has to read the disk.
        return TaskResult(
            artifacts=[Artifact(kind="text", label="tags", path=final,
                                format="json")],
            meta={"text": payload,
                  "top_tags": [t["label"] for t in tags[:6]]})

    def unload(self) -> None:
        self._audio2beats = None
        self._btc = None
        self._squim = None

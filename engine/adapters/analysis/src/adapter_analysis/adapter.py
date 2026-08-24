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


class AnalysisAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._audio2beats = None

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

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task == "tag":
            return self._run_tag(params, out_dir, progress_cb, cancel)
        if task != "analyze":
            raise NotImplementedError(f"unsupported task '{task}'")
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

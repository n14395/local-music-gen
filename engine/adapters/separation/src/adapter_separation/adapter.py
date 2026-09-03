"""Stem separation: Demucs (4/6-stem) and RoFormer 2-stem via audio-separator.

settings.engine selects the backend:
  {"engine": "demucs",   "model": "htdemucs" | "htdemucs_ft" | "htdemucs_6s"}
  {"engine": "roformer", "checkpoint": "<audio-separator registry filename>"}

Weights are fetched by the backends themselves on first use (demucs: HF hub
with fbaipublicfiles fallback; audio-separator: its own registry, ckpt+yaml
pairs). Caches are steered into the engine's data dir so wiping the data dir
is a clean slate.  TODO(assets-mirror): point catalog entries at the user-owned
HF mirror once it exists so install-state becomes real for these families.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir, clear_stale_link)


class SeparationAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._separator = None  # lazily built; survives across jobs (warm worker)
        # demucs' Separator captures its callback at construction; this
        # trampoline lets each job swap in its own progress/cancel closure
        # without rebuilding the (weight-holding) Separator.
        self._callback_holder: dict = {"cb": None}

    def load(self, progress_cb: ProgressCb) -> None:
        # Demucs consults TORCH_HOME for its checkpoint cache.
        os.environ.setdefault("TORCH_HOME", aux_dir("torch-cache"))
        progress_cb(None, "separation runtime ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError("separation models only support task jobs")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "separate":
            raise NotImplementedError(f"unsupported task '{task}'")
        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        engine = self.settings.get("engine", "demucs")
        if engine == "demucs":
            return self._run_demucs(src, params, out_dir, progress_cb, cancel)
        if engine == "roformer":
            return self._run_roformer(src, out_dir, progress_cb, cancel)
        raise RuntimeError(f"unknown separation engine '{engine}'")

    # MARK: demucs

    def _run_demucs(self, src: str, params: dict, out_dir: str,
                    progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        import torch
        from demucs.api import Separator

        model_name = self.settings.get("model", "htdemucs")
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        shifts = max(1, min(5, int(params.get("shifts", 1))))

        def callback(info: dict) -> None:
            if cancel.cancelled:
                raise CancelledError()
            if info.get("state") != "end":
                return
            models = max(1, int(info.get("models", 1) or 1))
            idx = int(info.get("model_idx_in_bag", 0) or 0)
            length = max(1, int(info.get("audio_length", 1) or 1))
            offset = min(int(info.get("segment_offset", 0) or 0), length)
            fraction = (idx + offset / length) / models
            progress_cb(min(0.98, fraction), f"separating ({model_name})")

        self._callback_holder["cb"] = callback

        def trampoline(info: dict, holder=self._callback_holder) -> None:
            cb = holder.get("cb")
            if cb is not None:
                cb(info)

        if self._separator is None or getattr(self, "_sep_key", None) != (model_name, shifts):
            progress_cb(None, f"loading {model_name} (downloads on first use)")
            self._separator = Separator(model=model_name, device=device,
                                        shifts=shifts, callback=trampoline)
            self._sep_key = (model_name, shifts)

        try:
            _origin, stems = self._separator.separate_audio_file(Path(src))
        except CancelledError:
            raise
        except Exception:
            if cancel.cancelled:
                raise CancelledError() from None
            raise

        sample_rate = int(self._separator.samplerate)
        artifacts: list[Artifact] = []
        for name, tensor in stems.items():
            if cancel.cancelled:
                raise CancelledError()
            wav = tensor.cpu().numpy().T  # (samples, channels)
            final = os.path.join(out_dir, f"{name}.wav")
            tmp = final + ".part"
            sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
            os.replace(tmp, final)
            artifacts.append(Artifact(kind="stem", label=name, path=final,
                                      format="wav", sample_rate=sample_rate,
                                      duration_s=round(wav.shape[0] / sample_rate, 3)))
        return TaskResult(artifacts=artifacts, meta={"engine": "demucs",
                                                     "model": model_name})

    # MARK: roformer (audio-separator)

    def _run_roformer(self, src: str, out_dir: str, progress_cb: ProgressCb,
                      cancel: CancelToken) -> TaskResult:
        from audio_separator.separator import Separator

        checkpoint = self.settings["checkpoint"]
        model_dir = aux_dir("audio-separator-models")
        # If the catalog entry ships the checkpoint via HF snapshots, stage the
        # files into the model dir so audio-separator skips its own (fragile,
        # non-resuming) GitHub download. settings["stage_as"] maps snapshot
        # filenames onto the registry names audio-separator expects.
        stage_as = self.settings.get("stage_as") or {}
        for snap in self.model_paths.values():
            for root, _dirs, files in os.walk(snap):
                for f in files:
                    dst = os.path.join(model_dir, stage_as.get(f, f))
                    clear_stale_link(dst)   # a library move strands this link
                    if not os.path.exists(dst):
                        try:
                            os.symlink(os.path.join(root, f), dst)
                        except OSError:
                            pass

        if self._separator is None or getattr(self, "_sep_key", None) != checkpoint:
            progress_cb(None, "loading separation model (downloads on first use)")
            self._separator = Separator(output_dir=out_dir,
                                        model_file_dir=model_dir,
                                        output_format="WAV")
            # BaseException: audio-separator can exit via SystemExit on a bad
            # checkpoint, which would kill the worker silently. An interrupted
            # download leaves a truncated file that fails on EVERY retry —
            # remove the model's files so the next attempt re-downloads.
            try:
                self._separator.load_model(model_filename=checkpoint)
            except BaseException as e:
                self._separator = None
                stem_name = os.path.splitext(checkpoint)[0]
                removed = []
                for f in os.listdir(model_dir):
                    if f.startswith(stem_name):
                        try:
                            os.unlink(os.path.join(model_dir, f))
                            removed.append(f)
                        except OSError:
                            pass
                raise RuntimeError(
                    f"separation model failed to load "
                    f"({type(e).__name__}: {e}); removed "
                    f"{removed or 'no files'} — likely an interrupted "
                    f"download, try again") from None
            self._sep_key = checkpoint
        else:
            self._separator.output_dir = out_dir
        if cancel.cancelled:
            raise CancelledError()

        # audio-separator exposes no per-chunk callback, but its passes run
        # real tqdm bars in this process — hook the class's update() for the
        # duration of the call. That turns a ~20-minute indeterminate wait
        # (DeEcho-DeReverb) into counted progress AND gives the render its
        # only cooperative cancel checkpoint (audit §5).
        progress_cb(None, "separating (this can take several minutes)")
        import tqdm as _tqdm

        orig_update = _tqdm.tqdm.update

        def patched_update(bar, n=1):
            result = orig_update(bar, n)
            if cancel.cancelled:
                raise CancelledError()
            total = getattr(bar, "total", None)
            if total:
                progress_cb(min(0.98, bar.n / total),
                            f"separating — {int(bar.n)}/{int(total)}",
                            step=int(bar.n), steps=int(total))
            return result

        _tqdm.tqdm.update = patched_update
        try:
            produced = self._separator.separate(
                src, {"Vocals": "vocals", "Instrumental": "instrumental",
                      "Other": "instrumental", "No Vocals": "instrumental"})
        except CancelledError:
            # A pass aborted mid-flight may leave the separator's buffers in
            # an unknown state; drop it so the next job reloads clean.
            self._separator = None
            raise
        finally:
            _tqdm.tqdm.update = orig_update
        if cancel.cancelled:
            raise CancelledError()

        artifacts: list[Artifact] = []
        for f in produced:
            path = f if os.path.isabs(f) else os.path.join(out_dir, f)
            # some audio-separator versions latch output_dir at load_model
            # time; pull any stray file into THIS job's out_dir
            if os.path.dirname(path) != os.path.normpath(out_dir):
                moved = os.path.join(out_dir, os.path.basename(path))
                os.replace(path, moved)
                path = moved
            base = os.path.splitext(os.path.basename(path))[0].lower()
            # Default audio-separator names embed the MODEL name (which may
            # itself contain "vocals"); the "_(stem)_" marker is authoritative
            # when present.
            marker = re.search(r"_\(([^)]+)\)_", base)
            stem_name = marker.group(1) if marker else base
            if stem_name in ("other", "no vocals", "no_vocals",
                             "accompaniment", "instrumental"):
                label = "instrumental"
            elif "vocal" in stem_name:
                label = "vocals"
            else:
                label = stem_name
            if any(a.label == label for a in artifacts):
                label = f"{label}-{len(artifacts)}"
            info = sf.info(path)
            artifacts.append(Artifact(kind="stem", label=label, path=path,
                                      format="wav",
                                      sample_rate=int(info.samplerate),
                                      duration_s=round(info.duration, 3)))
        return TaskResult(artifacts=artifacts,
                          meta={"engine": "roformer", "checkpoint": checkpoint})

    def unload(self) -> None:
        self._separator = None

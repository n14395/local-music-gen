"""Neural Amp Modeler re-amping (task `reamp`): a track through a captured
amp, pedal or full rig.

The model is the user's own `.nam` capture file, uploaded per job as the
`nam_file` param — TONE3000 hosts hundreds of thousands of them (their site
is the browse UX; the Select/OAuth flow can come later). 26× realtime on CPU
(10 s re-amped in 0.38 s, measured).

Format notes, learned in triage:
- TONE3000 serves Architecture-1 exports: config keys `layers` / `head`,
  which nam 0.10's WaveNet takes after renaming to `layers_configs` /
  `head_config`. Architecture-2 files already use the new names.
- `architecture` may also be "LSTM"; nam 0.10 has the class for it.
- NAM captures are trained at 48 kHz mono; the adapter resamples in and
  keeps the source rate on the way out.
"""

from __future__ import annotations

import json
import os

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

NAM_SR = 48000
CHUNK_S = 30.0


def _build_model(payload: dict):
    """A nam 0.10 model from a parsed .nam file, either architecture."""
    import torch

    arch = str(payload.get("architecture") or "WaveNet")
    config = dict(payload.get("config") or {})
    if arch == "WaveNet":
        from nam.models.wavenet import WaveNet

        if "layers" in config:  # Architecture-1 export
            config = {"layers_configs": config["layers"],
                      "head_config": config.get("head"),
                      "head_scale": config.get("head_scale", 1.0)}
        model = WaveNet.init_from_config(config)
    elif arch == "LSTM":
        from nam.models.recurrent import LSTM

        model = LSTM.init_from_config(config)
    else:
        raise RuntimeError(f"unsupported .nam architecture '{arch}'")
    model.import_weights(torch.tensor(payload["weights"]))
    model.eval()
    return model


class NamAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        # (path, mtime) -> model: the same capture re-amps many stems in a
        # session, and a WaveNet builds in milliseconds anyway.
        self._cache: dict = {}

    def load(self, progress_cb: ProgressCb) -> None:
        progress_cb(None, "re-amp runtime ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "re-amping transforms existing audio — submit a reamp task")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "reamp":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        import soxr
        import torch

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        nam_path = params.get("nam_file")
        if not nam_path or not os.path.isfile(nam_path):
            raise RuntimeError("nam_file missing — pick a .nam capture "
                               "(tone3000.com has thousands, free)")

        key = (nam_path, os.path.getmtime(nam_path))
        model = self._cache.get(key)
        if model is None:
            progress_cb(0.02, "building the rig from the capture")
            try:
                with open(nam_path) as f:
                    payload = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                raise RuntimeError(f"not a readable .nam file: {e}") from None
            model = _build_model(payload)
            self._cache = {key: model}   # one at a time; they are tiny

        progress_cb(0.1, "reading the audio")
        data, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = data.mean(axis=1)
        work = soxr.resample(mono, sr, NAM_SR) if sr != NAM_SR else mono

        chunk = int(CHUNK_S * NAM_SR)
        pieces: list[np.ndarray] = []
        total = max(1, (len(work) + chunk - 1) // chunk)
        with torch.no_grad():
            for i in range(total):
                if cancel.cancelled:
                    raise CancelledError()
                x = torch.from_numpy(
                    work[i * chunk: (i + 1) * chunk]).unsqueeze(0)
                y = model(x)
                pieces.append(np.atleast_2d(y.numpy())[0].ravel())
                progress_cb(0.15 + 0.75 * (i + 1) / total, "re-amping")

        progress_cb(0.92, "saving")
        out = np.concatenate(pieces)
        if sr != NAM_SR:
            out = soxr.resample(out, NAM_SR, sr)
        final = os.path.join(out_dir, "reamped.wav")
        tmp = final + ".part"
        sf.write(tmp, out, sr, format="WAV", subtype="PCM_16")
        os.replace(tmp, final)
        return TaskResult(
            artifacts=[Artifact(kind="stem", label="reamped", path=final,
                                format="wav", sample_rate=int(sr),
                                duration_s=round(len(out) / sr, 3))],
            meta={"engine": "nam",
                  "capture": os.path.basename(nam_path)})

    def unload(self) -> None:
        self._cache = {}

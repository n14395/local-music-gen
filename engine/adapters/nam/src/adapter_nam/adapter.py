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
- Captures carry their training sample rate in the file (usually 48 kHz,
  sometimes 44.1 k); the adapter runs at that rate and keeps the source
  rate on the way out.
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
        cached = self._cache.get(key)
        if cached is None:
            progress_cb(0.02, "building the rig from the capture")
            try:
                with open(nam_path) as f:
                    payload = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                raise RuntimeError(f"not a readable .nam file: {e}") from None
            model = _build_model(payload)
            # The capture file says what rate it was trained at — a 44.1 k
            # capture run at a hardcoded 48 k played 8.8 % off (audit §3).
            try:
                cap_sr = int(payload.get("sample_rate") or NAM_SR)
            except (TypeError, ValueError):
                cap_sr = NAM_SR
            cached = (model, cap_sr)
            self._cache = {key: cached}   # one at a time; they are tiny
        model, cap_sr = cached

        progress_cb(0.1, "reading the audio")
        data, sr = sf.read(src, dtype="float32", always_2d=True)
        mono = data.mean(axis=1)
        work = soxr.resample(mono, sr, cap_sr) if sr != cap_sr else mono

        chunk = int(CHUNK_S * cap_sr)
        # Each model() call starts from silence, so a bare 30 s grid reset
        # the amp state at every boundary — an audible dip on sustained
        # material (audit §3). Feed each chunk a second of real left
        # context and keep only its own span.
        overlap = cap_sr
        pieces: list[np.ndarray] = []
        total = max(1, (len(work) + chunk - 1) // chunk)
        with torch.no_grad():
            for i in range(total):
                if cancel.cancelled:
                    raise CancelledError()
                s = i * chunk
                lead = min(overlap, s)
                span = min(chunk, len(work) - s)
                x = torch.from_numpy(work[s - lead: s + span]).unsqueeze(0)
                y = model(x)
                arr = np.atleast_2d(y.numpy())[0].ravel()
                # Aligned from the end: correct whether the model returns
                # input-length output or trims its receptive field.
                pieces.append(arr[-span:])
                progress_cb(0.15 + 0.75 * (i + 1) / total, "re-amping")

        progress_cb(0.92, "saving")
        out = np.concatenate(pieces)
        if sr != cap_sr:
            out = soxr.resample(out, cap_sr, sr)
        # Hot captures can push past full scale, which PCM16 would hard-clip
        # (audit §3); one broadband trim preserves the shape.
        peak = float(np.max(np.abs(out))) if len(out) else 0.0
        if peak > 0.99:
            out = out * (0.99 / peak)
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

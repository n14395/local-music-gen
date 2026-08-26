"""MelodyFlow: single-stage flow-matching text-to-music, plus the thing no
other family here has — text-guided EDITING of existing audio (regularized
latent inversion: feed a song, describe the change).

The inference code lives only in the vendored HF Space audiocraft tree (see
pyproject); weights are the ordinary HF snapshot. The catalog entry ships
settings.device = "mps" (proven 2026-08-26: 10 s of audio in 2.8 s
steady-state at 8 euler steps, load 7 s, no NaN/artifacts; the machine's
very first run pays a one-off ~2 min Metal shader warm-up). CPU remains the
adapter default fallback and is itself faster than realtime (10 s in 7.2 s).

xformers is stubbed FUNCTIONALLY before audiocraft imports: this tree calls
`ops.memory_efficient_attention` even on the torch path, so the stub routes it
through torch SDPA (transpose B,T,H,D ↔ B,H,T,D; a mask argument means
causal). The plain import-stub the main audiocraft family ships would crash
here at the first attention call.
"""

from __future__ import annotations

import os
import sys
import types

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

MAX_DURATION_S = 30.0


def _install_xformers_stub() -> None:
    if "xformers" in sys.modules:
        return

    def _mea(q, k, v, attn_bias=None, p=0.0):
        import torch.nn.functional as F

        qt, kt, vt = (x.transpose(1, 2) for x in (q, k, v))
        out = F.scaled_dot_product_attention(
            qt, kt, vt, is_causal=attn_bias is not None, dropout_p=p)
        return out.transpose(1, 2)

    def _unbind(t, dim=0):
        import torch

        return torch.unbind(t, dim=dim)

    xf = types.ModuleType("xformers")
    xf.ops = types.SimpleNamespace(
        memory_efficient_attention=_mea, unbind=_unbind,
        LowerTriangularMask=type("LowerTriangularMask", (), {}))
    sys.modules["xformers"] = xf
    sys.modules["xformers.ops"] = xf.ops


class MelodyFlowAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.device = str(self.settings.get("device") or "cpu")

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        _install_xformers_stub()
        progress_cb(None, "loading MelodyFlow")
        from audiocraft.models import MelodyFlow

        # get_pretrained accepts a local snapshot directory (the loader's
        # isdir path), so nothing reaches for the network.
        self.model = MelodyFlow.get_pretrained(self._snapshot(),
                                               device=self.device)
        progress_cb(None, f"MelodyFlow ready on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        import torch

        assert self.model is not None
        duration = min(MAX_DURATION_S, float(params.get("duration_s") or 10.0))
        steps = max(1, min(125, int(params.get("steps") or 10)))
        solver = str(params.get("solver") or "euler")
        if solver not in ("euler", "midpoint"):
            solver = "euler"

        def on_step(elapsed: int, total: int) -> None:
            if cancel.cancelled:
                raise CancelledError()
            progress_cb(min(0.98, elapsed / max(1, total)), "rendering",
                        phase="diffusion", step=elapsed, steps=total)

        self.model.set_custom_progress_callback(on_step)
        self.model.set_generation_params(solver=solver, steps=steps,
                                         duration=duration)

        src = params.get("src_audio")
        with torch.no_grad():
            if src and os.path.isfile(src):
                wav = self._edit(src, prompt, params, steps, solver,
                                 progress_cb)
            else:
                progress_cb(None, "encoding the prompt", phase="prompt_encode")
                wav = self.model.generate([prompt])
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(None, "saving", phase="master")
        out = wav[0].float().cpu().numpy().T
        sample_rate = int(self.model.sample_rate)
        tmp = out_path + ".part"
        sf.write(tmp, out, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(out.shape[0] / sample_rate, 3),
            sample_rate=sample_rate,
            seed_used=None)

    def _edit(self, src: str, prompt: str, params: dict, steps: int,
              solver: str, progress_cb: ProgressCb):
        """Rewrite existing audio toward the prompt (latent inversion)."""
        import numpy as np
        import soxr
        import torch

        strength = float(params.get("edit_strength") or 0.8)
        # target_flowstep is the inversion pivot: 0 = re-noise fully (the
        # strongest rewrite), nearer 1 = keep more of the source.
        target_flowstep = min(0.9, max(0.0, 1.0 - strength))
        self.model.set_editing_params(solver=solver, steps=max(steps, 25),
                                      target_flowstep=target_flowstep,
                                      regularize=True)

        progress_cb(None, "encoding the source", phase="prompt_encode")
        audio, sr = sf.read(src, dtype="float32", always_2d=True)
        target_sr = int(self.model.sample_rate)
        if sr != target_sr:
            audio = soxr.resample(audio, sr, target_sr)
        max_samples = int(target_sr * MAX_DURATION_S)
        audio = audio[:max_samples]
        if audio.shape[1] == 1:
            audio = np.repeat(audio, 2, axis=1)
        wav = torch.from_numpy(np.ascontiguousarray(audio.T))[None]
        tokens = self.model.encode_audio(wav.to(self.model.device))
        # Naming what the source IS helps the inversion hold onto it while
        # the target description pulls it elsewhere. Empty = the upstream
        # default (invert against nothing in particular).
        source_caption = str(params.get("edit_source_caption") or "").strip()
        return self.model.edit(prompt_tokens=tokens, descriptions=[prompt],
                               src_descriptions=[source_caption])

    def unload(self) -> None:
        self.model = None

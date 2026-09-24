# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

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
import secrets
import sys
import types

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     release_accelerator_memory)

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
        # The checkpoint's own cfg_coef, read once at load — see generate().
        self._cfg_default = None

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
        # cfg_coef is a persistent field of the flow LM, so assigning it in
        # generate() used to stick: the first take that set it made the
        # catalog's declared default (null = "the checkpoint's own value")
        # unreachable for every later take in this worker (audit 09-B3).
        # Remembered here so a null param can put it back.
        lm = getattr(self.model, "lm", None)
        self._cfg_default = getattr(lm, "cfg_coef", None)
        progress_cb(None, f"MelodyFlow ready on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        import torch

        assert self.model is not None
        duration = min(MAX_DURATION_S, float(params.get("duration_s") or 10.0))
        steps = max(1, min(125, int(params.get("steps") or 10)))

        # Draw a seed when none was given rather than leaving the take
        # unreproducible: the initial latent is a torch normal draw, so
        # seeding torch is all it takes, and reporting it back is what lets a
        # take you liked be reproduced after changing one other setting.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        torch.manual_seed(seed)
        solver = str(params.get("solver") or "euler")
        if solver not in ("euler", "midpoint"):
            solver = "euler"
        if solver == "midpoint" and steps % 2:
            # Upstream asserts midpoint runs an even step count; rounding
            # down keeps the request inside the declared 1-125 range.
            steps = max(2, steps - 1)

        def on_step(elapsed: int, total: int) -> None:
            if cancel.cancelled:
                raise CancelledError()
            progress_cb(min(0.98, elapsed / max(1, total)), "rendering",
                        phase="diffusion", step=elapsed, steps=total)

        self.model.set_custom_progress_callback(on_step)
        self.model.set_generation_params(solver=solver, steps=steps,
                                         duration=duration)

        # Guidance is an attribute of the flow model rather than a generation
        # parameter — `FlowMatchingModel.generate` takes no cfg argument and
        # reads `self.cfg_coef` at the step (`flow.py`), which is why this is
        # a field assignment and not a kwarg. None RESTORES the checkpoint's
        # own value (captured in load): the field sticks, so "leave it alone"
        # had to become "put it back". On an edit it applies to the pass that
        # travels towards the new description; the inversion pass runs
        # unguided by construction, upstream forces cfg to 0 there to stop it
        # diverging.
        cfg = params.get("cfg_coef")
        lm = getattr(self.model, "lm", None)
        if lm is not None:
            if cfg is not None:
                lm.cfg_coef = float(cfg)
            elif self._cfg_default is not None:
                lm.cfg_coef = self._cfg_default

        src = params.get("src_audio")
        with torch.no_grad():
            if src and os.path.isfile(src):
                wav = self._edit(src, prompt, params, steps, progress_cb)
            else:
                progress_cb(None, "encoding the prompt", phase="prompt_encode")
                # progress=True is what makes the per-step callback fire —
                # and that callback is also the only cancel checkpoint, so
                # without it a generate was both silent and unstoppable
                # (audit B8, live-confirmed).
                wav = self.model.generate([prompt], progress=True)
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
            seed_used=seed)

    def _edit(self, src: str, prompt: str, params: dict, steps: int,
              progress_cb: ProgressCb):
        """Rewrite existing audio toward the prompt (latent inversion)."""
        import numpy as np
        import soxr
        import torch

        strength = float(params.get("edit_strength") or 0.8)
        # target_flowstep is the inversion pivot: 0 = re-noise fully (the
        # strongest rewrite), nearer 1 = keep more of the source.
        target_flowstep = min(0.9, max(0.0, 1.0 - strength))
        # Edits always regularize (their quality lever), and upstream asserts
        # regularization is euler-only — midpoint here killed every edit
        # (audit B8), so the solver choice applies to generates only.
        self.model.set_editing_params(solver="euler", steps=max(steps, 25),
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
        self._cfg_default = None
        # settings.device is "mps" for this entry, and dropping the reference
        # leaves torch's caching allocator holding every block the model
        # touched — the next model of this family then loads against a full
        # arena (audit 09-B7).
        release_accelerator_memory()

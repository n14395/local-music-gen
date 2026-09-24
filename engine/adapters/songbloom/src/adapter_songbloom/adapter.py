# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""SongBloom: lyrics + a 10-second style clip → a full coherent song
(interleaved autoregressive sketching + diffusion; 150 s checkpoints, DPO
variant preferred).

Orphaned upstream — the official repos were deleted; the code survives in the
rsxdalv fork (pinned tarball) and the weights on the user-owned HF mirror
rtikw/SongBloom (unmodified copy of the last surviving host, ModelScope).
Everything here treats the project as frozen.

Device: settings.device = "mps" routes the whole pipeline to the GPU by
retargeting the `.cuda()` shims — upstream's single device move is
`.eval().cuda().to(dtype)` in build_from_trainer, and the sampler captures
its device from the moved parameters AFTER that line, so `.cuda()`→
`.to("mps")` carries everything (inputs included — their generate moves
them to self.device itself). fp32 on either device; their cuda-autocast
contexts already degrade to no-ops here, proven by the CPU runs. Without
the setting: CPU, the proven triage configuration (30 s of song in 657 s;
the catalog estimate carries that honestly). Shims common to both routes:
torch.load→CPU; `.cuda()` patched on Tensor, Module AND Lightning's own
device mixin (all three are reached); DISABLE_FLASH_ATTN=1 (its absence
asserts CUDA).

Lyrics use their structure-token format — `[intro] [verse] ... [chorus] ...`
with `.`-separated lines and ` , ` between sections (see the entry's
lyrics_hint). The style prompt is 10 s of any reference audio.
"""

from __future__ import annotations

import os
import secrets
import sys

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir,
                                     release_accelerator_memory)
from engine_protocol.staging import fetch_tarball_tree, staged

# Read at torch import: lets any stray op the MPS backend lacks fall back
# to CPU instead of aborting the render. Harmless on the CPU route.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

REPO_COMMIT = "712b35aac8893c5dc442dd299b5e998628d08ef8"
REPO_TARBALL = (f"https://github.com/rsxdalv/SongBloom/archive/"
                f"{REPO_COMMIT}.tar.gz")


class SongBloomAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.variant = str(self.settings.get("variant")
                           or "songbloom_full_150s_dpo")
        self.device = str(self.settings.get("device") or "cpu")

    def _snapshot(self) -> str:
        # By needle, not exact id: the weights moved from ModelScope
        # (AI-ModelScope/SongBloom) to the user-owned HF mirror
        # (rtikw/SongBloom); the adapter stays host-agnostic.
        for repo, path in self.model_paths.items():
            if "songbloom" in repo.lower():
                return path
        raise RuntimeError("no SongBloom snapshot in model_paths")

    def load(self, progress_cb: ProgressCb) -> None:
        import torch

        cache = aux_dir("songbloom")
        repo = os.path.join(cache, f"SongBloom-{REPO_COMMIT}")

        def adopt_extracted() -> None:
            # GitHub names a tarball's top directory after the repository,
            # and the pinned fork is called "tts-webui.SongBloom", not
            # "SongBloom" — so claim whichever directory carries the commit.
            if os.path.isdir(repo):
                return
            for entry in os.listdir(cache):
                full = os.path.join(cache, entry)
                if entry.endswith(f"-{REPO_COMMIT}") and os.path.isdir(full):
                    os.rename(full, repo)
                    return

        adopt_extracted()
        if not staged(repo, "infer.py",
                      "SongBloom/models/songbloom/songbloom_pl.py"):
            progress_cb(None, "fetching the SongBloom code (pinned fork "
                              "snapshot, first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache,
                               f"SongBloom-{REPO_COMMIT}")
        if repo not in sys.path:
            sys.path.insert(0, repo)
        os.environ["DISABLE_FLASH_ATTN"] = "1"

        # Their sampler: .eval().cuda().to(dtype) — unconditional. Lightning's
        # mixin overrides Module.cuda, so all three need the same patch. On
        # the MPS route `.cuda()` becomes the move to the GPU; the sampler
        # captures its device from the moved parameters right after.
        if self.device == "mps":
            _cuda = lambda self, *a, **kw: self.to("mps")  # noqa: E731
        else:
            _cuda = lambda self, *a, **kw: self  # noqa: E731
        torch.Tensor.cuda = _cuda
        torch.nn.Module.cuda = _cuda
        from lightning.fabric.utilities import device_dtype_mixin

        device_dtype_mixin._DeviceDtypeModuleMixin.cuda = _cuda
        orig_load = torch.load
        torch.load = lambda *a, **kw: orig_load(
            *a, **{"map_location": "cpu", "weights_only": False, **kw})

        progress_cb(None, "loading SongBloom (8 GB — takes about a minute)")
        from infer import load_config
        from SongBloom.models.songbloom.songbloom_pl import SongBloom_Sampler

        snapshot = self._snapshot()
        cfg = load_config(os.path.join(snapshot, f"{self.variant}.yaml"),
                          parent_dir=snapshot)
        self._cfg = cfg
        self.model = SongBloom_Sampler.build_from_trainer(
            cfg, strict=True, dtype=torch.float32)
        self.model.set_generation_params(**cfg.inference)
        progress_cb(None, "SongBloom ready on the GPU (MPS)"
                          if self.device == "mps" else
                          "SongBloom ready (CPU — renders take many minutes; "
                          "the estimate is honest)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        import soxr
        import torch

        assert self.model is not None
        if not lyrics or not lyrics.strip():
            raise RuntimeError(
                "SongBloom needs lyrics in its structure-token format — "
                "see the model's lyrics hint")
        style_path = params.get("style_audio")
        if not style_path or not os.path.isfile(style_path):
            raise RuntimeError("style_audio missing — SongBloom sets its "
                               "sound from a ~10 s reference clip")
        duration_s = min(150.0, float(params.get("duration_s") or 60.0))
        self._cfg.max_dur = int(duration_s)
        # The sampler froze max_frames at load from the yaml's 150 s;
        # without this per-render update the duration slider was dead and
        # every take decoded to EOS (audit §2). 25 frames/s is the model's
        # own rate (max_duration * 25 upstream); set_generation_params
        # update()s, so the yaml's other sampling params survive.
        self.model.set_generation_params(max_frames=int(duration_s * 25))
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. `seed_used` reports it back.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        torch.manual_seed(seed)

        progress_cb(None, "reading the style clip")
        audio, sr = sf.read(style_path, dtype="float32", always_2d=True)
        mono = audio.mean(axis=1)
        target_sr = int(self.model.sample_rate)
        if sr != target_sr:
            mono = soxr.resample(mono, sr, target_sr)
        mono = mono[: 10 * target_sr]
        prompt_wav = torch.from_numpy(mono).unsqueeze(0)

        progress_cb(None, "writing the song (autoregressive sketch + "
                          "diffusion"
                          + ("; GPU)" if self.device == "mps"
                             else "; many minutes on CPU)"))
        if cancel.cancelled:
            raise CancelledError()

        # Wrap the per-block sampler: real progress (one call per
        # block_size latent frames), the render's only cancel checkpoint,
        # and the MPS allocator flush every AR family needs (audit §3/§5 —
        # three messages across a possible 55-minute render, no cancel, no
        # flush).
        dit = getattr(self.model, "diffusion", None)
        wav = None
        if dit is not None and hasattr(dit, "_sample_next_block"):
            block = int(getattr(dit, "block_size", 32) or 32)
            total = max(1, int(duration_s * 25) // block)
            done = 0
            orig_sample = dit._sample_next_block

            def wrapped(*a, **kw):
                nonlocal done
                if cancel.cancelled:
                    raise CancelledError()
                if self.device == "mps":
                    torch.mps.empty_cache()
                done += 1
                progress_cb(min(0.98, done / total),
                            f"writing the song — block {done}"
                            f"/~{total}", step=done, steps=total)
                return orig_sample(*a, **kw)

            dit._sample_next_block = wrapped
            try:
                wav = self.model.generate(lyrics, prompt_wav)
            finally:
                dit._sample_next_block = orig_sample
        else:
            wav = self.model.generate(lyrics, prompt_wav)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(None, "saving")
        out = wav[0].cpu().float().numpy()
        out = np.atleast_2d(out).T  # (samples, channels)
        tmp = out_path + ".part"
        sf.write(tmp, out, target_sr, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(out.shape[0] / target_sr, 3),
            sample_rate=target_sr,
            seed_used=seed)

    def unload(self) -> None:
        self.model = None
        # Rebinding frees the Python objects; the Metal arena the DiT and its
        # codec filled stays checked out until the allocator is told.
        release_accelerator_memory()

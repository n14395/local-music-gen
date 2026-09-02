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
import sys
import tarfile
import urllib.request

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir)

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
        if not os.path.isdir(repo):
            progress_cb(None, "fetching the SongBloom code (pinned fork "
                              "snapshot, first use only)")
            tar_path = os.path.join(cache, "repo.tar.gz")
            with urllib.request.urlopen(REPO_TARBALL, timeout=300) as resp, \
                    open(tar_path, "wb") as f:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            with tarfile.open(tar_path) as tar:
                tar.extractall(cache, filter="data")
            os.unlink(tar_path)
            adopt_extracted()
        if not os.path.isdir(repo):
            raise RuntimeError("the SongBloom code snapshot failed to "
                               "extract — nothing in the cache carries "
                               f"commit {REPO_COMMIT[:8]}")
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
        seed = params.get("seed")
        if seed is not None:
            torch.manual_seed(int(seed))

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
            seed_used=int(seed) if seed is not None else None)

    def unload(self) -> None:
        self.model = None

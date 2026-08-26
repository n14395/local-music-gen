"""InspireMusic (Alibaba, ModelScope-only): long-form text-to-music and music
CONTINUATION — the 1.5B-Long variant holds 3+ minutes of coherent structure.

Honesty first: this runs on CPU at roughly 29× slower than realtime in fast
mode (measured). The upstream code is MPS-aware but inconsistently — model
halves land on different devices and crash — so MPS is disabled until a real
device-unification port is done (a known, scoped piece of further work). The
catalog entry says "slow" and means it.

The five shims and the CWD scaffold, all proven in triage:
  1. torch.load → CPU (CUDA pickles)
  2. flash_attention_2 → sdpa and device_map=auto → cpu, patched at the
     transformers base classes so the vendored code stays unmodified
  3. torchaudio.set_audio_backend no-op (API removed in 2.2)
  4. torch.backends.mps.is_available → False (split-device crash)
  5. torch.cuda.synchronize no-op (called after generation)
The snapshot's inspiremusic.yaml resolves model paths RELATIVE TO CWD
(../../pretrained_models/<name>/), so the adapter builds a scratch tree with
a symlink and chdirs into it. Code comes from a pinned GitHub tarball plus
the Matcha-TTS submodule; weights come from the user-owned HF mirror
rtikw/InspireMusic-1.5B-Long (unmodified copy of the delisted original).
"""

from __future__ import annotations

import glob
import os
import sys
import tarfile
import urllib.request

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

MODEL_NAME = "InspireMusic-1.5B-Long"
REPO_COMMIT = "0aefb55b58b8df91accdc4aed20c99e44741e0a7"
REPO_TARBALL = (f"https://github.com/QwenAudio/FunMusic/archive/"
                f"{REPO_COMMIT}.tar.gz")
MATCHA_COMMIT = "77804265f877b0c42f13cfdece6541dde7838090"
MATCHA_TARBALL = (f"https://github.com/shivammehta25/Matcha-TTS/archive/"
                  f"{MATCHA_COMMIT}.tar.gz")


def _fetch_tar(url: str, cache: str, progress_cb: ProgressCb,
               what: str) -> None:
    tar_path = os.path.join(cache, "dl.tar.gz")
    progress_cb(None, f"fetching {what} (first use only)")
    with urllib.request.urlopen(url, timeout=300) as resp, \
            open(tar_path, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    with tarfile.open(tar_path) as tar:
        tar.extractall(cache, filter="data")
    os.unlink(tar_path)


class InspireMusicAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None

    def _cache_dir(self) -> str:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        d = os.path.join(base, "inspiremusic")
        os.makedirs(d, exist_ok=True)
        return d

    def _snapshot(self) -> str:
        # By needle, not exact id: the weights moved from ModelScope
        # (iic/InspireMusic-1.5B-Long) to the user-owned HF mirror
        # (rtikw/InspireMusic-1.5B-Long), and the adapter should not need
        # to know which host the catalog is pointing at this week.
        for repo, path in self.model_paths.items():
            if "inspiremusic" in repo.lower():
                return path
        raise RuntimeError("no InspireMusic snapshot in model_paths")

    def _apply_shims(self) -> None:
        import torch
        import torchaudio
        from transformers.modeling_utils import PreTrainedModel
        from transformers.models.auto.auto_factory import _BaseAutoModelClass

        if not hasattr(torchaudio, "set_audio_backend"):
            torchaudio.set_audio_backend = lambda *a, **kw: None
        torch.backends.mps.is_available = lambda: False
        torch.cuda.synchronize = lambda *a, **kw: None
        orig_load = torch.load
        torch.load = lambda *a, **kw: orig_load(
            *a, **{"map_location": "cpu", "weights_only": False, **kw})

        def _sdpa_patch(cls):
            orig = cls.from_pretrained.__func__

            def wrapped(klass, *a, **kw):
                if kw.get("attn_implementation") == "flash_attention_2":
                    kw["attn_implementation"] = "sdpa"
                if kw.get("device_map") == "auto":
                    kw["device_map"] = "cpu"
                return orig(klass, *a, **kw)

            cls.from_pretrained = classmethod(wrapped)

        for cls in (PreTrainedModel, _BaseAutoModelClass):
            _sdpa_patch(cls)

    def load(self, progress_cb: ProgressCb) -> None:
        cache = self._cache_dir()
        repo = os.path.join(cache, f"FunMusic-{REPO_COMMIT}")
        if not os.path.isdir(repo):
            _fetch_tar(REPO_TARBALL, cache, progress_cb,
                       "the InspireMusic code")
        matcha = os.path.join(repo, "third_party", "Matcha-TTS")
        if not os.path.isdir(os.path.join(matcha, "matcha")):
            _fetch_tar(MATCHA_TARBALL, cache, progress_cb,
                       "the Matcha-TTS submodule")
            extracted = os.path.join(cache, f"Matcha-TTS-{MATCHA_COMMIT}")
            os.makedirs(os.path.dirname(matcha), exist_ok=True)
            if not os.path.isdir(matcha):
                os.rename(extracted, matcha)

        # The yaml resolves ../../pretrained_models/<name>/ from CWD.
        work = os.path.join(cache, "work", "run", "here")
        os.makedirs(work, exist_ok=True)
        models_dir = os.path.join(cache, "work", "pretrained_models")
        os.makedirs(models_dir, exist_ok=True)
        link = os.path.join(models_dir, MODEL_NAME)
        if not os.path.exists(link):
            os.symlink(self._snapshot(), link)

        for path in (repo, matcha):
            if path not in sys.path:
                sys.path.insert(0, path)
        self._apply_shims()
        os.chdir(work)

        progress_cb(None, "loading InspireMusic (11 GB — this takes a "
                          "little while)")
        from inspiremusic.cli.inference import InspireMusicModel

        self._out_root = os.path.join(cache, "out")
        self.model = InspireMusicModel(
            model_name=MODEL_NAME,
            model_dir=self._snapshot(),
            max_generate_audio_seconds=float(
                self.settings.get("max_generate_audio_seconds", 180.0)),
            fast=bool(self.settings.get("fast", True)),
            fp16=False,
            dtype="fp32",
            load_jit=False,
            gpu=-1,
            result_dir=self._out_root)
        progress_cb(None, "InspireMusic ready (CPU — renders are slow and "
                          "the estimate is honest)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.model is not None
        duration_s = min(180.0, float(params.get("duration_s") or 30.0))
        self.model.max_generate_audio_seconds = duration_s
        extend = params.get("extend_audio")
        task = ("continuation" if extend and os.path.isfile(extend)
                else "text-to-music")

        progress_cb(None, f"rendering ({task}; ~29× slower than realtime "
                          f"on CPU — cancel any time)")
        for old in glob.glob(os.path.join(self._out_root, "**", "*.wav"),
                             recursive=True):
            os.unlink(old)
        if cancel.cancelled:
            raise CancelledError()
        kwargs = {"task": task, "text": prompt}
        if task == "continuation":
            kwargs["audio_prompt"] = extend
        # Structure conditioning: the text prompt is wrapped in
        # <|time_start|><|chorus|><|text|><|time_end|> tokens upstream, so
        # these steer which part of a song the model believes it is writing.
        chorus = str(params.get("chorus") or "").strip()
        if chorus:
            kwargs["chorus"] = chorus
        if params.get("time_start") is not None:
            kwargs["time_start"] = float(params["time_start"])
        if params.get("time_end") is not None:
            kwargs["time_end"] = float(params["time_end"])
        self.model.inference(**kwargs)
        if cancel.cancelled:
            raise CancelledError()

        wavs = glob.glob(os.path.join(self._out_root, "**", "*.wav"),
                         recursive=True)
        if not wavs:
            raise RuntimeError("InspireMusic produced no audio")
        audio, sr = sf.read(sorted(wavs)[-1], dtype="float32",
                            always_2d=True)
        tmp = out_path + ".part"
        sf.write(tmp, audio, sr, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(audio.shape[0] / sr, 3),
            sample_rate=int(sr),
            seed_used=None)

    def unload(self) -> None:
        self.model = None

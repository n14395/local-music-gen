"""InspireMusic (Alibaba, ModelScope-only): long-form text-to-music and music
CONTINUATION — the 1.5B-Long variant holds 3+ minutes of coherent structure.

Runs on MPS when the catalog says so (settings.device = "mps"; the
2026-08-26 port: 10 s of music in 33 s, an 8.6× speedup over the CPU
baseline's 288 s). The upstream code is MPS-aware but inconsistently —
`_apply_mps_unification` closes the two seams (frontend device ladder,
llm_job's unmoved float64 embeddings). Without the setting it falls back
to the proven CPU configuration (~29× realtime in fast mode, measured).

The shims and the CWD scaffold, all proven in triage / the MPS port:
  1. torch.load → CPU (CUDA pickles)
  2. flash_attention_2 → sdpa and device_map=auto → cpu, patched at the
     transformers base classes so the vendored code stays unmodified
  3. torchaudio.set_audio_backend no-op (API removed in 2.2)
  4. torch.backends.mps.is_available → False when CPU-pinned
     (split-device crash without the unification patches)
  5. torch.cuda.synchronize no-op (called after generation)
  6. torchaudio.save/load → soundfile (torchaudio ≥ 2.9 delegates I/O to
     torchcodec, whose ffmpeg dylibs don't load in the worker — the save
     at the END of a render fails otherwise, on any device)
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
import tempfile

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir)
from engine_protocol.staging import fetch_tarball_tree, staged

MODEL_NAME = "InspireMusic-1.5B-Long"
REPO_COMMIT = "0aefb55b58b8df91accdc4aed20c99e44741e0a7"
REPO_TARBALL = (f"https://github.com/QwenAudio/FunMusic/archive/"
                f"{REPO_COMMIT}.tar.gz")
MATCHA_COMMIT = "77804265f877b0c42f13cfdece6541dde7838090"
MATCHA_TARBALL = (f"https://github.com/shivammehta25/Matcha-TTS/archive/"
                  f"{MATCHA_COMMIT}.tar.gz")


class InspireMusicAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None

    def _snapshot(self) -> str:
        # By needle, not exact id: the weights moved from ModelScope
        # (iic/InspireMusic-1.5B-Long) to the user-owned HF mirror
        # (rtikw/InspireMusic-1.5B-Long), and the adapter should not need
        # to know which host the catalog is pointing at this week.
        for repo, path in self.model_paths.items():
            if "inspiremusic" in repo.lower():
                return path
        raise RuntimeError("no InspireMusic snapshot in model_paths")

    def _apply_shims(self, use_mps: bool) -> None:
        import torch
        import torchaudio
        from transformers.modeling_utils import PreTrainedModel
        from transformers.models.auto.auto_factory import _BaseAutoModelClass

        if not hasattr(torchaudio, "set_audio_backend"):
            torchaudio.set_audio_backend = lambda *a, **kw: None
        if not use_mps:
            torch.backends.mps.is_available = lambda: False
        torch.cuda.synchronize = lambda *a, **kw: None

        # torchaudio >= 2.9 delegates audio I/O to torchcodec, whose ffmpeg
        # dylibs don't load here (no DYLD path in the worker) — the save at
        # the end of a render fails on ANY device. The runtime call sites
        # are plain save(fn, tensor, sample_rate=..)/load(path), so route
        # both through soundfile.
        def _sf_save(uri, src, sample_rate=24000, *a, **kw):
            data = src.detach().cpu().numpy()
            if data.ndim == 2:
                data = data.T
            sf.write(str(uri), data, int(sample_rate))

        def _sf_load(uri, *a, **kw):
            import numpy as np
            data, sr = sf.read(str(uri), dtype="float32", always_2d=True)
            return torch.from_numpy(np.ascontiguousarray(data.T)), sr

        torchaudio.save = _sf_save
        torchaudio.load = _sf_load
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

    def _apply_mps_unification(self) -> None:
        """The two seams of the 2026-08-26 MPS port: frontend.py's device
        ladder only knows cuda/cpu (its text/audio tokens and wavtokenizer
        would stay on CPU), and llm_job forwards the chorus/time embeddings
        tuple to the MPS-resident LLM unmoved — and in float64, which the
        MPS framework does not support. Everything else already lands on
        MPS via the upstream ladders."""
        import torch
        import inspiremusic.cli.frontend as fe
        import inspiremusic.cli.model as im_model

        if getattr(fe.InspireMusicFrontEnd, "_localmusic_mps", False):
            return
        fe.InspireMusicFrontEnd._localmusic_mps = True

        orig_init = fe.InspireMusicFrontEnd.__init__

        def unified_init(self_, *a, **kw):
            orig_init(self_, *a, **kw)
            dev = torch.device("mps")
            self_.device = dev
            self_.bandwidth_id = self_.bandwidth_id.to(dev)
            self_.wavtokenizer = self_.wavtokenizer.to(dev)

        fe.InspireMusicFrontEnd.__init__ = unified_init

        orig_llm_job = im_model.InspireMusicModel.llm_job

        def patched_llm_job(self_, text, audio_token, audio_token_len,
                            prompt_text, llm_prompt_audio_token, embeddings,
                            uuid, duration_to_gen, task):
            if embeddings is not None:
                embeddings = [
                    e.to(device=self_.device,
                         dtype=(torch.float32 if torch.is_floating_point(e)
                                else e.dtype))
                    if torch.is_tensor(e) else e
                    for e in embeddings]
            return orig_llm_job(self_, text, audio_token, audio_token_len,
                                prompt_text, llm_prompt_audio_token,
                                embeddings, uuid, duration_to_gen, task)

        im_model.InspireMusicModel.llm_job = patched_llm_job

    def load(self, progress_cb: ProgressCb) -> None:
        cache = aux_dir("inspiremusic")
        repo = os.path.join(cache, f"FunMusic-{REPO_COMMIT}")
        if not staged(repo, "inspiremusic/__init__.py"):
            progress_cb(None, "fetching the InspireMusic code "
                              "(first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache, f"FunMusic-{REPO_COMMIT}")
        matcha = os.path.join(repo, "third_party", "Matcha-TTS")
        # A submodule placeholder from the repo tarball, or the husk of an
        # extraction that died partway: either way a Matcha dir with no
        # `matcha` package inside fails this guard and gets restaged.
        if not staged(matcha, "matcha"):
            progress_cb(None, "fetching the Matcha-TTS submodule "
                              "(first use only)")
            os.makedirs(os.path.dirname(matcha), exist_ok=True)
            fetch_tarball_tree(MATCHA_TARBALL, os.path.dirname(matcha),
                               "Matcha-TTS")

        # The yaml resolves ../../pretrained_models/<name>/ from CWD.
        work = os.path.join(cache, "work", "run", "here")
        os.makedirs(work, exist_ok=True)
        models_dir = os.path.join(cache, "work", "pretrained_models")
        os.makedirs(models_dir, exist_ok=True)
        link = os.path.join(models_dir, MODEL_NAME)
        # This link crosses from the aux cache into the HF snapshot, and the
        # two roots move independently — a library relocate leaves it dangling.
        # `os.path.exists` follows the link, so a dangling one reads as absent;
        # the unlink is what stops the re-create from raising EEXIST.
        if not os.path.exists(link):
            if os.path.islink(link):
                os.unlink(link)
            os.symlink(self._snapshot(), link)

        for path in (repo, matcha):
            if path not in sys.path:
                sys.path.insert(0, path)
        use_mps = False
        if str(self.settings.get("device") or "cpu") == "mps":
            import torch
            use_mps = bool(torch.backends.mps.is_available())
        self._use_mps = use_mps
        self._apply_shims(use_mps)
        os.chdir(work)

        progress_cb(None, "loading InspireMusic (11 GB — this takes a "
                          "little while)")
        from inspiremusic.cli.inference import InspireMusicModel

        if use_mps:
            self._apply_mps_unification()

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
        progress_cb(None, "InspireMusic ready on "
                    + ("MPS (about 3.5× the clip length)" if use_mps
                       else "CPU — renders are slow and the estimate is "
                            "honest"))

    @staticmethod
    def _tail_clip(path: str, seconds: float = 5.0) -> str:
        """Hand continuation the clip's END. Upstream head-truncates its
        audio prompt to ~5 s, so a raw file conditioned "continue this
        song" on the opening bars — the wrong end (audit §3)."""
        try:
            audio, sr = sf.read(path, dtype="float32", always_2d=True)
        except Exception:  # noqa: BLE001 — let upstream report the file
            return path
        n = int(seconds * sr)
        if audio.shape[0] <= n:
            return path
        fd, out = tempfile.mkstemp(suffix=".wav", prefix="im-tail-")
        os.close(fd)
        sf.write(out, audio[-n:], sr)
        return out

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.model is not None
        duration_s = min(180.0, float(params.get("duration_s") or 30.0))
        self.model.max_generate_audio_seconds = duration_s
        extend = params.get("extend_audio")
        task = ("continuation" if extend and os.path.isfile(extend)
                else "text-to-music")

        progress_cb(None, f"rendering ({task}"
                    + ("; on the GPU)" if getattr(self, "_use_mps", False)
                       else "; ~29× slower than realtime on CPU — cancel "
                            "any time)"))
        for old in glob.glob(os.path.join(self._out_root, "**", "*.wav"),
                             recursive=True):
            os.unlink(old)
        if cancel.cancelled:
            raise CancelledError()
        kwargs = {"task": task, "text": prompt}
        if task == "continuation":
            kwargs["audio_prompt"] = self._tail_clip(extend)
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

        # llm.inference is a generator, one yield per audio token — wrap it
        # for counted progress and a real cancel checkpoint through the
        # longest phase, which used to run on a single message (audit §5).
        core = getattr(getattr(getattr(self.model, "model", None),
                               "model", None), "llm", None)
        orig_inf = getattr(core, "inference", None)
        if core is not None and callable(orig_inf):
            total_tokens = max(1, int(duration_s * 75))

            def counted(*a, **kw):
                for n, tok in enumerate(orig_inf(*a, **kw), 1):
                    if cancel.cancelled:
                        # llm_job runs on ITS OWN thread and the consumer
                        # loop spins until llm_end_dict flips — raising here
                        # would kill the thread before it flips and hang the
                        # render forever. Ending the generator lets the
                        # pipeline wind down; the adapter re-raises after.
                        return
                    if n % 25 == 0:
                        progress_cb(min(0.95, n / total_tokens),
                                    f"writing music — token {n}"
                                    f"/~{total_tokens}",
                                    step=n, steps=total_tokens)
                    yield tok

            core.inference = counted
        try:
            self.model.inference(**kwargs)
        finally:
            if core is not None and callable(orig_inf):
                core.inference = orig_inf
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

"""ACE-Step 1.5: full songs with vocals. LM half on MLX, DiT half on PyTorch MPS.

Uses the documented Python API (acestep.handler / acestep.llm_inference /
acestep.inference.generate_music). Weights come from the supervisor's snapshot of
ACE-Step/Ace-Step1.5 (subfolders: vae, Qwen3-Embedding-0.6B, acestep-v15-turbo,
acestep-5Hz-lm-1.7B). HF_HOME is set by the worker, so any auto-download ACE-Step
attempts resolves instantly from the same cache.

Reported phases are `lm_reasoning` → `prompt_encode` → `diffusion` → `vocoder` →
`master`, matching the `capabilities.pipeline` this family's catalog entries
declare — in that order, because the LM really does run before the DiT's input
prep. `lm_reasoning` is the optional one: the five src-audio tasks skip the LM
entirely. None of the phases carry step counts; see _PHASE_BY_DESC.
"""

from __future__ import annotations

import inspect
import os
import shutil

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb)

DIT_CONFIG = "acestep-v15-turbo"
LM_MODEL = "acestep-5Hz-lm-1.7B"

# ACE-Step's only progress signal is the `desc` string it passes to the callback,
# so the phase has to be recovered from that text. Matched in order against the
# lower-cased desc; anything unrecognised (upstream rewording, a stage added in a
# later revision) reports no phase rather than a wrong one. Ids match the
# `capabilities.pipeline` this family's catalog entries declare.
#
# None of these carry step counts, and the diffusion band must never grow one:
# upstream drives it from a `diffusion-progress` timer thread that interpolates
# a fraction from a *historical per-step estimate* (see acestep's
# ProgressMixin._start_diffusion_progress_estimator). The steps it implies were
# never counted, so they are not ours to report.
_PHASE_BY_DESC = (
    ("phase 1", "lm_reasoning"),       # CoT metadata
    ("phase 2", "lm_reasoning"),       # audio codes
    ("preparing inputs", "prompt_encode"),
    ("generating music", "diffusion"),
    ("decoding audio", "vocoder"),
    ("preparing audio", "master"),
)


class ACEStepAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.dit = None
        self.llm = None

    def _snapshot(self) -> str:
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        os.environ.setdefault("ACESTEP_LM_BACKEND", "mlx")
        os.environ.setdefault("ACESTEP_DOWNLOAD_SOURCE", "huggingface")
        # ACE-Step logs through loguru, whose default handler is DEBUG and
        # reads its level from here at import. Left at DEBUG one render wrote
        # 17,476 lines, and the INFO half of that is the useful half: what it
        # is decoding, which backend the VAE took, what it normalised to. This
        # keeps that and drops the per-tensor commentary underneath it. Set
        # before the acestep import below, because loguru reads the variable
        # once when it is first imported.
        os.environ.setdefault("LOGURU_LEVEL", "INFO")
        import torch

        from acestep.handler import AceStepHandler
        from acestep.llm_inference import LLMHandler

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        snapshot = self._snapshot()

        # initialize_service resolves models at <project_root>/checkpoints/<config>.
        # Snapshots keep those folders at their top level; variant models span two
        # repos (core package + DiT variant), so merge every snapshot's top-level
        # entries into one checkpoints dir via symlinks.
        import shutil

        root = os.path.join(self.work_dir, "acestep-project")
        ckpt = os.path.join(root, "checkpoints")
        if os.path.islink(ckpt):
            os.unlink(ckpt)
        elif os.path.isdir(ckpt):
            shutil.rmtree(ckpt)
        os.makedirs(ckpt, exist_ok=True)
        # DiT variant repos keep their files at top level; settings.dit_repo names
        # the repo whose whole snapshot becomes checkpoints/<dit_config>. Link it
        # first so it wins over any same-named folder in the core package.
        dit_config = self.settings.get("dit_config", DIT_CONFIG)
        dit_repo = self.settings.get("dit_repo")
        for repo_id, snap in self.model_paths.items():
            if dit_repo and repo_id == dit_repo:
                dst = os.path.join(ckpt, dit_config)
                if not os.path.exists(dst):
                    os.symlink(snap, dst)
        for repo_id, snap in self.model_paths.items():
            if dit_repo and repo_id == dit_repo:
                continue
            for name in os.listdir(snap):
                dst = os.path.join(ckpt, name)
                if not os.path.exists(dst):
                    os.symlink(os.path.join(snap, name), dst)
        _ = snapshot  # merged layout supersedes the single-snapshot path

        progress_cb(None, "initializing DiT (MPS)")
        self.dit = AceStepHandler()
        self._check(self._call_flexible(self.dit.initialize_service, {
            "project_root": root,
            "config_path": dit_config,
            "device": device,
        }), "DiT init")

        progress_cb(None, "initializing language model (MLX)")
        self.llm = LLMHandler()
        self._check(self._call_flexible(self.llm.initialize, {
            "checkpoint_dir": ckpt,
            "lm_model_path": self.settings.get("lm_model", LM_MODEL),
            "backend": "mlx",
            "device": device,
        }), "LM init")
        progress_cb(None, "ACE-Step ready")

    @staticmethod
    def _check(result, what: str) -> None:
        """ACE-Step init methods return (message, ok) tuples instead of raising."""
        if isinstance(result, tuple) and len(result) == 2:
            message, ok = result
            if not ok:
                raise RuntimeError(f"{what} failed: {message}")

    @staticmethod
    def _call_flexible(fn, kwargs: dict):
        """Call fn with only the kwargs it actually accepts — tolerant of upstream
        signature drift between pinned revisions."""
        accepted = set(inspect.signature(fn).parameters)
        return fn(**{k: v for k, v in kwargs.items() if k in accepted})

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        from acestep.inference import (GenerationConfig, GenerationParams,
                                       generate_music)

        assert self.dit is not None and self.llm is not None
        duration_s = float(params.get("duration_s", 60.0))
        seed = params.get("seed")

        def progress_shim(*args, **kwargs) -> None:
            if cancel.cancelled:
                raise CancelledError()
            fraction = None
            for a in args:
                if isinstance(a, (int, float)) and 0 <= a <= 1:
                    fraction = float(a)
                    break
            message = kwargs.get("desc") or next(
                (a for a in args if isinstance(a, str)), "generating")
            text = str(message)
            phase = next((p for needle, p in _PHASE_BY_DESC
                          if needle in text.lower()), None)
            progress_cb(fraction, text[:200], phase=phase)

        # Task modes (SR3): cover/repaint on any DiT; extract/lego/complete need
        # a base/sft DiT (the pipeline does not refuse a wrong DiT itself — it
        # just produces garbage, so gate here as well as in the catalog).
        task_type = str(params.get("task_type") or "text2music")
        src_audio = params.get("src_audio")
        track = params.get("track")
        dit_config = self.settings.get("dit_config", DIT_CONFIG)
        if "turbo" in dit_config and task_type not in ("text2music", "repaint",
                                                       "cover"):
            raise RuntimeError(
                f"'{task_type}' needs the Base or SFT DiT — this model runs "
                f"the Turbo DiT; pick an ACE-Step Base/SFT variant")
        if task_type != "text2music" and not src_audio:
            raise RuntimeError(f"'{task_type}' needs a source audio file")

        # FlowEdit morph: a caption-to-caption restyle that rides text2music
        # rather than being a task of its own, which is why it is the one
        # restyle mode a *turbo* DiT can serve. Upstream honours the overlay for
        # text2music and cover only, and refuses it outright without a source.
        morph = bool(params.get("flow_edit_morph")) and bool(src_audio) \
            and task_type in ("text2music", "cover")
        if params.get("flow_edit_morph") and not src_audio:
            raise RuntimeError("a morph needs a source audio file to morph")

        # The track/classes ride the instruction prompt (upstream convention;
        # empty instruction = pipeline default, which lacks the track slot).
        from acestep.constants import TASK_INSTRUCTIONS
        instruction = None
        if task_type in ("extract", "lego"):
            if track:
                instruction = TASK_INSTRUCTIONS[task_type].format(
                    TRACK_NAME=str(track).upper())
            else:
                instruction = TASK_INSTRUCTIONS[f"{task_type}_default"]
        elif task_type == "complete":
            if track:
                instruction = TASK_INSTRUCTIONS["complete"].format(
                    TRACK_CLASSES=str(track).upper())
            else:
                instruction = TASK_INSTRUCTIONS["complete_default"]

        # A morph rewrites the source rather than writing something new, so it
        # takes the src-audio rules — output length locks to the source, and
        # the LM planning half is skipped — even though its task_type says
        # text2music.
        src_task = task_type != "text2music" or morph
        gen_params = self._build_flexible(GenerationParams, {
            "task_type": task_type,
            # extract is purely mechanical: the app sends a human title as the
            # prompt (jobs require one), which must not bias the extraction
            "caption": "" if task_type == "extract" else prompt,
            "lyrics": lyrics or "",
            "instrumental": not lyrics,
            # src-audio tasks lock output length to the source
            "duration": -1 if src_task else int(duration_s),
            "inference_steps": int(params.get("steps", 8)),
            "guidance_scale": float(params.get("guidance_scale", 7.0)),
            "seed": int(seed) if seed is not None else -1,
            # 3.0 suits turbo DiTs; base/sft variants want 1.0 (set via catalog settings)
            "shift": float(self.settings.get("shift", 3.0)),
            # all five src-audio tasks are direct-conditioning: the LM is
            # skipped by the pipeline; passing thinking=False makes it explicit
            "thinking": False if src_task else bool(params.get("thinking", True)),
            "bpm": int(params["bpm"]) if params.get("bpm") else None,
            "vocal_language": str(params.get("vocal_language", "en")),
            "src_audio": src_audio,
            "reference_audio": params.get("reference_audio"),
            "audio_cover_strength": (
                float(params["audio_cover_strength"])
                if params.get("audio_cover_strength") is not None else None),
            "repainting_start": (
                float(params["repainting_start"])
                if params.get("repainting_start") is not None else None),
            "repainting_end": (
                float(params["repainting_end"])
                if params.get("repainting_end") is not None else None),
            "flow_edit_morph": True if morph else None,
            "flow_edit_source_caption": (
                str(params["flow_edit_source_caption"])
                if morph and params.get("flow_edit_source_caption") else None),
            "instruction": instruction,
            # keep extracted stems at natural levels for downstream mixing
            "enable_normalization": False if task_type == "extract" else None,
        })
        gen_config = self._build_flexible(GenerationConfig, {
            "batch_size": 1,
            "audio_format": "wav",
            "use_random_seed": seed is None,
        })

        save_dir = os.path.join(self.work_dir, "acestep-out")
        os.makedirs(save_dir, exist_ok=True)
        result = generate_music(self.dit, self.llm, gen_params, gen_config,
                                save_dir=save_dir, progress=progress_shim)
        if cancel.cancelled:
            raise CancelledError()
        if not getattr(result, "success", False):
            raise RuntimeError(str(getattr(result, "error", "generation failed")))

        progress_cb(1.0, "writing audio", phase="master")
        audio = result.audios[0]
        produced = audio["path"]
        sample_rate = int(audio.get("sample_rate", 48000))
        tmp = out_path + ".part"
        shutil.move(produced, tmp)
        os.replace(tmp, out_path)

        import soundfile as sf
        info = sf.info(out_path)
        seed_used = None
        try:
            seed_used = int(audio.get("params", {}).get("seed"))
        except (TypeError, ValueError):
            pass
        return GenerateResult(wav_path=out_path, duration_s=info.duration,
                              sample_rate=info.samplerate, seed_used=seed_used)

    @staticmethod
    def _build_flexible(cls, kwargs: dict):
        accepted = set(inspect.signature(cls).parameters)
        return cls(**{k: v for k, v in kwargs.items()
                      if k in accepted and v is not None})

    def unload(self) -> None:
        self.dit = None
        self.llm = None

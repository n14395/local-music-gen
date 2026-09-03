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
import json
import os
import random
import shutil
import threading

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, UnstoppableWorkError,
                                     clear_stale_link)

# How often the cancel token is checked while generate_music runs. Short enough
# that the button feels connected, long enough to be free.
_CANCEL_POLL_S = 0.25

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
                clear_stale_link(dst)   # a library move strands this link
                if not os.path.exists(dst):
                    os.symlink(snap, dst)
        for repo_id, snap in self.model_paths.items():
            if dit_repo and repo_id == dit_repo:
                continue
            for name in os.listdir(snap):
                dst = os.path.join(ckpt, name)
                clear_stale_link(dst)   # a library move strands this link
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
        # Drawn here when absent, never left to the pipeline: upstream reads
        # only GenerationConfig.seeds — GenerationParams.seed is decorative —
        # and with seeds unset it drew one seed to render with and reported a
        # different one (audit B7). One value, drawn once, both used and
        # reported.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else random.randrange(2**32)

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
        elif task_type in ("repaint", "cover"):
            # Left unset these ran under the pipeline's text2music fill-mask
            # instruction instead of their own (audit B7); upstream's table
            # has dedicated lines for both.
            instruction = TASK_INSTRUCTIONS[task_type]

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
            "seed": seed,
            # 3.0 suits turbo DiTs; base/sft variants want 1.0 (set via catalog settings)
            "shift": float(self.settings.get("shift", 3.0)),
            # all five src-audio tasks are direct-conditioning: the LM is
            # skipped by the pipeline; passing thinking=False makes it explicit
            "thinking": False if src_task else bool(params.get("thinking", True)),
            "bpm": int(params["bpm"]) if params.get("bpm") else None,
            "vocal_language": str(params.get("vocal_language", "en")),
            # The planning half, made steerable. Everything here is inert on a
            # src-audio task, where the pipeline skips the LM outright.
            "keyscale": _text(params.get("keyscale")),
            "timesignature": _text(params.get("timesignature")),
            "use_cot_metas": _flag(params.get("use_cot_metas")),
            "use_cot_caption": _flag(params.get("use_cot_caption")),
            "use_cot_language": _flag(params.get("use_cot_language")),
            "lm_temperature": _number(params.get("lm_temperature")),
            "lm_cfg_scale": _number(params.get("lm_cfg_scale")),
            "lm_top_p": _number(params.get("lm_top_p")),
            # A plan captured from an earlier take. Handing these back makes
            # upstream skip code generation and render the plan it already
            # wrote (inference.py: `user_provided_audio_codes`), which is what
            # "keep the song, change how it sounds" is made of. The LM still
            # runs its cheap first phase for the metadata unless `thinking` is
            # off, so the take stays properly conditioned.
            "audio_codes": _text(params.get("audio_codes")),
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
            # seeds is the field generation actually reads (prepare_seeds
            # gets config.seeds joined to a string; params.seed never enters).
            "seeds": [seed],
            "use_random_seed": False,
        })

        # config.seeds pins every draw that takes a key, but the MLX SDE
        # sampler also pulls per-step noise from the GLOBAL RNG
        # (dit_generate.py: unkeyed mx.random.normal) — pin that too, or a
        # pinned seed still renders a different song each run (2026-09
        # revalidation finding).
        try:
            import mlx.core as mx
            mx.random.seed(seed)
        except Exception:  # noqa: BLE001 — a missing runtime seeds nothing
            pass
        try:
            import torch
            torch.manual_seed(seed)
        except Exception:  # noqa: BLE001
            pass

        save_dir = os.path.join(self.work_dir, "acestep-out")
        os.makedirs(save_dir, exist_ok=True)
        result = self._generate_cancellably(
            lambda: generate_music(self.dit, self.llm, gen_params, gen_config,
                                   save_dir=save_dir, progress=progress_shim),
            cancel)
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
        # The pipeline's readback when it has one, else the seed we pinned —
        # which config.seeds guarantees is the one that rendered.
        seed_used = seed
        try:
            seed_used = int(audio.get("params", {}).get("seed"))
        except (TypeError, ValueError):
            pass
        return GenerateResult(wav_path=out_path, duration_s=info.duration,
                              sample_rate=info.samplerate, seed_used=seed_used,
                              extra=self._plan_of(result, gen_params))

    @staticmethod
    def _plan_of(result, gen_params) -> dict:
        """What the language model decided, for the app to show and reuse.

        Empty for the src-audio tasks, which never run the LM — an absent plan
        is the honest answer there, and the app draws nothing rather than
        inventing a tempo the model was never asked for.
        """
        extra = getattr(result, "extra_outputs", None) or {}
        metadata = extra.get("lm_metadata")
        # The codes actually rendered: either the ones the LM wrote this run or
        # the ones handed in. Both are worth returning — the app cannot tell
        # which happened, and either way this is the plan behind this audio.
        codes = ""
        try:
            codes = str(getattr(gen_params, "audio_codes", "") or "")
        except Exception:  # noqa: BLE001 — a plan is never worth failing over
            codes = ""
        for key in ("audio_codes", "lm_audio_codes"):
            got = extra.get(key)
            if isinstance(got, str) and got:
                codes = got
                break
            if isinstance(got, list) and got and isinstance(got[0], str):
                codes = got[0]
                break
        else:
            # Where the pipeline actually files a take's rendered codes
            # (audit B7): per-audio params. Without this fallback, "render
            # this plan again" quietly re-rolled from nothing.
            try:
                got = (result.audios[0].get("params") or {}).get("audio_codes")
                if isinstance(got, str) and got:
                    codes = got
            except (AttributeError, IndexError, TypeError):
                pass
        plan: dict = {}
        if isinstance(metadata, dict) and metadata:
            plan["lm_metadata"] = metadata
        if codes:
            plan["audio_codes"] = codes
        if plan:
            plan["planner"] = "acestep-5hz-lm"
        return plan

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        """`plan`: run only the language-model half and return what it wrote.

        The expensive part of an ACE-Step render is the DiT. The planner in
        front of it is comparatively cheap, and it is the half that decides
        what the song actually *is* — tempo, key, time signature, the shape of
        the arrangement. Running it alone lets someone read three plans in the
        time one render would take and pick the one they want before paying
        for it.

        Each plan is (metadata, codes): the metadata is human-readable and is
        what the app puts on screen; the codes are the sketch the DiT will
        render, opaque but reusable. Handing a chosen plan's codes back to
        `generate` renders that exact plan.
        """
        if task != "plan":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.llm is not None

        count = max(1, min(6, int(params.get("plan_count") or 3)))
        caption = _text(params.get("plan_caption")) or ""
        lyrics = _text(params.get("plan_lyrics")) or ""
        duration = _number(params.get("plan_duration_s"))

        # Only the values the user actually pinned. Upstream treats a present
        # key as "do not think about this one", so sending our own defaults
        # here would quietly disable the planning we are trying to show off.
        pinned: dict = {}
        if params.get("bpm"):
            pinned["bpm"] = int(params["bpm"])
        if _text(params.get("keyscale")):
            pinned["keyscale"] = _text(params.get("keyscale"))
        if _text(params.get("timesignature")):
            pinned["timesignature"] = _text(params.get("timesignature"))
        if duration:
            pinned["duration"] = int(duration)

        plans: list[dict] = []
        for i in range(count):
            if cancel.cancelled:
                raise CancelledError()
            progress_cb(i / count, f"planning {i + 1} of {count}")

            def plan_progress(*args, **kwargs) -> None:
                if cancel.cancelled:
                    raise CancelledError()

            result = self._call_flexible(
                self.llm.generate_with_stop_condition, {
                    "caption": caption,
                    "lyrics": lyrics,
                    # Both phases: metadata *and* the code sketch, because a
                    # plan the user picks has to be renderable exactly as
                    # shown. Phase 1 alone would make "pick this one" a
                    # re-roll rather than a choice.
                    "infer_type": "llm_dit",
                    "temperature": _number(params.get("lm_temperature")) or 0.85,
                    "cfg_scale": _number(params.get("lm_cfg_scale")) or 2.0,
                    "top_p": _number(params.get("lm_top_p")) or 0.9,
                    "target_duration": duration,
                    "user_metadata": pinned or None,
                    "use_cot_metas": _flag(params.get("use_cot_metas"), True),
                    "use_cot_caption": _flag(params.get("use_cot_caption"), True),
                    "use_cot_language": _flag(params.get("use_cot_language"), True),
                    "batch_size": 1,
                    "progress": plan_progress,
                })
            if not isinstance(result, dict) or not result.get("success", False):
                message = "planning failed"
                if isinstance(result, dict):
                    message = str(result.get("error") or message)
                raise RuntimeError(message)
            metadata = result.get("metadata") or {}
            codes = result.get("audio_codes") or ""
            if isinstance(metadata, list):
                metadata = metadata[0] if metadata else {}
            if isinstance(codes, list):
                codes = codes[0] if codes else ""
            plans.append({"index": i, "metadata": metadata,
                          "audio_codes": codes})

        progress_cb(1.0, "plans ready")
        path = os.path.join(out_dir, "plans.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump({"plans": plans}, f, ensure_ascii=False)
        os.replace(tmp, path)
        return TaskResult(
            artifacts=[Artifact(kind="plan", label="plans", path=path,
                                format="json")],
            meta={"plans": plans})

    @staticmethod
    def _generate_cancellably(call, cancel: CancelToken):
        """Run `call` on a thread this adapter owns, so the cancel token can be
        read while it runs.

        The progress callback cannot serve as the cancel check for this family,
        which is what it was doing. Upstream's `generate_music` hands the real
        work to its own `service-generate` thread, drives our shim from a
        *separate* progress-estimator thread, and calls that shim inside
        `except Exception: pass` (`handler/progress.py`) — so the CancelledError
        the shim raises during diffusion is raised on the wrong thread and then
        thrown away. Meanwhile upstream's own thread is joined with a 600 s
        timeout, and there is no per-step hook to reach it through: pressing
        Cancel take did nothing at all for the length of a render.

        So the token is polled here instead, on the thread that can act on it.

        What we cannot do is stop the work. Python cannot interrupt a thread,
        upstream offers no way in, and the diffusion holds the GPU either way —
        upstream's own timeout path admits as much ("the CUDA operation may
        still be running in the background"), and the worker log shows exactly
        that: an abandoned DiT loop still stepping while the next job's LM phase
        started in the same process, each starving the other. Hence
        UnstoppableWorkError: the job is cancelled, and the process goes with
        it, because process death is the only unload this codebase trusts.
        """
        box: dict = {}

        def run() -> None:
            try:
                box["value"] = call()
            except BaseException as e:  # noqa: BLE001 — re-raised on the caller
                box["error"] = e

        thread = threading.Thread(target=run, name="acestep-generate",
                                  daemon=True)
        thread.start()
        while True:
            thread.join(timeout=_CANCEL_POLL_S)
            if not thread.is_alive():
                break
            if cancel.cancelled:
                raise UnstoppableWorkError(
                    "ACE-Step cannot stop a generation once it has started")
        if "error" in box:
            # Includes the CancelledError the shim raises from upstream's own
            # main-thread progress calls, which unwinds cleanly and leaves the
            # worker reusable — the good case, and the reason this is not
            # simply UnstoppableWorkError every time.
            raise box["error"]
        return box.get("value")

    @staticmethod
    def _build_flexible(cls, kwargs: dict):
        accepted = set(inspect.signature(cls).parameters)
        return cls(**{k: v for k, v in kwargs.items()
                      if k in accepted and v is not None})

    def unload(self) -> None:
        self.dit = None
        self.llm = None


# MARK: param coercion
#
# Every one of these returns None for "not set", because `_build_flexible`
# drops None and lets upstream's own default stand. A param the user left blank
# must reach the pipeline as absent, not as an empty string or a zero — an
# empty `keyscale` is a key the model should choose, while `""` handed to
# `user_metadata` would read as a key it has already been told.

def _text(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _number(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _flag(value, default=None):
    if value is None:
        return default
    return bool(value)

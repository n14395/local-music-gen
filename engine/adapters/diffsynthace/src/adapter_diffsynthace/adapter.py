"""ACE-Step 1.5 XL LoRA pack on the DiffSynth-Studio runtime.

A separate family from `acestep` on purpose: that one runs the upstream
acestep package (LM + DiT pipeline); this one is DiffSynth's own AceStep
implementation, which is what the ModelScope-exclusive LoRAs were built
against. Two runtimes, two families — the rule the adapter layout is built on.

Entries share the XL SFT base (HF: the sharded DiT + the core repo's Qwen3
text embedder and VAE) and differ in the LoRA they load (ModelScope,
`ms_repos`). vocals2music additionally wraps the pipeline in DiffSynth's
TemplatePipeline: its repo carries a small ControlNet (`model.py`) that
conditions the DiT on an a-cappella vocal, so the render is an accompaniment
around the voice rather than a song from nothing.

Proven numbers (this Mac, MPS bf16, triage 2026-08-25): pipeline load ~23 s;
vocals2music 30 s of accompaniment in ~30 s at 12 steps (~21 GB peak);
instrument LoRAs ~26 s for 20 s clips.
"""

from __future__ import annotations

import glob
import os

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

CORE_REPO = "ACE-Step/Ace-Step1.5"
DIT_REPO = "ACE-Step/acestep-v15-xl-sft"


class DiffSynthAceAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.pipe = None
        self.template = None
        self.device = "cpu"

    def _path(self, repo_id: str) -> str:
        path = self.model_paths.get(repo_id)
        if not path:
            raise RuntimeError(f"snapshot for {repo_id} is missing")
        return path

    def load(self, progress_cb: ProgressCb) -> None:
        import torch
        from diffsynth.pipelines.ace_step import AceStepPipeline, ModelConfig

        core = self._path(CORE_REPO)
        dit = self._path(DIT_REPO)
        shards = sorted(glob.glob(os.path.join(dit, "model-*.safetensors")))
        if not shards:
            raise RuntimeError(f"no DiT shards under {dit}")

        self.device = ("mps" if torch.backends.mps.is_available() else "cpu")
        dtype = torch.bfloat16 if self.device == "mps" else torch.float32

        progress_cb(None, "loading ACE-Step XL (DiT + text embedder + VAE)")
        self.pipe = AceStepPipeline.from_pretrained(
            torch_dtype=dtype,
            device=self.device,
            model_configs=[
                ModelConfig(path=shards),
                ModelConfig(path=os.path.join(
                    core, "Qwen3-Embedding-0.6B", "model.safetensors")),
                ModelConfig(path=os.path.join(
                    core, "vae", "diffusion_pytorch_model.safetensors")),
            ],
            text_tokenizer_config=ModelConfig(
                path=os.path.join(core, "Qwen3-Embedding-0.6B")),
        )

        lora_repo = self.settings.get("lora_repo")
        if lora_repo:
            progress_cb(None, "applying the LoRA")
            self.pipe.load_lora(
                self.pipe.dit,
                ModelConfig(path=os.path.join(self._path(lora_repo),
                                              "model.safetensors")))

        template_repo = self.settings.get("template_repo")
        if template_repo:
            progress_cb(None, "loading the vocal-conditioning ControlNet")
            from diffsynth.diffusion.template import TemplatePipeline

            self.template = TemplatePipeline.from_pretrained(
                torch_dtype=dtype,
                device=self.device,
                model_configs=[ModelConfig(path=self._path(template_repo))],
            )
        progress_cb(None, f"ACE-Step XL ready on {self.device}")

    def _read_audio(self, path: str):
        """(channels, samples) float32 tensor at the VAE's rate."""
        import soxr
        import torch

        target_sr = int(self.pipe.vae.sampling_rate)
        audio, sr = sf.read(path, dtype="float32", always_2d=True)
        if sr != target_sr:
            audio = soxr.resample(audio, sr, target_sr)
        return torch.from_numpy(np.ascontiguousarray(audio.T)), target_sr

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.pipe is not None
        duration = int(float(params.get("duration_s") or 30))
        steps = max(1, min(50, int(params.get("steps") or 12)))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else None

        kwargs: dict = {
            "prompt": prompt,
            "lyrics": lyrics or "[instrumental]",
            "duration": duration,
            "cfg_scale": float(params.get("cfg_scale") or 1.0),
            "num_inference_steps": steps,
            "shift": float(self.settings.get("shift", 6.0)),
            "seed": seed,
        }
        bpm = params.get("bpm")
        if bpm is not None:
            kwargs["bpm"] = int(bpm)
        keyscale = str(params.get("keyscale") or "").strip()
        if keyscale:
            kwargs["keyscale"] = keyscale
        timesignature = str(params.get("timesignature") or "").strip()
        if timesignature:
            kwargs["timesignature"] = timesignature
        if params.get("vocal_language"):
            kwargs["vocal_language"] = str(params["vocal_language"])

        # Cover / repaint / reference conditioning — the DiffSynth pipeline
        # takes the same task vocabulary as upstream ACE-Step (`text2music`,
        # `cover`, `repaint`), so the app's Style-Transfer modes drive the
        # LoRA pack with no translation layer.
        task_type = str(params.get("task_type") or "text2music").strip()
        kwargs["task_type"] = task_type
        src_path = params.get("src_audio")
        if src_path and os.path.isfile(src_path):
            progress_cb(None, "reading the source audio",
                        phase="prompt_encode")
            src, _sr = self._read_audio(src_path)
            kwargs["src_audio"] = src
        if params.get("audio_cover_strength") is not None:
            kwargs["audio_cover_strength"] = float(
                params["audio_cover_strength"])
        if params.get("denoising_strength") is not None:
            kwargs["denoising_strength"] = float(params["denoising_strength"])
        ref_path = params.get("reference_audio")
        if ref_path and os.path.isfile(ref_path):
            progress_cb(None, "reading the reference audio",
                        phase="prompt_encode")
            ref, _sr = self._read_audio(ref_path)
            kwargs["reference_audios"] = [ref]
        codes = str(params.get("audio_codes") or "").strip()
        if codes:
            # A plan's token string from an ACE-Step LM, re-rendered through
            # the XL SFT + LoRA — same token format, shared upstream.
            kwargs["audio_code_string"] = codes
        start = params.get("repainting_start")
        end = params.get("repainting_end")
        if start is not None and end is not None and float(end) > float(start):
            kwargs["repainting_ranges"] = [(float(start), float(end))]
            if params.get("repainting_strength") is not None:
                kwargs["repainting_strength"] = float(
                    params["repainting_strength"])

        def stepper(timesteps):
            total = len(timesteps)
            for i, t in enumerate(timesteps):
                if cancel.cancelled:
                    raise CancelledError()
                progress_cb(i / total, "rendering", phase="diffusion",
                            step=i + 1, steps=total)
                yield t

        kwargs["progress_bar_cmd"] = stepper

        if self.template is not None:
            vocal_path = params.get("accompany_audio")
            if not vocal_path or not os.path.isfile(vocal_path):
                raise RuntimeError("accompany_audio missing — this model "
                                   "builds a band around a vocal recording")
            progress_cb(None, "reading the vocal", phase="prompt_encode")
            vocals, sr = self._read_audio(vocal_path)
            # The template conditions on what it is given: cap the render at
            # the vocal's own length so the band never plays on after the
            # singer stops.
            vocal_s = vocals.shape[1] / sr
            kwargs["duration"] = int(min(duration, max(1.0, vocal_s)))
            scale = float(params.get("template_scale") or 1.0)
            audio = self.template(
                self.pipe,
                template_inputs=[{"audio": (vocals, sr), "scale": scale}],
                **kwargs)
        else:
            progress_cb(None, "encoding the prompt", phase="prompt_encode")
            audio = self.pipe(**kwargs)

        if cancel.cancelled:
            raise CancelledError()
        progress_cb(None, "decoding and saving", phase="master")
        sample_rate = int(self.pipe.vae.sampling_rate)
        wav = audio
        if hasattr(wav, "dim") and wav.dim() == 3:
            wav = wav[0]
        wav = wav.float().cpu().numpy().T  # (samples, channels)
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(wav.shape[0] / sample_rate, 3),
            sample_rate=sample_rate,
            seed_used=seed)

    def unload(self) -> None:
        self.pipe = None
        self.template = None
        try:
            import torch

            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:  # noqa: BLE001 — unload must never raise
            pass

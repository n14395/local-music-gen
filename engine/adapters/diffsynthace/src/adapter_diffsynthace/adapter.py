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
import secrets

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

CORE_REPO = "ACE-Step/Ace-Step1.5"
DIT_REPO = "ACE-Step/acestep-v15-xl-sft"

# Above this, decode the VAE in tiles (see the note at the `tiled` kwarg).
# 240 s rather than the ~350 s the arithmetic gives: 240 is the longest take
# this family shipped before the ceiling moved to 600, so it is the longest
# the untiled path is known — not calculated — to survive.
TILED_DECODE_ABOVE_S = 240.0


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
            # Without this the default ModelConfig silently downloads the
            # file from modelscope.cn into $CWD/models on first load (audit
            # B9) — the identical tensor already ships in the xl-sft
            # snapshot.
            silence_latent_config=ModelConfig(
                path=os.path.join(dit, "silence_latent.pt")),
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
        if audio.shape[1] == 1:
            # The VAE's front conv is Conv1d(2, …): a mono voice memo — the
            # most likely vocals2music input — crashed it (audit B9).
            audio = np.repeat(audio, 2, axis=1)
        return torch.from_numpy(np.ascontiguousarray(audio.T)), target_sr

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.pipe is not None
        duration = int(float(params.get("duration_s") or 30))
        steps = max(1, min(50, int(params.get("steps") or 12)))
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. `seed_used` reports it back.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)

        kwargs: dict = {
            "prompt": prompt,
            "lyrics": lyrics or "[instrumental]",
            "duration": duration,
            "cfg_scale": float(params.get("cfg_scale") or 1.0),
            "num_inference_steps": steps,
            "shift": float(self.settings.get("shift", 6.0)),
            "seed": seed,
        }
        # The DiT renders any length the catalog offers, but the VAE decode is
        # where a long take dies: the decoder's last upsampling block holds
        # 128 channels x 48000 samples per second of audio in one tensor, and
        # past roughly 350 s that clears the 2^31 elements MPS can address, so
        # conv_transpose1d falls off the Metal path and raises
        # "convolution_overrideable not implemented" — after the whole
        # diffusion has already been paid for.
        #
        # `tiled` is upstream's own answer (OobleckVAE.tiled_decode): decode
        # ~20 s of latent at a time, blend the overlaps, accumulate on CPU.
        # Only above a length the untiled path is known to survive, because
        # tiling decodes the overlap twice and there is no reason to spend
        # that on a 30 s take.
        if duration > TILED_DECODE_ABOVE_S:
            kwargs["tiled"] = True
        # Blank is not "model chooses" here: omitting these lands on the
        # pipeline's literal defaults — 100 BPM, B minor, 4/4 — baked into
        # every conditioning string (audit B9). "N/A" is upstream's own
        # free-choice sentinel (it only ever reaches an f-string, so a
        # string bpm is safe).
        bpm = params.get("bpm")
        kwargs["bpm"] = int(bpm) if bpm is not None else "N/A"
        kwargs["keyscale"] = str(params.get("keyscale") or "").strip() or "N/A"
        kwargs["timesignature"] = (str(params.get("timesignature") or "")
                                   .strip() or "N/A")
        if params.get("vocal_language"):
            kwargs["vocal_language"] = str(params["vocal_language"])

        # Cover / repaint / reference conditioning — the DiffSynth pipeline
        # takes the same task vocabulary as upstream ACE-Step (`text2music`,
        # `cover`, `repaint`), so the app's Style-Transfer modes drive the
        # LoRA pack with no translation layer.
        task_type = str(params.get("task_type") or "text2music").strip()
        kwargs["task_type"] = task_type
        src_path = params.get("src_audio")
        src_path = src_path if src_path and os.path.isfile(src_path) else None
        codes = str(params.get("audio_codes") or "").strip()
        # The same guard the two sibling ACE-Step adapters carry, and for the
        # same reason: without it a source task reaches DiffSynth's own
        # assertion ("For cover task, either src_audio or audio_code_string
        # must be provided"), which fires *after* the ~23 s pipeline load and
        # names wire keys the user never typed.
        #
        # Codes stand in for the file on a cover, because upstream accepts
        # either — a captured plan is a source of a different kind. Not on a
        # repaint, which masks a span of the source's own latent and so has
        # nothing to mask without one.
        has_source = bool(src_path) or (task_type == "cover" and bool(codes))
        if task_type != "text2music" and not has_source:
            raise RuntimeError(
                f"'{task_type}' works on existing audio — add a source file")
        if src_path:
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
        if codes:
            # A plan's token string from an ACE-Step LM, re-rendered through
            # the XL SFT + LoRA — same token format, shared upstream.
            kwargs["audio_code_string"] = codes
        start = params.get("repainting_start")
        end = params.get("repainting_end")
        if start is not None:
            start = float(start)
            end = float(end) if end is not None else -1.0
            if end < 0:
                # The advertised "-1 = to the end" (audit B9): resolve it to
                # the source's real duration instead of silently dropping
                # the range into an upstream assert.
                src_t = kwargs.get("src_audio")
                if src_t is not None:
                    end = src_t.shape[1] / float(self.pipe.vae.sampling_rate)
            if end > start:
                kwargs["repainting_ranges"] = [(start, end)]
                if params.get("repainting_strength") is not None:
                    kwargs["repainting_strength"] = float(
                        params["repainting_strength"])
        # Upstream asserts a non-empty range for repaint, so a window that was
        # never set — or that ends before it starts — is the same dead end as a
        # missing source, one dialog further in. Said here, in seconds, with
        # the names of the two controls that fix it.
        if task_type == "repaint" and "repainting_ranges" not in kwargs:
            raise RuntimeError(
                "repaint needs a window to repaint — set a start and an end, "
                "with the end after the start")

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

"""ACE-Step 1.5 via acestep.cpp — the native C++/GGML runtime (Metal on Macs).

Two-stage CLI pipeline, one subprocess each per generation:
  ace-lm    caption(+lyrics) -> metadata + audio codes (writes <req>0.json)
  ace-synth codes -> DiT flow matching -> VAE -> 48 kHz stereo WAV

The GGUF files live in the model snapshot (the catalog entry downloads exactly
the files this runtime needs via allow_patterns). Binaries are built by
scripts/build_acestep_cpp.sh into engine/adapters/acestepcpp/bin. There is no
resident model: each run mmaps the GGUFs fresh, which takes seconds.
Cancellation kills the child process; the worker itself stays alive.

Reported phases are `lm_reasoning` → `diffusion` → `vocoder` → `master`, matching
the `capabilities.pipeline` this family's catalog entries declare. Unlike the
Python ACE-Step runtime, the C++ tools print real step numbers on stderr, so the
diffusion phase here does carry counts.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb,
                                     clear_stale_link)

# stderr progress lines emitted by the tools
_LM1_RE = re.compile(r"\[LM-Phase1\] Step (\d+)")
_LM2_RE = re.compile(r"\[LM-Phase2\] Step (\d+)")
_DIT_RE = re.compile(r"\[DiT\] Step (\d+)/(\d+)")
LM_CODE_RATE = 5.0  # audio codes per second of music (5 Hz LM)


def _bin_dir() -> Path:
    if custom := os.environ.get("LOCALMUSIC_ACESTEP_CPP_BIN"):
        return Path(custom)
    # src/adapter_acestepcpp/adapter.py -> adapters/acestepcpp/bin
    return Path(__file__).resolve().parents[2] / "bin"


class AceStepCppAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.models_dir: str | None = None
        self.adapters_dir: str | None = None

    def load(self, progress_cb: ProgressCb) -> None:
        bin_dir = _bin_dir()
        for tool in ("ace-lm", "ace-synth"):
            if not os.access(bin_dir / tool, os.X_OK):
                raise RuntimeError(
                    f"acestep.cpp binary missing: {bin_dir / tool} — run "
                    f"scripts/build_acestep_cpp.sh (needs cmake)")
        # By repo id, not "the first one": an entry that also declares LoRA
        # repos has several snapshots and only one of them holds the GGUFs.
        self.models_dir = next(
            (path for repo, path in self.model_paths.items()
             if "GGUF" in repo or "gguf" in repo),
            next(iter(self.model_paths.values())))
        for key in ("lm_model", "synth_model", "vae"):
            name = self.settings.get(key)
            if name and not os.path.exists(os.path.join(self.models_dir, name)):
                raise RuntimeError(f"model file missing from snapshot: {name}")
        self.adapters_dir = self._stage_adapters()
        progress_cb(None, "acestep.cpp ready (models load per generation)")

    def _stage_adapters(self) -> str | None:
        """Give the binary an adapters directory it can scan, or None.

        `registry_scan_adapters` identifies an adapter by its FILENAME, and
        every LoRA snapshot on the Hub calls its weights `model.safetensors` —
        so four snapshots would present as four copies of one name. Symlinking
        each into a directory of our own under the name the catalog uses is
        the whole trick, and it is also what lets the catalog's enum values be
        readable words rather than repo ids.
        """
        loras = {key: os.path.join(path, "model.safetensors")
                 for key, repo in (self.settings.get("adapters") or {}).items()
                 for name, path in self.model_paths.items() if name == repo}
        loras = {k: v for k, v in loras.items() if os.path.exists(v)}
        if not loras:
            return None
        staged = os.path.join(self.work_dir, "adapters")
        os.makedirs(staged, exist_ok=True)
        for key, source in loras.items():
            link = os.path.join(staged, f"{key}.safetensors")
            clear_stale_link(link)
            if not os.path.exists(link):
                try:
                    os.symlink(source, link)
                except OSError:
                    pass
        return staged

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.models_dir is not None
        duration_s = float(params.get("duration_s", 60.0))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else -1

        # The six source-audio tasks. Every one of them exists in the binary's
        # own request schema and dispatch table (`pipeline-synth.cpp`), and
        # none was reachable: the adapter only ever sent text2music.
        task_type = str(params.get("task_type") or "text2music")
        src_audio = params.get("src_audio")
        src_audio = src_audio if src_audio and os.path.isfile(src_audio) else None
        ref_audio = params.get("reference_audio")
        ref_audio = ref_audio if ref_audio and os.path.isfile(ref_audio) else None
        if task_type != "text2music" and src_audio is None:
            raise RuntimeError(
                f"'{task_type}' works on existing audio — add a source file")

        request = {
            "caption": prompt,
            "lyrics": lyrics or "",
            "duration": duration_s,
            "seed": seed,
            "lm_seed": seed,
            "inference_steps": int(params.get("steps", 0)),
            "guidance_scale": float(params.get("guidance_scale", 0.0)),
            "use_cot_caption": bool(params.get("thinking", True)),
            "output_format": "wav16",
            "task_type": task_type,
            "lm_model": self.settings.get("lm_model", ""),
            "synth_model": self.settings.get("synth_model", ""),
            "vae": self.settings.get("vae", ""),
        }
        if params.get("bpm"):
            request["bpm"] = int(params["bpm"])
        # Facts the composer LM would otherwise invent, and the planner's own
        # sampler — the same surface the Python ACE-Step family exposes, which
        # this runtime had in its request struct all along.
        for key in ("keyscale", "timesignature", "vocal_language", "track"):
            value = str(params.get(key) or "").strip()
            if value:
                request[key] = value
        for key in ("lm_temperature", "lm_cfg_scale", "lm_top_p"):
            if params.get(key) is not None:
                request[key] = float(params[key])
        negative = str(params.get("negative_prompt") or "").strip()
        if negative:
            # The LM's negative branch, not the DiT's: this steers the plan
            # (what the song is) rather than the render (how it sounds).
            request["lm_negative_prompt"] = negative
        if params.get("audio_cover_strength") is not None:
            request["audio_cover_strength"] = float(
                params["audio_cover_strength"])
        if params.get("repainting_start") is not None:
            request["repainting_start"] = float(params["repainting_start"])
        if params.get("repainting_end") is not None:
            request["repainting_end"] = float(params["repainting_end"])

        # LoRA. The runtime merges the adapter into the quantised GGUF weights
        # before upload (`adapter-merge.h`, which names Q8_0 and the K-quants
        # explicitly), so this is a real merge and not a second model.
        adapter = str(params.get("adapter") or "").strip()
        if adapter and adapter != "none":
            if not self.adapters_dir:
                raise RuntimeError(
                    "this model has no LoRA pack installed — reinstall the "
                    "entry to fetch it")
            request["adapter"] = f"{adapter}.safetensors"
            request["adapter_scale"] = float(
                params.get("adapter_scale") or 1.0)

        req_path = os.path.join(self.work_dir, "request.json")
        with open(req_path, "w") as f:
            json.dump(request, f)

        bin_dir = _bin_dir()
        lm_total = max(1, int(duration_s * LM_CODE_RATE))

        def lm_progress(line: str) -> None:
            if m := _LM1_RE.search(line):
                # pass 1 prints a step number but no total (the CoT metadata
                # runs to an end token), so it reports the phase alone
                progress_cb(0.05, f"language model: pass 1 (step {m.group(1)})",
                            phase="lm_reasoning")
            elif m := _LM2_RE.search(line):
                step = int(m.group(1))
                frac = min(1.0, step / lm_total)
                # `step` is read straight out of the tool; `lm_total` is a
                # projection from the requested duration, which the `min(1.0,
                # ...)` two lines up already admits `step` can exceed. It is
                # good enough to drive a fraction and not good enough to print
                # as a total, so the phase carries the step alone — the same
                # way pass 1 above drops what it does not know. (`_DIT_RE`
                # below is the honest shape: the tool prints its own total.)
                progress_cb(0.1 + 0.45 * frac,
                            f"language model: composing ({step} codes)",
                            phase="lm_reasoning", step=step)

        if task_type == "text2music":
            self._run_tool([str(bin_dir / "ace-lm"),
                            "--models", self.models_dir,
                            "--request", req_path],
                           lm_progress, cancel, "ace-lm")
            codes_path = os.path.join(self.work_dir, "request0.json")
            if not os.path.exists(codes_path):
                raise RuntimeError("ace-lm produced no output request")
        else:
            # The source-audio tasks skip the composer entirely — the plan is
            # the audio you handed over, and the DiT reads its codes from
            # `--src-audio`. The Python family does the same, for the same
            # reason. So ace-synth reads the original request.
            progress_cb(0.05, f"reading the source ({task_type})",
                        phase="lm_reasoning")
            codes_path = req_path

        def synth_progress(line: str) -> None:
            if m := _DIT_RE.search(line):
                step, total = int(m.group(1)), max(1, int(m.group(2)))
                progress_cb(0.55 + 0.4 * min(1.0, step / total),
                            f"denoising: step {step}/{total}",
                            phase="diffusion", step=step, steps=total)
            elif "[VAE]" in line:
                # The binary announces the decode as "[VAE] Tiled decode:" /
                # "[VAE] Decoded:" — the old "[Ace-Synth] … Write" match
                # never fired, so the UI parked on Diffusion through the
                # whole decode (audit §5).
                progress_cb(0.97, "decoding audio", phase="vocoder")

        synth_cmd = [str(bin_dir / "ace-synth"),
                     "--models", self.models_dir, "--request", codes_path]
        if src_audio:
            synth_cmd += ["--src-audio", src_audio]
        if ref_audio:
            synth_cmd += ["--ref-audio", ref_audio]
        if self.adapters_dir and request.get("adapter"):
            synth_cmd += ["--adapters", self.adapters_dir]
        self._run_tool(synth_cmd, synth_progress, cancel, "ace-synth")

        # ace-synth names its output `<request basename><index>.wav`, so which
        # request it was handed decides the filename: `request0.json` from the
        # LM gives `request00.wav`, the original `request.json` gives
        # `request0.wav`.
        wav_src = os.path.splitext(codes_path)[0] + "0.wav"
        if not os.path.exists(wav_src):
            raise RuntimeError("ace-synth produced no audio")
        # The fp16 weight-norm vocoder failure mode is an all-NaN latent
        # written as a silent WAV that passes every existence check
        # (audit §3) — fail loudly instead of shipping silence.
        check, _sr = sf.read(wav_src, dtype="float32", always_2d=True)
        if check.size and float(abs(check).max()) < 1e-5:
            raise RuntimeError(
                "the vocoder produced silence (a known fp16 overflow "
                "symptom) — try the render again; if it repeats, report "
                "the model variant")
        progress_cb(1.0, "writing audio", phase="master")
        os.replace(wav_src, out_path)
        info = sf.info(out_path)
        with open(codes_path) as f:
            seed_used = json.load(f).get("seed", seed)
        return GenerateResult(wav_path=out_path,
                              duration_s=float(info.frames) / info.samplerate,
                              sample_rate=int(info.samplerate),
                              seed_used=int(seed_used) if seed_used >= 0 else None)

    def _run_tool(self, cmd: list[str], on_line, cancel: CancelToken,
                  name: str) -> None:
        proc = subprocess.Popen(cmd, cwd=self.work_dir,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True, bufsize=1)
        tail: list[str] = []
        assert proc.stderr is not None
        try:
            for line in proc.stderr:
                if cancel.cancelled:
                    proc.kill()
                    raise CancelledError()
                line = line.rstrip()
                if line:
                    tail = (tail + [line])[-8:]
                    # Forward before parsing. These are the richest per-step
                    # lines any family in this app produces — `[DiT] Step 6/8`,
                    # the LM's own counters — and until now they were read for
                    # their numbers and then dropped on the floor, so the one
                    # runtime with real output had the emptiest log pane. The
                    # worker's stderr is mirrored to that pane (contract §6);
                    # this is the only thing standing between the two.
                    print(line, file=sys.stderr, flush=True)
                    on_line(line)
            proc.wait()
        finally:
            if proc.poll() is None:
                proc.kill()
        if cancel.cancelled:
            raise CancelledError()
        if proc.returncode != 0:
            raise RuntimeError(f"{name} failed (exit {proc.returncode}): "
                               + " | ".join(tail[-3:]))

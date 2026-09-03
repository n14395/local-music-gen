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
                                     ModelAdapter, ProgressCb)

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

    def load(self, progress_cb: ProgressCb) -> None:
        bin_dir = _bin_dir()
        for tool in ("ace-lm", "ace-synth"):
            if not os.access(bin_dir / tool, os.X_OK):
                raise RuntimeError(
                    f"acestep.cpp binary missing: {bin_dir / tool} — run "
                    f"scripts/build_acestep_cpp.sh (needs cmake)")
        self.models_dir = next(iter(self.model_paths.values()))
        for key in ("lm_model", "synth_model", "vae"):
            name = self.settings.get(key)
            if name and not os.path.exists(os.path.join(self.models_dir, name)):
                raise RuntimeError(f"model file missing from snapshot: {name}")
        progress_cb(None, "acestep.cpp ready (models load per generation)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.models_dir is not None
        duration_s = float(params.get("duration_s", 60.0))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else -1

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
            "lm_model": self.settings.get("lm_model", ""),
            "synth_model": self.settings.get("synth_model", ""),
            "vae": self.settings.get("vae", ""),
        }
        if params.get("bpm"):
            request["bpm"] = int(params["bpm"])

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

        self._run_tool([str(bin_dir / "ace-lm"),
                        "--models", self.models_dir, "--request", req_path],
                       lm_progress, cancel, "ace-lm")

        codes_path = os.path.join(self.work_dir, "request0.json")
        if not os.path.exists(codes_path):
            raise RuntimeError("ace-lm produced no output request")

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

        self._run_tool([str(bin_dir / "ace-synth"),
                        "--models", self.models_dir, "--request", codes_path],
                       synth_progress, cancel, "ace-synth")

        wav_src = os.path.join(self.work_dir, "request00.wav")
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

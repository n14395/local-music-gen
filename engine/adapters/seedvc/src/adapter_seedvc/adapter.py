# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""seed-vc zero-shot voice conversion (task `convert-voice`).

The consent-clean voice architecture: the target voice is a short recording
the USER supplies per job (`reference_audio`) — there is no voice library
anywhere in this family, on purpose. Speaks and sings (`sing_mode` switches
on F0 conditioning, seed-vc's singing path).

The upstream repo is research code with no package: the adapter fetches a
pinned GitHub tarball at first load (the checkpoints then auto-download from
HF into the engine cache on the first conversion) and runs `inference.py` in
a subprocess of this venv's python — with MPS hidden, because their code
autocasts on MPS and torch 2.4 rejects it (the proven triage configuration;
a torch≥2.6 MPS port is known further work).

`settings.version = 2` selects the same repo's `inference_v2.py` (AR +
CFM stack): speech-only, but it can carry the reference's style/emotion
over (`convert_style`) or anonymize a voice. V2 has no singing path —
the V1 entry keeps that job.
"""

from __future__ import annotations

import glob
import os
import secrets
import subprocess
import sys

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)
from engine_protocol.progress import iter_progress_lines, parse_tqdm
from engine_protocol.staging import fetch_tarball_tree, staged

REPO_COMMIT = "51383efd921027683c89e5348211d93ff12ac2a8"
REPO_TARBALL = (f"https://github.com/Plachtaa/seed-vc/archive/"
                f"{REPO_COMMIT}.tar.gz")


class SeedVCAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None

    def load(self, progress_cb: ProgressCb) -> None:
        cache = aux_dir("seedvc")
        repo = os.path.join(cache, f"seed-vc-{REPO_COMMIT}")
        if not staged(repo, "inference.py", "configs/v2/vc_wrapper.yaml"):
            progress_cb(None, "fetching seed-vc (pinned GitHub snapshot, "
                              "first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache, f"seed-vc-{REPO_COMMIT}")
        self.repo = repo
        progress_cb(None, "seed-vc ready (model weights fetch on the first "
                          "conversion)")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "voice conversion transforms existing audio — submit a "
            "convert-voice task")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "convert-voice":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.repo is not None

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        ref = params.get("reference_audio")
        if not ref or not os.path.isfile(ref):
            raise RuntimeError("reference_audio missing — record a few "
                               "seconds of the voice this should become")
        length = min(2.0, max(0.5,
                              float(params.get("length_adjust") or 1.0)))
        # Neither route took a seed: v1's CLI has no --seed flag and the v2
        # wrapper takes none either, so every conversion was a fresh draw from
        # the CFM sampler and no two runs of the same settings matched. Both
        # routes are driven through a `-c` bootstrap, which is a place to seed
        # torch before their code runs — so the seed lands in the same process
        # that does the sampling.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        v2 = int(self.settings.get("version") or 1) == 2
        if v2:
            steps = max(4, min(100, int(params.get("diffusion_steps") or 30)))
            sing = False
            # `is None` rather than `or`: 0.0 is the legal "guidance off"
            # end of both sliders and `or` silently rewrote it to 0.7
            # (audit §2).
            sim = params.get("similarity_cfg_rate")
            sim = min(1.0, max(0.0, 0.7 if sim is None else float(sim)))
            intel = params.get("intelligibility_cfg_rate")
            intel = min(1.0, max(0.0,
                                 0.7 if intel is None else float(intel)))
            style = bool(params.get("convert_style"))
            anon = bool(params.get("anonymize"))
            # v2 has two conversion paths and only one was reachable.
            # `convert_timbre` never runs the autoregressive stage: the CFM
            # re-voices the source while its own timing and delivery are left
            # exactly as they were. That is the right tool for a sung line,
            # where the AR path is free to re-phrase it.
            #
            # Measured 2026-09-04: the *other* path only reaches the AR when
            # `convert_style` or `anonymization_only` is set (`if
            # convert_style:` in vc_wrapper.py), so with both off the two
            # modes are the same computation and return byte-identical audio
            # in the same time. The mode is a real choice only next to those
            # two flags — which is what the catalog help now says.
            timbre_only = str(params.get("mode") or "full") == "timbre"
            if timbre_only and (style or anon):
                # Say it rather than drop it: both flags belong to the stage
                # this mode exists to skip.
                print("seed-vc: 'Voice only' does not run the stage that "
                      "copies style or anonymizes — those settings are "
                      "ignored for this conversion", file=sys.stderr,
                      flush=True)
            # Not inference_v2.py: that CLI hardcodes fp16, which CPU
            # linears reject (Half×Float mat1/mat2 crash, proven in the
            # 2026-08-26 smoke). Drive the wrapper directly in float32 —
            # same flow, safe dtype. `intelligebility` is upstream's own
            # spelling of the kwarg.
            bootstrap = (
                "import os, sys\n"
                "sys.path.insert(0, os.getcwd())\n"
                "import torch\n"
                "torch.backends.mps.is_available = (lambda: False)\n"
                f"torch.manual_seed({seed})\n"
                "import soundfile as sf\n"
                "import yaml\n"
                "from hydra.utils import instantiate\n"
                "from omegaconf import DictConfig\n"
                "device = torch.device('cpu')\n"
                "dtype = torch.float32\n"
                "cfg = DictConfig(yaml.safe_load("
                "open('configs/v2/vc_wrapper.yaml')))\n"
                "vc = instantiate(cfg)\n"
                "vc.load_checkpoints(ar_checkpoint_path=None, "
                "cfm_checkpoint_path=None)\n"
                "vc.to(device)\n"
                "vc.eval()\n"
                "vc.setup_ar_caches(max_batch_size=1, max_seq_len=4096, "
                "dtype=dtype, device=device)\n")
            if timbre_only:
                # Returns the waveform itself, shape (1, samples) at `vc.sr`,
                # rather than streaming chunks — so there is no generator to
                # drain and the write is one line. `inference_cfg_rate` is
                # this path's single guidance knob; the similarity /
                # intelligibility pair belongs to the AR path that is being
                # skipped, so the similarity dial stands in for it.
                #
                # Upstream's convert_timbre does not run at this pin. It calls
                # CFM.inference with `sway_sampling` / `amo_sampling`, which
                # that class does not accept (TypeError, proven live), and
                # hands it a scalar `inference_cfg_rate` where `solve_euler`
                # both iterates it (`all(i == 0 for i in ...)`) and indexes
                # [0] and [1]. `convert_voice`, which we do not use, is broken
                # the same way: only `convert_voice_with_streaming` — which
                # passes `[intel, sim]` and no sampling flags — was updated
                # when modules/v2/cfm.py was rewritten. Adapt at the call
                # boundary rather than editing their tree: the shim is a
                # no-op for the streaming path, and it refuses rather than
                # silently drops a sampling flag that was actually asked for.
                bootstrap += (
                    "_cfm_cls = type(vc.cfm)\n"
                    "_cfm_inference = _cfm_cls.inference\n"
                    "def _cfm_shim(self, *a, inference_cfg_rate=0.5,\n"
                    "              sway_sampling=False, amo_sampling=False,\n"
                    "              **kw):\n"
                    "    if sway_sampling or amo_sampling:\n"
                    "        raise RuntimeError('this seed-vc revision has no "
                    "sway/amo sampling')\n"
                    "    try:\n"
                    "        rate = [float(r) for r in inference_cfg_rate]\n"
                    "    except TypeError:\n"
                    "        rate = [float(inference_cfg_rate)] * 2\n"
                    "    return _cfm_inference(self, *a, "
                    "inference_cfg_rate=rate, **kw)\n"
                    "_cfm_cls.inference = _cfm_shim\n"
                    "audio = vc.convert_timbre("
                    f"source_audio_path={src!r}, target_audio_path={ref!r}, "
                    f"diffusion_steps={steps}, length_adjust={length}, "
                    f"inference_cfg_rate={sim}, "
                    "device=device, dtype=dtype)\n"
                    f"sf.write(os.path.join({out_dir!r}, 'converted_v2.wav'), "
                    "audio[0], vc.sr)\n")
            else:
                bootstrap += (
                    "gen = vc.convert_voice_with_streaming("
                    f"source_audio_path={src!r}, target_audio_path={ref!r}, "
                    f"diffusion_steps={steps}, length_adjust={length}, "
                    f"intelligebility_cfg_rate={intel}, "
                    f"similarity_cfg_rate={sim}, "
                    "top_p=0.9, temperature=1.0, repetition_penalty=1.0, "
                    f"convert_style={style}, anonymization_only={anon}, "
                    "device=device, dtype=dtype, stream_output=True)\n"
                    "full = None\n"
                    "for out in gen:\n"
                    "    _, full = out\n"
                    "sr, audio = full\n"
                    f"sf.write(os.path.join({out_dir!r}, "
                    "'converted_v2.wav'), audio, sr)\n")
        else:
            steps = max(4, min(50, int(params.get("diffusion_steps") or 10)))
            sing = bool(params.get("sing_mode"))
            shift = int(params.get("pitch_shift_st") or 0)
            # 0.0 = "guidance off" is legal; `or` rewrote it to 0.7 (audit §2)
            cfg = params.get("cfg_rate")
            cfg = min(1.0, max(0.0, 0.7 if cfg is None else float(cfg)))

            argv = ["inference.py",
                    "--source", src, "--target", ref, "--output", out_dir,
                    "--diffusion-steps", str(steps), "--fp16", "False",
                    "--length-adjust", str(length),
                    "--inference-cfg-rate", str(cfg),
                    "--f0-condition", str(sing),
                    "--auto-f0-adjust", str(sing and shift == 0),
                    "--semi-tone-shift", str(shift)]
            # A -c bootstrap rather than the CLI directly: MPS must be
            # hidden before their model code loads (torch-2.4 autocast
            # crash), and only code inside the process can do that.
            bootstrap = (
                "import sys, runpy, torch;"
                "torch.backends.mps.is_available = (lambda: False);"
                f"torch.manual_seed({seed});"
                f"sys.argv = {argv!r};"
                "runpy.run_path(sys.argv[0], run_name='__main__')")

        progress_cb(None, "converting (weights download on the first run; "
                          "the conversion runs at about "
                          + ("6" if v2 else "5")
                          + "× the clip length)")
        proc = subprocess.Popen(
            [sys.executable, "-c", bootstrap], cwd=self.repo,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        stderr_tail: list[str] = []
        assert proc.stderr is not None
        # The wrapper's per-chunk tqdm counts were on this stderr all along
        # and got discarded — one message for a 6×-realtime conversion read
        # as a hang (audit §5).
        for line in iter_progress_lines(proc.stderr):
            if cancel.cancelled:
                proc.kill()
                proc.wait()
                raise CancelledError()
            stderr_tail.append(line)
            stderr_tail = stderr_tail[-30:]
            got = parse_tqdm(line)
            if got:
                step, total = got
                # Not all one thing, and none of them was a "chunk" on a
                # 12-second clip: the CFM solver counts diffusion steps (its
                # total is exactly the number we asked for), the AR — which
                # only runs for convert_style/anonymize — counts generated
                # tokens (4000 of them, observed), and only a source long
                # enough to window adds a real per-chunk bar. Name the one we
                # can identify exactly and stay generic about the rest.
                progress_cb(min(0.98, step / total),
                            (f"denoising — step {step}/{total}"
                             if total == steps
                             else f"converting — step {step}/{total}"),
                            step=step, steps=total)
        proc.wait()
        if cancel.cancelled:
            raise CancelledError()
        if proc.returncode != 0:
            raise RuntimeError("seed-vc failed: "
                               + " / ".join(stderr_tail[-4:]))

        wavs = sorted(glob.glob(os.path.join(out_dir, "*.wav")),
                      key=os.path.getmtime)
        if not wavs:
            raise RuntimeError("seed-vc produced no audio")
        produced = wavs[-1]
        final = os.path.join(out_dir, "converted.wav")
        if produced != final:
            os.replace(produced, final)
        info = sf.info(final)
        return TaskResult(
            artifacts=[Artifact(kind="stem", label="converted", path=final,
                                format="wav",
                                sample_rate=int(info.samplerate),
                                duration_s=round(info.duration, 3))],
            meta={"engine": "seedvc", "version": 2 if v2 else 1,
                  "sing_mode": sing, "diffusion_steps": steps,
                  "seed_used": seed})

    def unload(self) -> None:
        pass

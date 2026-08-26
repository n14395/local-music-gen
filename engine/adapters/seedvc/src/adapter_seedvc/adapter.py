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
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import tarfile
import urllib.request

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

REPO_COMMIT = "51383efd921027683c89e5348211d93ff12ac2a8"
REPO_TARBALL = (f"https://github.com/Plachtaa/seed-vc/archive/"
                f"{REPO_COMMIT}.tar.gz")


class SeedVCAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None

    def _cache_dir(self) -> str:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        d = os.path.join(base, "seedvc")
        os.makedirs(d, exist_ok=True)
        return d

    def load(self, progress_cb: ProgressCb) -> None:
        cache = self._cache_dir()
        repo = os.path.join(cache, f"seed-vc-{REPO_COMMIT}")
        if not os.path.isdir(repo):
            progress_cb(None, "fetching seed-vc (pinned GitHub snapshot, "
                              "first use only)")
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
        steps = max(4, min(50, int(params.get("diffusion_steps") or 10)))
        sing = bool(params.get("sing_mode"))
        shift = int(params.get("pitch_shift_st") or 0)
        length = min(2.0, max(0.5,
                              float(params.get("length_adjust") or 1.0)))
        cfg = min(1.0, max(0.0, float(params.get("cfg_rate") or 0.7)))

        argv = ["inference.py",
                "--source", src, "--target", ref, "--output", out_dir,
                "--diffusion-steps", str(steps), "--fp16", "False",
                "--length-adjust", str(length),
                "--inference-cfg-rate", str(cfg),
                "--f0-condition", str(sing),
                "--auto-f0-adjust", str(sing and shift == 0),
                "--semi-tone-shift", str(shift)]
        # A -c bootstrap rather than the CLI directly: MPS must be hidden
        # before their model code loads (torch-2.4 autocast crash), and only
        # code inside the process can do that.
        bootstrap = (
            "import sys, runpy, torch;"
            "torch.backends.mps.is_available = (lambda: False);"
            f"sys.argv = {argv!r};"
            "runpy.run_path('inference.py', run_name='__main__')")

        progress_cb(None, "converting (weights download on the first run; "
                          "the conversion itself takes about a minute)")
        proc = subprocess.Popen(
            [sys.executable, "-c", bootstrap], cwd=self.repo,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        stderr_tail: list[str] = []
        while proc.poll() is None:
            if cancel.cancelled:
                proc.kill()
                proc.wait()
                raise CancelledError()
            line = proc.stderr.readline() if proc.stderr else ""
            if line:
                stderr_tail.append(line.strip())
                stderr_tail = stderr_tail[-30:]
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
            meta={"engine": "seedvc", "sing_mode": sing,
                  "diffusion_steps": steps})

    def unload(self) -> None:
        pass

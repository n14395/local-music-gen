"""Research-frontier separation: the ZFTurbo MSST zoo and Inria's BSRNN.

Two engines behind one venv (both live on the torch 2.7 pair):

  msst   — ZFTurbo/Music-Source-Separation-Training. One generic driver
           (`inference.py --model_type X --config_path Y --start_check_point
           Z`) runs the whole zoo: every additional model is a catalog entry
           carrying config/checkpoint URLs, no new code. Entry settings:
           {"engine": "msst", "model_type": ..., "config_url": ...,
            "ckpt_url": ...}
  bsrnn  — magronp/bsrnn (Inria), the only commercially-clean separator in
           the zoo (CC BY 4.0 weights). Hydra CLI, one checkpoint per stem,
           fetched as the Zenodo zip. Entry settings: {"engine": "bsrnn",
            "targets": ["vocals", ...]}

Both repos are research code with no package: pinned GitHub tarballs are
fetched at first load and driven as subprocesses of this venv's python.
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

MSST_COMMIT = "b15aa41299f852c4d8b0e482abcae9d9ad8479a4"
MSST_TARBALL = ("https://github.com/ZFTurbo/Music-Source-Separation-Training/"
                f"archive/{MSST_COMMIT}.tar.gz")
BSRNN_COMMIT = "66b24f9aca916119396bbeeceb5c3aeebdd8f5be"
BSRNN_TARBALL = f"https://github.com/magronp/bsrnn/archive/{BSRNN_COMMIT}.tar.gz"
BSRNN_WEIGHTS_ZIP = ("https://zenodo.org/records/17516442/files/"
                     "bsrnn-large.zip?download=1")


def _fetch(url: str, dest: str, progress_cb: ProgressCb, what: str) -> None:
    if os.path.exists(dest):
        return
    progress_cb(None, f"fetching {what} (first use only)")
    part = dest + ".part"
    os.makedirs(os.path.dirname(part), exist_ok=True)
    with urllib.request.urlopen(url, timeout=600) as resp, \
            open(part, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(part, dest)


class MSSTAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None

    def _cache(self, name: str) -> str:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        d = os.path.join(base, name)
        os.makedirs(d, exist_ok=True)
        return d

    def _engine(self) -> str:
        engine = str(self.settings.get("engine") or "msst")
        if engine not in ("msst", "bsrnn"):
            raise RuntimeError(f"unknown msst engine '{engine}'")
        return engine

    def _ensure_repo(self, url: str, commit: str, repo_name: str,
                     progress_cb: ProgressCb) -> str:
        cache = self._cache("msst")
        repo = os.path.join(cache, f"{repo_name}-{commit}")
        if not os.path.isdir(repo):
            tar_path = os.path.join(cache, f"{repo_name}.tar.gz")
            _fetch(url, tar_path, progress_cb, f"the {repo_name} code")
            with tarfile.open(tar_path) as tar:
                tar.extractall(cache, filter="data")
            os.unlink(tar_path)
        return repo

    def load(self, progress_cb: ProgressCb) -> None:
        if self._engine() == "msst":
            self.repo = self._ensure_repo(
                MSST_TARBALL, MSST_COMMIT,
                "Music-Source-Separation-Training", progress_cb)
        else:
            self.repo = self._ensure_repo(
                BSRNN_TARBALL, BSRNN_COMMIT, "bsrnn", progress_cb)
        progress_cb(None, "separation runtime ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError("separation models only run task jobs")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "separate":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        if self._engine() == "msst":
            cmd, cleanup = self._msst_cmd(src, out_dir, progress_cb)
        else:
            cmd, cleanup = self._bsrnn_cmd(src, out_dir, params, progress_cb)

        progress_cb(None, "separating (this can take several minutes)")
        try:
            proc = subprocess.Popen(cmd, cwd=self.repo,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, text=True)
            tail: list[str] = []
            while proc.poll() is None:
                if cancel.cancelled:
                    proc.kill()
                    proc.wait()
                    raise CancelledError()
                line = proc.stderr.readline() if proc.stderr else ""
                if line:
                    tail.append(line.strip())
                    tail = tail[-30:]
            if proc.returncode != 0:
                raise RuntimeError("separation failed: "
                                   + " / ".join(tail[-4:]))
        finally:
            cleanup()

        artifacts: list[Artifact] = []
        for path in sorted(glob.glob(os.path.join(out_dir, "**", "*.wav"),
                                     recursive=True)):
            label = os.path.splitext(os.path.basename(path))[0].lower()
            # MSST may prefix the input name ("clip_vocals"); keep the tail.
            if "_" in label:
                label = label.rsplit("_", 1)[-1]
            flat = os.path.join(out_dir, f"{label}.wav")
            if os.path.abspath(path) != os.path.abspath(flat):
                os.replace(path, flat)
            info = sf.info(flat)
            artifacts.append(Artifact(kind="stem", label=label, path=flat,
                                      format="wav",
                                      sample_rate=int(info.samplerate),
                                      duration_s=round(info.duration, 3)))
        if not artifacts:
            raise RuntimeError("separation produced no stems")
        return TaskResult(artifacts=artifacts,
                          meta={"engine": self._engine()})

    def _msst_cmd(self, src: str, out_dir: str, progress_cb: ProgressCb):
        model_type = str(self.settings["model_type"])
        weights = self._cache("msst-weights")
        config = os.path.join(weights,
                              os.path.basename(self.settings["config_url"]))
        ckpt = os.path.join(weights,
                            os.path.basename(self.settings["ckpt_url"]))
        _fetch(self.settings["config_url"], config, progress_cb,
               "the model config")
        _fetch(self.settings["ckpt_url"], ckpt, progress_cb,
               "the model checkpoint")
        indir = tempfile.mkdtemp(prefix="msst-in-")
        shutil.copy(src, os.path.join(indir, "input.wav"))
        cmd = [sys.executable, "inference.py",
               "--model_type", model_type,
               "--config_path", config,
               "--start_check_point", ckpt,
               "--input_folder", indir,
               "--store_dir", out_dir,
               "--force_cpu"]
        return cmd, lambda: shutil.rmtree(indir, ignore_errors=True)

    def _bsrnn_cmd(self, src: str, out_dir: str, params: dict,
                   progress_cb: ProgressCb):
        # The catalog entry now ships the checkpoints as an HF snapshot
        # (rtikw/bsrnn-large, an unmodified per-file mirror of the Zenodo
        # record) — prefer it: real install-state, resumable download. The
        # Zenodo zip stays as the fallback for a snapshot-less install.
        model_dir = next(
            (path for repo, path in self.model_paths.items()
             if "bsrnn" in repo.lower()
             and os.path.exists(os.path.join(path, "vocals.ckpt"))), None)
        if model_dir is None:
            weights_root = self._cache("bsrnn-weights")
            model_dir = os.path.join(weights_root, "bsrnn-large")
            if not os.path.isdir(model_dir):
                zip_path = os.path.join(weights_root, "bsrnn-large.zip")
                _fetch(BSRNN_WEIGHTS_ZIP, zip_path, progress_cb,
                       "the BSRNN checkpoints (1.6 GB, Zenodo)")
                with zipfile.ZipFile(zip_path) as z:
                    z.extractall(weights_root)
                os.unlink(zip_path)
        # One stem on request: each BSRNN target is its own checkpoint and
        # its own pass, so asking for just the vocals costs a quarter of a
        # full four-stem split.
        choice = str(params.get("targets") or "all").strip()
        if choice != "all":
            targets = [choice]
        else:
            targets = self.settings.get("targets") or ["vocals", "bass",
                                                       "drums", "other"]
        cmd = [sys.executable, "separate.py",
               f"file={src}", f"model_dir={model_dir}",
               "targets=[" + ",".join(targets) + "]",
               "eval.device=cpu", f"rec_dir={out_dir}"]
        return cmd, lambda: None

    def unload(self) -> None:
        pass

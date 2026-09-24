# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

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

Device: settings.device = "mps" routes both engines to the GPU. MSST's
pinned inference.py already auto-picks MPS on its own — the CPU pin was
only ever our `--force_cpu` flag, dropped on this route. BSRNN's device
line knows only cuda-or-cpu (`eval.device=mps` would silently land on
CPU), so load() teaches it "mps" with an idempotent text patch on the
pinned snapshot. MPS subprocesses run with PYTORCH_ENABLE_MPS_FALLBACK=1
so any op the backend lacks falls back instead of aborting. Without the
setting: CPU, the triage-proven configuration.
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)
from engine_protocol.progress import iter_progress_lines, parse_tqdm
from engine_protocol.staging import fetch_tarball_tree, staged

MSST_COMMIT = "b15aa41299f852c4d8b0e482abcae9d9ad8479a4"
MSST_TARBALL = ("https://github.com/ZFTurbo/Music-Source-Separation-Training/"
                f"archive/{MSST_COMMIT}.tar.gz")
BSRNN_COMMIT = "66b24f9aca916119396bbeeceb5c3aeebdd8f5be"
BSRNN_TARBALL = f"https://github.com/magronp/bsrnn/archive/{BSRNN_COMMIT}.tar.gz"
BSRNN_WEIGHTS_ZIP = ("https://zenodo.org/records/17516442/files/"
                     "bsrnn-large.zip?download=1")


def _fetch(url: str, dest: str, progress_cb: ProgressCb, what: str,
           cancel: CancelToken | None = None) -> None:
    """Download `url` to `dest`, reporting bytes and honouring Cancel.

    These are the biggest first-use downloads in the engine — 448 MB for the
    MDX23C checkpoint, 1.6 GB for the BSRNN zip — and they used to run behind
    one indeterminate message with no way out: Cancel was ignored for the
    whole transfer. Reporting per megabyte is also the cancel checkpoint,
    because `progress_cb` raises CancelledError on a cancelled job.
    """
    if os.path.exists(dest):
        return
    progress_cb(None, f"fetching {what} (first use only)")
    part = dest + ".part"
    os.makedirs(os.path.dirname(part), exist_ok=True)
    try:
        with urllib.request.urlopen(url, timeout=600) as resp, \
                open(part, "wb") as f:
            length = resp.headers.get("Content-Length")
            total = int(length) if length and length.isdigit() else 0
            done = 0
            while True:
                if cancel is not None and cancel.cancelled:
                    raise CancelledError()
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                progress_cb(None, f"fetching {what} — {done >> 20} MB"
                                  + (f" of {total >> 20} MB" if total else ""))
    except BaseException:
        # A cancelled 1.6 GB transfer must not leave 1.6 GB behind.
        try:
            os.unlink(part)
        except OSError:
            pass
        raise
    os.replace(part, dest)


class MSSTAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None
        self.device = str(self.settings.get("device") or "cpu")

    def _engine(self) -> str:
        engine = str(self.settings.get("engine") or "msst")
        if engine not in ("msst", "bsrnn"):
            raise RuntimeError(f"unknown msst engine '{engine}'")
        return engine

    def _ensure_repo(self, url: str, commit: str, repo_name: str,
                     progress_cb: ProgressCb, *landmarks: str) -> str:
        cache = aux_dir("msst")
        repo = os.path.join(cache, f"{repo_name}-{commit}")
        if not staged(repo, *landmarks):
            progress_cb(None, f"fetching the {repo_name} code "
                              "(first use only)")
            fetch_tarball_tree(url, cache, f"{repo_name}-{commit}")
        return repo

    def load(self, progress_cb: ProgressCb) -> None:
        if self._engine() == "msst":
            self.repo = self._ensure_repo(
                MSST_TARBALL, MSST_COMMIT,
                "Music-Source-Separation-Training", progress_cb,
                "inference.py", "utils/settings.py")
        else:
            # The BSRNN tarball ships an absolute symlink that used to abort
            # the whole extraction and leave a husk here; `staged` refuses
            # the husk and the staging fetch replaces it.
            self.repo = self._ensure_repo(
                BSRNN_TARBALL, BSRNN_COMMIT, "bsrnn", progress_cb,
                "separate.py")
            self._teach_bsrnn_mps(self.repo)
        progress_cb(None, "separation runtime ready")

    @staticmethod
    def _teach_bsrnn_mps(repo: str) -> None:
        """BSRNN's separate.py resolves eval.device as cuda-or-cpu, so
        `eval.device=mps` would silently land on CPU; teach it "mps" with a
        text patch on the pinned snapshot (idempotent — the CLI behaves
        identically unless mps is actually asked for and available)."""
        path = os.path.join(repo, "separate.py")
        with open(path) as f:
            src = f.read()
        if '"mps"' in src:
            return
        old = ('        "cuda" if (torch.cuda.is_available() and '
               'args.eval.device == "cuda") else "cpu"\n')
        if old not in src:
            raise RuntimeError("the pinned separate.py no longer carries "
                              "the expected device line — refusing to guess")
        new = ('        "mps" if (args.eval.device == "mps" and '
               'torch.backends.mps.is_available())\n'
               '        else "cuda" if (torch.cuda.is_available() and '
               'args.eval.device == "cuda") else "cpu"\n')
        with open(path, "w") as f:
            f.write(src.replace(old, new, 1))

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
            cmd, cleanup = self._msst_cmd(src, params, out_dir, progress_cb,
                                          cancel)
        else:
            cmd, cleanup = self._bsrnn_cmd(src, out_dir, params, progress_cb,
                                           cancel)

        progress_cb(None, "separating (on the GPU)" if self.device == "mps"
                          else "separating (this can take several minutes)")
        env = {**os.environ}
        if self.device == "mps":
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        try:
            proc = subprocess.Popen(cmd, cwd=self.repo, env=env,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, text=True)
            tail: list[str] = []
            assert proc.stderr is not None
            # Both CLIs run real per-chunk tqdm bars; splitting on \r turns
            # what used to be discarded error-tail into live progress
            # (audit §5).
            for line in iter_progress_lines(proc.stderr):
                if cancel.cancelled:
                    proc.kill()
                    proc.wait()
                    raise CancelledError()
                tail.append(line)
                tail = tail[-30:]
                got = parse_tqdm(line)
                if got:
                    step, total = got
                    progress_cb(min(0.98, step / total),
                                f"separating — chunk {step}/{total}",
                                step=step, steps=total)
            proc.wait()
            if cancel.cancelled:
                raise CancelledError()
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

    def _msst_cmd(self, src: str, params: dict, out_dir: str,
                  progress_cb: ProgressCb, cancel: CancelToken):
        model_type = str(self.settings["model_type"])
        weights = aux_dir("msst-weights")
        config = os.path.join(weights,
                              os.path.basename(self.settings["config_url"]))
        ckpt = os.path.join(weights,
                            os.path.basename(self.settings["ckpt_url"]))
        _fetch(self.settings["config_url"], config, progress_cb,
               "the model config", cancel)
        _fetch(self.settings["ckpt_url"], ckpt, progress_cb,
               "the model checkpoint", cancel)
        indir = tempfile.mkdtemp(prefix="msst-in-")
        shutil.copy(src, os.path.join(indir, "input.wav"))
        cmd = [sys.executable, "inference.py",
               "--model_type", model_type,
               "--config_path", config,
               "--start_check_point", ckpt,
               "--input_folder", indir,
               "--store_dir", out_dir]
        if self.device != "mps":
            # Without the flag their CLI auto-picks MPS on its own.
            cmd.append("--force_cpu")
        if params.get("tta"):
            # Upstream's own summary: polarity and channel inversion averaged
            # back in, "triples the runtime, reduces noise and slightly
            # improves prediction quality". The estimate the catalog prints is
            # scaled to match rather than left lying.
            cmd.append("--use_tta")
        if params.get("extract_instrumental"):
            # Not a second model: the mix minus the vocal stem, computed by the
            # CLI itself. Free, and the stem people actually want from a
            # vocal-only separator.
            cmd.append("--extract_instrumental")
        return cmd, lambda: shutil.rmtree(indir, ignore_errors=True)

    def _bsrnn_cmd(self, src: str, out_dir: str, params: dict,
                   progress_cb: ProgressCb, cancel: CancelToken):
        # The catalog entry now ships the checkpoints as an HF snapshot
        # (rtikw/bsrnn-large, an unmodified per-file mirror of the Zenodo
        # record) — prefer it: real install-state, resumable download. The
        # Zenodo zip stays as the fallback for a snapshot-less install.
        model_dir = next(
            (path for repo, path in self.model_paths.items()
             if "bsrnn" in repo.lower()
             and os.path.exists(os.path.join(path, "vocals.ckpt"))), None)
        if model_dir is None:
            weights_root = aux_dir("bsrnn-weights")
            model_dir = os.path.join(weights_root, "bsrnn-large")
            if not staged(model_dir, "vocals.ckpt"):
                zip_path = os.path.join(weights_root, "bsrnn-large.zip")
                _fetch(BSRNN_WEIGHTS_ZIP, zip_path, progress_cb,
                       "the BSRNN checkpoints (1.6 GB, Zenodo)", cancel)
                # Extract beside, land by rename: a died-partway extraction
                # must not leave a husk the next run trusts. The rmtree is in
                # a finally because a raising extractall used to leave the
                # whole .staging-XXXX tree behind — 1.6 GB per attempt.
                progress_cb(None, "unpacking the BSRNN checkpoints")
                tmp = tempfile.mkdtemp(prefix=".staging-", dir=weights_root)
                try:
                    with zipfile.ZipFile(zip_path) as z:
                        z.extractall(tmp)
                    tops = [e for e in os.listdir(tmp)
                            if os.path.isdir(os.path.join(tmp, e))]
                    if len(tops) != 1:
                        raise RuntimeError("unexpected BSRNN checkpoint zip "
                                           f"layout: {tops!r}")
                    if os.path.isdir(model_dir):
                        shutil.rmtree(model_dir)
                    os.rename(os.path.join(tmp, tops[0]), model_dir)
                finally:
                    shutil.rmtree(tmp, ignore_errors=True)
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
        # The path lands in a Hydra override, where spaces and parens in an
        # ordinary filename ("My Song (final).wav") break parsing — feed it
        # a copy with a boring name, like the MSST route does.
        indir = tempfile.mkdtemp(prefix="bsrnn-in-")
        safe_src = os.path.join(indir, "input.wav")
        shutil.copy(src, safe_src)
        # Quoted for Hydra's override grammar: the default output root lives
        # under "Application Support", and an unquoted space ends the value.
        argv = ["separate.py",
                f"file='{safe_src}'", f"model_dir='{model_dir}'",
                "targets=[" + ",".join(targets) + "]",
                f"eval.device={self.device}", f"rec_dir='{out_dir}'"]
        # torch ≥2.6 defaults weights_only=True and the BSRNN checkpoints
        # carry an omegaconf DictConfig, which the safe unpickler refuses —
        # these are pinned weights from the user-owned mirror, so load them
        # the way every other family loads its trusted checkpoints
        # (2026-09 revalidation finding).
        bootstrap = (
            "import runpy, sys, torch\n"
            "_orig = torch.load\n"
            "torch.load = lambda *a, **k: _orig("
            "*a, **{**k, 'weights_only': False})\n"
            f"sys.argv = {argv!r}\n"
            "runpy.run_path('separate.py', run_name='__main__')\n")
        cmd = [sys.executable, "-c", bootstrap]
        return cmd, lambda: shutil.rmtree(indir, ignore_errors=True)

    def unload(self) -> None:
        pass

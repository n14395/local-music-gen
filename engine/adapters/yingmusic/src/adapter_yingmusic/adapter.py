"""YingMusic-Singer (task `sing`): zero-shot singing voice synthesis — typed
lyrics performed to a melody (a MIDI file or a sung/played reference) in the
timbre of a short recording the USER supplies. Consent-clean by construction:
the voice comes from the job, not from a library.

Port shims, all proven in triage:
- Their decoder's `flash_attention` asserts CUDA; the run subprocess
  substitutes a torch-SDPA equivalent (GQA repeat_interleave, k_lens padding
  mask honored; the sliding window is ignored — restoring it is the known
  quality follow-up).
- LangSegment 0.2.0 (the only PyPI release; upstream deleted) ships an
  __init__ importing four filter setters its module never defines; the
  adapter appends benign defaults to the installed file once, at load.
- CPU; torchcodec handles audio I/O (the supervisor exports the ffmpeg DYLD
  fallback path for it).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tarfile
import urllib.request

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)

REPO_COMMIT = "6d7c453781cdaf286227ba7a51e79d57b19fad71"
REPO_TARBALL = (f"https://github.com/GiantAILab/YingMusic-Singer/archive/"
                f"{REPO_COMMIT}.tar.gz")

LANGSEGMENT_PATCH = '''

# --- LocalMusic patch: LangSegment 0.2.0's __init__ imports these four
# setters but the module never defines them; upstream is deleted, so provide
# benign defaults. ---
_lang_filters = []

def setLangfilters(filters):
    global _lang_filters
    _lang_filters = list(filters)

def getLangfilters():
    return list(_lang_filters)

def setfilters(filters):
    setLangfilters(filters)

def getfilters():
    return getLangfilters()
'''

BOOTSTRAP = '''
import sys, runpy, torch
sys.path.insert(0, SRC_DIR)
import singer.decoder.modules as M

def sdpa_attention(q, k=None, v=None, q_lens=None, k_lens=None,
                   dropout_p=0.0, softmax_scale=None, q_scale=None,
                   causal=False, window_size=(-1, -1), deterministic=False,
                   dtype=torch.bfloat16, **kw):
    import torch.nn.functional as F
    b, lq, nq, c = q.shape
    lk, nk = k.shape[1], k.shape[2]
    if nk != nq:
        rep = nq // nk
        k = k.repeat_interleave(rep, dim=2)
        v = v.repeat_interleave(rep, dim=2)
    qt, kt, vt = (t.transpose(1, 2).float() for t in (q, k, v))
    mask = None
    if k_lens is not None:
        mask = (torch.arange(lk, device=q.device)[None, :]
                < k_lens[:, None])[:, None, None, :]
    out = F.scaled_dot_product_attention(qt, kt, vt, attn_mask=mask,
                                         is_causal=causal,
                                         scale=softmax_scale)
    return out.transpose(1, 2).to(q.dtype)

M.flash_attention = sdpa_attention
sys.argv = ARGV
runpy.run_path(MODEL_PY, run_name="__main__")
'''


def _patch_langsegment() -> None:
    import importlib.util

    spec = importlib.util.find_spec("LangSegment")
    if spec is None or not spec.submodule_search_locations:
        return
    path = os.path.join(list(spec.submodule_search_locations)[0],
                        "LangSegment.py")
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return
    if "setLangfilters" not in text:
        with open(path, "a") as f:
            f.write(LANGSEGMENT_PATCH)


class YingMusicAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.repo: str | None = None

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        _patch_langsegment()
        cache = aux_dir("yingmusic")
        repo = os.path.join(cache, f"YingMusic-Singer-{REPO_COMMIT}")
        if not os.path.isdir(repo):
            progress_cb(None, "fetching the YingMusic code (pinned "
                              "snapshot, first use only)")
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
        progress_cb(None, "YingMusic-Singer ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "the singer performs typed lyrics — submit a sing task")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "sing":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.repo is not None

        lyrics = str(params.get("lyrics_text") or "").strip()
        if not lyrics:
            raise RuntimeError("lyrics_text missing — type the words to sing")
        ref = params.get("reference_audio")
        if not ref or not os.path.isfile(ref):
            raise RuntimeError("reference_audio missing — a few seconds of "
                               "the voice that should sing")
        ref_text = str(params.get("reference_text") or "").strip()
        if not ref_text:
            raise RuntimeError("reference_text missing — type what the "
                               "reference recording says or sings")
        midi = params.get("melody_midi")
        melody_audio = params.get("source_audio")
        if midi and os.path.isfile(midi):
            melody_args = ["--midi_file", midi]
        elif melody_audio and os.path.isfile(melody_audio):
            melody_args = ["--melody_audio_path", melody_audio]
        else:
            raise RuntimeError("no melody — pick a melody recording or a "
                               "MIDI file")

        steps = max(4, min(64, int(params.get("nfe_steps") or 8)))
        cfg = float(params.get("cfg_strength") or 4.0)
        shift = int(params.get("pitch_shift_st") or 0)
        out_path = os.path.join(out_dir, "sung.wav")

        argv = ["model.py",
                "--timbre_audio_path", ref,
                "--timbre_audio_content", ref_text,
                "--lyrics", lyrics,
                "--out_path", out_path,
                "--ckpt_path", self._snapshot(),
                "--cfg_strength", str(cfg),
                "--nfe_steps", str(steps),
                "--pitch_shift", str(shift)] + melody_args
        src_dir = os.path.join(self.repo, "src")
        model_py = os.path.join(src_dir, "singer", "model.py")
        code = (BOOTSTRAP
                .replace("SRC_DIR", repr(src_dir))
                .replace("ARGV", repr(argv))
                .replace("MODEL_PY", repr(model_py)))

        progress_cb(None, "singing (about half a minute per line on CPU)")
        proc = subprocess.Popen([sys.executable, "-c", code], cwd=self.repo,
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
            raise RuntimeError("YingMusic failed: " + " / ".join(tail[-4:]))
        if not os.path.exists(out_path):
            raise RuntimeError("YingMusic produced no audio")

        info = sf.info(out_path)
        return TaskResult(
            artifacts=[Artifact(kind="stem", label="sung", path=out_path,
                                format="wav",
                                sample_rate=int(info.samplerate),
                                duration_s=round(info.duration, 3))],
            meta={"engine": "yingmusic", "nfe_steps": steps})

    def unload(self) -> None:
        pass

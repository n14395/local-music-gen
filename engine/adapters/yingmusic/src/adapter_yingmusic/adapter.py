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

import json
import os
import random
import subprocess
import sys

import soundfile as sf

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)
from engine_protocol.progress import iter_progress_lines, parse_tqdm
from engine_protocol.staging import fetch_tarball_tree, staged

REPO_COMMIT = "6d7c453781cdaf286227ba7a51e79d57b19fad71"
REPO_TARBALL = (f"https://github.com/GiantAILab/YingMusic-Singer/archive/"
                f"{REPO_COMMIT}.tar.gz")

LANGSEGMENT_PATCH = '''

# --- LocalMusicGen patch: LangSegment 0.2.0's __init__ imports these four
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

# Run in the subprocess with the config file as its one argument. Nothing is
# substituted into this template: the run arguments carry three user-supplied
# strings (lyrics, reference_text, the timbre content), and MODEL_PY used to be
# replaced *after* the argv list had been spliced in — lyrics containing the
# literal "MODEL_PY" rewrote the argv literal and the subprocess died with a
# NameError reported as "YingMusic failed: …".
BOOTSTRAP = '''
import json, sys, runpy, torch
_cfg = json.load(open(sys.argv[1]))
sys.path.insert(0, _cfg["src_dir"])
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
sys.argv = _cfg["argv"]
runpy.run_path(_cfg["model_py"], run_name="__main__")
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
        self.proc: subprocess.Popen | None = None

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        _patch_langsegment()
        cache = aux_dir("yingmusic")
        repo = os.path.join(cache, f"YingMusic-Singer-{REPO_COMMIT}")
        if not staged(repo, "src/singer/model.py",
                      "src/singer/decoder/modules.py"):
            progress_cb(None, "fetching the YingMusic code (pinned "
                              "snapshot, first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache,
                               f"YingMusic-Singer-{REPO_COMMIT}")
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
        # Upstream pins DEFAULT_SEED=2025, so without an explicit draw every
        # "random" retake of the same inputs was bit-identical (audit B10).
        seed = params.get("seed")
        seed = int(seed) if seed is not None else random.randrange(2**31)
        out_path = os.path.join(out_dir, "sung.wav")

        argv = ["model.py",
                "--timbre_audio_path", ref,
                "--timbre_audio_content", ref_text,
                "--lyrics", lyrics,
                "--out_path", out_path,
                "--ckpt_path", self._snapshot(),
                "--cfg_strength", str(cfg),
                "--nfe_steps", str(steps),
                "--seed", str(seed),
                "--pitch_shift", str(shift)] + melody_args
        src_dir = os.path.join(self.repo, "src")
        model_py = os.path.join(src_dir, "singer", "model.py")
        os.makedirs(self.work_dir, exist_ok=True)
        cfg_path = os.path.join(self.work_dir, "yingmusic-run.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump({"src_dir": src_dir, "model_py": model_py,
                       "argv": argv}, f)

        progress_cb(None, "singing (about half a minute per line on CPU)")
        proc = subprocess.Popen([sys.executable, "-c", BOOTSTRAP, cfg_path],
                                cwd=self.repo,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        self.proc = proc
        tail: list[str] = []
        assert proc.stderr is not None
        try:
            # The CLI's tqdm (NFE steps per line) was on this stderr and
            # discarded (audit §5); \r-splitting turns it into live progress.
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
                                f"singing — {step}/{total}",
                                step=step, steps=total)
            proc.wait()
        except BaseException:
            # progress_cb itself raises CancelledError on a cancelled job, so
            # the loop can exit without passing the branch above, leaving the
            # singer running for the rest of the session.
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            raise
        finally:
            self.proc = None
        if cancel.cancelled:
            raise CancelledError()
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
            meta={"engine": "yingmusic", "nfe_steps": steps,
                  "seed_used": seed})

    def unload(self) -> None:
        # Nothing is held in this process — but a run that ended by exception
        # may have left the singer subprocess alive.
        proc, self.proc = self.proc, None
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()

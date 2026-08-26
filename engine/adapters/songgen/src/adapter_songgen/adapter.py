"""SongGen (ICML 2025): single-stage autoregressive text+lyrics→song, with
optional 3-second reference-voice conditioning from a USER-SUPPLIED recording
(the processor separates the reference itself; no voice library ships).

Two packaging gaps in the upstream repo (its find_packages excludes them) are
repaired at load by staging from a pinned repo tarball into site-packages:
the `songgen/xcodec_wrapper/xcodec_infer/` tree and
`songgen/lyrics_utils/vocab.json`. The X-Codec checkpoint additionally comes
from the ZhenYe234/xcodec snapshot into the path the wrapper hard-codes.

CPU-only for now (their device handling is CUDA-else-CPU; the token rate is
roughly realtime). torch.load is shimmed to CPU — the checkpoints are
CUDA-pickled.
"""

from __future__ import annotations

import os
import shutil
import tarfile
import urllib.request

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

REPO_COMMIT = "94d2d20ca882aa55c8e0abc6154a6ac52840c781"
REPO_TARBALL = f"https://github.com/LiuZH-19/SongGen/archive/{REPO_COMMIT}.tar.gz"
XCODEC_FILE = "xcodec_hubert_general_audio_v2.pth"
# audio tokens per second of output (their frame rate); caps token budget
TOKENS_PER_S = 50


def _site_packages_root() -> str:
    import importlib.util

    spec = importlib.util.find_spec("songgen")
    assert spec is not None and spec.origin
    return os.path.dirname(os.path.dirname(spec.origin))


def _stage_package_data(progress_cb: ProgressCb) -> None:
    """Repair the pip install: copy the excluded trees from the pinned repo."""
    root = _site_packages_root()
    pkg = os.path.join(root, "songgen")
    vocab = os.path.join(pkg, "lyrics_utils", "vocab.json")
    infer = os.path.join(pkg, "xcodec_wrapper", "xcodec_infer")
    if os.path.exists(vocab) and os.path.isdir(infer):
        return
    progress_cb(None, "repairing the SongGen install (staging excluded "
                      "package files, first use only)")
    cache = os.path.join(root, "..", "..", "..", "songgen-stage")
    cache = os.path.abspath(cache)
    os.makedirs(cache, exist_ok=True)
    tar_path = os.path.join(cache, "repo.tar.gz")
    if not os.path.isdir(os.path.join(cache, f"SongGen-{REPO_COMMIT}")):
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
    src = os.path.join(cache, f"SongGen-{REPO_COMMIT}", "songgen")
    if not os.path.isdir(infer):
        shutil.copytree(os.path.join(src, "xcodec_wrapper", "xcodec_infer"),
                        infer)
    if not os.path.exists(vocab):
        shutil.copy(os.path.join(src, "lyrics_utils", "vocab.json"), vocab)


def _stage_xcodec(snapshot: str) -> None:
    """The wrapper hard-codes ckpts/general_more/<file> inside its own tree."""
    root = _site_packages_root()
    dest = os.path.join(root, "songgen", "xcodec_wrapper", "xcodec_infer",
                        "ckpts", "general_more", XCODEC_FILE)
    if os.path.exists(dest):
        return
    src = os.path.join(snapshot, XCODEC_FILE)
    if not os.path.exists(src):
        raise RuntimeError(f"xcodec checkpoint missing from snapshot {snapshot}")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        os.symlink(src, dest)
    except OSError:
        shutil.copy(src, dest)


class SongGenAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.processor = None

    def _snapshot(self, needle: str) -> str:
        for repo, path in self.model_paths.items():
            if needle in repo.lower():
                return path
        raise RuntimeError(f"no snapshot matching '{needle}'")

    def load(self, progress_cb: ProgressCb) -> None:
        import torch

        # CUDA-pickled checkpoints + CUDA-else-CPU device handling.
        torch.backends.mps.is_available = lambda: False
        orig_load = torch.load
        torch.load = lambda *a, **kw: orig_load(
            *a, **{"map_location": "cpu", "weights_only": False, **kw})

        _stage_package_data(progress_cb)
        _stage_xcodec(self._snapshot("xcodec"))

        progress_cb(None, "loading SongGen (5 GB)")
        from songgen import (SongGenMixedForConditionalGeneration,
                             SongGenProcessor)

        ckpt = self._snapshot("songgen")
        self.model = SongGenMixedForConditionalGeneration.from_pretrained(
            ckpt, attn_implementation="sdpa").to("cpu").eval()
        self.processor = SongGenProcessor(ckpt, "cpu")
        progress_cb(None, "SongGen ready (CPU)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        import torch
        from transformers import StoppingCriteria, StoppingCriteriaList

        assert self.model is not None and self.processor is not None
        duration_s = float(params.get("duration_s") or 15.0)
        max_tokens = int(min(duration_s, 120) * TOKENS_PER_S)
        seed = params.get("seed")
        if seed is not None:
            torch.manual_seed(int(seed))

        ref = params.get("ref_voice")
        ref = ref if ref and os.path.isfile(ref) else None
        progress_cb(None, "encoding text and lyrics", phase="prompt_encode")
        inputs = self.processor(text=prompt,
                                lyrics=lyrics or "la la la",
                                ref_voice_path=ref)

        class _Progress(StoppingCriteria):
            def __call__(self, input_ids, scores, **kwargs) -> bool:
                done = input_ids.shape[-1]
                if done % 25 == 0:
                    progress_cb(min(0.95, done / max_tokens), "singing",
                                phase="lm_decode", step=done,
                                steps=max_tokens)
                return cancel.cancelled

        progress_cb(0.02, "singing", phase="lm_decode")
        sampling: dict = {}
        if params.get("temperature") is not None:
            sampling["temperature"] = float(params["temperature"])
        if params.get("top_k") is not None:
            sampling["top_k"] = int(params["top_k"])
        if params.get("top_p") is not None:
            sampling["top_p"] = float(params["top_p"])
        gen = self.model.generate(
            **inputs, do_sample=True, max_new_tokens=max_tokens,
            stopping_criteria=StoppingCriteriaList([_Progress()]),
            **sampling)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(None, "saving", phase="master")
        audio = gen.cpu().numpy().squeeze()
        sample_rate = int(self.model.config.sampling_rate)
        tmp = out_path + ".part"
        sf.write(tmp, audio, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(len(audio) / sample_rate, 3),
            sample_rate=sample_rate,
            seed_used=int(seed) if seed is not None else None)

    def unload(self) -> None:
        self.model = None
        self.processor = None

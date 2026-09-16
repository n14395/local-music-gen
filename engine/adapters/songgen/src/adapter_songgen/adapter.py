"""SongGen (ICML 2025): single-stage autoregressive text+lyrics→song, with
optional 3-second reference-voice conditioning from a USER-SUPPLIED recording
(the processor separates the reference itself; no voice library ships).

Two packaging gaps in the upstream repo (its find_packages excludes them) are
repaired at load by staging from a pinned repo tarball into site-packages:
the `songgen/xcodec_wrapper/xcodec_infer/` tree and
`songgen/lyrics_utils/vocab.json`. The X-Codec checkpoint additionally comes
from the ZhenYe234/xcodec snapshot into the path the wrapper hard-codes.

Device: settings.device = "mps" puts the model, the processor (its demucs
included — the same htdemucs the separation family already proves on MPS)
and the xcodec decode on the GPU; the modeling code is device-agnostic
transformers+SDPA, and its only CUDA references are training utilities the
runtime never imports. Without the setting: CPU, the proven configuration
(their own device handling is CUDA-else-CPU; the token rate is roughly
realtime there). On the CPU route MPS is also hidden from torch — their
code would otherwise scatter tensors across devices. torch.load is shimmed
to CPU on both routes — the checkpoints are CUDA-pickled.
"""

from __future__ import annotations

import os
import secrets
import shutil
import urllib.request

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     clear_stale_link,
                                     release_accelerator_memory)
from engine_protocol.staging import fetch_tarball_tree, staged

# Read at torch import: lets any stray op the MPS backend lacks fall back
# to CPU instead of aborting the render. Harmless on the CPU route.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

REPO_COMMIT = "94d2d20ca882aa55c8e0abc6154a6ac52840c781"
REPO_TARBALL = f"https://github.com/LiuZH-19/SongGen/archive/{REPO_COMMIT}.tar.gz"
XCODEC_FILE = "xcodec_hubert_general_audio_v2.pth"
XCODEC_CONFIG = "config_hubert_general.yaml"
XCODEC_CONFIG_URL = ("https://huggingface.co/ZhenYe234/xcodec/resolve/main/"
                     + XCODEC_CONFIG)
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
    staged_repo = os.path.join(cache, f"SongGen-{REPO_COMMIT}")
    if not staged(staged_repo, "songgen/lyrics_utils/vocab.json",
                  "songgen/xcodec_wrapper/xcodec_infer"):
        fetch_tarball_tree(REPO_TARBALL, cache, f"SongGen-{REPO_COMMIT}")
    src = os.path.join(staged_repo, "songgen")
    if not os.path.isdir(infer):
        shutil.copytree(os.path.join(src, "xcodec_wrapper", "xcodec_infer"),
                        infer)
    if not os.path.exists(vocab):
        shutil.copy(os.path.join(src, "lyrics_utils", "vocab.json"), vocab)


def _stage_xcodec(snapshot: str) -> None:
    """The wrapper hard-codes ckpts/general_more/<file> inside its own tree —
    both the checkpoint AND its config yaml. The yaml lives in the same
    ZhenYe234/xcodec repo; snapshots fetched before it joined the entry's
    allow_patterns don't carry it, so it falls back to a direct fetch."""
    root = _site_packages_root()
    ckpts = os.path.join(root, "songgen", "xcodec_wrapper", "xcodec_infer",
                         "ckpts", "general_more")
    os.makedirs(ckpts, exist_ok=True)

    dest = os.path.join(ckpts, XCODEC_FILE)
    clear_stale_link(dest)   # a library move strands this link
    if not os.path.exists(dest):
        src = os.path.join(snapshot, XCODEC_FILE)
        if not os.path.exists(src):
            raise RuntimeError(
                f"xcodec checkpoint missing from snapshot {snapshot}")
        try:
            os.symlink(src, dest)
        except OSError:
            shutil.copy(src, dest)

    config_dest = os.path.join(ckpts, XCODEC_CONFIG)
    clear_stale_link(config_dest)
    if not os.path.exists(config_dest):
        config_src = os.path.join(snapshot, XCODEC_CONFIG)
        if os.path.exists(config_src):
            try:
                os.symlink(config_src, config_dest)
            except OSError:
                shutil.copy(config_src, config_dest)
        else:
            part = config_dest + ".part"
            with urllib.request.urlopen(XCODEC_CONFIG_URL,
                                        timeout=120) as resp, \
                    open(part, "wb") as f:
                f.write(resp.read())
            os.replace(part, config_dest)


def _define_missing_torch_flag() -> None:
    """SongGen vendored transformers' `isin_mps_friendly` but not the module
    global it reads: `is_torch_greater_or_equal_than_2_4` only exists in
    transformers >= 4.44, and this stack pins 4.43. Python short-circuits the
    name away unless the tensor is on MPS, so the NameError fires only on the
    GPU route, at the first sampled token — after a 5 GB load. Define it from
    the torch actually installed; on >= 2.4 that also selects plain
    `torch.isin`, which is what their workaround exists to avoid needing."""
    import torch
    from packaging.version import parse
    from songgen import logits_processors

    if not hasattr(logits_processors, "is_torch_greater_or_equal_than_2_4"):
        release = parse(torch.__version__.split("+")[0]).release
        logits_processors.is_torch_greater_or_equal_than_2_4 = release >= (2, 4)


def _teach_processor_float32() -> None:
    """Let a reference voice be separated on the GPU.

    The processor's vocal-separation branch builds its demucs input with
    `torch.tensor(wav[None], device=self.device).to(torch.float32)` — but the
    cast happens *after* construction, and `wav` arrives from soundfile as
    float64, so on MPS the tensor is rejected before the cast can help
    ("Cannot convert a MPS Tensor to float64 dtype"). Upstream only ever ran
    this on CUDA, where float64 is legal. Caught 2026-09-03 the first time a
    ref_voice job ran on this machine.

    Patch the pinned copy in the venv (the msst/acestep idiom): cast in numpy,
    before the tensor exists. Idempotent, re-applied on every load."""
    import importlib.util
    import os

    spec = importlib.util.find_spec("songgen")
    if spec is None or not spec.submodule_search_locations:
        raise RuntimeError("the songgen package is not importable")
    path = os.path.join(spec.submodule_search_locations[0],
                        "processing_songgen.py")
    with open(path) as f:
        src = f.read()
    if "LOCALMUSIC-FLOAT32" in src:
        return
    old = ("                    torch.tensor(wav[None], device=self.device)"
           ".to(torch.float32), \n")
    if old not in src:
        raise RuntimeError("processing_songgen.py no longer carries the "
                           "expected demucs input line — refusing to guess")
    new = ("                    # LOCALMUSIC-FLOAT32: cast in numpy, because "
           "MPS refuses to\n"
           "                    # build the float64 tensor this used to make "
           "first.\n"
           "                    torch.tensor(wav[None].astype('float32'), "
           "device=self.device),\n")
    with open(path, "w") as f:
        f.write(src.replace(old, new, 1))


class SongGenAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.processor = None
        self.device = str(self.settings.get("device") or "cpu")
        # Dual-track: the checkpoint writes the vocal and the accompaniment as
        # two streams and never mixes them, so the take is a mix we make and
        # the two parts travel with it. Selected by the entry, because it is a
        # different checkpoint and a different model class, not a flag.
        self.dual = bool(self.settings.get("dual_track"))

    def _snapshot(self, needle: str) -> str:
        for repo, path in self.model_paths.items():
            if needle in repo.lower():
                return path
        raise RuntimeError(f"no snapshot matching '{needle}'")

    def load(self, progress_cb: ProgressCb) -> None:
        import torch

        # CUDA-pickled checkpoints; on the CPU route MPS is also hidden so
        # their CUDA-else-CPU device handling cannot scatter tensors.
        if self.device != "mps":
            torch.backends.mps.is_available = lambda: False
        orig_load = torch.load
        torch.load = lambda *a, **kw: orig_load(
            *a, **{"map_location": "cpu", "weights_only": False, **kw})

        _stage_package_data(progress_cb)
        _stage_xcodec(self._snapshot("xcodec"))
        _teach_processor_float32()

        progress_cb(None, "loading SongGen (5 GB)")
        from songgen import (SongGenDualTrackForConditionalGeneration,
                             SongGenMixedForConditionalGeneration,
                             SongGenProcessor)

        _define_missing_torch_flag()

        ckpt = self._snapshot("songgen")
        cls = (SongGenDualTrackForConditionalGeneration if self.dual
               else SongGenMixedForConditionalGeneration)
        self.model = cls.from_pretrained(
            ckpt, attn_implementation="sdpa").to(self.device).eval()
        self.processor = SongGenProcessor(ckpt, self.device)
        if self.dual:
            # The pattern is a property of the trained weights, not a runtime
            # choice — the checkpoint's own config carries it, and generate()
            # reads it from there. Surfaced here so the log says which layout
            # is loaded, and so a mismatched settings/checkpoint pair is
            # visible rather than mysterious.
            pattern = getattr(self.model.decoder.config, "track_pattern", "?")
            declared = self.settings.get("track_pattern")
            if declared and declared != pattern:
                raise RuntimeError(
                    f"this checkpoint is a '{pattern}' dual-track model but "
                    f"the entry declares '{declared}'")
            progress_cb(None, f"SongGen dual-track ready ({pattern})")
            return
        progress_cb(None, "SongGen ready on the GPU (MPS)"
                          if self.device == "mps" else "SongGen ready (CPU)")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        import torch
        from transformers import StoppingCriteria, StoppingCriteriaList

        assert self.model is not None and self.processor is not None
        # SongGen has no instrumental path: no instrumental token, mode or
        # checkpoint exists in the package. This used to substitute
        # "la la la" for an empty lyrics box, so a user who asked for an
        # instrumental got a voice singing nonsense instead of an answer. The
        # catalog now declares `requires_lyrics` so the app gates it; this is
        # the API caller's version of the same message.
        if not (lyrics or "").strip():
            raise RuntimeError("SongGen sings — it has no instrumental mode, "
                               "so give it some lyrics")
        duration_s = float(params.get("duration_s") or 15.0)
        # The decoder has 6547 positions and the codec runs at 50 Hz, so a
        # mixed render tops out near 131 s and the catalog declares 120. The
        # interleaving dual-track layout weaves both streams along *time*
        # (`reshape(bsz, n, 2 * seq_len)`), spending two positions per frame of
        # audio — so the same context reaches about 65 s and that entry
        # declares 60. Two tokens per frame is also why it takes roughly twice
        # as long for the same length. (The `parallel_*` layouts stack the
        # streams on the codebook axis instead and would cost neither, but no
        # checkpoint for them has ever been released.)
        cap, per_frame = (60, 2) if self.dual else (120, 1)
        max_tokens = int(min(duration_s, cap) * TOKENS_PER_S * per_frame)
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. `seed_used` reports it back.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        torch.manual_seed(seed)

        ref = params.get("ref_voice")
        ref = ref if ref and os.path.isfile(ref) else None
        progress_cb(None, "encoding text and lyrics"
                          + (" (separating the voice reference)"
                             if ref else ""), phase="prompt_encode")
        # separate=True: upstream expects a vocals-only reference; without
        # the separation pass a normal song clip silently degraded the
        # voice cloning (audit §3).
        inputs = self.processor(text=prompt,
                                lyrics=lyrics,
                                ref_voice_path=ref,
                                separate=bool(ref))

        use_mps = torch.backends.mps.is_available()

        class _Progress(StoppingCriteria):
            def __call__(self, input_ids, scores, **kwargs) -> bool:
                done = input_ids.shape[-1]
                if done % 25 == 0:
                    if use_mps:
                        # Same MPS allocator pathology as every AR family:
                        # the streaming KV concat grows the driver footprint
                        # quadratically unless freed blocks go back to the
                        # OS — worker-songgen.log recorded a 58 GiB Metal
                        # footprint before this flush (audit §3).
                        torch.mps.empty_cache()
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
        sample_rate = int(self.model.config.sampling_rate)

        def _write(path: str, samples) -> None:
            tmp = path + ".part"
            sf.write(tmp, samples, sample_rate, format="WAV",
                     subtype="PCM_16")
            os.replace(tmp, path)

        stems: list[dict] = []
        if self.dual:
            # Dual-track generate() returns (accompaniment, vocal) and no mix
            # — the two streams ARE the song. We make the mix by summing them,
            # which is what "dual track" means.
            acc_t, vocal_t = gen
            acc = acc_t.cpu().numpy().squeeze()
            vocal = vocal_t.cpu().numpy().squeeze()
            n = min(len(acc), len(vocal))
            acc, vocal = acc[:n], vocal[:n]
            audio = acc + vocal
            # Two full-scale streams summed will clip. Scale all three by the
            # same factor rather than only the mix, so the stems still sum to
            # exactly the song the user hears — the one property that makes
            # them worth having over a separation model's guess.
            peak = float(abs(audio).max()) if n else 0.0
            if peak > 1.0:
                acc, vocal, audio = acc / peak, vocal / peak, audio / peak
            out_dir = os.path.dirname(os.path.abspath(out_path))
            take = os.path.splitext(os.path.basename(out_path))[0]
            for label, samples in (("vocals", vocal),
                                   ("accompaniment", acc)):
                path = os.path.join(out_dir, f"{take}-{label}.wav")
                _write(path, samples)
                stems.append({"label": label, "path": path,
                              "sample_rate": sample_rate,
                              "duration_s": round(n / sample_rate, 3)})
        else:
            audio = gen.cpu().numpy().squeeze()

        _write(out_path, audio)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(len(audio) / sample_rate, 3),
            sample_rate=sample_rate,
            seed_used=seed,
            stems=stems)

    def unload(self) -> None:
        self.model = None
        self.processor = None
        # 5 GB of weights: the references go here, the allocator's blocks
        # only go back when it is told.
        release_accelerator_memory()

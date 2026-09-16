"""HeartMuLa: lyrics + style tags to a full 48 kHz stereo song. A 3B
Llama-3.2-style global transformer with a 300M local decoder over HeartCodec's
12.5 Hz RVQ frames — the only fully Apache-2.0 (code AND weights) song model
in the catalog.

heartlib expects one assembled checkpoint folder (HeartMuLa-oss-3B/,
HeartCodec-oss/, tokenizer.json, gen_config.json — its `_resolve_paths` names
them exactly), while the library holds three separate HF snapshots. The
adapter scaffolds that folder in the aux cache out of symlinks, the same move
InspireMusic uses for its pretrained_models tree.

The generation loop runs one `generate_frame` call per 80 ms frame, which
makes progress and cancellation cheap: wrap the bound method, count calls,
and raise CancelledError from the wrapper — everything runs on this thread,
so the raise unwinds the pipeline cleanly (no llm_job-style consumer thread
to strand, unlike InspireMusic).

Upstream's postprocess writes the take with torchaudio.save — the same
torchcodec/ffmpeg trap the 2026-09 InspireMusic triage hit — so the adapter
drives preprocess/_forward itself and decodes with `codec.detokenize`,
writing through soundfile.
"""

from __future__ import annotations

import os
import random
import secrets

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir, clear_stale_link)

GEN_NEEDLE = "heartmulagen"          # tokenizer.json + gen_config.json
MULA_NEEDLE = "heartmula-oss-3b"     # the LM (happy-new-year checkpoint)
CODEC_NEEDLE = "heartcodec"          # HeartCodec-oss
FRAME_MS = 80                        # HeartCodec runs at 12.5 Hz


class HeartMuLaAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.pipe = None

    def _snapshot(self, needle: str) -> str:
        for repo, path in self.model_paths.items():
            if needle in repo.lower():
                return path
        raise RuntimeError(f"no '{needle}' snapshot in model_paths")

    @staticmethod
    def _decode_windows(n_codes: int, duration: float = 29.76) -> int:
        """How many flow-matching windows `HeartCodec.detokenize` runs for
        `n_codes` frames — its own padding arithmetic, repeated here so the
        decode bar has a total. Only the bar depends on it being exact."""
        import math
        min_samples = int(duration * 12.5)
        hop = min_samples // 93 * 80
        ovlp = min_samples - hop
        n = max(n_codes, min_samples)
        if (n - ovlp * 2) % hop > 0:
            n = math.ceil((n - ovlp) / hop) * hop + ovlp
        return max(1, len(range(0, n - hop + 1, hop)))

    def _scaffold(self) -> str:
        """The assembled checkpoint folder heartlib wants, built from links.

        Links cross from the aux cache into HF snapshots and a library
        relocate strands them, so every one goes through clear_stale_link
        before the exists-check — the InspireMusic lesson.
        """
        root = os.path.join(aux_dir("heartmula"), "ckpt")
        os.makedirs(root, exist_ok=True)
        gen = self._snapshot(GEN_NEEDLE)
        pairs = [
            (os.path.join(root, "HeartMuLa-oss-3B"), self._snapshot(MULA_NEEDLE)),
            (os.path.join(root, "HeartCodec-oss"), self._snapshot(CODEC_NEEDLE)),
            (os.path.join(root, "tokenizer.json"),
             os.path.join(gen, "tokenizer.json")),
            (os.path.join(root, "gen_config.json"),
             os.path.join(gen, "gen_config.json")),
        ]
        for link, target in pairs:
            clear_stale_link(link)
            if os.path.islink(link) and os.path.realpath(link) != \
                    os.path.realpath(target):
                # Alive but pointing at an older snapshot revision.
                os.unlink(link)
            if not os.path.exists(link):
                os.symlink(target, link)
        return root

    def load(self, progress_cb: ProgressCb) -> None:
        import torch
        from heartlib import HeartMuLaGenPipeline

        use_mps = (str(self.settings.get("device") or "cpu") == "mps"
                   and torch.backends.mps.is_available())
        device = torch.device("mps" if use_mps else "cpu")
        self._use_mps = use_mps

        progress_cb(None, "loading HeartMuLa (3B bf16 + HeartCodec fp32 — "
                          "takes a little while)")
        # bf16 LM / fp32 codec are upstream's own example defaults;
        # lazy_load=False keeps both resident, which is what a model the
        # user explicitly loaded is for.
        self.pipe = HeartMuLaGenPipeline.from_pretrained(
            self._scaffold(),
            device=device,
            dtype={"mula": torch.bfloat16, "codec": torch.float32},
            version="3B",
            lazy_load=False)
        progress_cb(None, "HeartMuLa ready on "
                    + ("MPS" if use_mps else "CPU — renders will be slow"))

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.pipe is not None
        import numpy as np
        import torch

        if not (lyrics or "").strip():
            raise RuntimeError("HeartMuLa writes songs from lyrics — "
                               "give it some")
        duration_s = min(360.0, float(params.get("duration_s") or 120.0))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        # heartlib never seeds; all three RNGs, set before the first frame,
        # make the draw reproducible (torch drives sampling, the others are
        # cheap insurance against library internals).
        random.seed(seed)
        np.random.seed(seed)
        torch.manual_seed(seed)

        cfg_scale = float(params.get("cfg_scale") or 1.5)
        forward_kwargs = {
            "max_audio_length_ms": int(duration_s * 1000),
            "temperature": float(params.get("temperature") or 1.0),
            "topk": int(params.get("top_k") or 50),
            "cfg_scale": cfg_scale,
        }
        total = max(1, int(duration_s * 1000) // FRAME_MS)
        progress_cb(0.0, "writing music", step=0, steps=total)

        # One generate_frame call per 80 ms frame (plus the prompt call).
        # The wrapper is the render's progress voice and its cancel
        # checkpoint; restored in `finally` so a failed take cannot leave
        # the model wrapped.
        mula = self.pipe.mula
        orig_frame = mula.generate_frame
        n = 0

        def counted(*a, **kw):
            nonlocal n
            if cancel.cancelled:
                raise CancelledError()
            out = orig_frame(*a, **kw)
            n += 1
            if n % 25 == 0:
                progress_cb(min(0.9, n / total),
                            f"writing music — frame {n}/~{total} "
                            f"({n * FRAME_MS // 1000} s)",
                            step=min(n, total), steps=total)
            return out

        mula.generate_frame = counted
        try:
            inputs = {"tags": (prompt or "").strip() or "pop", "lyrics": lyrics}
            with torch.no_grad():
                model_inputs = self.pipe.preprocess(inputs, cfg_scale=cfg_scale)
                out = self.pipe._forward(model_inputs, **forward_kwargs)
        finally:
            mula.generate_frame = orig_frame
        if cancel.cancelled:
            raise CancelledError()

        # `detokenize` decodes in 29.76 s windows on a 25.6 s hop — five
        # flow-matching passes for a two-minute song, thirteen for six, about
        # half the render's wall time — and offers no hook, so the bar used to
        # sit at 0.92 for all of it and Cancel waited for the whole decode.
        # Its per-window call is wrapped the way generate_frame is above: a
        # real checkpoint and a real bar for the decode half, restored in
        # `finally` so a failed take cannot leave the codec wrapped.
        frames = out["frames"].to(self.pipe.codec_device)
        windows = self._decode_windows(int(frames.shape[-1]))
        flow = self.pipe.codec.flow_matching
        orig_infer = flow.inference_codes
        done = 0

        def counted_window(*a, **kw):
            nonlocal done
            if cancel.cancelled:
                raise CancelledError()
            progress_cb(min(0.99, 0.92 + 0.07 * done / windows),
                        f"decoding with HeartCodec — window "
                        f"{min(done + 1, windows)}/{windows}",
                        step=done, steps=windows)
            res = orig_infer(*a, **kw)
            done += 1
            return res

        progress_cb(0.92, "decoding with HeartCodec (flow matching)")
        flow.inference_codes = counted_window
        try:
            with torch.no_grad():
                wav = self.pipe.codec.detokenize(frames)
        finally:
            flow.inference_codes = orig_infer
        if cancel.cancelled:
            raise CancelledError()
        audio = wav.to(torch.float32).cpu().numpy()
        if audio.ndim == 2:            # (channels, samples) -> (samples, ch)
            audio = audio.T
        tmp = out_path + ".part"
        sf.write(tmp, audio, 48000, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(audio.shape[0] / 48000, 3),
            sample_rate=48000,
            seed_used=seed)

    def unload(self) -> None:
        self.pipe = None

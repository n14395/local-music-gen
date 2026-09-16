"""YuE2 (m-a-p): lyrics + style to a full 48 kHz stereo song, replacing the
two-stage 7B+1B YuE 1 stack with one 3.6B AR-NAR Mixture-of-Transformers plus
flow matching and a small fp32 VAE.

Unlike every other research checkout this app rides, YuE2 is a real installable
package with MPS support engineered in upstream (device ladder cuda→mps→cpu,
GQA fallback for MPS attention, seeded sampling routed through CPU multinomial
so seeds reproduce on MPS, chunked non-CUDA NAR attention, windowed VAE
decode). No shims, no vendored-tree staging: the venv installs the pinned
GitHub tarball and the weights come from the two HF snapshots.

The pipeline is driven stage by stage rather than through its __call__, for
the same reason the InspireMusic adapter wraps llm.inference: each stage hands
this adapter its own progress voice and a real cancel checkpoint —
`plan` (ABC score tokens) → `generate_semantic` (the long counted phase) →
`synthesize` (flow matching) → `decode` (VAE). Upstream polls `cancelled`
inside every stage and raises InterruptedError, which maps 1:1 onto
CancelledError.
"""

from __future__ import annotations

import os
import secrets

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb)

MODEL_NEEDLE = "yue2-3b"
VAE_NEEDLE = "yue2-vae"
# Semantic tokens per song second (upstream's 9000-token sampling ceiling over
# its documented 360 s full-song range; the VAE runs 25 latent frames/s). The
# model ends a song on its own when the lyrics run out — the duration slider
# is a ceiling on the token budget, not a target the take is stretched to.
TOKENS_PER_SECOND = 25


class YuE2Adapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.pipe = None

    def _snapshot(self, needle: str) -> str:
        # By needle, not exact id, like InspireMusic: the adapter should not
        # care whether the catalog points at m-a-p or a future mirror.
        for repo, path in self.model_paths.items():
            if needle in repo.lower():
                return path
        raise RuntimeError(f"no '{needle}' snapshot in model_paths")

    def load(self, progress_cb: ProgressCb) -> None:
        import torch
        from yue2 import YuE2Pipeline

        device = "cpu"
        if str(self.settings.get("device") or "cpu") == "mps" \
                and torch.backends.mps.is_available():
            device = "mps"
        self._device = device

        # __init__ hashes every weight shard against weights_manifest.json —
        # worth a message, because 8 GB of SHA-256 is not instant.
        progress_cb(None, "verifying YuE2 weights (integrity hash, ~8 GB)")
        self.pipe = YuE2Pipeline(
            self._snapshot(MODEL_NEEDLE), self._snapshot(VAE_NEEDLE),
            device=device, progress=False)
        progress_cb(None, "loading YuE2 (3.6B bf16 — takes a little while)")
        # The pipeline loads lazily on first use; pulling the load forward
        # keeps the first take's estimate honest, like every other adapter.
        self.pipe._load_model()
        progress_cb(None, "YuE2 ready on "
                    + ("MPS" if device == "mps"
                       else "CPU — renders will be very slow"))

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.pipe is not None
        from yue2.protocol import SongRequest

        if not (lyrics or "").strip():
            raise RuntimeError("YuE2 writes songs from lyrics — give it some")
        duration_s = min(360.0, float(params.get("duration_s") or 120.0))
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)

        req_kwargs = {"style": (prompt or "").strip() or "a song",
                      "lyrics": lyrics, "seed": seed,
                      "cot": str(params.get("cot") or "full")}
        if params.get("cfg_scale") is not None:
            req_kwargs["cfg_scale"] = float(params["cfg_scale"])
        request = SongRequest(**req_kwargs)

        total = max(200, int(duration_s * TOKENS_PER_SECOND))

        def cancelled() -> bool:
            return cancel.cancelled

        abc_n = sem_n = 0

        def on_abc(phase, token) -> None:
            nonlocal abc_n
            abc_n += 1
            if abc_n % 50 == 0:
                progress_cb(None, f"planning the score — token {abc_n}")

        def on_semantic(phase, token) -> None:
            nonlocal sem_n
            sem_n += 1
            if sem_n % 25 == 0:
                progress_cb(min(0.9, sem_n / total),
                            f"writing music — token {sem_n}/~{total}",
                            step=sem_n, steps=total)

        try:
            if request.cot != "off":
                progress_cb(None, "planning the score (chain-of-thought ABC)")
            plan = self.pipe.plan(request=request, cancelled=cancelled,
                                  on_token=on_abc)
            progress_cb(0.0, "writing music", step=0, steps=total)
            semantic = self.pipe.generate_semantic(
                plan, sampling={"max_tokens": total},
                cancelled=cancelled, on_token=on_semantic)
            progress_cb(0.9, "refining to audio (flow matching)")
            latents = self.pipe.synthesize(semantic, cancelled=cancelled)
            if cancel.cancelled:
                raise CancelledError()
            progress_cb(0.95, "decoding to 48 kHz stereo")
            audio = self.pipe.decode(latents)
        except InterruptedError:
            # Upstream's own cancellation signal, raised at its stage
            # checkpoints when `cancelled()` reports True.
            raise CancelledError() from None

        # (frames, 2) float — the same shape upstream's SongResult.save writes.
        tmp = out_path + ".part"
        sf.write(tmp, audio, 48000, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        extra = {}
        if plan.truncated or semantic.truncated:
            # The token ceiling cut the song off before its end token — the
            # audio is playable but ends mid-thought. Worth surfacing.
            extra["truncated"] = True
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(len(audio) / 48000, 3),
            sample_rate=48000,
            seed_used=seed,
            extra=extra)

    def unload(self) -> None:
        self.pipe = None

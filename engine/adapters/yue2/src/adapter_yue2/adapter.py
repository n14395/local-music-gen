# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

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

Driving it stage by stage also puts this adapter at the seams between them,
which is where the MPS allocator has to be told to hand its pool back — see
MPS_FLUSH_TOKENS for the render that made that necessary.
"""

from __future__ import annotations

import os
import secrets

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir, clear_stale_link,
                                     release_accelerator_memory)

MODEL_NEEDLE = "yue2-3b"
VAE_NEEDLE = "yue2-vae"
# Everything upstream reads from a checkpoint folder (its own MODEL_FILES),
# beyond the shards the weights manifest names. Linked when present.
STAGED_FILES = ("config.json", "generation_config.json",
                "yue2_generation_config.json", "weights_manifest.json",
                "model.safetensors", "model.safetensors.index.json",
                "qwen.tiktoken", "modeling_yue2.py", "modeling_vae.py",
                "LICENSE", "THIRD_PARTY_NOTICES.md")
# Semantic tokens per song second (upstream's 9000-token sampling ceiling over
# its documented 360 s full-song range; the VAE runs 25 latent frames/s). The
# model ends a song on its own when the lyrics run out — the duration slider
# is a ceiling on the token budget, not a target the take is stretched to.
TOKENS_PER_SECOND = 25
# Tokens between MPS allocator flushes in the two AR stages.
#
# A 303 s render died in flow matching with "MPS allocated: 72.80 GiB" — the
# torch MPS allocator's heap total, of which barely 8 GiB was live tensors.
# Nothing leaks: measured on this render's own shapes, each stage's footprint
# is flat in token count (the AR pass settles ~4 GiB above the model by token
# 300 and stays there; flow matching peaks at ~16 GiB over it). What the
# allocator does is keep every high-water mark it has ever reached, because
# it only tries to reclaim at its low watermark — 1.4x the Metal working set,
# 72.6 GiB on a 64 GB Mac, i.e. above the machine's own RAM. So a warm worker
# carried each take's peak into the next, climbing 8.9 → 18.9 GiB across five
# takes, until the pool plus the ~15 GiB of non-torch Metal allocations beside
# it crossed the 88.13 GiB device ceiling and a 1 MiB attention output failed.
#
# The flushes that matter are therefore the ones at the boundaries, where the
# model is all that is live. This in-loop interval is the smaller effect
# (4.12 → 3.50 GiB of AR pool) and saturates: 25 and 5 measure the same, so
# 100 buys the whole of it for a commit-and-wait every ~10 s of decoding.
MPS_FLUSH_TOKENS = 100


class YuE2Adapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.pipe = None
        # load() settles this; generate() reads it to decide whether the
        # allocator flushes are worth making at all.
        self._device = "cpu"

    def _snapshot(self, needle: str) -> str:
        # By needle, not exact id, like InspireMusic: the adapter should not
        # care whether the catalog points at m-a-p or a future mirror.
        for repo, path in self.model_paths.items():
            if needle in repo.lower():
                return path
        raise RuntimeError(f"no '{needle}' snapshot in model_paths")

    def _stage(self, needle: str, name: str) -> str:
        """A clean twin of the snapshot holding only the files upstream reads.

        The library volume is ExFAT, which cannot carry extended attributes,
        so macOS writes an AppleDouble `._X` twin beside every file in it.
        Upstream's manifest check enumerates the folder with
        `Path.glob("*.safetensors")` — which, unlike `glob.glob`, returns
        dot-files — finds `._model.safetensors`, has no manifest entry for
        it, and refuses to load ("Weight integrity failed"). This is why the
        entry had never rendered. Deleting the twins is no fix, macOS
        recreates them; so the pipeline is pointed at a folder of links to
        exactly the files the manifest and the loaders name, the move the
        HeartMuLa adapter makes for its checkpoint folder.

        Links cross from the aux cache into an HF snapshot and a library
        relocate strands them, so each goes through clear_stale_link before
        the exists-check — the InspireMusic lesson. Anything else that turns
        up in the stage (a twin of a link, a shard from an older revision)
        would fail the same check, so the sweep at the end removes it.
        """
        import json
        snapshot = self._snapshot(needle)
        root = os.path.join(aux_dir("yue2"), name)
        os.makedirs(root, exist_ok=True)
        names = set(STAGED_FILES)
        manifest = os.path.join(snapshot, "weights_manifest.json")
        if os.path.exists(manifest):
            with open(manifest) as f:
                names.update(json.load(f).get("files", {}))
        for filename in sorted(names):
            target = os.path.join(snapshot, filename)
            link = os.path.join(root, filename)
            clear_stale_link(link)
            if os.path.islink(link) and os.path.realpath(link) != \
                    os.path.realpath(target):
                # Alive but pointing at an older snapshot revision.
                os.unlink(link)
            if os.path.exists(target) and not os.path.lexists(link):
                os.symlink(target, link)
        for entry in os.listdir(root):
            if entry not in names:
                os.unlink(os.path.join(root, entry))
        return root

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
            self._stage(MODEL_NEEDLE, "YuE2-3B"),
            self._stage(VAE_NEEDLE, "YuE2-Vae"),
            # offload_ar is upstream's own memory tradeoff: the AR attention
            # and MLP weights go to the CPU for the duration of the ODE, which
            # only touches the NAR half of the Mixture-of-Transformers. It
            # halves what is live in the stage the 303 s render died in, 8.2 →
            # 4.2 GiB, for one 4 GB round trip per chunk. The memory is a
            # direct reading; the transfer's cost never rose above this
            # machine's run-to-run variance on the stage (which is wide —
            # 59-86 s per solver step for one unchanged configuration), so
            # treat it as bought memory rather than as free. Not worth the
            # transfer on CPU, where nothing is being made room for.
            offload_ar=device == "mps",
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
        import torch

        from yue2.protocol import SongRequest, chunk_ranges

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

        def flush() -> None:
            if self._device == "mps":
                torch.mps.empty_cache()

        # The most valuable flush of the render: between takes the model is
        # the only thing live, so the whole of the previous take's pool can
        # go back. A warm worker never called unload() between takes, so it
        # carried every take's high-water mark into the next one — measured
        # climbing 8.9 → 18.9 GiB across five takes and never falling.
        flush()

        # Upstream polls `cancelled` once before each chunk's acoustic prefill
        # and twice per ODE step, and that is its only hook into flow matching.
        # What rides along is progress, NOT a flush: upstream reports the
        # stage's steps through its own Progress object, which this adapter
        # turns off, so the longest stage of the render used to pass in
        # silence — 33 minutes of it at a 300 s song, which reads as a hung
        # job. Counting the polls recovers a real step number.
        #
        # An `empty_cache()` here hangs the render: it hands the whole pool
        # back twice a step and flow matching asks for all of it again on the
        # next layer. 149 s per solver step against a ~60-86 s baseline, and
        # — the part that matters, because it is well outside this machine's
        # wide variance — climbing inside a single run, 119 → 178 s across
        # two steps. Extrapolated over 32 steps that is hours, which is what
        # "stuck at refining to audio" was. It had bought ~1 GiB of peak.
        # The flushes that pay for themselves are the ones at the seams,
        # where the stage is over and the model is all that is live.
        ode_total = 0
        ode_polls = 0
        ode_reported = -1

        def cancelled() -> bool:
            nonlocal ode_polls, ode_reported
            if ode_total:
                ode_polls += 1
                # One prefill poll per chunk, then two per solver step.
                step = min(ode_total, ode_polls // 2)
                if step != ode_reported:
                    ode_reported = step
                    progress_cb(0.9 + 0.05 * step / ode_total,
                                f"refining to audio — step {step}/{ode_total}",
                                step=step, steps=ode_total)
            return cancel.cancelled

        abc_n = sem_n = 0

        def on_abc(phase, token) -> None:
            nonlocal abc_n
            abc_n += 1
            if abc_n % 50 == 0:
                progress_cb(None, f"planning the score — token {abc_n}")
            if abc_n % MPS_FLUSH_TOKENS == 0:
                flush()

        def on_semantic(phase, token) -> None:
            nonlocal sem_n
            sem_n += 1
            if sem_n % 25 == 0:
                progress_cb(min(0.9, sem_n / total),
                            f"writing music — token {sem_n}/~{total}",
                            step=sem_n, steps=total)
            if sem_n % MPS_FLUSH_TOKENS == 0:
                flush()

        try:
            if request.cot != "off":
                progress_cb(None, "planning the score (chain-of-thought ABC)")
            plan = self.pipe.plan(request=request, cancelled=cancelled,
                                  on_token=on_abc)
            flush()
            progress_cb(0.0, "writing music", step=0, steps=total)
            semantic = self.pipe.generate_semantic(
                plan, sampling={"max_tokens": total},
                cancelled=cancelled, on_token=on_semantic)
            # Between stages the model is the only thing still live, so a
            # flush here hands back everything the AR pass accumulated
            # before the acoustic prefill — the largest single allocation of
            # the render — asks for its own.
            flush()
            progress_cb(0.9, "refining to audio (flow matching)")
            # Upstream's own chunking and solver settings decide how many
            # steps this stage really has; ask it rather than assuming one
            # chunk. Setting the total is what arms the reporting in
            # `cancelled` — it is zero, and silent, during the AR stages.
            cfg = self.pipe.generation_config
            ode_total = cfg.ode_steps * len(chunk_ranges(
                len(semantic.tokens), len(semantic.plan.prefix), cfg.context))
            try:
                latents = self.pipe.synthesize(semantic, cancelled=cancelled)
            finally:
                ode_total = 0
            if cancel.cancelled:
                raise CancelledError()
            flush()
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
        # close() is upstream's own teardown — it drops `_model` and `_vae`,
        # which this adapter cannot reach — and only after it does dropping
        # the pipe free anything. Rebinding alone left a 3.6 B bf16 model's
        # Metal buffers checked out for the next model in a warm worker.
        pipe, self.pipe = self.pipe, None
        if pipe is not None:
            try:
                pipe.close()
            except Exception:  # noqa: BLE001 — unload must never raise
                pass
        del pipe
        release_accelerator_memory()

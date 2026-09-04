"""VampNet: masked-token variation on existing audio — "make variations of
this loop", a capability class nothing else in the catalog has.

Rides the ordinary `generate` task with a required `src_audio` param (the
style-transfer precedent): the prompt is unused by the model, the audio is
the material, and the masks decide how much survives. `periodic_prompt`
controls the density of kept tokens (low = the source shows through
everywhere, high = freer variation); `upper_codebook_mask` how many coarse
codebooks stay conditioned.

Packaging notes, learned in triage: the package reads a DEFAULT_HF_MODEL_REPO
file beside site-packages at import (setup.py forgets to install it — created
here before the import); the steps kwarg is `_sampling_steps`; decoding is
`interface.decode(z)`, not the documented `to_signal`.

Device: the catalog keeps VampNet on CPU. The PyTorch 2.4 MPS codec path can
abort the worker in Metal while allocating its first compiled codec buffer,
despite ample system RAM. CPU is the proven path for this family.
"""

from __future__ import annotations

import math
import os
import secrets

# Read at torch import: lets any stray op the MPS backend lacks fall back
# to CPU instead of aborting the render. Harmless on the CPU route.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

MAX_INPUT_S = 20.0   # coarse context is ~10 s; 20 s runs two windows

# What `beat_mask` may say. It was a bool meaning "protect the onsets" before
# the beat tracker was wired up, and old presets still carry that bool — so
# True keeps meaning exactly what it used to.
SYNC_MODES = ("off", "onsets", "beats", "downbeats")


def _sync_mode(value) -> str:
    if value is True:
        return "onsets"
    if not value:
        return "off"
    mode = str(value).strip().lower()
    return mode if mode in SYNC_MODES else "off"


def _ensure_repo_marker() -> None:
    """vampnet/__init__ crashes without the repo-name file its setup.py
    forgets to ship; write it where ROOT (= site-packages) expects it."""
    import importlib.util
    import pathlib

    spec = importlib.util.find_spec("vampnet")
    if spec is None or not spec.origin:
        return
    marker = pathlib.Path(spec.origin).parent.parent / "DEFAULT_HF_MODEL_REPO"
    if not marker.exists():
        marker.write_text("hugggof/vampnet")


def _apply_mps_patch() -> None:
    """Keep VampNet's attention scale in MPS-supported float32 precision.

    The pinned upstream implementation divides the MPS attention tensor by
    ``numpy.sqrt(...)``. That returns a NumPy float64 scalar and PyTorch tries
    to promote the tensor to float64, which MPS cannot represent.
    """
    import torch
    import vampnet.beats as beats
    import vampnet.modules.transformer as transformer

    attention = transformer.MultiHeadRelativeAttention
    if getattr(attention, "_localmusic_mps", False):
        return
    attention._localmusic_mps = True

    def forward(self_, q, k, v, mask=None, position_bias=None):
        q = transformer.rearrange(self_.w_qs(q), "b l (head k) -> head b l k",
                                  head=self_.n_head)
        k = transformer.rearrange(self_.w_ks(k), "b t (head k) -> head b t k",
                                  head=self_.n_head)
        v = transformer.rearrange(self_.w_vs(v), "b t (head k) -> head b t k",
                                  head=self_.n_head)
        attn = transformer.torch.einsum("hblk,hbtk->hblt", [q, k])
        attn = attn / math.sqrt(q.shape[-1])
        if position_bias is None:
            if self_.has_relative_attention_bias:
                position_bias = self_.compute_bias(q.size(-2), k.size(-2))
            else:
                position_bias = transformer.torch.zeros_like(attn)
        attn += position_bias
        if mask is not None:
            attn = attn.masked_fill(mask[None] == 0, -1e9)
        attn = self_.dropout(transformer.torch.softmax(attn, dim=3))
        output = transformer.torch.einsum("hblt,hbtv->hblv", [attn, v])
        output = transformer.rearrange(output, "head b l v -> b l (head v)")
        return self_.fc(output), position_bias

    attention.forward = forward

    # WaveBeat's own extraction path selects CPU whenever CUDA is unavailable,
    # including Apple Silicon. Loading its Lightning checkpoint on MPS first is
    # therefore both unnecessary and invalid: the checkpoint contains float64
    # tensors that MPS cannot deserialize.
    wavebeat = beats.WaveBeat
    if not getattr(wavebeat, "_localmusic_cpu_load", False):
        wavebeat._localmusic_cpu_load = True

        def init(self_, ckpt_path: str, device: str = "cpu") -> None:
            from wavebeat.dstcn import dsTCNModel

            model = dsTCNModel.load_from_checkpoint(
                ckpt_path, map_location=torch.device("cpu"))
            model.eval()
            self_.device = "cpu"
            self_.model = model

        wavebeat.__init__ = init


class VampNetAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.interface = None
        requested_device = str(self.settings.get("device") or "cpu")
        # Protect existing user catalogs created before the MPS route proved
        # unstable; new catalog entries already request CPU explicitly.
        self.device = "cpu" if requested_device == "mps" else requested_device

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        _ensure_repo_marker()
        progress_cb(None, "loading VampNet (coarse + c2f + codec + wavebeat)")
        from vampnet import interface as vi

        if self.device == "mps":
            _apply_mps_patch()

        snap = self._snapshot()
        # A finetune entry names its checkpoint pair under loras/<name>/;
        # the codec and beat tracker are always the root ones. These are
        # full coarse/c2f swaps, not adapter deltas — same Interface call.
        lora = str(self.settings.get("lora") or "").strip()
        pair_dir = os.path.join(snap, "loras", lora) if lora else snap
        self.interface = vi.Interface(
            coarse_ckpt=os.path.join(pair_dir, "coarse.pth"),
            coarse2fine_ckpt=os.path.join(pair_dir, "c2f.pth"),
            codec_ckpt=os.path.join(snap, "codec.pth"),
            wavebeat_ckpt=os.path.join(snap, "wavebeat.pth"),
            device=self.device)
        progress_cb(None, "VampNet ready on the GPU (MPS)"
                          if self.device == "mps" else "VampNet ready")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.interface is not None
        import audiotools as at
        import torch

        src = params.get("src_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("src_audio missing — VampNet makes variations "
                               "OF something; give it a loop")

        periodic = max(1, min(30, int(params.get("periodic_prompt") or 7)))
        # `or` swallowed the legal 0 ("mask nothing") and turned the slider's
        # bottom stop into the default (audit §2).
        um = params.get("upper_codebook_mask")
        upper_mask = max(0, min(14, 3 if um is None else int(um)))
        temperature = float(params.get("temperature") or 1.0)
        steps = max(2, min(36, int(params.get("steps") or 8)))
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. `seed_used` reports it back.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        torch.manual_seed(seed)

        duration = min(MAX_INPUT_S, float(params.get("duration_s") or 10.0))
        progress_cb(0.05, "encoding the source", phase="prompt_encode")
        signal = at.AudioSignal(src, duration=duration)
        # SoundFile decodes some input formats to float64. The interface moves
        # this signal to MPS before preprocessing, where float64 is unsupported.
        signal.samples = signal.samples.to(dtype=torch.float32)
        z = self.interface.encode(signal)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(0.2, "vamping (coarse)", phase="lm_decode")
        mask_kwargs: dict = {"periodic_prompt": periodic,
                             "upper_codebook_mask": upper_mask,
                             "prefix_s": max(0.0, float(
                                 params.get("prefix_s") or 0.0)),
                             "suffix_s": max(0.0, float(
                                 params.get("suffix_s") or 0.0))}
        sync = _sync_mode(params.get("beat_mask"))
        if sync == "onsets":
            # Keep tokens around detected onsets so attacks survive the vamp.
            # ±5 tokens ≈ ±90 ms at the codec's hop. This is librosa's
            # spectral onset detector inside build_mask — every transient,
            # with no idea where the bar is.
            mask_kwargs["onset_mask_width"] = 5
        mask = self.interface.build_mask(z, signal, **mask_kwargs)
        if sync in ("beats", "downbeats"):
            mask = self._beat_sync(mask, signal, downbeats_only=(
                sync == "downbeats"), progress_cb=progress_cb)

        stretch = max(1, min(4, int(params.get("time_stretch") or 1)))
        if stretch > 1:
            # Upstream's own token-level stretch (`Interface.vamp`): insert
            # `stretch - 1` empty slots after every source token and mark them
            # for generation, so the model writes what happens in between.
            # The loop gets longer without anything being resampled — pitch
            # and timbre are untouched, the playing is what is invented.
            z = z.repeat_interleave(stretch, dim=-1)
            mask = mask.repeat_interleave(stretch, dim=-1)
            added = torch.ones_like(mask)
            added[:, :, ::stretch] = 0
            mask = (mask.bool() | added.bool()).long()

        zv, _mask = self.interface.coarse_vamp(
            z, mask=mask, _sampling_steps=steps, temperature=temperature,
            return_mask=True)
        if cancel.cancelled:
            raise CancelledError()
        progress_cb(0.6, "refining (coarse-to-fine)", phase="lm_decode")
        zv = self.interface.coarse_to_fine(zv, temperature=0.8,
                                           _sampling_steps=max(2, steps // 2))
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(0.9, "decoding", phase="master")
        out = self.interface.decode(zv)
        # `.part.wav`, not `.part`: audiotools writes through soundfile,
        # which infers the container from the extension and refuses a name
        # it does not recognise. The rename to out_path is still atomic.
        tmp = out_path + ".part.wav"
        out.write(tmp)
        os.replace(tmp, out_path)
        sample_rate = int(out.sample_rate)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(float(out.duration), 3),
            sample_rate=sample_rate,
            seed_used=seed)

    def _beat_sync(self, mask, signal, *, downbeats_only: bool, progress_cb):
        """Narrow `mask` so the tracked beats survive the vamp.

        This is what the wavebeat checkpoint every entry downloads is FOR — it
        was fetched and never called until now. Onset masking (above) protects
        every transient it can hear; this protects the pulse, which is a
        different and usually better thing to keep: the groove stays put while
        everything between the beats is re-imagined.

        `make_beat_mask(invert=True)` marks the beat neighbourhoods as
        keep-me, and `mask_and` means a token is only regenerated where both
        masks agree it should be.

        Never fatal: a track the tracker finds no pulse in should vamp
        normally rather than fail, so a failure here degrades to the mask that
        was already built.
        """
        import torch
        from vampnet.mask import mask_and

        try:
            progress_cb(0.15, "finding the beat", phase="prompt_encode")
            beat_mask = self.interface.make_beat_mask(
                signal,
                before_beat_s=0.0,
                # ~70 ms after each beat: enough to hold the transient and its
                # attack, short enough that the model still rewrites the space
                # between beats rather than copying it.
                after_beat_s=0.07,
                mask_upbeats=not downbeats_only,
                mask_downbeats=True,
                invert=True)
            # The beat mask is built from the signal's duration and the
            # codes from the encoder, and the two round to token counts
            # independently. Line them up rather than letting a one-token
            # disagreement raise from inside the library.
            width = mask.shape[-1]
            if beat_mask.shape[-1] < width:
                pad = torch.ones(
                    beat_mask.shape[0], beat_mask.shape[1],
                    width - beat_mask.shape[-1],
                    dtype=beat_mask.dtype, device=beat_mask.device)
                beat_mask = torch.cat([beat_mask, pad], dim=-1)
            beat_mask = beat_mask[:, :mask.shape[1], :width]
            return mask_and(mask, beat_mask)
        except Exception as e:  # noqa: BLE001 — no pulse found is not a failure
            import sys

            print(f"beat tracking found nothing usable ({e}); "
                  f"vamping without it", file=sys.stderr)
            return mask

    def unload(self) -> None:
        self.interface = None

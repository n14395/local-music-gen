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

# Read at torch import: lets any stray op the MPS backend lacks fall back
# to CPU instead of aborting the render. Harmless on the CPU route.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb)

MAX_INPUT_S = 20.0   # coarse context is ~10 s; 20 s runs two windows


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
        seed = params.get("seed")
        if seed is not None:
            torch.manual_seed(int(seed))

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
        if params.get("beat_mask"):
            # Keep tokens around detected onsets so the downbeats survive
            # the vamp. ±5 tokens ≈ ±90 ms at the codec's hop.
            mask_kwargs["onset_mask_width"] = 5
        mask = self.interface.build_mask(z, signal, **mask_kwargs)
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
            seed_used=int(seed) if seed is not None else None)

    def unload(self) -> None:
        self.interface = None

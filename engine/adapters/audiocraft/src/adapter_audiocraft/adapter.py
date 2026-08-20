"""Meta audiocraft runtime: MAGNeT and audiocraft-format MusicGen checkpoints.

Unlocks the models transformers cannot load: MAGNeT (non-autoregressive, no
transformers port), MusicGen-Style, and community finetunes that only ship
audiocraft's state_dict.bin (e.g. musicgen-songstarter).

Snapshot layout: the model repo provides state_dict.bin +
compression_state_dict.bin; a second, pattern-scoped t5-base repo pre-seeds the
HF cache so audiocraft's T5 conditioner never hits the network at load time.
fp16 autocast is disabled after load — unsupported/artifact-prone on MPS.

MusicGen-Style conditions on an *audio excerpt* rather than on a melody, and
audiocraft routes both through the same `self_wav` slot — so `generate_with_chroma`
is the entry point for each and the difference is which conditioner the
checkpoint registered. What the two preserve is opposite: chroma keeps the tune
and discards the timbre, the style conditioner keeps the texture and discards
the tune.

Reported phases are `prompt_encode` → `lm_decode` → `master`, matching the
`capabilities.pipeline` this family's catalog entries declare. `lm_decode` covers
both runtimes' token loops: MAGNeT's decoding steps are not autoregressive, but
audiocraft counts them through the same callback.
"""

from __future__ import annotations

import os
import sys

# Must precede any audiocraft import (its transformer module imports xformers
# at module scope; there are no macOS wheels).
_STUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_stub")
if _STUB not in sys.path:
    sys.path.insert(0, _STUB)

import numpy as np
import soundfile as sf
import torch

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb)


_autocast_patched = False


def _disarm_mps_autocast() -> None:
    """audiocraft constructs fp16/fp32 autocast contexts for any non-CPU
    device (genmodel and several conditioners). torch 2.1 rejects
    device_type='mps' at construction, and fp16 MusicGen on MPS is a known
    artifact source anyway — force those contexts to no-ops."""
    global _autocast_patched
    if _autocast_patched:
        return
    from audiocraft.utils import autocast as ac

    original_init = ac.TorchAutocast.__init__

    def mps_safe_init(self, enabled: bool, *args, **kwargs):
        if kwargs.get("device_type") == "mps":
            enabled, args, kwargs = False, (), {}
        original_init(self, enabled, *args, **kwargs)

    ac.TorchAutocast.__init__ = mps_safe_init

    # Melody (chroma-stem) conditioning cannot run on MPS with torch 2.1:
    # torchaudio's spectrogram does complex in-place division there, and the
    # conditioner already probes it at construction. Demucs + chroma are cheap
    # next to the LM — build the whole conditioner on CPU; its forward()
    # re-homes the embedding onto the projection's device.
    from audiocraft.modules import conditioners as cond_mod

    original_chroma_init = cond_mod.ChromaStemConditioner.__init__

    def cpu_chroma_init(self, *args, **kwargs):
        kwargs["device"] = "cpu"
        original_chroma_init(self, *args, **kwargs)

    cond_mod.ChromaStemConditioner.__init__ = cpu_chroma_init
    _autocast_patched = True


def _pad_to_excerpt(wav: "torch.Tensor", sample_rate: int,
                    excerpt_s: float) -> "torch.Tensor":
    """Make a style reference at least one excerpt long, by looping it.

    `FeatureExtractor._get_wav_embedding` picks its excerpt with
    `random.randint(0, len - length_subwav)`, which raises `ValueError: empty
    range` the moment the clip is shorter than the excerpt — and nothing
    upstream pads it: the `match_len_on_eval` padding lives in
    `ChromaStemConditioner`, not in the style conditioner's base class. A
    two-second loop handed to a three-second excerpt is a perfectly ordinary
    thing for a user to try, so it has to work.

    Looping rather than zero-padding: silence is not neutral to a conditioner
    that is being asked what the audio *sounds like*, and half an excerpt of it
    would drag the style toward "quiet".
    """
    # A little longer than asked for. The excerpt is measured in the *model's*
    # sample rate after audiocraft resamples the clip, so padding to exactly the
    # requested duration can still land a sample short of `length_subwav` once
    # the rates do not divide evenly — and a sample short is the whole failure.
    needed = int((excerpt_s + 0.1) * sample_rate)
    length = wav.shape[-1]
    if length >= needed or length == 0:
        return wav
    repeats = -(-needed // length)          # ceil
    return wav.repeat(1, repeats)[:, :needed]


class AudiocraftAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.kind = self.settings.get("kind", "musicgen")  # musicgen | magnet
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        if self.settings.get("device"):
            self.device = str(self.settings["device"])

    def _snapshot(self) -> str:
        for repo_id, path in self.model_paths.items():
            if os.path.exists(os.path.join(path, "state_dict.bin")):
                return path
        raise RuntimeError("no audiocraft checkpoint (state_dict.bin) in snapshot")

    def load(self, progress_cb: ProgressCb) -> None:
        _disarm_mps_autocast()
        from audiocraft.models import MAGNeT, MusicGen

        progress_cb(None, f"loading {self.kind} weights")
        cls = MAGNeT if self.kind == "magnet" else MusicGen
        self.model = cls.get_pretrained(self._snapshot(), device=self.device)
        # The builder does condition_provider.to(device) after construction,
        # dragging the (deliberately CPU-built) chroma module's buffers to MPS
        # — demucs alone is hidden from the module tree. Move it back.
        conditioners = getattr(
            getattr(getattr(self.model, "lm", None), "condition_provider",
                    None), "conditioners", None)
        if conditioners is not None and "self_wav" in conditioners:
            self_wav = conditioners["self_wav"]
            if hasattr(self_wav, "chroma"):
                self_wav.chroma.to("cpu")
        progress_cb(None, f"{self.kind} on {self.device}")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.model is not None
        duration_s = float(params.get("duration_s", 10.0))
        seed = params.get("seed")
        if seed is not None:
            torch.manual_seed(int(seed))

        if self.kind == "magnet":
            # MAGNeT's span pattern fixes the clip length per checkpoint.
            self.model.set_generation_params(
                temperature=float(params.get("temperature", 3.0)),
                top_p=float(params.get("top_p", 0.9)))
        else:
            self.model.set_generation_params(
                duration=duration_s,
                use_sampling=True,
                top_k=int(params.get("top_k", 250)),
                temperature=float(params.get("temperature", 1.0)),
                cfg_coef=float(params.get("guidance_scale", 3.0)))

        def on_tokens(done: int, total: int) -> None:
            if cancel.cancelled:
                raise CancelledError()
            if done % 25 == 0 and self.device == "mps":
                # Same MPS allocator pathology as the transformers MusicGen:
                # the streaming KV concat grows the driver footprint
                # quadratically (observed ~62 GB mid-clip) unless freed blocks
                # are returned to the OS.
                torch.mps.empty_cache()
            progress_cb(min(1.0, done / max(1, total)),
                        f"{done}/{total} tokens",
                        phase="lm_decode", step=done, steps=total)

        # MusicGen-Style's excerpt conditioner has its own knobs, and they are
        # set per generation rather than at load.
        excerpt_s = None
        if self.settings.get("style"):
            excerpt_s = float(params.get("style_excerpt_s", 3.0))
            self.model.set_style_conditioner_params(excerpt_length=excerpt_s)

        self.model.set_custom_progress_callback(on_tokens)
        progress_cb(None, "encoding prompt", phase="prompt_encode")
        try:
            # Melody and style ride the *same* conditioning slot upstream
            # (`self_wav`), and `generate_with_chroma` is the entry point for
            # both — whichever conditioner the checkpoint registered there
            # consumes the wav. So one call site serves two very different
            # capabilities: chroma keeps the tune and throws away the timbre,
            # the style conditioner does the opposite.
            ref_path = params.get("melody_audio") or params.get("style_audio")
            is_style = bool(self.settings.get("style")
                            and params.get("style_audio"))
            if ref_path and (self.settings.get("melody") or is_style):
                wav, sr = sf.read(str(ref_path), dtype="float32",
                                  always_2d=True)
                melody = torch.from_numpy(wav.T)  # (C, T)
                if is_style:
                    melody = _pad_to_excerpt(melody, sr, excerpt_s or 3.0)
                audio = self.model.generate_with_chroma(
                    [prompt], melody[None], sr, progress=True)
            else:
                audio = self.model.generate([prompt], progress=True)
        finally:
            self.model.set_custom_progress_callback(None)
            if self.device == "mps":
                torch.mps.empty_cache()
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(1.0, "writing audio", phase="master")
        sample_rate = int(self.model.sample_rate)
        wav = audio[0].detach().float().cpu().numpy().T  # (T, C)
        if wav.ndim == 2 and wav.shape[1] == 1:
            wav = wav[:, 0]
        wav = np.clip(wav, -1.0, 1.0)
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=int(seed) if seed is not None else None)

    def unload(self) -> None:
        self.model = None
        if self.device == "mps":
            torch.mps.empty_cache()

# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Meta audiocraft runtime: MAGNeT and audiocraft-format MusicGen checkpoints.

Unlocks the models transformers cannot load: MAGNeT (non-autoregressive, no
transformers port), MusicGen-Style, and community finetunes that only ship
audiocraft's state_dict.bin (e.g. musicgen-songstarter).

Snapshot layout: the model repo provides state_dict.bin +
compression_state_dict.bin; a second, pattern-scoped t5-base repo pre-seeds the
HF cache so audiocraft's T5 conditioner never hits the network at load time.
fp16 autocast is disabled after load — unsupported/artifact-prone on MPS.

EnCodec's decoder is repaired on the way in: see `_fix_mps_elu`. Without it
every model in this family returns noise, however good its tokens were.

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
import secrets
import random
import sys

# Must precede any audiocraft import (its transformer module imports xformers
# at module scope; there are no macOS wheels).
_STUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_stub")

# How much of the source a continuation listens to. MusicGen's attention window
# is 30 s and the prompt lives inside it, so this is bought directly out of how
# much new music fits — 10 s is upstream's own demo figure.
CONTINUE_PROMPT_S = 10.0
if _STUB not in sys.path:
    sys.path.insert(0, _STUB)

import numpy as np
import soundfile as sf
import torch

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb,
                                     release_accelerator_memory)


_autocast_patched = False
_elu_patched = False


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


def _fix_mps_elu() -> None:
    """Make `nn.ELU` contiguous-safe, without which every model here is noise.

    torch 2.1's MPS `elu` reads a non-contiguous input as if it were packed, so
    it returns garbage — silently, and only for that one activation:

        x = torch.randn(100, 1, 1024).permute(1, 2, 0)   # not contiguous
        (torch.nn.ELU()(x.to("mps")).cpu() - torch.nn.ELU()(x)).abs().max()
        # -> same order as the signal itself; relu/tanh/sigmoid are all exact

    EnCodec walks straight into it. `SLSTM.forward` ends `y.permute(1, 2, 0)`
    and the next module in the SEANet decoder is that ELU, so the very first
    thing done to the latents is wrong and all the upsampling that follows is
    working on noise. The tokens are perfect — greedy decoding gives the same
    ids on CPU and MPS to the last one — which is what makes it so hard to see
    from the outside: it looks like a broken model rather than a broken codec.
    Measured on musicgen-medium's codec, a 3 s clip round-trips at +15.86 dB on
    CPU and -0.57 dB on MPS; with this patch MPS matches CPU exactly.

    Every audiocraft checkpoint is affected, not just the one that got reported
    — MAGNeT, musicgen-style and songstarter all decode through this. The
    family is alone in it only because audiocraft pins torch==2.1.0 while every
    other adapter here is on 2.7+, where the op is fixed. That pin is the thing
    to remove when audiocraft's own floor moves; until then this is the repair.

    Patched on the class rather than at the call sites because there are two
    EnCodec implementations in play — audiocraft's own `SEANetDecoder` and the
    transformers port that `nateraw/musicgen-songstarter-v0.2` delegates to —
    and both reach the same `nn.ELU`.
    """
    global _elu_patched
    if _elu_patched:
        return
    import torch.nn as nn

    _elu_patched = True
    if not torch.backends.mps.is_available():
        return
    # Probed rather than version-gated, so the workaround disappears by itself
    # the day the pin moves to a torch that has the op right — a patch that
    # outlives its bug is how a wrong result gets blamed on the fix.
    probe = torch.randn(8, 1, 32).permute(1, 2, 0)
    elu = nn.ELU()
    if torch.allclose(elu(probe.to("mps")).cpu(), elu(probe), atol=1e-5):
        return

    original_forward = nn.ELU.forward

    def contiguous_elu(self, input):
        return original_forward(
            self, input if input.is_contiguous() else input.contiguous())

    nn.ELU.forward = contiguous_elu


def _tail_clip(path: str, seconds: float):
    """The last `seconds` of a file as a (channels, samples) tensor + its rate.

    No resampling: `generate_continuation` is told the rate and converts the
    clip itself (`convert_audio` to the model's rate and channel count), so
    doing it here would be the same work done twice and slightly worse.
    """
    import torch

    wav, sr = sf.read(path, dtype="float32", always_2d=True)
    keep = int(seconds * sr)
    if len(wav) > keep:
        wav = wav[-keep:]
    return torch.from_numpy(np.ascontiguousarray(wav.T)), int(sr)


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

    def _mert_snapshot(self) -> str | None:
        for repo_id, path in self.model_paths.items():
            if "mert" in repo_id.lower():
                return path
        return None

    def _redirect_mert(self) -> None:
        """Serve audiocraft's hardcoded `m-a-p/MERT-v1-95M` from the local
        snapshot. Without this the style conditioner re-fetches MERT's remote
        code from the Hub at every load and fails offline (audit §3)."""
        snap = self._mert_snapshot()
        if not snap:
            return
        import transformers

        orig = transformers.AutoModel.from_pretrained

        def patched(name, *args, **kwargs):
            if isinstance(name, str) and "MERT-v1-95M" in name:
                name = snap
                kwargs.setdefault("local_files_only", True)
            return orig(name, *args, **kwargs)

        transformers.AutoModel.from_pretrained = patched

    def _repair_mert_pos_conv(self) -> None:
        """Copy MERT's positional-conv weight-norm tensors in by hand.

        Under the pinned transformers the checkpoint's legacy
        `weight_g`/`weight_v` keys no longer match the parametrized module,
        so the positional conv came up randomly initialized — degraded style
        conditioning that differed per worker process (audit §3). The rename
        shim only covers transformers' own classes, not MERT's remote code.
        """
        snap = self._mert_snapshot()
        conditioners = getattr(
            getattr(getattr(self.model, "lm", None), "condition_provider",
                    None), "conditioners", {}) or {}
        feat = next((getattr(c, "feat_extractor", None)
                     for c in conditioners.values()
                     if getattr(c, "model_name", "") == "mert"), None)
        if feat is None or not snap:
            return
        try:
            sd = torch.load(os.path.join(snap, "pytorch_model.bin"),
                            map_location="cpu", weights_only=True)
            g = sd.get("encoder.pos_conv_embed.conv.weight_g")
            v = sd.get("encoder.pos_conv_embed.conv.weight_v")
            conv = feat.encoder.pos_conv_embed.conv
            if g is None or v is None:
                return
            with torch.no_grad():
                if hasattr(conv, "parametrizations"):
                    p = conv.parametrizations.weight
                    p.original0.copy_(g.to(p.original0.dtype))
                    p.original1.copy_(v.to(p.original1.dtype))
                else:
                    conv.weight_g.copy_(g.to(conv.weight_g.dtype))
                    conv.weight_v.copy_(v.to(conv.weight_v.dtype))
        except Exception as e:  # noqa: BLE001 — degraded style beats no load
            print(f"MERT pos-conv repair failed ({e}); style conditioning "
                  "runs with the degraded random init", file=sys.stderr)

    def load(self, progress_cb: ProgressCb) -> None:
        _disarm_mps_autocast()
        _fix_mps_elu()
        if self.settings.get("style"):
            self._redirect_mert()
        from audiocraft.models import MAGNeT, MusicGen

        progress_cb(None, f"loading {self.kind} weights")
        cls = MAGNeT if self.kind == "magnet" else MusicGen
        self.model = cls.get_pretrained(self._snapshot(), device=self.device)
        if self.settings.get("style"):
            self._repair_mert_pos_conv()
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
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. `seed_used` reports it back.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        torch.manual_seed(seed)
        # …and Python's own RNG, which is the one that matters for the
        # style model: the style conditioner crops its excerpt with
        # `random.randint` (conditioners.py:837), outside torch entirely.
        # Measured 2026-09-03: with only torch seeded, two same-seed
        # musicgen-style renders in ONE process correlated 0.07 (plain
        # musicgen, which draws nothing from `random`, was already 1.0),
        # so the declared seed could not reproduce a style take at all.
        random.seed(seed)
        np.random.seed(seed % (2 ** 32))

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
            # A windowed (>30 s) MusicGen render reports `done` accumulated
            # across windows against a per-window `total`, which pinned the
            # bar at 100 % from window 2 (audit §5) — rescale against the
            # whole request. MAGNeT counts decoding steps, not frames, so
            # its totals pass through untouched.
            expected = (int(duration_s
                            * float(getattr(self.model, "frame_rate", 50.0)))
                        if self.kind == "musicgen" else 0)
            # Deliberately NOT adjusted for a continuation's prompt: the
            # callback's own `total` already counts the new tokens alone.
            # Checked 2026-09-04 on an 8 s continuation off a 10 s excerpt —
            # the last event is `403/400 tokens` at fraction 1.0, not 900.
            total_all = max(1, total, expected)
            progress_cb(min(1.0, done / total_all),
                        f"{done}/{total_all} tokens",
                        phase="lm_decode", step=done, steps=total_all)

        # Set inside the continuation branch below, where the prompt's own
        # length is known; nonzero means the take opens with the excerpt and
        # has to be trimmed back to what was actually asked for.
        continued_s = 0.0

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
            continue_path = params.get("continue_audio")
            if params.get("melody_audio") and params.get("style_audio"):
                # Both ride the same `self_wav` slot, so only one can be used.
                print("ignoring style_audio: melody_audio was supplied and "
                      "both use the same conditioning slot",
                      file=sys.stderr, flush=True)
            if ref_path and continue_path and (self.settings.get("melody")
                                               or is_style):
                # It used to disappear without a word: the take came back
                # looking like an ordinary style/melody render (audit 09-B10).
                # stderr is mirrored into the render card's log.
                print("ignoring continue_audio: this take conditions on the "
                      "reference audio instead — render a continuation "
                      "without a melody or style reference to use it",
                      file=sys.stderr, flush=True)
            if ref_path and not (self.settings.get("melody") or is_style):
                # A reference in a slot this checkpoint cannot use, which is
                # the same silent drop seen from the other side.
                print(f"ignoring the reference audio: this checkpoint has no "
                      f"conditioner for it (melody="
                      f"{bool(self.settings.get('melody'))}, style="
                      f"{bool(self.settings.get('style'))})",
                      file=sys.stderr, flush=True)
            if ref_path and (self.settings.get("melody") or is_style):
                wav, sr = sf.read(str(ref_path), dtype="float32",
                                  always_2d=True)
                melody = torch.from_numpy(wav.T)  # (C, T)
                if is_style:
                    melody = _pad_to_excerpt(melody, sr, excerpt_s or 3.0)
                audio = self.model.generate_with_chroma(
                    [prompt], melody[None], sr, progress=True)
            elif continue_path and os.path.isfile(str(continue_path)):
                # The trained continuation path, and the only one in this
                # catalog: the excerpt is encoded to EnCodec tokens and becomes
                # the decoder's actual prefix, so the model carries on from
                # inside the music rather than being told about it.
                #
                # The excerpt is the source's TAIL — a continuation continues
                # an ending — and short, because prompt and continuation share
                # one 30 s attention window: every second handed over is a
                # second that cannot be written.
                clip, clip_rate = _tail_clip(str(continue_path),
                                             CONTINUE_PROMPT_S)
                continued_s = clip.shape[-1] / clip_rate
                progress_cb(None,
                            f"listening to the last {continued_s:.0f}s",
                            phase="prompt_encode")
                # `duration` counts prompt + continuation here (unlike the
                # transformers path, where it counts new tokens only), so ask
                # for the sum and cut the prompt back off below.
                #
                # No 30 s cap: it used to clamp the sum, so anything over
                # ~20 s of new music came back short without a word (a 30 s
                # request returned 20 s, and so did a 600 s one). `duration`
                # past `max_duration` is the vendored library's own windowed
                # path — it keeps the prompt tokens and strides — and
                # `extend_stride` is what that path asserts it needs, so it is
                # passed explicitly rather than left to the default.
                self.model.set_generation_params(
                    duration=duration_s + continued_s,
                    extend_stride=18.0,
                    use_sampling=True,
                    top_k=int(params.get("top_k", 250)),
                    temperature=float(params.get("temperature", 1.0)),
                    cfg_coef=float(params.get("guidance_scale", 3.0)))
                audio = self.model.generate_continuation(
                    clip[None], clip_rate, [prompt], progress=True)
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
        if continued_s:
            # `generate_continuation` returns prompt-then-continuation. The
            # length asked for was a length of NEW music, so the excerpt comes
            # back off — otherwise every continuation would open by replaying
            # audio the user already has.
            wav = wav[int(continued_s * sample_rate):]
        wav = np.clip(wav, -1.0, 1.0)
        tmp = out_path + ".part"
        sf.write(tmp, wav, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=len(wav) / sample_rate,
                              sample_rate=sample_rate,
                              seed_used=seed)

    def unload(self) -> None:
        self.model = None
        release_accelerator_memory()

# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

# Copyright © 2024 Apple Inc.
#
# Vendored from ml-explore/mlx-examples (musicgen example) at
# 796f5b53cab69a3d48a44233ce21aae889e94a08, MIT license (see LICENSE).
# LocalMusicGen changes: loads the transformers-format facebook/musicgen-*
# snapshot the engine already has on disk (T5 + EnCodec + decoder are all
# remapped from the one safetensors checkpoint — no hub downloads),
# generate() takes a per-step callback for progress/cancel, and it can decode
# the tokens generated so far into a partial waveform for streaming previews.

import json
from functools import partial
from pathlib import Path
from types import SimpleNamespace
from typing import Callable, Optional

import mlx.core as mx
import mlx.nn as nn

from .encodec import EncodecModel
from .t5 import T5, Tokenizer


class TextConditioner(nn.Module):
    def __init__(self, t5, tokenizer, input_dim, output_dim):
        super().__init__()
        self._t5 = t5
        self.tokenizer = tokenizer
        self.output_proj = nn.Linear(input_dim, output_dim)

    def __call__(self, text):
        x = self.tokenizer.encode(text)
        x = self._t5.encode(x)
        return self.output_proj(x)


class KVCache:
    def __init__(self, head_dim, n_kv_heads):
        self.n_kv_heads = n_kv_heads
        if isinstance(head_dim, int):
            self.k_head_dim = self.v_head_dim = head_dim
        elif isinstance(head_dim, tuple) and len(head_dim) == 2:
            self.k_head_dim, self.v_head_dim = head_dim
        else:
            raise ValueError("head_dim must be an int or a tuple of two ints")
        self.keys = None
        self.values = None
        self.offset = 0
        self.step = 256

    def update_and_fetch(self, keys, values):
        prev = self.offset
        if self.keys is None or (prev + keys.shape[2]) > self.keys.shape[2]:
            B = keys.shape[0]
            n_steps = (self.step + keys.shape[2] - 1) // self.step
            k_shape = (B, self.n_kv_heads, n_steps * self.step, self.k_head_dim)
            v_shape = (B, self.n_kv_heads, n_steps * self.step, self.v_head_dim)
            new_k = mx.zeros(k_shape, keys.dtype)
            new_v = mx.zeros(v_shape, values.dtype)
            if self.keys is not None:
                if prev % self.step != 0:
                    self.keys = self.keys[..., :prev, :]
                    self.values = self.values[..., :prev, :]
                self.keys = mx.concatenate([self.keys, new_k], axis=2)
                self.values = mx.concatenate([self.values, new_v], axis=2)
            else:
                self.keys, self.values = new_k, new_v

        self.offset += keys.shape[2]
        self.keys[..., prev : self.offset, :] = keys
        self.values[..., prev : self.offset, :] = values
        return self.keys[..., : self.offset, :], self.values[..., : self.offset, :]

    @property
    def state(self):
        return self.keys, self.values


class MultiHeadAttention(nn.Module):
    def __init__(self, dim, n_heads):
        super().__init__()

        self.n_heads = n_heads

        head_dim = dim // n_heads

        self.scale = head_dim**-0.5

        self.q_proj = nn.Linear(dim, dim, bias=False)
        self.k_proj = nn.Linear(dim, dim, bias=False)
        self.v_proj = nn.Linear(dim, dim, bias=False)
        self.out_proj = nn.Linear(dim, dim, bias=False)

    def __call__(
        self,
        queries: mx.array,
        keys: mx.array,
        values: mx.array,
        mask: Optional[mx.array] = None,
        cache: Optional[KVCache] = None,
    ) -> mx.array:
        B, L_q, D = queries.shape
        L_k = keys.shape[1]

        queries, keys, values = (
            self.q_proj(queries),
            self.k_proj(keys),
            self.v_proj(values),
        )

        # Prepare the queries, keys and values for the attention computation
        queries = queries.reshape(B, L_q, self.n_heads, -1).transpose(0, 2, 1, 3)
        keys = keys.reshape(B, L_k, self.n_heads, -1).transpose(0, 2, 1, 3)
        values = values.reshape(B, L_k, self.n_heads, -1).transpose(0, 2, 1, 3)

        if cache is not None:
            keys, values = cache.update_and_fetch(keys, values)

        output = mx.fast.scaled_dot_product_attention(
            queries, keys, values, scale=self.scale, mask=mask
        )
        output = output.transpose(0, 2, 1, 3).reshape(B, L_q, -1)
        return self.out_proj(output)


class TransformerBlock(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.num_attention_heads = config.decoder.num_attention_heads
        self.hidden_size = config.decoder.hidden_size
        self.self_attn = MultiHeadAttention(self.hidden_size, self.num_attention_heads)
        self.cross_attn = MultiHeadAttention(self.hidden_size, self.num_attention_heads)
        self.linear1 = nn.Linear(self.hidden_size, config.decoder.ffn_dim, bias=False)
        self.linear2 = nn.Linear(config.decoder.ffn_dim, self.hidden_size, bias=False)

        self.norm1 = nn.LayerNorm(self.hidden_size, eps=1e-5)
        self.norm_cross = nn.LayerNorm(self.hidden_size, eps=1e-5)
        self.norm2 = nn.LayerNorm(self.hidden_size, eps=1e-5)

    def __call__(
        self,
        x: mx.array,
        conditioning: mx.array,
        mask: Optional[mx.array] = None,
        cache: Optional[KVCache] = None,
    ) -> mx.array:
        xn = self.norm1(x)
        x += self.self_attn(xn, xn, xn, mask, cache)
        xn = self.norm_cross(x)
        x += self.cross_attn(xn, conditioning, conditioning, mask)
        xn = self.norm2(x)
        x += self.linear2(nn.gelu(self.linear1(xn)))
        return x


@partial(mx.compile, inputs=mx.random.state, outputs=mx.random.state)
def top_k_sampling(
    logits: mx.array, top_k: float, temperature: float, axis: int = -1
) -> mx.array:
    """
    Apply top-k sampling to logits.

    Args:
        logits: The logits from the model's output.
        top_k: Sample from the top k logits.
        temperature: Temperature parameter for softmax distribution reshaping.
        axis: Axis along which to sample.
    Returns:
        token selected based on the top-k criterion.
    """
    # referenced implementation from https://github.com/huggingface/transformers/blob/main/src/transformers/generation/logits_process.py#L449-L460
    probs = mx.softmax(logits * (1 / temperature), axis=axis)

    # sort probs in ascending order
    sorted_indices = mx.argsort(probs, axis=axis)
    sorted_probs = mx.take_along_axis(probs, sorted_indices, axis=axis)
    prob_threshold = mx.take(sorted_probs, mx.array(-top_k), axis=axis)

    # select the top K tokens in probability
    top_probs = mx.where(
        sorted_probs > prob_threshold,
        sorted_probs,
        0,
    )

    sorted_token = mx.random.categorical(mx.log(top_probs), axis=axis)
    token = mx.take_along_axis(
        sorted_indices, mx.expand_dims(sorted_token, axis), axis=axis
    )

    return token


def create_sin_embedding(positions: mx.array, dim: int, max_period: float = 10000):
    assert dim % 2 == 0
    half_dim = dim // 2
    adim = mx.arange(half_dim).reshape(1, 1, -1)
    phase = positions / (max_period ** (adim / (half_dim - 1)))
    return mx.concatenate([mx.cos(phase), mx.sin(phase)], axis=-1)


class MusicGen(nn.Module):
    def __init__(self, config, text_conditioner, audio_decoder):
        self.num_codebooks = config.decoder.num_codebooks
        self.codebook_size = config.audio_encoder.codebook_size
        self.bos_token_id = config.decoder.bos_token_id
        self.hidden_size = config.decoder.hidden_size
        self.num_attention_heads = config.decoder.num_attention_heads
        self.sampling_rate = config.audio_encoder.sampling_rate

        self.text_conditioner = text_conditioner
        self.emb = [
            nn.Embedding(self.codebook_size + 1, self.hidden_size)
            for _ in range(self.num_codebooks)
        ]
        self.layers = [
            TransformerBlock(config) for _ in range(config.decoder.num_hidden_layers)
        ]
        self.out_norm = nn.LayerNorm(self.hidden_size, eps=1e-5)
        self.linears = [
            nn.Linear(self.hidden_size, self.codebook_size, bias=False)
            for _ in range(self.num_codebooks)
        ]
        self._audio_decoder = audio_decoder

    def __call__(
        self,
        audio_tokens: mx.array,
        conditioning: mx.array,
        cache: list[KVCache] = None,
    ):

        if cache is None:
            cache = [None] * len(self.layers)

        x = sum([self.emb[k](audio_tokens[..., k]) for k in range(self.num_codebooks)])

        offset = cache[0].offset if cache[0] is not None else 0
        pos_emb = create_sin_embedding(offset, self.hidden_size)
        x += pos_emb.astype(x.dtype)

        for layer, c in zip(self.layers, cache):
            x = layer(x, conditioning, cache=c)

        x = self.out_norm(x)
        x = mx.stack([self.linears[k](x) for k in range(self.num_codebooks)], axis=-1)
        return x

    def generate(
        self,
        text: str,
        max_steps: int = 200,
        top_k: int = 250,
        temp: float = 1.0,
        guidance_coef: float = 3.0,
        callback: Optional[Callable[[int, int], None]] = None,
        preview: Optional[Callable[[mx.array, int], None]] = None,
        preview_every: int = 0,
    ) -> mx.array:
        """
        Generates a waveform conditioned on `text`.

        Args:
            text (str): The text to condition generation on.
            max_steps (int): Max steps to generate.
            top_k (int): Top k used in sampling.
            temp (float): Sampling softmax temperature.
            guidance_coef (float): Classifier free guidance coefficent.
                Used to combine conditional and unconditional logits.
            preview: Called with (partial waveform, step) every
                `preview_every` steps. Each call is a full EnCodec decode of
                everything generated so far, so it is off unless asked for.
            preview_every: Steps between preview decodes; 0 disables.

        Returns:
            An mx.array of audio samples of shape ``(num_samples,)``.
        """
        # Assuming no audio prompt we start with all bos token for the codebooks
        audio_shape = (1, max_steps + 1, self.num_codebooks)
        audio_seq = mx.full(audio_shape, self.bos_token_id)

        text_tokens = self.text_conditioner(text)
        # Compute conditional and unconditional logits in one batch
        text_tokens = mx.concatenate([text_tokens, mx.zeros_like(text_tokens)], axis=0)

        head_dim = self.hidden_size // self.num_attention_heads
        cache = [
            KVCache(head_dim, self.num_attention_heads) for _ in range(len(self.layers))
        ]
        for offset in range(max_steps):
            if callback is not None:
                callback(offset, max_steps)
            audio_input = mx.tile(audio_seq[:, offset : offset + 1], [2, 1, 1])
            audio_logits = self(audio_input, text_tokens, cache)
            cond_logits, uncond_logits = audio_logits[:1], audio_logits[1:2]
            audio_logits = uncond_logits + (cond_logits - uncond_logits) * guidance_coef
            audio_tokens = top_k_sampling(audio_logits, top_k, temp, axis=-2)
            # "delay" pattern
            audio_tokens[..., offset + 1 :] = self.bos_token_id
            audio_tokens[..., : -max_steps + offset] = self.bos_token_id
            audio_seq[:, offset + 1 : offset + 2] = audio_tokens
            mx.eval(audio_seq)
            if preview is not None and preview_every \
                    and (offset + 1) % preview_every == 0:
                partial = self._decode_partial(audio_seq, offset)
                if partial is not None:
                    preview(partial, offset + 1)

        # Undo delay
        for i in range(self.num_codebooks):
            audio_seq[:, : -self.num_codebooks, i] = audio_seq[
                :, i : -self.num_codebooks + i, i
            ]
        audio_seq = audio_seq[:, 1 : -self.num_codebooks + 1]

        audio_seq = mx.swapaxes(audio_seq, -1, -2)[:, mx.newaxis]
        audio = self._audio_decoder.decode(audio_seq, audio_scales=[None])
        return audio[0]

    def _decode_partial(self, audio_seq: mx.array, offset: int):
        """Decode the tokens generated so far into audio, for previews.

        The delay is undone by *reading* rather than by the in-place shift the
        end of generate() does: the loop is still writing into `audio_seq`, and
        rewriting it here would corrupt the take.

        Codebook k's stream starts one position later than k-1's, so the newest
        frame every codebook has a real token for is
        ``offset + 1 - (num_codebooks - 1)``. Reading past that would decode the
        bos filler the delay mask writes ahead of each codebook, which is not
        audio — it is the reason the frame count is short of the step count.
        """
        frames = offset + 2 - self.num_codebooks
        if frames <= 0:
            return None
        codes = mx.stack(
            [audio_seq[0, i + 1 : i + 1 + frames, i]
             for i in range(self.num_codebooks)], axis=0)
        codes = codes[mx.newaxis, mx.newaxis]      # (1, 1, codebooks, frames)
        return self._audio_decoder.decode(codes, audio_scales=[None])[0]

    @classmethod
    def sanitize(cls, weights):
        out_weights = {}
        for k, arr in weights.items():
            if k.startswith("transformer."):
                k = k[len("transformer.") :]

            if "cross_attention" in k:
                k = k.replace("cross_attention", "cross_attn")

            if "condition_provider" in k:
                k = k.replace(
                    "condition_provider.conditioners.description", "text_conditioner"
                )

            if "in_proj_weight" in k:
                dim = arr.shape[0] // 3
                name = "in_proj_weight"
                out_weights[k.replace(name, "q_proj.weight")] = arr[:dim]
                out_weights[k.replace(name, "k_proj.weight")] = arr[dim : dim * 2]
                out_weights[k.replace(name, "v_proj.weight")] = arr[dim * 2 :]
                continue

            out_weights[k] = arr
        return out_weights

    @classmethod
    def from_snapshot(cls, snapshot_path: str) -> "MusicGen":
        """Build from a transformers-format facebook/musicgen-* snapshot.

        The one checkpoint holds all three components (T5 text encoder, EnCodec
        decoder, MusicGen decoder); each is split out by prefix and remapped to
        this module tree. Everything stays on disk-local files — no hub access.
        """
        path = Path(snapshot_path)
        with open(path / "config.json", "r") as f:
            raw = json.load(f)
        if raw.get("model_type") != "musicgen":
            raise ValueError(
                f"the MLX backend supports plain MusicGen checkpoints only "
                f"(got model_type={raw.get('model_type')!r})")
        config = SimpleNamespace(**raw)
        config.text_encoder = SimpleNamespace(**raw["text_encoder"])
        config.audio_encoder = SimpleNamespace(**raw["audio_encoder"])
        config.decoder = SimpleNamespace(**raw["decoder"])
        if getattr(config.decoder, "audio_channels", 1) != 1:
            raise ValueError("the MLX backend supports mono MusicGen models only")

        # Not every facebook/musicgen-* repo has safetensors (medium/large ship
        # torch pickles only), so fall back to pytorch_model*.bin.
        weights = {}
        shards = sorted(path.glob("*.safetensors"))
        if shards:
            for shard in shards:
                weights.update(mx.load(str(shard)))
        else:
            import torch

            for shard in sorted(path.glob("pytorch_model*.bin")):
                state = torch.load(str(shard), map_location="cpu",
                                   weights_only=True)
                weights.update({k: mx.array(v.numpy())
                                for k, v in state.items()})
        if not weights:
            raise ValueError(f"no model weights found in {path}")

        t5 = T5(config.text_encoder, encoder_only=True)
        t5_weights = T5.sanitize(
            {k[len("text_encoder."):]: v for k, v in weights.items()
             if k.startswith("text_encoder.")
             # torch pickles keep the tied duplicate of shared./wte.
             and k != "text_encoder.encoder.embed_tokens.weight"})
        t5.load_weights(list(t5_weights.items()))
        tokenizer = Tokenizer(config.text_encoder, str(path))
        conditioner = TextConditioner(t5, tokenizer,
                                      config.text_encoder.d_model,
                                      config.decoder.hidden_size)

        audio_decoder = EncodecModel(config.audio_encoder)
        enc_weights = _convert_encodec_weights(
            {k[len("audio_encoder."):]: v for k, v in weights.items()
             if k.startswith("audio_encoder.")}, audio_decoder)
        audio_decoder.load_weights(list(enc_weights.items()))

        model = cls(config, conditioner, audio_decoder)
        decoder_weights = {}
        for k, v in weights.items():
            if k.startswith(("decoder.", "enc_to_dec_proj.")):
                if "embed_positions" in k:
                    continue  # sinusoidal, computed at runtime
                decoder_weights[_remap_decoder_key(k)] = v
        model.load_weights(list(decoder_weights.items()))
        mx.eval(model)
        return model


_DECODER_KEY_MAP = [
    ("decoder.model.decoder.embed_tokens.", "emb."),
    ("decoder.model.decoder.layers.", "layers."),
    ("decoder.model.decoder.layer_norm.", "out_norm."),
    ("decoder.lm_heads.", "linears."),
    ("enc_to_dec_proj.", "text_conditioner.output_proj."),
    (".self_attn_layer_norm.", ".norm1."),
    (".encoder_attn_layer_norm.", ".norm_cross."),
    (".final_layer_norm.", ".norm2."),
    (".encoder_attn.", ".cross_attn."),
    (".fc1.", ".linear1."),
    (".fc2.", ".linear2."),
]


def _remap_decoder_key(key: str) -> str:
    """transformers MusicgenForConditionalGeneration → this module tree."""
    for old, new in _DECODER_KEY_MAP:
        key = key.replace(old, new)
    return key


def _convert_encodec_weights(weights: dict, model: EncodecModel) -> dict:
    """transformers EncodecModel → MLX EncodecModel weights.

    Adapted from mlx-examples/encodec/convert.py: folds weight-norm
    (weight_g/weight_v) into plain weights, renames LSTM parameters to the
    custom kernel's Wx/Wh/bias layout, and moves conv weights to
    channels-last (transposed convs differ from plain ones).
    """
    new_weights = {}
    for k, v in weights.items():
        basename, pname = k.rsplit(".", 1)
        if pname == "weight_v":
            g = weights[basename + ".weight_g"]
            v = g * (v / mx.linalg.norm(v, axis=(1, 2), keepdims=True))
            k = basename + ".weight"
        elif pname in ["weight_g", "embed_avg", "cluster_size", "inited"]:
            continue
        elif "lstm" in basename:
            w_or_b, ih_or_hh, ln = pname.split("_")
            if w_or_b == "weight":
                new_pname = "Wx" if ih_or_hh == "ih" else "Wh"
            elif w_or_b == "bias" and ih_or_hh == "ih":
                continue
            else:
                v = v + weights[k.replace("_hh_", "_ih_")]
                new_pname = "bias"
            k = basename + "." + ln[1:] + "." + new_pname
        if "conv.weight" in k:
            # Possibly a transposed conv which has a different order
            if "decoder" in k:
                layer_index = int(k.split(".")[2])
                layer = model.decoder.layers[layer_index]
                if "conv" in layer and isinstance(layer.conv, nn.ConvTranspose1d):
                    v = mx.moveaxis(v, 0, 2)
                else:
                    v = mx.moveaxis(v, 1, 2)
            else:
                v = mx.moveaxis(v, 1, 2)
        new_weights[k] = v
    return new_weights

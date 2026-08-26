"""BTC chord recognition (Park & Choi, ISMIR 2019) — vendored.

The upstream repo (github.com/jayg996/BTC-ISMIR19, MIT) is frozen research
code: pip-uninstallable, PyYAML-5-era, and using `np.float` (removed in
NumPy 1.24). The model itself is ~200 lines of clean torch, so the inference
path lives here, modernised, instead of behind era pins in a venv of its own —
exactly the treatment the frozen repo can never conflict with.

Vendored from: btc_model.py + utils/transformer_modules.py (model),
utils/mir_eval_modules.py (chord vocabularies + CQT frontend), run_config.yaml
(hyperparameters, inlined as CONFIG). Checkpoints are the ones committed in
the repo's test/ directory, fetched from GitHub raw at first use (12 MB each).
"""

from __future__ import annotations

import math
import os
import urllib.request

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# run_config.yaml, inlined (training keys dropped).
FEATURE = {"song_hz": 22050, "inst_len": 10.0, "n_bins": 144,
           "bins_per_octave": 24, "hop_length": 2048}
MODEL = {"feature_size": 144, "timestep": 108, "num_chords": 25,
         "input_dropout": 0.2, "layer_dropout": 0.2, "attention_dropout": 0.2,
         "relu_dropout": 0.2, "num_layers": 8, "num_heads": 4,
         "hidden_size": 128, "total_key_depth": 128, "total_value_depth": 128,
         "filter_size": 128, "probs_out": False}

CHECKPOINTS = {
    False: ("btc_model.pt",
            "https://github.com/jayg996/BTC-ISMIR19/raw/master/test/"
            "btc_model.pt"),
    True: ("btc_model_large_voca.pt",
           "https://github.com/jayg996/BTC-ISMIR19/raw/master/test/"
           "btc_model_large_voca.pt"),
}

IDX2CHORD = ['C', 'C:min', 'C#', 'C#:min', 'D', 'D:min', 'D#', 'D#:min',
             'E', 'E:min', 'F', 'F:min', 'F#', 'F#:min', 'G', 'G:min',
             'G#', 'G#:min', 'A', 'A:min', 'A#', 'A#:min', 'B', 'B:min', 'N']

_ROOTS = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
_QUALITIES = ['min', 'maj', 'dim', 'aug', 'min6', 'maj6', 'min7', 'minmaj7',
              'maj7', '7', 'dim7', 'hdim7', 'sus2', 'sus4']


def idx2voca_chord() -> dict[int, str]:
    mapping = {169: 'N', 168: 'X'}
    for i in range(168):
        root = _ROOTS[i // 14]
        quality = _QUALITIES[i % 14]
        mapping[i] = root if i % 14 == 1 else f"{root}:{quality}"
    return mapping


# MARK: model (btc_model.py + transformer_modules.py, condensed)

def _gen_bias_mask(max_length: int) -> torch.Tensor:
    np_mask = np.triu(np.full([max_length, max_length], -np.inf), 1)
    return torch.from_numpy(np_mask).float().unsqueeze(0).unsqueeze(1)


def _gen_timing_signal(length: int, channels: int,
                       min_timescale: float = 1.0,
                       max_timescale: float = 1.0e4) -> torch.Tensor:
    position = np.arange(length)
    num_timescales = channels // 2
    log_timescale_increment = (math.log(max_timescale / min_timescale)
                               / (num_timescales - 1))
    # upstream: np.arange(...).astype(np.float) — the one modernised line
    inv_timescales = min_timescale * np.exp(
        np.arange(num_timescales).astype(np.float64)
        * -log_timescale_increment)
    scaled_time = np.expand_dims(position, 1) * np.expand_dims(inv_timescales, 0)
    signal = np.concatenate([np.sin(scaled_time), np.cos(scaled_time)], axis=1)
    signal = np.pad(signal, [[0, 0], [0, channels % 2]], 'constant')
    return torch.from_numpy(signal.reshape([1, length, channels])).float()


class _LayerNorm(nn.Module):
    def __init__(self, features: int, eps: float = 1e-6) -> None:
        super().__init__()
        self.gamma = nn.Parameter(torch.ones(features))
        self.beta = nn.Parameter(torch.zeros(features))
        self.eps = eps

    def forward(self, x):
        mean = x.mean(-1, keepdim=True)
        std = x.std(-1, keepdim=True)
        return self.gamma * (x - mean) / (std + self.eps) + self.beta


class _MultiHeadAttention(nn.Module):
    def __init__(self, input_depth, total_key_depth, total_value_depth,
                 output_depth, num_heads, bias_mask=None, dropout=0.0,
                 attention_map=False) -> None:
        super().__init__()
        self.attention_map = attention_map
        self.num_heads = num_heads
        self.query_scale = (total_key_depth // num_heads) ** -0.5
        self.bias_mask = bias_mask
        self.query_linear = nn.Linear(input_depth, total_key_depth, bias=False)
        self.key_linear = nn.Linear(input_depth, total_key_depth, bias=False)
        self.value_linear = nn.Linear(input_depth, total_value_depth, bias=False)
        self.output_linear = nn.Linear(total_value_depth, output_depth, bias=False)
        self.dropout = nn.Dropout(dropout)

    def _split_heads(self, x):
        b, t, d = x.shape
        return x.view(b, t, self.num_heads, d // self.num_heads).permute(0, 2, 1, 3)

    def _merge_heads(self, x):
        b, h, t, d = x.shape
        return x.permute(0, 2, 1, 3).contiguous().view(b, t, d * h)

    def forward(self, queries, keys, values):
        queries = self._split_heads(self.query_linear(queries))
        keys = self._split_heads(self.key_linear(keys))
        values = self._split_heads(self.value_linear(values))
        queries = queries * self.query_scale
        logits = torch.matmul(queries, keys.permute(0, 1, 3, 2))
        if self.bias_mask is not None:
            logits = logits + self.bias_mask[
                :, :, :logits.shape[-2], :logits.shape[-1]].type_as(logits.data)
        weights = F.softmax(logits, dim=-1)
        weights = self.dropout(weights)
        contexts = self._merge_heads(torch.matmul(weights, values))
        outputs = self.output_linear(contexts)
        return (outputs, weights) if self.attention_map else outputs


class _Conv(nn.Module):
    def __init__(self, input_size, output_size, kernel_size, pad_type) -> None:
        super().__init__()
        padding = ((kernel_size - 1, 0) if pad_type == 'left'
                   else (kernel_size // 2, (kernel_size - 1) // 2))
        self.pad = nn.ConstantPad1d(padding, 0)
        self.conv = nn.Conv1d(input_size, output_size, kernel_size=kernel_size,
                              padding=0)

    def forward(self, inputs):
        return self.conv(self.pad(inputs.permute(0, 2, 1))).permute(0, 2, 1)


class _PositionwiseFeedForward(nn.Module):
    def __init__(self, input_depth, filter_size, output_depth,
                 layer_config='ll', padding='left', dropout=0.0) -> None:
        super().__init__()
        sizes = ([(input_depth, filter_size)]
                 + [(filter_size, filter_size)] * (len(layer_config) - 2)
                 + [(filter_size, output_depth)])
        layers = []
        for lc, s in zip(list(layer_config), sizes):
            layers.append(nn.Linear(*s) if lc == 'l'
                          else _Conv(*s, kernel_size=3, pad_type=padding))
        self.layers = nn.ModuleList(layers)
        self.relu = nn.ReLU()
        self.dropout = nn.Dropout(dropout)

    def forward(self, inputs):
        x = inputs
        for layer in self.layers:
            x = self.dropout(self.relu(layer(x)))
        return x


class _SelfAttentionBlock(nn.Module):
    def __init__(self, hidden_size, total_key_depth, total_value_depth,
                 filter_size, num_heads, bias_mask=None, layer_dropout=0.0,
                 attention_dropout=0.0, relu_dropout=0.0,
                 attention_map=False) -> None:
        super().__init__()
        self.attention_map = attention_map
        self.multi_head_attention = _MultiHeadAttention(
            hidden_size, total_key_depth, total_value_depth, hidden_size,
            num_heads, bias_mask, attention_dropout, attention_map)
        self.positionwise_convolution = _PositionwiseFeedForward(
            hidden_size, filter_size, hidden_size, layer_config='cc',
            padding='both', dropout=relu_dropout)
        self.dropout = nn.Dropout(layer_dropout)
        self.layer_norm_mha = _LayerNorm(hidden_size)
        self.layer_norm_ffn = _LayerNorm(hidden_size)

    def forward(self, inputs):
        x = inputs
        x_norm = self.layer_norm_mha(x)
        y, weights = self.multi_head_attention(x_norm, x_norm, x_norm)
        x = self.dropout(x + y)
        x_norm = self.layer_norm_ffn(x)
        y = self.positionwise_convolution(x_norm)
        y = self.dropout(x + y)
        return y, weights


class _BiDirectionalSelfAttention(nn.Module):
    def __init__(self, hidden_size, total_key_depth, total_value_depth,
                 filter_size, num_heads, max_length, layer_dropout=0.0,
                 attention_dropout=0.0, relu_dropout=0.0) -> None:
        super().__init__()
        common = (hidden_size, total_key_depth or hidden_size,
                  total_value_depth or hidden_size, filter_size, num_heads)
        tail = (layer_dropout, attention_dropout, relu_dropout, True)
        self.attn_block = _SelfAttentionBlock(
            *common, _gen_bias_mask(max_length), *tail)
        self.backward_attn_block = _SelfAttentionBlock(
            *common, torch.transpose(_gen_bias_mask(max_length), 2, 3), *tail)
        self.linear = nn.Linear(hidden_size * 2, hidden_size)

    def forward(self, inputs):
        x, weights_list = inputs
        encoder_outputs, weights = self.attn_block(x)
        reverse_outputs, reverse_weights = self.backward_attn_block(x)
        y = self.linear(torch.cat((encoder_outputs, reverse_outputs), dim=2))
        weights_list = weights_list + [weights, reverse_weights]
        return y, weights_list


class _BiDirectionalSelfAttentionLayers(nn.Module):
    def __init__(self, embedding_size, hidden_size, num_layers, num_heads,
                 total_key_depth, total_value_depth, filter_size,
                 max_length=100, input_dropout=0.0, layer_dropout=0.0,
                 attention_dropout=0.0, relu_dropout=0.0) -> None:
        super().__init__()
        self.timing_signal = _gen_timing_signal(max_length, hidden_size)
        params = (hidden_size, total_key_depth or hidden_size,
                  total_value_depth or hidden_size, filter_size, num_heads,
                  max_length, layer_dropout, attention_dropout, relu_dropout)
        self.embedding_proj = nn.Linear(embedding_size, hidden_size, bias=False)
        self.self_attn_layers = nn.Sequential(
            *[_BiDirectionalSelfAttention(*params) for _ in range(num_layers)])
        self.layer_norm = _LayerNorm(hidden_size)
        self.input_dropout = nn.Dropout(input_dropout)

    def forward(self, inputs):
        x = self.input_dropout(inputs)
        x = self.embedding_proj(x)
        x = x + self.timing_signal[:, :inputs.shape[1], :].type_as(inputs.data)
        y, weights_list = self.self_attn_layers((x, []))
        return self.layer_norm(y), weights_list


class BTCModel(nn.Module):
    """State-dict compatible with the published checkpoints: the module tree
    (self_attn_layers / output_layer) keeps upstream's names."""

    def __init__(self, config: dict) -> None:
        super().__init__()
        self.timestep = config['timestep']
        self.self_attn_layers = _BiDirectionalSelfAttentionLayers(
            config['feature_size'], config['hidden_size'],
            config['num_layers'], config['num_heads'],
            config['total_key_depth'], config['total_value_depth'],
            config['filter_size'], config['timestep'],
            config['input_dropout'], config['layer_dropout'],
            config['attention_dropout'], config['relu_dropout'])
        self.output_layer = _SoftmaxOutputLayer(
            hidden_size=config['hidden_size'],
            output_size=config['num_chords'])


class _SoftmaxOutputLayer(nn.Module):
    def __init__(self, hidden_size: int, output_size: int) -> None:
        super().__init__()
        self.output_size = output_size
        self.output_projection = nn.Linear(hidden_size, output_size)
        # Unused at inference but present in the checkpoints; load_state_dict
        # with strict=True keeps validating every other weight.
        self.lstm = nn.LSTM(input_size=hidden_size,
                            hidden_size=int(hidden_size / 2),
                            batch_first=True, bidirectional=True)

    def forward(self, hidden):
        probs = F.softmax(self.output_projection(hidden), -1)
        _topk, indices = torch.topk(probs, 2)
        return indices[:, :, 0], indices[:, :, 1]


# MARK: inference

def _checkpoint(cache_dir: str, large_voca: bool, progress_cb) -> str:
    name, url = CHECKPOINTS[large_voca]
    dest = os.path.join(cache_dir, name)
    if not os.path.exists(dest):
        progress_cb(None, f"fetching {name} (12 MB, GitHub)")
        part = dest + ".part"
        with urllib.request.urlopen(url, timeout=120) as resp, \
                open(part, "wb") as f:
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
        os.replace(part, dest)
    return dest


def load(cache_dir: str, large_voca: bool, progress_cb):
    """-> (model, mean, std, idx_to_chord)"""
    import copy

    config = copy.deepcopy(MODEL)
    if large_voca:
        config['num_chords'] = 170
    path = _checkpoint(cache_dir, large_voca, progress_cb)
    checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    model = BTCModel(config)
    model.load_state_dict(checkpoint['model'])
    model.eval()
    idx_to_chord = idx2voca_chord() if large_voca else IDX2CHORD
    return model, checkpoint['mean'], checkpoint['std'], idx_to_chord


def recognize(bundle, mono: np.ndarray, sr: int, progress_cb,
              check) -> list[dict]:
    """Chord segments [{start_s, end_s, chord}] for a mono float array."""
    import librosa
    import soxr

    model, mean, std, idx_to_chord = bundle
    hz = FEATURE["song_hz"]
    if sr != hz:
        mono = soxr.resample(mono, sr, hz)
    check()

    # Upstream computes the CQT in 10 s windows and concatenates; kept, since
    # the checkpoints' normalisation stats were computed over exactly this.
    inst_samples = int(hz * FEATURE["inst_len"])
    pieces = []
    for start in range(0, max(1, len(mono)), inst_samples):
        pieces.append(librosa.cqt(
            mono[start:start + inst_samples], sr=hz,
            n_bins=FEATURE["n_bins"],
            bins_per_octave=FEATURE["bins_per_octave"],
            hop_length=FEATURE["hop_length"]))
        check()
    feature = np.log(np.abs(np.concatenate(pieces, axis=1)) + 1e-6).T
    feature = (feature - mean) / std

    timestep = MODEL["timestep"]
    time_unit = FEATURE["inst_len"] / timestep
    num_pad = timestep - (feature.shape[0] % timestep)
    feature = np.pad(feature, ((0, num_pad), (0, 0)), mode="constant")
    num_instance = feature.shape[0] // timestep

    frames: list[int] = []
    with torch.no_grad():
        x = torch.tensor(feature, dtype=torch.float32).unsqueeze(0)
        for t in range(num_instance):
            window = x[:, timestep * t: timestep * (t + 1), :]
            hidden, _weights = model.self_attn_layers(window)
            prediction, _second = model.output_layer(hidden)
            frames.extend(int(v) for v in prediction.squeeze(0))
            progress_cb(0.2 + 0.7 * (t + 1) / num_instance,
                        "reading chords")
            check()
    frames = frames[: len(frames) - num_pad]

    segments: list[dict] = []
    start = 0.0
    prev = frames[0] if frames else None
    for i, chord in enumerate(frames[1:], start=1):
        if chord != prev:
            segments.append({"start_s": round(start, 3),
                             "end_s": round(i * time_unit, 3),
                             "chord": idx_to_chord[prev]})
            start = i * time_unit
            prev = chord
    if prev is not None:
        segments.append({"start_s": round(start, 3),
                         "end_s": round(len(frames) * time_unit, 3),
                         "chord": idx_to_chord[prev]})
    return segments

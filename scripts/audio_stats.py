#!/usr/bin/env python3
"""Audio sanity stats for smoke-test outputs: is this music-like or noise/silence?

Usage: python3 audio_stats.py file.wav [file2.wav ...]
Prints one line per file plus a verdict. Pure numpy + stdlib wave.
Handles PCM16/24/32 and float32 WAVs (24-bit via manual unpack).
"""
import sys, wave, math
import numpy as np


def load_riff(path):
    """Minimal RIFF parser for float32/PCM WAVs the stdlib refuses."""
    import struct
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
    pos, fmt, raw = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos+4], struct.unpack('<I', data[pos+4:pos+8])[0]
        body = data[pos+8:pos+8+size]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', body[:16])
        elif cid == b'data':
            raw = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, _, _, bits = fmt
    if tag == 3 and bits == 32:
        x = np.frombuffer(raw, dtype='<f4').astype(np.float64)
    elif tag in (1, 0xFFFE) and bits == 32:
        x = np.frombuffer(raw, dtype='<i4').astype(np.float64) / 2147483648.0
    elif tag in (1, 0xFFFE) and bits == 16:
        x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0
    else:
        raise ValueError(f"fmt tag={tag} bits={bits}")
    return x.reshape(-1, ch).T, sr


def load(path):
    try:
        with wave.open(path) as w:
            sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
            raw = w.readframes(n)
    except wave.Error:
        return load_riff(path)
    if sw == 2:
        x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0
    elif sw == 4:
        # could be int32 or float32; heuristic: float32 wav has format 3 but
        # stdlib wave rejects those, so int32 it is
        x = np.frombuffer(raw, dtype='<i4').astype(np.float64) / 2147483648.0
    elif sw == 3:
        a = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        x = ((a[:, 0].astype(np.int32)) | (a[:, 1].astype(np.int32) << 8)
             | (a[:, 2].astype(np.int32) << 16))
        x = np.where(x >= 1 << 23, x - (1 << 24), x).astype(np.float64) / (1 << 23)
    else:
        raise ValueError(f"sampwidth {sw}")
    return x.reshape(-1, ch).T, sr


def flatness(mono, sr):
    """Mean spectral flatness over 4096-sample Hann frames (up to ~8 kHz band)."""
    fl, N = [], 4096
    win = np.hanning(N)
    hop = N * 2
    hi = int(8000 / sr * N) or N // 2
    for i in range(0, len(mono) - N, hop):
        f = np.abs(np.fft.rfft(mono[i:i + N] * win))[8:hi] ** 2 + 1e-12
        fl.append(np.exp(np.mean(np.log(f))) / np.mean(f))
    return float(np.mean(fl)) if fl else float('nan')


def main():
    for path in sys.argv[1:]:
        try:
            x, sr = load(path)
        except Exception as e:
            print(f"{path}: UNREADABLE ({e})")
            continue
        mono = x.mean(axis=0)
        dur = mono.size / sr
        rms = float(np.sqrt(np.mean(mono ** 2) + 1e-20))
        peak = float(np.max(np.abs(x)))
        clip = float(np.mean(np.abs(x) > 0.999))
        dc = float(np.mean(mono))
        sf = flatness(mono, sr)
        # tail silence: fraction of last 25% that is < -60 dBFS in 50 ms blocks
        blk = max(1, int(0.05 * sr))
        tail = mono[int(0.75 * len(mono)):]
        nb = len(tail) // blk
        tail_sil = float(np.mean([np.sqrt(np.mean(tail[i*blk:(i+1)*blk]**2)) < 1e-3
                                  for i in range(nb)])) if nb else 0.0
        verdict = "OK"
        if rms < 1e-4:
            verdict = "SILENT"
        elif not math.isnan(sf) and sf > 0.35:
            verdict = "NOISE-LIKE"
        elif clip > 0.05:
            verdict = "CLIPPED"
        elif tail_sil > 0.9:
            verdict = "TAIL-SILENT"
        print(f"{path}\n  {dur:.2f}s sr={sr} ch={x.shape[0]} "
              f"rms={20*math.log10(rms+1e-20):.1f}dBFS peak={20*math.log10(peak+1e-20):.1f}dBFS "
              f"clip={clip*100:.2f}% dc={dc:+.4f} flatness={sf:.3f} tail_sil={tail_sil*100:.0f}%"
              f"  → {verdict}")


if __name__ == "__main__":
    main()

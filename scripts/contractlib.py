"""Shared helpers for contract verification scripts. Stdlib only."""

from __future__ import annotations

import array
import http.client
import io
import json
import math
import threading
import time
import urllib.error
import urllib.request
import wave

CHECKS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    CHECKS.append((name, ok, detail))
    print(f"  {'✓' if ok else '✗ FAIL'} {name}"
          + (f" — {detail}" if detail and not ok else ""))


def report() -> int:
    failed = [c for c in CHECKS if not c[1]]
    print(f"\n{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed")
    return 1 if failed else 0


class Client:
    def __init__(self, port: int, token: str) -> None:
        self.base = f"http://127.0.0.1:{port}"
        self.token = token

    def req(self, method: str, path: str, body: dict | None = None,
            auth: bool = True, timeout: float = 10) -> tuple[int, dict]:
        r = urllib.request.Request(self.base + path, method=method)
        if auth:
            r.add_header("Authorization", f"Bearer {self.token}")
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, data=data, timeout=timeout) as resp:
                raw = resp.read()
                return resp.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read()
            return e.code, json.loads(raw) if raw else {}

    def req_raw(self, method: str, path: str, data: bytes,
                timeout: float = 10) -> tuple[int, dict]:
        """Raw-body request (uploads); response is still JSON."""
        r = urllib.request.Request(self.base + path, method=method)
        r.add_header("Authorization", f"Bearer {self.token}")
        r.add_header("Content-Type", "application/octet-stream")
        try:
            with urllib.request.urlopen(r, data=data, timeout=timeout) as resp:
                raw = resp.read()
                return resp.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read()
            return e.code, json.loads(raw) if raw else {}


def click_wav(duration_s: float, sample_rate: int,
              at: list[float], burst_frames: int = 4) -> bytes:
    """Mono PCM16 WAV that is EXACTLY digital silence apart from a full-scale
    burst at each time in `at`.

    Exact zeros are the whole point: loudness normalisation and the limiter are
    multiplicative, so silence survives the mix pipeline as silence and the
    onset of each burst can be located by an integer != 0 test — no epsilon, no
    guessing which sample "counts" as the start.
    """
    frames = array.array("h", [0]) * int(duration_s * sample_rate)
    for t in at:
        start = int(round(t * sample_rate))
        for i in range(burst_frames):
            if 0 <= start + i < len(frames):
                frames[start + i] = 32767
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(frames.tobytes())
    return buf.getvalue()


def tone_wav(duration_s: float, sample_rate: int, freq: float = 440.0,
             amplitude: float = 0.5) -> bytes:
    """Mono PCM16 steady sine.

    For envelope assertions, unlike `click_wav`: a continuous tone leaves the
    mix's loudness normalisation with a sane gain (and the limiter idle), so
    amplitude ratios inside the file still mean what they say. Sparse clicks in
    near-silence get normalised up until every one of them hits the limiter.
    """
    frames = array.array("h", [0]) * int(duration_s * sample_rate)
    for i in range(len(frames)):
        frames[i] = int(amplitude * 32767
                        * math.sin(2 * math.pi * freq * i / sample_rate))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(frames.tobytes())
    return buf.getvalue()


def onset_frames(path: str, threshold: int = 1000) -> list[int]:
    """Frame index of each non-silent run in a WAV (channel 0).

    Returns run STARTS, so a stereo mixdown of two clicks yields two indices
    whose difference is the placement gap — and a constant pipeline latency
    cancels out of that difference.
    """
    with wave.open(path, "rb") as w:
        channels, width = w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError(f"expected PCM16, got {width * 8}-bit")
    samples = array.array("h")
    samples.frombytes(raw)
    starts, inside = [], False
    for i in range(0, len(samples), channels):
        loud = abs(samples[i]) >= threshold
        if loud and not inside:
            starts.append(i // channels)
        inside = loud
    return starts


def wav_duration_s(path: str) -> float:
    with wave.open(path, "rb") as w:
        return w.getnframes() / float(w.getframerate())


def peak_between(path: str, start_s: float, end_s: float) -> float:
    """Peak amplitude (0…1) in a window — for envelope shape assertions, which
    survive the mix's loudness normalisation because they are relative."""
    with wave.open(path, "rb") as w:
        channels, width, rate = w.getnchannels(), w.getsampwidth(), \
            w.getframerate()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError(f"expected PCM16, got {width * 8}-bit")
    samples = array.array("h")
    samples.frombytes(raw)
    lo = max(0, int(start_s * rate) * channels)
    hi = min(len(samples), int(end_s * rate) * channels)
    if hi <= lo:
        return 0.0
    return max(abs(s) for s in samples[lo:hi]) / 32768.0


class SSEListener(threading.Thread):
    """Collects (id, event, data) tuples from /v1/events. Also records heartbeats."""

    def __init__(self, port: int, token: str,
                 last_event_id: str | None = None) -> None:
        super().__init__(daemon=True)
        self.port, self.token, self.leid = port, token, last_event_id
        self.events: list[tuple[int, str, dict]] = []
        self.heartbeats = 0
        self.lock = threading.Lock()
        self.conn: http.client.HTTPConnection | None = None

    def run(self) -> None:
        try:
            self.conn = http.client.HTTPConnection("127.0.0.1", self.port,
                                                   timeout=60)
            headers = {"Authorization": f"Bearer {self.token}"}
            if self.leid:
                headers["Last-Event-ID"] = self.leid
            self.conn.request("GET", "/v1/events", headers=headers)
            resp = self.conn.getresponse()
            eid, event = 0, ""
            for raw in resp:
                line = raw.decode().rstrip("\n")
                if line.startswith(":"):
                    with self.lock:
                        self.heartbeats += 1
                elif line.startswith("id: "):
                    eid = int(line[4:])
                elif line.startswith("event: "):
                    event = line[7:]
                elif line.startswith("data: "):
                    with self.lock:
                        self.events.append((eid, event, json.loads(line[6:])))
        except Exception:
            pass  # connection torn down at end of test

    def names(self) -> list[str]:
        with self.lock:
            return [e for _, e, _ in self.events]

    def mark(self) -> int:
        """Position marker: pass as `since` so wait_for ignores older events."""
        with self.lock:
            return len(self.events)

    def wait_for(self, event: str, timeout: float = 30,
                 pred=lambda d: True, since: int = 0) -> dict | None:
        deadline = time.time() + timeout
        seen = since
        while time.time() < deadline:
            with self.lock:
                for _, e, d in self.events[seen:]:
                    if e == event and pred(d):
                        return d
                seen = len(self.events)
            time.sleep(0.1)
        return None

    def stop(self) -> None:
        if self.conn:
            try:
                self.conn.close()
            except Exception:
                pass

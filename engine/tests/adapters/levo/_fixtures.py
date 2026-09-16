"""A decoder child made of a string. No subprocess, no torch, no MLX."""

from __future__ import annotations

import io


class Progress:
    def __init__(self, raise_at: int | None = None) -> None:
        self.calls: list[dict] = []
        self.raise_at = raise_at

    def __call__(self, fraction, message, *, phase=None, step=None,
                 steps=None) -> None:
        self.calls.append({"fraction": fraction, "message": message,
                           "step": step, "steps": steps})
        if self.raise_at is not None and len(self.calls) >= self.raise_at:
            from engine_protocol.adapter import CancelledError
            raise CancelledError()

    @property
    def fractions(self) -> list[float]:
        return [c["fraction"] for c in self.calls if c["fraction"] is not None]

    @property
    def windows(self) -> list[int]:
        return [c["step"] for c in self.calls if c["step"] is not None]


class FakeProc:
    """Just enough of `subprocess.Popen` for the pacing loop.

    `poll()` reports "running" until the process is killed or waited on,
    which is what makes the reap-on-exception branch observable.
    """

    def __init__(self, transcript: str) -> None:
        self.stdout = io.StringIO(transcript)
        self.kills = 0
        self.waits = 0
        self._returncode: int | None = None

    def poll(self) -> int | None:
        return self._returncode

    def kill(self) -> None:
        self.kills += 1
        self._returncode = -9

    def wait(self) -> int:
        self.waits += 1
        if self._returncode is None:
            self._returncode = 0
        return self._returncode


class NeverCancelled:
    cancelled = False


class CancelledNow:
    cancelled = True


def shard_bar(step: int, total: int) -> str:
    """What `Loading checkpoint shards` really renders as."""
    pct = int(100 * step / total)
    return (f"Loading checkpoint shards: {pct:3d}%|"
            f"{'█' * step}{' ' * (total - step)}| {step}/{total} "
            f"[00:00<00:00,  1.50it/s]")


def ode_bar(step: int, total: int = 10) -> str:
    """One redraw of a decode window's 10-step ODE bar."""
    pct = int(100 * step / total)
    return (f"{pct:3d}%|{'█' * step}{' ' * (total - step)}| {step}/{total} "
            f"[00:01<00:02,  3.00it/s]")


def plain_shard_line(step: int, total: int = 2) -> str:
    """The shard loader with its bar suppressed — no `|` and no `[`, so
    neither tqdm pattern matches it and the pacing loop ignores it."""
    return f"Loading checkpoint shards: {step}/{total}"


def transcript(windows: int, *, shards: int = 0, plain_shards: int = 0) -> str:
    """A captured decoder run: optional shard loader, then `windows` bars.

    Each bar redraws in place with a carriage return, which is exactly why
    the adapter reads the stream \\r-aware.
    """
    parts: list[str] = []
    for i in range(1, plain_shards + 1):
        parts.append(plain_shard_line(i, plain_shards) + "\n")
    for i in range(1, shards + 1):
        parts.append(shard_bar(i, shards) + "\r")
    if shards:
        parts.append("\n")
    for _ in range(windows):
        for step in range(0, 11):
            parts.append(ode_bar(step) + "\r")
        parts.append("\n")
    return "".join(parts)

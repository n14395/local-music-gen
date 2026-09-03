"""Subprocess progress interception shared by the CLI-driving adapters.

tqdm redraws its bar with carriage returns on one long line, so a
`readline()` loop sees nothing until the bar finishes — the reason several
families sat silent through their longest phase while real step counts
scrolled by on the stderr they were already reading (audit §5).
`iter_progress_lines` splits on both ``\r`` and ``\n``; `parse_tqdm` and
`parse_percent` pull the numbers out of the common bar formats.
"""

from __future__ import annotations

import re
import typing as tp

_TQDM_BAR = re.compile(r"\|\s*(\d+)/(\d+)")        # "45%|████| 9/20 [...]"
_TQDM_PLAIN = re.compile(r"\b(\d+)/(\d+)\s*\[")    # "9/20 [00:05<00:06]"
_PCT = re.compile(r"\b(\d{1,3})%")


def parse_tqdm(line: str) -> tuple[int, int] | None:
    """(step, total) from a tqdm-style render, else None."""
    m = _TQDM_BAR.search(line) or _TQDM_PLAIN.search(line)
    if m:
        step, total = int(m.group(1)), int(m.group(2))
        if 0 < total and step <= total:
            return step, total
    return None


def parse_percent(line: str) -> float | None:
    """A bare percentage as a fraction, else None."""
    m = _PCT.search(line)
    if m:
        pct = int(m.group(1))
        if 0 <= pct <= 100:
            return pct / 100.0
    return None


def iter_progress_lines(stream: tp.IO[str]) -> tp.Iterator[str]:
    """Non-empty stripped lines from a text stream, split on \\n AND \\r.

    Character-at-a-time on top of the stream's own buffer: tqdm's in-place
    redraws become visible as they happen instead of arriving as one giant
    line when the bar completes. Ends at EOF (process exit closes the pipe).
    """
    buf: list[str] = []
    while True:
        ch = stream.read(1)
        if not ch:
            tail = "".join(buf).strip()
            if tail:
                yield tail
            return
        if ch in "\r\n":
            line = "".join(buf).strip()
            buf.clear()
            if line:
                yield line
        else:
            buf.append(ch)

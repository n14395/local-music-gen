"""What a worker's stderr is allowed to put on the event stream.

Every line a worker prints is written to its log file — that file is the
record, and nothing here touches it. This is only about the `job.log` mirror
(contract §6), which is a different job with a different budget: it feeds a ten
line pane in the app, over an SSE stream, one event per line.

Left unbounded that mirror is not a trickle. Measured from this repo's own
worker logs, one ACE-Step (torch) render printed 17,476 lines — 2,614 of them
tqdm redraws and 7,416 of them the names of tensors in a checkpoint. Every one
of those was an event on the wire.

Two rules, and they are different rules because the two problems are different:

  * A progress-bar redraw is not a line, it is a frame of an animation. tqdm
    writes them with a carriage return so each one *overwrites* the last, and
    the worker reads its pipe in text mode, so every overwrite arrives here
    looking like a new line. Mirroring them means sending a value that is
    already stale, drawn as bar art, into a pane one line tall. They are
    dropped — the file still has them, and the step counts reach the app as
    progress events anyway.

  * Everything else is real output, and the only problem with it is volume. So
    it is rate limited rather than filtered, and when the limit bites the app
    is told how much it did not get. A cap that hides its own existence would
    make a quiet render and a truncated one look the same.
"""

from __future__ import annotations

import re

# `76%|███████▌  | 38/50 [00:06<00:01, 8.74it/s]` — the shape every tqdm bar
# has, whatever it is counting. Anchored on the percentage immediately before
# the bar so that prose which merely mentions a percentage does not match.
_BAR = re.compile(r"\d+%\|")

# Eight lines a second is faster than anyone reads and slow enough that a
# burst cannot swamp the stream. A render that prints less than this — most of
# them — never notices the mirror is here at all.
LINES_PER_SECOND = 8


class LogMirror:
    """Decides which stderr lines become `job.log` events.

    Holds no clock: every call takes `now`, so the whole thing is testable
    without waiting for time to pass.
    """

    def __init__(self, lines_per_second: int = LINES_PER_SECOND) -> None:
        self.lines_per_second = lines_per_second
        self._window_start: float | None = None
        self._sent = 0
        self._suppressed = 0

    def reset(self) -> None:
        """New job, new budget. A render must not inherit the last one's
        suppression count and open with someone else's bad news."""
        self._window_start = None
        self._sent = 0
        self._suppressed = 0

    def offer(self, line: str, now: float) -> list[str]:
        """The lines to mirror for this one line of stderr.

        Usually the line itself, sometimes nothing, and sometimes the line
        preceded by a note about what was dropped while the last window was
        full.
        """
        line = line.strip()
        if not line or _BAR.search(line):
            return []

        if self._window_start is None or now - self._window_start >= 1.0:
            self._window_start = now
            self._sent = 0
            dropped, self._suppressed = self._suppressed, 0
            out = [self._note(dropped)] if dropped else []
            self._sent = 1
            return out + [line]

        if self._sent >= self.lines_per_second:
            self._suppressed += 1
            return []
        self._sent += 1
        return [line]

    def flush(self) -> list[str]:
        """Anything still owed, when there will be no next line to carry it.

        The note above rides on the next line the mirror lets through, which
        is fine while a render is still talking. It is not fine at the end of
        one: a burst that is the *last* thing a worker prints — a stack trace
        on the way out, a stage that dumps and then finishes — would otherwise
        be capped in silence, and the pane would simply stop mid-flood with no
        indication that it had. Called at end of stream and end of job.
        """
        dropped, self._suppressed = self._suppressed, 0
        return [self._note(dropped)] if dropped else []

    @staticmethod
    def _note(dropped: int) -> str:
        return (f"… {dropped} more line{'' if dropped == 1 else 's'} "
                "not shown (see the worker log)")

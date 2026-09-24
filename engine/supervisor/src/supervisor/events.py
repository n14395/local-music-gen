# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import json
import sys
import time
from typing import AsyncIterator

RING_SIZE = 500
HEARTBEAT_S = 15.0

# Per-subscriber backlog, in frames. A client that holds the connection open
# but stops reading — a suspended app, a full TCP window, a debugger paused on
# a frame — used to accumulate every event for the life of the session:
# job.progress up to 10/s, job.log up to 8/s, download.progress 1/s, telemetry
# every 2 s, with nothing ever dropping or disconnecting it. 2000 frames is
# minutes of a busy render, so nothing healthy comes near it.
SUBSCRIBER_QUEUE_MAX = 2000

# Put on a subscriber's queue in place of its backlog when it overflows; the
# stream sends one last frame and ends. See emit().
_OVERFLOW = object()
OVERFLOW_MESSAGE = ("this client fell too far behind the event stream; "
                    "reconnect with Last-Event-ID to replay what it missed")


class EventBus:
    """In-process pub/sub feeding the /v1/events SSE stream.

    emit() is safe from the event loop; emit_threadsafe() from worker/downloader
    threads.
    """

    def __init__(self, loop: asyncio.AbstractEventLoop | None = None) -> None:
        self.loop = loop or asyncio.get_event_loop()
        self.next_id = 1
        self.ring: list[tuple[int, str, dict]] = []
        self.subscribers: set[asyncio.Queue] = set()

    def emit(self, event: str, data: dict) -> None:
        eid = self.next_id
        self.next_id += 1
        self.ring.append((eid, event, data))
        del self.ring[:-RING_SIZE]
        for q in list(self.subscribers):
            try:
                q.put_nowait((eid, event, data))
            except asyncio.QueueFull:
                self._overflow(q)

    def _overflow(self, q: asyncio.Queue) -> None:
        """Cut a subscriber loose once its backlog is full.

        The subscriber goes, not the events: a client resumes with
        `Last-Event-ID` and the ring replays everything it missed (and it
        re-fetches /v1/models, /v1/downloads and /v1/jobs after any reconnect),
        whereas an event quietly dropped from the middle of its queue is a hole
        its resume point has already moved past — unrecoverable by exactly the
        mechanism that exists to recover it. Draining the queue is the point of
        the exercise: the memory goes back now rather than when the socket
        finally dies.
        """
        self.subscribers.discard(q)
        while not q.empty():
            q.get_nowait()
        q.put_nowait(_OVERFLOW)
        print(f"warning: an event-stream subscriber fell "
              f"{SUBSCRIBER_QUEUE_MAX} frames behind and stopped reading; "
              f"closing its stream so it reconnects", file=sys.stderr)

    def emit_threadsafe(self, event: str, data: dict) -> None:
        self.loop.call_soon_threadsafe(self.emit, event, data)

    async def stream(self, last_event_id: str | None) -> AsyncIterator[str]:
        q: asyncio.Queue = asyncio.Queue(maxsize=SUBSCRIBER_QUEUE_MAX)
        self.subscribers.add(q)
        try:
            if last_event_id is not None and last_event_id.isdigit():
                for eid, event, data in list(self.ring):
                    if eid > int(last_event_id):
                        yield _frame(eid, event, data)
            # The heartbeat is on a clock, not on silence: telemetry now ticks
            # every 10 s even on an idle engine, and a heartbeat that only fired
            # after 15 s of nothing would never fire again.
            next_beat = time.monotonic() + HEARTBEAT_S
            while True:
                try:
                    item = await asyncio.wait_for(
                        q.get(), timeout=max(0.0, next_beat - time.monotonic()))
                    if item is _OVERFLOW:
                        # Deliberately carries no `id:`: the client's resume
                        # point has to stay at the last event it really saw,
                        # which is what makes the replay after its reconnect
                        # cover the gap.
                        yield (f"event: stream.overflow\ndata: "
                               f"{json.dumps({'message': OVERFLOW_MESSAGE})}\n\n")
                        return
                    eid, event, data = item
                    yield _frame(eid, event, data)
                except asyncio.TimeoutError:
                    next_beat = time.monotonic() + HEARTBEAT_S
                    yield ": hb\n\n"
        finally:
            self.subscribers.discard(q)


def _frame(eid: int, event: str, data: dict) -> str:
    return f"id: {eid}\nevent: {event}\ndata: {json.dumps(data)}\n\n"

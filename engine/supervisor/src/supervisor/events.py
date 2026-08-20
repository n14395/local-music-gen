from __future__ import annotations

import asyncio
import json
import time
from typing import AsyncIterator

RING_SIZE = 500
HEARTBEAT_S = 15.0


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
            q.put_nowait((eid, event, data))

    def emit_threadsafe(self, event: str, data: dict) -> None:
        self.loop.call_soon_threadsafe(self.emit, event, data)

    async def stream(self, last_event_id: str | None) -> AsyncIterator[str]:
        q: asyncio.Queue = asyncio.Queue()
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
                    eid, event, data = await asyncio.wait_for(
                        q.get(), timeout=max(0.0, next_beat - time.monotonic()))
                    yield _frame(eid, event, data)
                except asyncio.TimeoutError:
                    next_beat = time.monotonic() + HEARTBEAT_S
                    yield ": hb\n\n"
        finally:
            self.subscribers.discard(q)


def _frame(eid: int, event: str, data: dict) -> str:
    return f"id: {eid}\nevent: {event}\ndata: {json.dumps(data)}\n\n"

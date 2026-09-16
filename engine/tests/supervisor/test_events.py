"""The SSE bus: replay, heartbeat, and the overflow cut-off (audit 08-I1).

A client that holds the connection open but stops reading — a suspended app,
a full TCP window, a debugger paused on a frame — used to accumulate every
event for the life of the session. The subscriber goes, not the events: it
resumes with `Last-Event-ID` and the ring replays what it missed, whereas an
event quietly dropped from the middle of its queue is a hole its resume
point has already moved past.
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import unittest

import _fixtures  # noqa: F401 — path bootstrap

from supervisor import events


class EventBusTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._cap = events.SUBSCRIBER_QUEUE_MAX
        self._beat = events.HEARTBEAT_S
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        events.SUBSCRIBER_QUEUE_MAX = self._cap
        events.HEARTBEAT_S = self._beat

    async def _subscribed(self, last_event_id: str | None = None):
        """A live stream that has already registered its queue."""
        bus = events.EventBus(asyncio.get_running_loop())
        stream = bus.stream(last_event_id)
        first = asyncio.create_task(stream.__anext__())
        await asyncio.sleep(0)
        return bus, stream, first

    async def _overflow(self) -> tuple[events.EventBus, list[str]]:
        events.SUBSCRIBER_QUEUE_MAX = 5
        bus, stream, first = await self._subscribed()
        bus.emit("job.progress", {"i": -1})
        await first
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            for i in range(50):              # nobody is reading now
                bus.emit("job.progress", {"i": i})
        self.warning = stderr.getvalue()
        return bus, [frame async for frame in stream]

    async def test_a_stalled_subscriber_is_dropped_from_the_bus(self) -> None:
        bus, _frames = await self._overflow()
        self.assertEqual(len(bus.subscribers), 0)

    async def test_its_backlog_is_dropped_with_it(self) -> None:
        """The memory goes back now rather than when the socket finally
        dies."""
        _bus, frames = await self._overflow()
        self.assertLessEqual(len(frames), 2, f"{len(frames)} frames left")

    async def test_it_gets_one_frame_saying_so(self) -> None:
        _bus, frames = await self._overflow()
        self.assertTrue(frames[-1].startswith("event: stream.overflow"),
                        repr(frames[-1]))

    async def test_the_overflow_frame_carries_no_id(self) -> None:
        """Its resume point has to stay at the last event it really saw,
        which is what makes the replay after its reconnect cover the gap."""
        _bus, frames = await self._overflow()
        self.assertNotIn("id:", frames[-1])

    async def test_the_overflow_frame_explains_how_to_recover(self) -> None:
        _bus, frames = await self._overflow()
        self.assertIn("Last-Event-ID", frames[-1])

    async def test_the_overflow_is_logged_to_stderr(self) -> None:
        """The app tails stderr into the engine log; a client that vanished
        should be explicable afterwards."""
        await self._overflow()
        self.assertIn("frames behind", self.warning)

    async def test_the_stream_ends_after_the_overflow_frame(self) -> None:
        _bus, frames = await self._overflow()
        self.assertEqual(sum(1 for f in frames
                             if f.startswith("event: stream.overflow")), 1)

    async def test_a_reading_subscriber_is_never_dropped(self) -> None:
        events.SUBSCRIBER_QUEUE_MAX = 5
        bus, stream, first = await self._subscribed()
        bus.emit("job.progress", {"i": 0})
        await first
        for i in range(1, 20):
            bus.emit("job.progress", {"i": i})
            frame = await stream.__anext__()
            self.assertIn(f'"i": {i}', frame)
        self.assertEqual(len(bus.subscribers), 1)
        await stream.aclose()

    async def test_a_frame_carries_id_event_and_data(self) -> None:
        bus, stream, first = await self._subscribed()
        bus.emit("job.queued", {"job_id": "job_1"})
        frame = await first
        self.assertEqual(frame,
                         'id: 1\nevent: job.queued\n'
                         'data: {"job_id": "job_1"}\n\n')
        await stream.aclose()

    async def test_last_event_id_replays_only_what_came_after_it(self) -> None:
        bus = events.EventBus(asyncio.get_running_loop())
        for i in range(4):
            bus.emit("job.progress", {"i": i})
        stream = bus.stream("2")
        replay = [await stream.__anext__() for _ in range(2)]
        self.assertEqual([f.splitlines()[0] for f in replay],
                         ["id: 3", "id: 4"])
        await stream.aclose()

    async def test_a_non_numeric_last_event_id_replays_nothing(self) -> None:
        events.HEARTBEAT_S = 0.01
        bus = events.EventBus(asyncio.get_running_loop())
        bus.emit("job.progress", {"i": 0})
        stream = bus.stream("not-a-number")
        self.assertEqual(await stream.__anext__(), ": hb\n\n")
        await stream.aclose()

    async def test_the_heartbeat_is_on_a_clock_not_on_silence(self) -> None:
        """Telemetry ticks even on an idle engine, and a heartbeat that only
        fired after 15 s of nothing would never fire again."""
        events.HEARTBEAT_S = 0.01
        bus, stream, first = await self._subscribed()
        self.assertEqual(await first, ": hb\n\n")
        await stream.aclose()

    async def test_the_ring_is_bounded(self) -> None:
        bus = events.EventBus(asyncio.get_running_loop())
        for i in range(events.RING_SIZE + 50):
            bus.emit("job.progress", {"i": i})
        self.assertEqual(len(bus.ring), events.RING_SIZE)
        self.assertEqual(bus.ring[-1][0], events.RING_SIZE + 50)

    async def test_closing_a_stream_unsubscribes_it(self) -> None:
        bus, stream, first = await self._subscribed()
        bus.emit("job.progress", {"i": 0})
        await first
        await stream.aclose()
        self.assertEqual(len(bus.subscribers), 0)


if __name__ == "__main__":
    unittest.main()

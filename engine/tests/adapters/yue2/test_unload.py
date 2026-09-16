"""YuE2's unload(): close the pipeline, drop it, then flush the allocator.

Covers 10-B12 (the memory vein). Rebinding `self.pipe = None` frees the
Python objects; the Metal arena a 3.6B bf16 model filled stays checked out
until the allocator is told, and the next model in a warm worker paid for it.
`close()` is upstream's own teardown — it drops `_model` and `_vae`, which
this adapter cannot reach — so it has to run first, and the flush last.

No pipeline is ever built: the fake records the order it was called in.
"""

import sys
import unittest
from unittest import mock

from adapter_yue2 import adapter as yue2
from adapter_yue2.adapter import YuE2Adapter


class FakePipe:
    def __init__(self, order: list[str], *, raises: bool = False) -> None:
        self.order = order
        self.raises = raises

    def close(self) -> None:
        self.order.append("close")
        if self.raises:
            raise RuntimeError("upstream teardown blew up")


class UnloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.order: list[str] = []
        self.pipe_at_flush: list[object] = []
        self.adapter = YuE2Adapter("yue2-3b", {}, "/tmp", {})

        def flush() -> None:
            self.order.append("release")
            self.pipe_at_flush.append(self.adapter.pipe)

        patch = mock.patch.object(yue2, "release_accelerator_memory", flush)
        patch.start()
        self.addCleanup(patch.stop)

    def test_close_runs_before_the_allocator_flush(self):
        """10-B12: a cache flush with the tensors still referenced returns
        nothing, so upstream's own teardown has to happen first."""
        self.adapter.pipe = FakePipe(self.order)
        self.adapter.unload()
        self.assertEqual(self.order, ["close", "release"])

    def test_the_last_reference_is_dropped_before_the_flush(self):
        """10-B12: `release_accelerator_memory` is called at the END of
        unload, after every reference is gone."""
        self.adapter.pipe = FakePipe(self.order)
        self.adapter.unload()
        self.assertEqual(self.pipe_at_flush, [None])
        self.assertIsNone(self.adapter.pipe)

    def test_the_allocator_is_flushed_exactly_once(self):
        self.adapter.pipe = FakePipe(self.order)
        self.adapter.unload()
        self.assertEqual(self.order.count("release"), 1)

    def test_unload_flushes_even_when_nothing_was_loaded(self):
        """A worker that failed to load still has to hand its blocks back."""
        self.adapter.pipe = None
        self.adapter.unload()
        self.assertEqual(self.order, ["release"])

    def test_a_raising_close_does_not_stop_the_flush(self):
        """unload must never raise, and the arena must come back anyway."""
        self.adapter.pipe = FakePipe(self.order, raises=True)
        self.adapter.unload()
        self.assertEqual(self.order, ["close", "release"])
        self.assertIsNone(self.adapter.pipe)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())

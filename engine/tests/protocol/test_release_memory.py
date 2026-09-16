"""`engine_protocol.adapter.release_accelerator_memory` — 09-B7 / 10-B12.

Nine families dropped their model references and freed nothing: both
allocators keep their arenas until told otherwise. This helper is what tells
them, it is called from `unload()`, and `unload()` must never raise — so
"never raises" is as much of the contract as "flushes".

Only runtimes the process already imported may be touched: a family that
never loaded torch must not pay for importing it here.
"""

from __future__ import annotations

import sys
import unittest

from _fixtures import Recorder, fake_mlx_core, fake_torch

from engine_protocol.adapter import release_accelerator_memory


class ReleaseAcceleratorMemoryTest(unittest.TestCase):
    def setUp(self) -> None:
        # These tests install fakes under real module names; put back whatever
        # was there (nothing, in the supervisor venv) whichever way we exit.
        self._saved = {name: sys.modules.get(name)
                       for name in ("torch", "mlx", "mlx.core")}
        for name in self._saved:
            sys.modules.pop(name, None)
        self.addCleanup(self._restore)
        self.rec = Recorder()

    def _restore(self) -> None:
        for name, mod in self._saved.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod

    def test_with_no_runtime_imported_it_touches_nothing(self) -> None:
        """A pure-DSP family has neither; importing torch to flush it would
        cost seconds and gigabytes for nothing."""
        release_accelerator_memory()
        self.assertEqual(self.rec.calls, [])
        self.assertNotIn("torch", sys.modules)
        self.assertNotIn("mlx.core", sys.modules)

    def test_an_imported_torch_gets_its_mps_cache_flushed(self) -> None:
        sys.modules["torch"] = fake_torch(self.rec, mps=True, cuda=False)
        release_accelerator_memory()
        self.assertIn("torch.mps.empty_cache", self.rec.calls)

    def test_cuda_is_left_alone_when_it_is_not_available(self) -> None:
        sys.modules["torch"] = fake_torch(self.rec, mps=True, cuda=False)
        release_accelerator_memory()
        self.assertNotIn("torch.cuda.empty_cache", self.rec.calls)

    def test_mlx_gets_its_buffer_cache_cleared(self) -> None:
        sys.modules["mlx.core"] = fake_mlx_core(self.rec)
        release_accelerator_memory()
        self.assertEqual(self.rec.calls, ["mx.clear_cache"])

    def test_an_mlx_family_does_not_drag_torch_in(self) -> None:
        """10-B12: the mlx families have no torch in their venv at all, and an
        unconditional `import torch` here would be an ImportError inside
        unload()."""
        sys.modules["mlx.core"] = fake_mlx_core(self.rec)
        release_accelerator_memory()
        self.assertNotIn("torch", sys.modules)

    def test_both_runtimes_present_are_both_flushed(self) -> None:
        sys.modules["torch"] = fake_torch(self.rec, mps=True, cuda=False)
        sys.modules["mlx.core"] = fake_mlx_core(self.rec)
        release_accelerator_memory()
        self.assertEqual(sorted(self.rec.calls),
                         ["mx.clear_cache", "torch.mps.empty_cache"])

    def test_a_runtime_that_raises_on_every_call_is_survived(self) -> None:
        """unload() must never raise — the supervisor's real unload is killing
        the worker, and an exception here would strand the load that follows."""
        sys.modules["torch"] = fake_torch(self.rec, explode=True)
        sys.modules["mlx.core"] = fake_mlx_core(self.rec)
        release_accelerator_memory()   # must not raise
        self.assertIn("torch.backends.mps.is_available", self.rec.calls)
        self.assertIn("mx.clear_cache", self.rec.calls)

    def test_an_mlx_that_raises_is_survived(self) -> None:
        mod = fake_mlx_core(self.rec)
        mod.clear_cache = self.rec.raiser("mx.clear_cache")
        sys.modules["mlx.core"] = mod
        release_accelerator_memory()   # must not raise
        self.assertEqual(self.rec.calls, ["mx.clear_cache"])

    def test_a_torch_without_an_mps_backend_is_survived(self) -> None:
        """Older/CPU-only torch has no `torch.backends.mps` at all."""
        import types
        mod = types.ModuleType("torch")
        mod.backends = types.SimpleNamespace()
        mod.cuda = types.SimpleNamespace(is_available=lambda: False)
        sys.modules["torch"] = mod
        release_accelerator_memory()   # must not raise

    def test_it_returns_none(self) -> None:
        self.assertIsNone(release_accelerator_memory())


if __name__ == "__main__":
    unittest.main()

"""ACE-Step: the catalog's step default, and what `unload()` has to let go of.

09-B9 — the turbo DiTs are distilled for 8 steps and every base/sft variant
declares 50, so a caller that omits `steps` used to render all five at turbo's
count.
09-B7 — `dcw_loader.WAVELET_CACHE` is a module-level singleton holding a
DWT/IWT module pair built on the MPS device; it survives both handlers, so
dropping the references alone freed nothing.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from _fixtures import (CALLS, install_fake_runtime, install_fake_wavelet_cache,
                       noop_progress)

install_fake_runtime()

import adapter_acestep.adapter as acestep_adapter  # noqa: E402
from adapter_acestep.adapter import ACEStepAdapter  # noqa: E402
from engine_protocol.adapter import CancelToken  # noqa: E402


class StepDefaultTest(unittest.TestCase):
    """09-B9 — adapter fallback == the catalog entry's declared default."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        CALLS.clear()
        self.adapter = ACEStepAdapter("acestep-test", {"repo": self.tmp.name},
                                      self.tmp.name, {"steps_default": 50})
        self.adapter.dit = object()
        self.adapter.llm = object()

    def _render(self, params=None) -> None:
        self.adapter.generate("a prompt", "la la", {"duration_s": 10.0,
                                                    **(params or {})},
                              os.path.join(self.tmp.name, "take.wav"),
                              noop_progress, CancelToken())

    def test_steps_come_from_the_entry_when_the_job_omits_them(self) -> None:
        self._render()
        self.assertEqual(CALLS[0]["params"].inference_steps, 50)

    def test_an_explicit_step_count_still_wins(self) -> None:
        self._render({"steps": 8})
        self.assertEqual(CALLS[0]["params"].inference_steps, 8)

    def test_the_drawn_seed_is_the_one_generation_reads(self) -> None:
        """B7: upstream reads GenerationConfig.seeds; params.seed is decorative."""
        self._render({"seed": 1234})
        self.assertEqual(CALLS[0]["config"].seeds, [1234])


class UnloadTest(unittest.TestCase):
    """09-B7 — everything let go of, then the allocators flushed."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = install_fake_wavelet_cache()
        self.adapter = ACEStepAdapter("acestep-test", {}, self.tmp.name, {})
        self.observed: list[dict] = []
        original = acestep_adapter.release_accelerator_memory

        def spy() -> None:
            self.observed.append({
                "cache": dict(self.cache._cache),
                "dit": self.adapter.dit,
                "llm": self.adapter.llm,
                "handler_unloaded": self.handler_unloaded[:],
            })

        acestep_adapter.release_accelerator_memory = spy
        self.addCleanup(setattr, acestep_adapter,
                        "release_accelerator_memory", original)
        self.handler_unloaded: list[str] = []
        unloaded = self.handler_unloaded

        class FakeLLM:
            def unload(self) -> None:
                unloaded.append("llm")

        self.adapter.dit = object()
        self.adapter.llm = FakeLLM()

    def test_unload_empties_the_wavelet_cache(self) -> None:
        self.adapter.unload()
        self.assertEqual(self.cache._cache, {})

    def test_the_allocator_flush_comes_last(self) -> None:
        """A cache flush with the tensors still referenced returns nothing."""
        self.adapter.unload()
        self.assertEqual(len(self.observed), 1)
        state = self.observed[0]
        self.assertEqual(state["cache"], {})
        self.assertIsNone(state["dit"])
        self.assertIsNone(state["llm"])
        self.assertEqual(state["handler_unloaded"], ["llm"])


if __name__ == "__main__":
    unittest.main()

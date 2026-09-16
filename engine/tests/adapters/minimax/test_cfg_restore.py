"""MiniMax Music 3: `guidance_scale` is a field of the guider, not an argument.

09-B3 — the same shape as MelodyFlow's `cfg_coef`: a take that raised it left
every later take in this worker raised too, whatever the slider said.
"""

from __future__ import annotations

import os
import sys
import tempfile
import types
import unittest

import numpy as np

PIPELINE_CFG = 1.7


class _FakeGuider:
    guidance_scale = PIPELINE_CFG


class _FakePipe:
    sampling_rate = 8000
    language_model = None      # no hook point: the coarse path, no hooks needed

    def __init__(self) -> None:
        self.guider = _FakeGuider()
        self.calls: list[dict] = []
        self.dtype = None
        self.device = None

    def load_components(self, dtype=None) -> None:
        self.dtype = dtype

    def to(self, device) -> None:
        self.device = device

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        return [np.zeros((2, self.sampling_rate), dtype=np.float32)]


class _FakeModularPipeline:
    instance: "_FakePipe | None" = None

    @classmethod
    def from_pretrained(cls, path):
        cls.instance = _FakePipe()
        return cls.instance


def _install_fake_diffusers() -> None:
    if "diffusers" in sys.modules:
        return
    module = types.ModuleType("diffusers")
    module.ModularPipeline = _FakeModularPipeline
    sys.modules["diffusers"] = module


_install_fake_diffusers()

from adapter_minimax.adapter import MiniMaxAdapter  # noqa: E402
from engine_protocol.adapter import CancelToken  # noqa: E402


def _noop(fraction, message, **kwargs) -> None:
    pass


class CfgRestoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = MiniMaxAdapter("minimax-test", {"repo": self.tmp.name},
                                      self.tmp.name, {"dtype": "float32"})
        self.adapter.load(_noop)
        self.out = os.path.join(self.tmp.name, "take.wav")

    def _render(self, params: dict) -> None:
        self.adapter.generate("a prompt", "[instrumental]",
                              {"duration_s": 1.0, **params}, self.out, _noop,
                              CancelToken())

    def test_load_captures_the_guiders_own_scale(self) -> None:
        """09-B3: "leave it alone" needs somewhere to put it back from."""
        self.assertEqual(self.adapter._cfg_default, PIPELINE_CFG)

    def test_a_null_cfg_scale_restores_the_pipeline_value(self) -> None:
        """09-B3: the take after a guided one is not still guided."""
        self._render({"cfg_scale": 8.0})
        self.assertEqual(self.adapter.pipe.guider.guidance_scale, 8.0)
        self._render({"cfg_scale": None})
        self.assertEqual(self.adapter.pipe.guider.guidance_scale, PIPELINE_CFG)


if __name__ == "__main__":
    unittest.main()

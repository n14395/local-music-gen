"""MelodyFlow: `cfg_coef` is a field of the flow LM, not a call argument.

09-B3 — assigning it per take used to stick, so the first take that set it made
the catalog's declared default (null = "the checkpoint's own value")
unreachable for every later take in the same worker.
"""

from __future__ import annotations

import os
import sys
import tempfile
import types
import unittest

import torch

CHECKPOINT_CFG = 4.5


class _FakeLM:
    cfg_coef = CHECKPOINT_CFG


class _FakeModel:
    sample_rate = 8000
    device = "cpu"

    def __init__(self) -> None:
        self.lm = _FakeLM()
        self.gen_params: list[dict] = []

    def set_custom_progress_callback(self, cb) -> None:
        pass

    def set_generation_params(self, **kwargs) -> None:
        self.gen_params.append(kwargs)

    def generate(self, descriptions, progress=False):
        return torch.zeros(1, 1, self.sample_rate)


class _FakeMelodyFlow:
    @staticmethod
    def get_pretrained(path, device="cpu"):
        return _FakeModel()


def _install_fake_audiocraft() -> None:
    if "audiocraft.models" in sys.modules:
        return
    models = types.ModuleType("audiocraft.models")
    models.MelodyFlow = _FakeMelodyFlow
    package = types.ModuleType("audiocraft")
    package.models = models
    sys.modules["audiocraft"] = package
    sys.modules["audiocraft.models"] = models


_install_fake_audiocraft()

from adapter_melodyflow.adapter import MelodyFlowAdapter  # noqa: E402
from engine_protocol.adapter import CancelToken  # noqa: E402


def _noop(fraction, message, **kwargs) -> None:
    pass


class CfgRestoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = MelodyFlowAdapter("melodyflow-test",
                                         {"repo": self.tmp.name},
                                         self.tmp.name, {"device": "cpu"})
        self.adapter.load(_noop)
        self.out = os.path.join(self.tmp.name, "take.wav")

    def _render(self, params: dict) -> None:
        self.adapter.generate("a prompt", None, {"duration_s": 1.0, **params},
                              self.out, _noop, CancelToken())

    def test_load_captures_the_checkpoints_own_guidance(self) -> None:
        """09-B3: "leave it alone" needs somewhere to put it back from."""
        self.assertEqual(self.adapter._cfg_default, CHECKPOINT_CFG)

    def test_a_null_cfg_restores_the_checkpoint_value(self) -> None:
        """09-B3: the take after a guided one is not still guided."""
        self._render({"cfg_coef": 8.0})
        self.assertEqual(self.adapter.model.lm.cfg_coef, 8.0)
        self._render({"cfg_coef": None})
        self.assertEqual(self.adapter.model.lm.cfg_coef, CHECKPOINT_CFG)


if __name__ == "__main__":
    unittest.main()

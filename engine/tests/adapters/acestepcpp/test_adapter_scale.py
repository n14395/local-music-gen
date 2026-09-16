"""acestep.cpp: a LoRA strength of 0.0 is a real setting, not an unset one.

09-B4 — `or 1.0` ate the bottom of the declared 0.0-2.0 range (the one value
that means "merge nothing") and sent full strength instead. It bit twice: in
the request the runtime merges from, and in the (DiT, adapter, scale) key that
decides whether the resident server keeps the right DiT loaded.
"""

from __future__ import annotations

import os
import tempfile
import unittest

import numpy as np
import soundfile as sf

from adapter_acestepcpp.adapter import AceStepCppAdapter
from engine_protocol.adapter import CancelToken


def _noop(fraction, message, **kwargs) -> None:
    pass


class _StopBeforeTheServer(Exception):
    """Raised in place of starting a real ace-server."""


class RequestTest(unittest.TestCase):
    """What the adapter asks the runtime for."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = AceStepCppAdapter("acestepcpp-test", {}, self.tmp.name,
                                         {"runtime": "server"})
        self.adapter.models_dir = self.tmp.name
        self.adapter.adapters_dir = self.tmp.name
        self.requests: list[dict] = []
        self.adapter._run_server = self._fake_run

    def _fake_run(self, request, task_type, src_audio, ref_audio, out_path,
                  lm_progress, synth_progress, progress_cb, cancel) -> int:
        self.requests.append(request)
        t = np.arange(8000, dtype=np.float32) / 8000.0
        sf.write(out_path, 0.2 * np.sin(2 * np.pi * 220.0 * t), 8000,
                 format="WAV", subtype="PCM_16")
        return int(request["seed"])

    def _render(self, params: dict) -> None:
        self.adapter.generate("a prompt", "la la",
                              {"duration_s": 4.0, **params},
                              os.path.join(self.tmp.name, "take.wav"), _noop,
                              CancelToken())

    def test_zero_adapter_scale_reaches_the_runtime(self) -> None:
        """09-B4: 0.0 means merge nothing, and must not become 1.0."""
        self._render({"adapter": "some-lora", "adapter_scale": 0.0})
        self.assertEqual(self.requests[0]["adapter_scale"], 0.0)

    def test_an_absent_adapter_scale_still_defaults_to_one(self) -> None:
        self._render({"adapter": "some-lora"})
        self.assertEqual(self.requests[0]["adapter_scale"], 1.0)


class ResidentKeyTest(unittest.TestCase):
    """09-B4 — the key that decides whether the server is restarted."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.adapter = AceStepCppAdapter("acestepcpp-test", {}, self.tmp.name,
                                         {"runtime": "server"})
        self.keys: list[tuple] = []

        def record(key):
            self.keys.append(key)
            raise _StopBeforeTheServer()

        self.adapter._ensure_server = record

    def _key_for(self, scale) -> tuple:
        request = {"synth_model": "dit.gguf", "adapter": "some-lora.safetensors",
                   "adapter_scale": scale}
        with self.assertRaises(_StopBeforeTheServer):
            self.adapter._run_server(request, "text2music", None, None,
                                     os.path.join(self.tmp.name, "t.wav"),
                                     _noop, _noop, _noop, CancelToken())
        return self.keys[-1]

    def test_zero_scale_keys_differently_from_full_strength(self) -> None:
        """Collapsing them kept the wrong merged-weight DiT resident."""
        self.assertNotEqual(self._key_for(0.0), self._key_for(1.0))

    def test_zero_scale_is_carried_into_the_key_verbatim(self) -> None:
        self.assertEqual(self._key_for(0.0),
                         ("dit.gguf", "some-lora.safetensors", 0.0))

    def test_an_absent_scale_keys_as_full_strength(self) -> None:
        self.assertEqual(self._key_for(None)[2], 1.0)


if __name__ == "__main__":
    unittest.main()

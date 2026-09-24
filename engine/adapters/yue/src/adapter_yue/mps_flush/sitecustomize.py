# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Injected into YuE's infer.py subprocess via PYTHONPATH (auto-imported by the
`site` module at interpreter startup).

transformers' per-step KV-cache concat makes the PyTorch MPS allocator footprint
grow quadratically with generated tokens — freed blocks are never reused for the
next, slightly larger request (measured ~66 GB by 600 tokens on MusicGen; see
adapter_musicgen). YuE's stage-1 pass generates thousands of tokens on a 7B
model, which would swap-death long before finishing. Wrapping generate() with a
stopping criteria that returns freed blocks to the OS every 25 tokens holds the
footprint flat at no measurable cost.

Set LOCALMUSICGEN_MPS_FLUSH_DEBUG=1 to log hook activity to stderr.
"""
import os
import sys

try:
    import torch

    if torch.backends.mps.is_available():
        from transformers.generation import StoppingCriteria, StoppingCriteriaList
        from transformers.generation.utils import GenerationMixin

        _debug = os.environ.get("LOCALMUSICGEN_MPS_FLUSH_DEBUG") == "1"

        class _FlushMPS(StoppingCriteria):
            def __init__(self) -> None:
                self.steps = 0

            def __call__(self, input_ids, scores, **kwargs) -> bool:
                self.steps += 1
                if self.steps % 25 == 0:
                    torch.mps.empty_cache()
                    if _debug:
                        print(f"[mps-flush] {self.steps} steps, "
                              f"driver {torch.mps.driver_allocated_memory() >> 20} MiB",
                              file=sys.stderr, flush=True)
                return False

        _original_generate = GenerationMixin.generate

        def _flushing_generate(self, *args, **kwargs):
            criteria = kwargs.get("stopping_criteria") or []
            kwargs["stopping_criteria"] = StoppingCriteriaList(
                list(criteria) + [_FlushMPS()])
            return _original_generate(self, *args, **kwargs)

        GenerationMixin.generate = _flushing_generate
        if _debug:
            print("[mps-flush] GenerationMixin.generate wrapped", file=sys.stderr,
                  flush=True)
except Exception:  # never break the subprocess over a memory optimization
    pass

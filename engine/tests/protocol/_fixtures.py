"""Shared helpers for the `engine_protocol` tests.

The supervisor venv installs `engine_protocol` editable, so the import works
without this — but the path insert keeps the group runnable from a bare
interpreter that happens to have nothing else, which is how these were
written.
"""

from __future__ import annotations

import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

for _p in (os.path.join(SRC, "engine", "protocol", "src"),):
    if _p not in sys.path:
        sys.path.insert(0, _p)


class Recorder:
    """Records every call made to it, in order."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def note(self, what: str):
        def fn(*_a, **_k):
            self.calls.append(what)
        return fn

    def raiser(self, what: str):
        def fn(*_a, **_k):
            self.calls.append(what)
            raise RuntimeError(f"{what} blew up")
        return fn


def fake_torch(rec: Recorder, *, mps: bool = True, cuda: bool = False,
               explode: bool = False) -> types.ModuleType:
    """A stand-in for the `torch` a worker venv would have imported.

    `release_accelerator_memory` only ever reaches into
    `torch.backends.mps`, `torch.mps.empty_cache`, `torch.cuda.is_available`
    and `torch.cuda.empty_cache`, so that is the whole of the surface.
    """
    mod = types.ModuleType("torch")
    backends = types.SimpleNamespace()
    if explode:
        backends.mps = types.SimpleNamespace(
            is_available=rec.raiser("torch.backends.mps.is_available"))
        mod.cuda = types.SimpleNamespace(
            is_available=rec.raiser("torch.cuda.is_available"),
            empty_cache=rec.note("torch.cuda.empty_cache"))
    else:
        backends.mps = types.SimpleNamespace(is_available=lambda: mps)
        mod.cuda = types.SimpleNamespace(
            is_available=lambda: cuda,
            empty_cache=rec.note("torch.cuda.empty_cache"))
    mod.backends = backends
    mod.mps = types.SimpleNamespace(empty_cache=rec.note("torch.mps.empty_cache"))
    return mod


def fake_mlx_core(rec: Recorder) -> types.ModuleType:
    mod = types.ModuleType("mlx.core")
    mod.clear_cache = rec.note("mx.clear_cache")
    return mod

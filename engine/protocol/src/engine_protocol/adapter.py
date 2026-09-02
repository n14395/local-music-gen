"""ModelAdapter — the seam every model family implements.

This package must stay stdlib-only: it is installed into every adapter venv, and the
supervisor imports it too. Heavy imports (torch, mlx, …) live in the adapter packages,
loaded only inside worker processes.
"""

from __future__ import annotations

import os
import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Protocol

# Every non-Hugging-Face cache directory this engine owns: weights adapters
# fetch themselves, from direct URLs, torch hub, or source tarballs.
#
# Adding one means adding its name here. scripts/check_supervisor.py fails the
# build otherwise, and an unlisted directory is one the library cannot count,
# move or clear — which is the bug this list exists to have fixed.
AUX_DIRS = ("audio-separator-models", "bsrnn-weights", "btc-chords",
            "bytedance-piano", "diffrhythm2", "essentia-models",
            "inspiremusic", "localmusic-soundfonts", "magenta-home",
            "mossmusic", "msst", "msst-weights", "mt3-checkpoints",
            "rave-models", "seedvc", "songbloom", "torch-cache", "yingmusic")


# Directories in the aux root that hold the *user's* files rather than weights
# the engine can fetch again on demand. Counted and moved with everything else,
# and never cleared: re-downloading one of these needs the user's own API key
# and, worse, needs them to remember which of TONE3000's several hundred
# thousand captures they had chosen.
#
# Written by the app, not by any adapter, which is why they are not in
# AUX_DIRS: `aux_dir()` refuses them and the adapter guard never looks for them.
AUX_KEPT_DIRS = ("tone3000-tones",)


def aux_root() -> str:
    """Where adapter-fetched weights live.

    The worker always sets `LOCALMUSIC_AUX_CACHE`. The fallback is the pre-aux
    derivation — a sibling of `HF_HOME` — kept only so an adapter still lands
    somewhere sane when it is driven directly by the verify scripts.
    """
    root = os.environ.get("LOCALMUSIC_AUX_CACHE")
    if root:
        return root
    hf_home = os.environ.get("HF_HOME")
    return (os.path.dirname(hf_home) if hf_home
            else os.path.expanduser("~/.cache"))


def clear_stale_link(path: str) -> None:
    """Remove `path` if it is a symlink whose target is gone.

    Staging links cross from an adapter's own tree (or the aux cache) into an
    HF snapshot, and the two roots move independently — relocating the library
    strands every link that still names the old root. `os.path.exists` follows
    the link, so a dangling one reads as *absent*: an "already staged?" guard
    re-stages, `os.symlink` then raises EEXIST, and a `shutil.copy` fallback
    writes *through* the dead link and reports ENOENT on the destination —
    which reads as a missing checkpoint when the weights are really fine.
    Call this before every such guard; re-staging then just works.
    """
    if os.path.islink(path) and not os.path.exists(path):
        os.unlink(path)


def aux_dir(name: str) -> str:
    """One aux cache directory, created on demand."""
    assert name in AUX_DIRS, f"unlisted aux dir {name!r} — add it to AUX_DIRS"
    d = os.path.join(aux_root(), name)
    os.makedirs(d, exist_ok=True)
    return d


class ProgressCb(Protocol):
    """(fraction 0..1 or None for indeterminate, human-readable message).

    `phase` names one of the ids the model declares in `capabilities.pipeline`;
    `step`/`steps` locate the work inside that phase. All three are keyword-only
    additions, so every call site written against the original two-argument
    signature keeps working.

    Report only what the adapter genuinely knows. A phase whose progress is
    driven by a timer, or by an opaque call that yields no counts, sends `phase`
    alone — never invented step numbers. A phase the adapter cannot name at all
    sends neither.
    """

    def __call__(self, fraction: float | None, message: str, *,
                 phase: str | None = None, step: int | None = None,
                 steps: int | None = None) -> None: ...


class PreviewCb(Protocol):
    """Publish partial audio for the take that is still rendering.

    `pcm16` is interleaved little-endian 16-bit PCM. The float→int conversion
    stays on the adapter side: this package is installed into every worker venv
    and has to stay stdlib-only (no numpy), and the adapter is the only side
    that knows its own tensor layout.

    Only ever pass audio the model genuinely produced — a decode of the latents
    or tokens that exist at this moment. Nothing downstream can tell an invented
    preview from a real one, so there is no honest way to approximate one.

    The default sink drops everything, so an adapter may call it unconditionally;
    what it must not do unconditionally is the decode that feeds it, which costs
    real time (see `preview_stride`).
    """

    def __call__(self, pcm16: bytes, sample_rate: int, channels: int = 1, *,
                 step: int | None = None) -> None: ...


def drop_preview(pcm16: bytes, sample_rate: int, channels: int = 1, *,
                 step: int | None = None) -> None:
    """The sink an adapter has until a job asks for previews."""


def preview_stride(total_steps: int | None, frames: int = 4) -> int:
    """How many steps to leave between previews.

    Every preview is a real autoencoder/codec decode and measurably slows the
    render, so they are sampled rather than streamed. Dividing the step count by
    a fixed frame budget keeps that cost constant instead of proportional: an
    8-step Stable Audio render still gets a few frames, and a 200-step one does
    not pay 200 decodes. A phase with no known total gets a fixed cadence, which
    is all there is to say when there is nothing to divide.
    """
    if not total_steps or total_steps <= 0:
        return 8
    # Ceiling, not floor. Floor division only overshoots when the total is under
    # 2 x frames — i.e. exactly the few-step samplers — where 5 // 4 == 1 and a
    # 6-step Stable Audio Open Small render pays six full decodes against six
    # diffusion steps. Rounding up caps the frame budget for every input.
    return max(1, -(-total_steps // max(1, frames)))


class CancelToken:
    """Cooperative cancellation flag; adapters poll between steps."""

    def __init__(self) -> None:
        self._event = threading.Event()

    def cancel(self) -> None:
        self._event.set()

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()


class CancelledError(Exception):
    """Raised by adapters when they observe a cancel request."""


class UnstoppableWorkError(CancelledError):
    """Cancelled, but the adapter could not unwind what it had already started.

    Some upstream pipelines run their real work on a thread of their own and
    expose no hook into it (ACE-Step's `generate_music` is the example), so
    there is no point at which an adapter can make that work stop. Raising this
    instead of a plain `CancelledError` says the difference out loud: the job is
    cancelled, and this worker process is not fit to be reused, because
    something inside it is still computing and still holding the accelerator.

    `worker_main` answers it by ending the process — which is this codebase's
    only real unload — after reporting the cancel.
    """


@dataclass
class GenerateResult:
    wav_path: str
    duration_s: float
    sample_rate: int
    seed_used: int | None = None
    extra: dict = field(default_factory=dict)


@dataclass
class Artifact:
    """One output of a task job. kind is an open set (stem | midi | analysis |
    audio today); label carries the human/slot identity (stem name, instrument,
    "preview:<track>" for MIDI audition renders)."""

    kind: str
    label: str
    path: str
    format: str                      # "wav" | "mid" | "json"
    sample_rate: int | None = None
    duration_s: float | None = None


@dataclass
class TaskResult:
    artifacts: list[Artifact]
    meta: dict = field(default_factory=dict)


class ModelAdapter(ABC):
    """One instance per loaded model, living inside a worker process.

    model_paths maps repo_id -> local snapshot directory. Unload is best-effort:
    the supervisor's real unload is killing the worker process.
    """

    def __init__(self, model_id: str, model_paths: dict[str, str], work_dir: str,
                 settings: dict) -> None:
        self.model_id = model_id
        self.model_paths = model_paths
        self.work_dir = work_dir
        self.settings = settings
        # Swapped for a real writer by the worker, for the duration of one
        # take, when the job asked for previews. Never a per-call argument:
        # every adapter's generate() signature is fixed by this class, and a
        # new keyword would break each one at the call site.
        self.preview_cb: PreviewCb = drop_preview

    @abstractmethod
    def load(self, progress_cb: ProgressCb) -> None: ...

    @abstractmethod
    def generate(self, prompt: str, lyrics: str | None, params: dict, out_path: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> GenerateResult: ...

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        """Non-generation work (separate/transcribe/analyze/render/mix). Concrete
        with a raising default so generation-only families need no changes; the
        supervisor's capabilities.tasks gating rejects unsupported tasks before
        this can be reached."""
        raise NotImplementedError(
            f"{type(self).__name__} does not support task '{task}'")

    def unload(self) -> None:  # noqa: B027 — optional hook
        pass

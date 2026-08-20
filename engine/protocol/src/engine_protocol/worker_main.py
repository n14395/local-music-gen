"""Generic worker entrypoint: `python -m engine_protocol.worker_main --family X`.

Runs inside an adapter venv. Reads JSONL commands on stdin, writes JSONL replies on
stdout; everything else (library chatter, tracebacks) goes to stderr. The adapter class
is resolved via the `local_music.adapters` entry-point group, so this module never
imports heavy dependencies itself.

stdout is reserved for the protocol: adapters/libraries printing to stdout would corrupt
it, so the real stdout is handed to the protocol layer and fd 1 is redirected to stderr
before the adapter is imported.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import sys
import threading
import time
import traceback
import wave
from importlib.metadata import entry_points

from . import messages
from .adapter import CancelledError, CancelToken, drop_preview


def _watch_parent(ppid: int) -> None:
    while True:
        time.sleep(2)
        try:
            os.kill(ppid, 0)
        except OSError:
            os._exit(0)


def _accelerator_bytes() -> int | None:
    """Metal memory held by this process. Invisible to RSS, so the usual process
    metrics miss it — this is the number that predicts unified-memory swap-death.
    Only consults frameworks the adapter has already imported.

    torch's driver_allocated_memory() is the PROCESS-WIDE Metal figure
    (MTLDevice.currentAllocatedSize) and therefore already includes MLX's
    buffers in dual-runtime workers like ACE-Step — so take the max of the
    reported figures, never the sum (summing double-counts and falsely kills
    healthy workers)."""
    readings = []
    torch = sys.modules.get("torch")
    if torch is not None:
        try:
            if torch.backends.mps.is_available():
                readings.append(int(torch.mps.driver_allocated_memory()))
        except Exception:  # noqa: BLE001 — sampling must never hurt the worker
            pass
    mx = sys.modules.get("mlx.core")
    if mx is not None:
        try:
            get_active = getattr(mx, "get_active_memory", None)
            if get_active is None:
                metal = getattr(mx, "metal", None)
                get_active = getattr(metal, "get_active_memory", None) if metal else None
            if get_active is not None:
                readings.append(int(get_active()))
        except Exception:  # noqa: BLE001
            pass
    return max(readings) if readings else None


def _accelerator_profile() -> tuple[str | None, int | None]:
    """Which accelerator this worker is on, and the working set Metal
    recommends for it — the real ceiling for a model, always well under
    hw.memsize. Same discipline as _accelerator_bytes: only frameworks the
    adapter has already imported are consulted, so a pure-DSP worker reports
    nothing rather than importing torch to find out.

    The supervisor cannot ask this itself; neither framework is in its venv.

    A dual-runtime worker (ACE-Step runs its DiT on torch/MPS and its language
    model on MLX) is reported as "metal": MLX is itself a Metal backend, so the
    label is true of both halves, merely less specific — and torch's memory
    figure, which is process-wide, is the one we report for it anyway. Both
    frameworks read the same MTLDevice property for the ceiling, so whichever
    answers first is the same number."""
    backend: str | None = None
    ceiling: int | None = None
    mx = sys.modules.get("mlx.core")
    if mx is not None:
        try:
            device_info = getattr(mx, "device_info", None)
            if device_info is None:
                metal = getattr(mx, "metal", None)
                device_info = getattr(metal, "device_info", None) if metal else None
            if device_info is not None:
                backend = "mlx"
                ceiling = int(device_info()["max_recommended_working_set_size"])
        except Exception:  # noqa: BLE001 — sampling must never hurt the worker
            pass
    torch = sys.modules.get("torch")
    if torch is not None:
        try:
            if torch.backends.mps.is_available():
                backend = "metal"
                if ceiling is None:
                    ceiling = int(torch.mps.recommended_max_memory())
            elif backend is None:
                backend = "cpu"
        except Exception:  # noqa: BLE001
            pass
    return backend, ceiling


def _watch_memory(proto_out) -> None:
    """Report accelerator memory to the supervisor. Reporting only — the
    supervisor warns the user past the threshold but never kills the job
    (transient allocator spikes between cache flushes can legitimately cross
    it; the user chose warn-don't-stop). The same message carries the
    accelerator's identity, which the supervisor has no other way to learn."""
    last_reported = None
    last_profile = None
    while True:
        time.sleep(2)
        used = _accelerator_bytes()
        profile = _accelerator_profile()
        moved = (used is not None
                 and (last_reported is None
                      or abs(used - last_reported) > 64 * 1024 * 1024))
        # a profile that has only just become knowable (the adapter imported its
        # framework since the last tick) is worth a message on its own, even for
        # a CPU-only worker that will never report a byte count
        if not moved and profile == last_profile:
            continue
        last_profile = profile
        fields = {}
        if used is not None:
            last_reported = used
            fields["bytes"] = used
        if profile[0] is not None:
            fields["backend"] = profile[0]
        if profile[1] is not None:
            fields["working_set_bytes"] = profile[1]
        if fields:
            messages.send(proto_out, "mem", **fields)


class _PreviewWriter:
    """Writes a partial take to `preview-<n>.wav` beside the take it belongs to
    and tells the supervisor where it landed.

    Beside the take, not in a temp dir, because the supervisor validates a
    preview path against the job's own output directory exactly as it does a
    task artifact — and "keep the partial" is then an ordinary file move rather
    than a second delivery channel.

    Written through a `.part` rename like every other output: the app reads
    these while the render is still writing the next one, and a half-written
    header is indistinguishable from a corrupt file.
    """

    def __init__(self, out_path: str, proto_out) -> None:
        self._dir = os.path.dirname(os.path.abspath(out_path))
        self._out = proto_out
        # Numbering continues past whatever is already there, because a
        # multi-take job builds one writer PER take into one directory —
        # restarting at 0 would have take 1 overwrite the frames take 0 sent,
        # under paths the supervisor had already published.
        used = [int(n[len("preview-"):-len(".wav")])
                for n in self._existing() if n.startswith("preview-")
                and n.endswith(".wav")
                and n[len("preview-"):-len(".wav")].isdigit()]
        self._n = max(used) + 1 if used else 0

    def _existing(self) -> list[str]:
        try:
            return os.listdir(self._dir)
        except OSError:
            return []

    def __call__(self, pcm16: bytes, sample_rate: int, channels: int = 1, *,
                 step: int | None = None) -> None:
        channels = max(1, channels)
        frames = len(pcm16) // (2 * channels)
        if frames <= 0 or sample_rate <= 0:
            return
        path = os.path.join(self._dir, f"preview-{self._n}.wav")
        self._n += 1
        tmp = path + ".part"
        with wave.open(tmp, "wb") as w:
            w.setnchannels(channels)
            w.setsampwidth(2)
            w.setframerate(sample_rate)
            w.writeframes(pcm16)
        os.replace(tmp, path)
        messages.send(self._out, "preview", path=path,
                      sample_rate=sample_rate,
                      duration_s=frames / sample_rate, step=step)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", required=True)
    ap.add_argument("--parent-pid", type=int, default=os.getppid())
    args = ap.parse_args()

    # Protocol owns the real stdout; fd 1 becomes a copy of stderr so stray prints
    # from research-repo imports can't corrupt the JSONL stream.
    proto_out = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    threading.Thread(target=_watch_parent, args=(args.parent_pid,), daemon=True).start()
    threading.Thread(target=_watch_memory, args=(proto_out,), daemon=True).start()

    eps = entry_points(group="local_music.adapters")
    try:
        adapter_cls = eps[args.family].load()
    except KeyError:
        messages.send(proto_out, "error", kind="runtime",
                      message=f"no adapter entry point for family '{args.family}'")
        return

    messages.send(proto_out, "ready", family=args.family, pid=os.getpid())

    adapter = None
    cancel = CancelToken()

    def progress(fraction: float | None, message: str, *,
                 phase: str | None = None, step: int | None = None,
                 steps: int | None = None) -> None:
        if cancel.cancelled:
            raise CancelledError()
        # Only the staged fields the adapter actually passed go on the wire: an
        # absent step count means "this phase does not count steps", which is a
        # different claim from zero, and the supervisor must be able to tell.
        staged = {k: v for k, v in (("phase", phase), ("step", step),
                                    ("steps", steps)) if v is not None}
        messages.send(proto_out, "progress", progress=fraction, message=message,
                      **staged)

    # A reader thread is required for cancel: while generate() runs, the main thread
    # cannot read stdin. Cancel/shutdown act on the CURRENT token immediately; other
    # commands queue for the main loop.
    import queue as _queue

    commands: _queue.Queue = _queue.Queue()

    def _read_stdin() -> None:
        while True:
            m = messages.recv(sys.stdin)
            if m is None or m["t"] == "shutdown":
                cancel.cancel()
                commands.put({"t": "shutdown"})
                return
            if m["t"] == "cancel":
                cancel.cancel()
            else:
                commands.put(m)

    threading.Thread(target=_read_stdin, daemon=True).start()

    while True:
        msg = commands.get()
        if msg["t"] == "shutdown":
            if adapter is not None:
                adapter.unload()
            return
        try:
            if msg["t"] == "load":
                # Loading a second model into a live worker must release the
                # first: rebinding alone leaves the old weights referenced by
                # the adapter until GC gets round to it, and MLX/MPS memory is
                # only really freed by the adapter's own unload().
                if adapter is not None:
                    try:
                        adapter.unload()
                    except Exception:  # noqa: BLE001 — best effort, never fatal
                        traceback.print_exc()
                    adapter = None
                adapter = adapter_cls(model_id=msg["model_id"],
                                      model_paths=msg["model_paths"],
                                      work_dir=msg["work_dir"],
                                      settings=msg.get("settings", {}))
                adapter.load(progress)
                messages.send(proto_out, "loaded", model_id=msg["model_id"])
            elif msg["t"] == "generate":
                if adapter is None:
                    messages.send(proto_out, "error", kind="runtime",
                                  message="generate before load")
                    continue
                cancel = CancelToken()
                params = msg.get("params", {})
                # Previews cost a decode per frame, so the writer only exists
                # for a job that asked (the same `preview` flag the adapter
                # reads to decide whether to do the decode at all), and only
                # for the take it belongs to.
                if params.get("preview"):
                    adapter.preview_cb = _PreviewWriter(msg["out_path"],
                                                        proto_out)
                try:
                    result = adapter.generate(
                        prompt=msg["prompt"], lyrics=msg.get("lyrics"),
                        params=params, out_path=msg["out_path"],
                        progress_cb=progress, cancel=cancel)
                finally:
                    adapter.preview_cb = drop_preview
                messages.send(proto_out, "result", wav_path=result.wav_path,
                              duration_s=result.duration_s,
                              sample_rate=result.sample_rate,
                              seed_used=result.seed_used, extra=result.extra)
            elif msg["t"] == "task":
                if adapter is None:
                    messages.send(proto_out, "error", kind="runtime",
                                  message="task before load")
                    continue
                cancel = CancelToken()
                task_result = adapter.run_task(
                    task=msg["task"], params=msg.get("params", {}),
                    out_dir=msg["out_dir"], progress_cb=progress, cancel=cancel)
                messages.send(proto_out, "task_result",
                              artifacts=[dataclasses.asdict(a)
                                         for a in task_result.artifacts],
                              meta=task_result.meta)
        except CancelledError:
            messages.send(proto_out, "error", kind="cancelled", message="cancelled")
        except MemoryError:
            messages.send(proto_out, "error", kind="oom", message="out of memory")
            return
        except Exception as e:  # noqa: BLE001 — worker must report, not die silently
            messages.send(proto_out, "error", kind="runtime", message=str(e),
                          traceback=traceback.format_exc())


if __name__ == "__main__":
    main()

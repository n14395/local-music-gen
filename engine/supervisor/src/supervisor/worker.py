"""Worker process handle: JSONL over stdio with an adapter venv's worker_main.

One worker per family, at most one alive at a time (unified-memory discipline).
Real unload is process death; kill() is always safe.
"""

from __future__ import annotations

import json
import os
import queue
import signal
import subprocess
import threading
import time
from typing import Protocol

from .config import Settings
from .events import EventBus
from .telemetry import process_tree_footprint_bytes


class WorkerDied(Exception):
    pass


class ProgressSink(Protocol):
    """Supervisor-side mirror of engine_protocol.adapter.ProgressCb. The two
    packages share no code (the supervisor only ever spawns a worker venv), so
    the shape is restated here rather than imported."""

    def __call__(self, fraction: float | None, message: str, *,
                 phase: str | None = None, step: int | None = None,
                 steps: int | None = None) -> None: ...


class PreviewSink(Protocol):
    """Partial audio a worker decoded mid-render (contract 5.6). Restated here
    for the same reason ProgressSink is: the two packages share no code."""

    def __call__(self, path: str, sample_rate: int, duration_s: float,
                 step: int | None) -> None: ...


class Worker:
    def __init__(self, family: str, python_path: str, settings: Settings,
                 bus: EventBus, log_suffix: str | None = None) -> None:
        self.family = family
        self.bus = bus
        self.loaded_model_id: str | None = None
        self.current_job_id: str | None = None
        # Monotonic time this worker last finished a job, or None while it is
        # working. The warm pool uses it as both the LRU key and the TTL clock.
        self.idle_since: float | None = None
        self.ready_seen = False
        self.mem_bytes = 0
        # Which accelerator this worker turned out to be using, and its Metal
        # working-set ceiling. Only the worker can see these (torch/mlx are in
        # its venv, not ours), and only once its adapter has imported them —
        # until then they stay None and /v1/system reports nothing rather than
        # guessing "Metal".
        self.backend: str | None = None
        self.working_set_bytes: int | None = None
        self.mem_limit = settings.mem_guard_bytes
        self._mem_warned = False
        self.messages: queue.Queue[dict | None] = queue.Queue()

        env = {**os.environ,
               "HF_HOME": settings.hf_cache_dir,
               "PYTORCH_ENABLE_MPS_FALLBACK": "1",
               "TOKENIZERS_PARALLELISM": "false"}
        # The transient slot passes a suffix: two workers of the same family
        # can be alive at once (a small mix model beside a big generator in
        # mlxaudio), and they must not share one log handle — kill() closes it.
        name = f"worker-{family}-{log_suffix}" if log_suffix else f"worker-{family}"
        log_path = os.path.join(settings.logs_dir, f"{name}.log")
        self._log = open(log_path, "ab", buffering=0)
        # start_new_session: the worker gets its own process group so kill() can take
        # down anything it spawned.
        self.proc = subprocess.Popen(
            [python_path, "-m", "engine_protocol.worker_main",
             "--family", family, "--parent-pid", str(os.getpid())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env, text=True, bufsize=1,
            start_new_session=True)
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    # MARK: pipes

    def _log_write(self, data: bytes) -> None:
        # The reader threads may still be draining the pipes after kill() has
        # closed the log file; dropping those tail lines beats a thread crash.
        try:
            self._log.write(data)
        except ValueError:
            pass

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                self._log_write(f"[bad stdout] {line}\n".encode())
                continue
            # memory telemetry is consumed here, not queued: nobody drains the
            # message queue between jobs. Past the threshold we WARN the user
            # but never stop the job (their call) — with hysteresis so a spiky
            # allocator doesn't flood the event stream.
            if msg.get("t") == "mem":
                if msg.get("backend"):
                    self.backend = msg["backend"]
                if msg.get("working_set_bytes"):
                    self.working_set_bytes = int(msg["working_set_bytes"])
                # a CPU-only worker names its backend but has no byte count to
                # report, and an absent count must not reset the last real one
                if msg.get("bytes") is None:
                    continue
                self.mem_bytes = int(msg["bytes"])
                if self.mem_limit and self.mem_bytes > self.mem_limit:
                    if not self._mem_warned:
                        self._mem_warned = True
                        self._log_write(f"[mem-warning] {line}\n".encode())
                        text = (f"generation is using ~{self.mem_bytes >> 30} GB "
                                f"of memory (warning level "
                                f"{self.mem_limit >> 30} GB) — the Mac may slow "
                                f"down; consider a shorter duration or a "
                                f"smaller model")
                        self.bus.emit_threadsafe("engine.warning",
                                                 {"message": text})
                        if self.current_job_id:
                            self.bus.emit_threadsafe(
                                "job.log", {"job_id": self.current_job_id,
                                            "line": text})
                elif self.mem_limit and self.mem_bytes < int(self.mem_limit * 0.85):
                    self._mem_warned = False
                continue
            self.messages.put(msg)
        self.messages.put(None)  # EOF sentinel

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self._log_write(line.encode())
            if self.current_job_id and line.strip():
                self.bus.emit_threadsafe(
                    "job.log", {"job_id": self.current_job_id,
                                "line": line.strip()[:500]})

    # MARK: protocol

    def send(self, msg: dict) -> None:
        if self.proc.poll() is not None or self.proc.stdin is None:
            raise WorkerDied(f"{self.family} worker is not running")
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def wait_until(self, terminal: set[str],
                   on_progress: ProgressSink | None = None,
                   timeout: float | None = None,
                   on_preview: PreviewSink | None = None) -> dict:
        """Consume messages until one of `terminal` arrives (or EOF/timeout)."""
        deadline = time.monotonic() + timeout if timeout else None
        while True:
            remaining = (deadline - time.monotonic()) if deadline else None
            if remaining is not None and remaining <= 0:
                raise TimeoutError(f"{self.family} worker timed out")
            try:
                msg = self.messages.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError(f"{self.family} worker timed out") from None
            if msg is None:
                raise WorkerDied(f"{self.family} worker exited unexpectedly")
            if msg["t"] == "progress":
                if on_progress:
                    # .get, not [...]: the staged fields are only present when
                    # the adapter knew them, and None must survive as None.
                    on_progress(msg.get("progress"), msg.get("message", ""),
                                phase=msg.get("phase"), step=msg.get("step"),
                                steps=msg.get("steps"))
                continue
            if msg["t"] == "preview":
                # Not logged as unexpected when nobody is listening: a load
                # wait and a task wait both share this loop, and a preview
                # arriving there is a stale frame from the take before, not a
                # protocol error.
                if on_preview:
                    on_preview(str(msg.get("path") or ""),
                               int(msg.get("sample_rate") or 0),
                               float(msg.get("duration_s") or 0.0),
                               msg.get("step"))
                continue
            if msg["t"] in terminal:
                return msg
            # unexpected message type: log and keep reading
            self._log_write(f"[unexpected] {json.dumps(msg)}\n".encode())

    def request_cancel(self) -> None:
        try:
            self.send({"t": "cancel"})
        except WorkerDied:
            pass

    def is_alive(self) -> bool:
        return self.proc.poll() is None

    def footprint_bytes(self) -> int | None:
        """Physical memory this worker holds, **including anything it spawned**,
        or None once it is gone. Adapters that drive a native CLI (acestep.cpp,
        YuE, whisper.cpp) keep the whole model in a child process, so counting
        the worker alone reported 0.0 GB for them all the way through a render.
        Checked against poll() first: a reaped pid can be reused, and reading a
        stranger's footprint would be worse than reporting nothing."""
        if self.proc.poll() is not None:
            return None
        return process_tree_footprint_bytes(self.proc.pid)

    def shutdown(self, grace_s: float = 3.0) -> None:
        try:
            self.send({"t": "shutdown"})
        except WorkerDied:
            pass
        deadline = time.monotonic() + grace_s
        while self.proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.1)
        self.kill()

    def kill(self) -> None:
        if self.proc.poll() is None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                self.proc.kill()
        try:
            self._log.close()
        except OSError:
            pass

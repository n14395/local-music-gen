"""Fakes and drivers shared by the supervisor tests.

Everything here exists so a test can reach real supervisor code without
starting anything: no uvicorn, no worker process, no event loop of its own,
no model. Three patterns recur.

* **Objects built without `__init__`.** `JobQueue.__init__` starts two
  threads and `Worker.__init__` forks a python; the methods under test touch
  a handful of attributes each, and those attributes are the whole of their
  world. `scripts/check_supervisor.py` established the idiom.
* **A fake bus.** `EventBus.emit_threadsafe` schedules onto a running loop,
  which there is not one of here. `FakeBus` records instead.
* **An in-process ASGI driver.** `call_asgi` speaks the ASGI protocol to the
  app `build_app()` returns — no port, no lifespan, no httpx — and records
  how many times the handler asked for the body, which is what makes
  "refused before the body was read" checkable.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

for _p in (os.path.join(SRC, "engine", "supervisor", "src"),
           os.path.join(SRC, "engine", "protocol", "src")):
    if _p not in sys.path:
        sys.path.insert(0, _p)


# MARK: - bus


class FakeBus:
    """Records what would have gone out on the event stream."""

    def __init__(self) -> None:
        self.events: list[tuple[str, dict]] = []

    def emit(self, event: str, data: dict) -> None:
        self.events.append((event, data))

    emit_threadsafe = emit

    def named(self, event: str) -> list[dict]:
        return [d for e, d in self.events if e == event]

    def names(self) -> list[str]:
        return [e for e, _ in self.events]


# MARK: - settings


def make_settings(tmp: str, **over):
    """A `Settings` rooted entirely in `tmp`. Nothing here touches the real
    data dir, the real library volume, or `~`."""
    from supervisor.config import Settings

    kwargs = dict(data_dir=os.path.join(tmp, "data"),
                  output_dir=os.path.join(tmp, "out"),
                  handshake_file=os.path.join(tmp, "handshake.json"),
                  parent_pid=None, auth_token="test-token")
    kwargs.update(over)
    settings = Settings(**kwargs)
    os.makedirs(settings.data_dir, exist_ok=True)
    os.makedirs(settings.output_dir, exist_ok=True)
    return settings


class EnvGuard:
    """Set (and restore) environment variables around a test."""

    def __init__(self, **values: str | None) -> None:
        self.values = values
        self.saved: dict[str, str | None] = {}

    def __enter__(self) -> "EnvGuard":
        for k, v in self.values.items():
            self.saved[k] = os.environ.get(k)
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        return self

    def __exit__(self, *_exc) -> None:
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# MARK: - catalog fakes


def model_entry(model_id: str = "fake-model", **over) -> dict:
    """One catalog entry in the shape `submit` reads. Deliberately minimal:
    every key here is one the code under test actually looks at."""
    entry = {
        "id": model_id,
        "family": "fakefam",
        "display_name": "Fake Model",
        "hf_repos": [{"repo_id": "fake/repo", "gated": False}],
        "size_bytes": 2_000_000_000,
        "capabilities": {
            "supports_lyrics": True,
            "instrumental_only": False,
            "duration": {"min_s": 1, "max_s": 60, "default_s": 30},
            "sample_rate": 44100,
            "outputs_per_job_max": 4,
            "est_seconds_per_audio_second": 1.0,
            "params": [
                {"key": "seed", "type": "int", "label": "Seed",
                 "default": None, "nullable": True, "min": 0, "max": 100},
                {"key": "steps", "type": "int", "label": "Steps",
                 "default": 20, "nullable": False, "min": 1, "max": 100},
            ],
        },
        "requirements": {"min_ram_bytes": 1, "disk_bytes": 1_000_000,
                         "speed_tier": "fast"},
        "license": {"name": "MIT", "commercial_use": True,
                    "requires_hf_token": False, "url": None},
        "notes": None,
    }
    entry.update(over)
    return entry


class FakeRegistry:
    """Just enough registry for `JobQueue.submit` and friends."""

    def __init__(self, models: list[dict] | None = None,
                 installed: bool = True) -> None:
        models = models or [model_entry()]
        self.models = {m["id"]: m for m in models}
        self._installed = installed
        self.settings = types.SimpleNamespace()

    def is_installed(self, model_id: str) -> bool:
        return self._installed

    def is_marked(self, model_id: str) -> bool:
        return self._installed


# MARK: - queue / worker fakes


def make_queue(registry=None, bus=None, settings=None):
    """A `JobQueue` with no runner thread and no canceller thread.

    Built with `object.__new__` for the reason `check_supervisor.py` gives:
    the real constructor starts two daemon threads that would then race every
    assertion in the test.
    """
    from supervisor.jobqueue import JobQueue

    q = object.__new__(JobQueue)
    q.registry = registry if registry is not None else FakeRegistry()
    q.bus = bus if bus is not None else FakeBus()
    q.settings = settings if settings is not None else types.SimpleNamespace(
        uploads_dir="/nonexistent-uploads")
    q.jobs = {}
    q.order = []
    q.active = None
    q.worker = None
    q.small_workers = {}
    q.pinned_model_id = None
    q.held = False
    q.lock = threading.RLock()
    q.wake = threading.Event()
    q.cancel_wake = threading.Event()
    return q


def fake_worker(family: str = "fakefam", model_id: str | None = None,
                idle_since: float | None = None, alive: bool = True,
                killed: list[str] | None = None):
    """A stand-in for `Worker` with the five attributes the queue reads."""
    w = types.SimpleNamespace(family=family,
                              loaded_model_id=model_id or f"{family}-model",
                              idle_since=idle_since,
                              cancels=0)
    w.is_alive = lambda: alive
    w.kill = lambda: (killed if killed is not None else []).append(
        w.loaded_model_id)

    def request_cancel() -> None:
        w.cancels += 1
    w.request_cancel = request_cancel
    return w


# MARK: - API state


class FakeState:
    """What `build_app` and the routers reach for on `app.state.engine`.

    Only `settings` is needed by the auth middleware; the rest are supplied
    per test, and anything a test does not supply raises AttributeError,
    which is a clearer failure than a silently wrong answer.
    """

    def __init__(self, settings=None, **attrs) -> None:
        self.settings = settings or types.SimpleNamespace(
            auth_token="test-token", uploads_dir="/nonexistent-uploads")
        for k, v in attrs.items():
            setattr(self, k, v)

    def uptime_s(self) -> float:
        # /healthz is the one unauthenticated route, so every envelope test
        # that checks the middleware's exemption reaches this.
        return 0.0


# MARK: - ASGI driver


class AsgiResponse:
    def __init__(self, status: int, headers: list[tuple[bytes, bytes]],
                 body: bytes, receives: int, exception: BaseException | None):
        self.status = status
        self.headers = {k.decode().lower(): v.decode() for k, v in headers}
        self.body = body
        #: How many times the handler pulled from `receive` — 0 means the
        #: request body was never read.
        self.receives = receives
        #: What the app raised after answering. `ServerErrorMiddleware` always
        #: re-raises once its handler has produced the response, so a 500 test
        #: needs both halves.
        self.exception = exception

    def json(self):
        return json.loads(self.body or b"null")

    def error(self) -> dict:
        """The contract's error envelope: {"error": {code, message, detail}}."""
        return self.json()["error"]


def call_asgi(app, method: str, path: str, *, token: str | None = "test-token",
              headers: dict[str, str] | None = None,
              body: bytes | list[bytes] = b"",
              query: str = "") -> AsgiResponse:
    """One HTTP request into an ASGI app, in-process.

    No port, no lifespan, no client library. `body` may be a list of chunks,
    which is how a streaming upload arrives.
    """
    raw: list[tuple[bytes, bytes]] = []
    if token is not None:
        raw.append((b"authorization", f"Bearer {token}".encode()))
    for k, v in (headers or {}).items():
        raw.append((k.lower().encode(), str(v).encode()))

    chunks = list(body) if isinstance(body, list) else [body]
    state: dict = {"status": 500, "headers": [], "body": b"", "receives": 0}

    async def receive() -> dict:
        state["receives"] += 1
        if chunks:
            chunk = chunks.pop(0)
            return {"type": "http.request", "body": chunk,
                    "more_body": bool(chunks)}
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message: dict) -> None:
        if message["type"] == "http.response.start":
            state["status"] = message["status"]
            state["headers"] = list(message.get("headers") or [])
        elif message["type"] == "http.response.body":
            state["body"] += message.get("body") or b""

    scope = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": method.upper(),
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "root_path": "",
        "query_string": query.encode(),
        "headers": raw,
        "client": ("127.0.0.1", 50000),
        "server": ("testserver", 80),
    }

    exception: list[BaseException] = []

    async def run() -> None:
        try:
            await app(scope, receive, send)
        except BaseException as exc:  # noqa: BLE001 — see AsgiResponse.exception
            exception.append(exc)

    asyncio.run(run())
    return AsgiResponse(state["status"], state["headers"], state["body"],
                        state["receives"], exception[0] if exception else None)

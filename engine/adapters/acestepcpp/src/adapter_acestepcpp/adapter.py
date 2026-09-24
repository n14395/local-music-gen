# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""ACE-Step 1.5 via acestep.cpp — the native C++/GGML runtime (Metal on Macs).

Two runtimes, chosen per catalog entry by `settings["runtime"]`:

  "server"  (default) one resident `ace-server` process per loaded model,
            driven over loopback HTTP. Models stay in VRAM between takes,
            cancel is cooperative, and the VAE encode of a source file is
            cached as latents.
  "cli"     the original pair of one-shot binaries, `ace-lm` then `ace-synth`,
            one process each per generation. Kept as the rollback path.

Either way the request JSON is identical, the same GGUFs are read from the
model snapshot (the catalog entry downloads exactly the files this runtime
needs via allow_patterns), and the same stderr lines drive progress. The
binaries are built by scripts/build_acestep_cpp.sh into
engine/adapters/acestepcpp/bin.

Reported phases are `lm_reasoning` → `diffusion` → `vocoder` → `master`, matching
the `capabilities.pipeline` this family's catalog entries declare. Unlike the
Python ACE-Step runtime, the C++ tools print real step numbers on stderr, so the
diffusion phase here does carry counts.

Policy decisions behind the server path (the plan's phase 0):

* **`--keep-loaded` is on for every entry** (`settings["keep_loaded"]`, per-entry
  so it can be turned off without a code change). It is the whole point of the
  swap; every acestep.cpp entry declares 12–16 GiB of RAM and lands in the
  supervisor's resident slot, so a worker holding its models between takes is
  what that slot already promises. The cost is visible: `footprint_bytes` walks
  the process tree, so the app now shows this family's real resident set while
  it sits idle instead of ~0.
* **`--max-batch` stays at 1.** It sizes the LM's KV cache permanently
  (`n_kv_sets = 2 * max_batch`) and buys nothing until the supervisor can hand
  an adapter every take of a `count: N` job at once — which is a change to the
  wire contract, not to this file. 1 also keeps the server's LM numerically
  identical to `ace-lm`, which passes `max_batch = lm_batch_size = 1`.
* **One DiT resident at a time.** `ModelKey` includes `adapter_path` *and*
  `adapter_scale`, and under `EVICT_NEVER` nothing is ever released — so
  nudging LoRA strength 1.0 → 0.9 → 0.8 would pin three separate copies of a
  5 GB XL DiT. `_ensure_server` restarts the server when the
  (DiT, adapter, scale) key would change: the common case (many takes, same
  settings) keeps the full win, and the pathological case costs one model load,
  which is what *every* take costs on the CLI path.

Three layers stop a server outliving its worker, none of them a fork of the
pinned C++ (it has no `--parent-pid` and no idle timeout):

1. `unload()` — which the worker calls on shutdown and before loading another
   model — and an `atexit` hook, both SIGTERM then SIGKILL.
2. The server is spawned *without* `start_new_session`, so it stays in the
   worker's process group and the supervisor's `killpg` reaches it.
3. A pidfile in `work_dir`, checked at `load()`: a server left by a worker that
   died without unwinding is killed before a new one starts.

Known cost of the transport: a finished take crosses the socket in memory
rather than being written to disk by the binary, so a 10-minute render is a
~115 MB response body. Nothing here streams it; the CLI path remains available
if that ever matters.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from pathlib import Path

import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb,
                                     clear_stale_link)

# stderr progress lines emitted by the tools — and, unchanged, by the server:
# it dups its own stderr into a ring buffer for GET /logs *and forwards every
# byte to the real stderr* (`log_reader_main`), so the swap needed no new
# progress mechanism, only a long-lived reader instead of a per-process one.
_LM1_RE = re.compile(r"\[LM-Phase1\] Step (\d+)")
_LM2_RE = re.compile(r"\[LM-Phase2\] Step (\d+)")
_DIT_RE = re.compile(r"\[DiT\] Step (\d+)/(\d+)")
LM_CODE_RATE = 5.0  # audio codes per second of music (5 Hz LM)

# The server's fixed multipart boundary (`MULTIPART_BOUNDARY` in ace-server.cpp).
_BOUNDARY = b"--ace-batch-boundary"
# What we send: any token httplib can split on. Its parser files a part under
# `files` only when the Content-Disposition carries a filename, and every part
# the handlers look for is fetched with `has_file`.
_UPLOAD_BOUNDARY = "localmusicgen-ace-upload"

_POLL_S = 0.2            # job status poll interval
_START_TIMEOUT_S = 60.0  # server boot: a registry scan reads GGUF metadata only
_STOP_GRACE_S = 5.0
_CANCEL_GRACE_S = 30.0
_LATENT_FRAME_BYTES = 64 * 4  # raw f32 [T, 64], the server's latent wire format

# Tasks whose source may be handed over as pre-encoded latents. Deliberately
# not the whole list: repaint and lego splice the *original PCM* back over
# everything outside the repainted region after the decode
# (`pipeline-synth-ops.cpp`, "[WAV-Splice]"), and that splice is skipped on the
# latent path because there is no waveform to read from. Sending latents for
# those two would quietly VAE-roundtrip the parts of the track the user asked
# to keep untouched — a worse render for a faster encode, which is not a trade
# worth making silently.
_LATENT_TASKS = frozenset({"cover", "cover-nofsq", "extract", "complete"})


def _bin_dir() -> Path:
    if custom := os.environ.get("LOCALMUSICGEN_ACESTEP_CPP_BIN"):
        return Path(custom)
    # src/adapter_acestepcpp/adapter.py -> adapters/acestepcpp/bin
    return Path(__file__).resolve().parents[2] / "bin"


def _free_port() -> int:
    """A port nobody is listening on, as of a moment ago.

    The standard small race: something else could take it between the close
    here and the server's bind. `_start_server` retries, and the server itself
    sets SO_REUSEADDR but *not* SO_REUSEPORT, so a genuine collision fails
    loudly at bind rather than silently sharing the port.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _file_digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _encode_multipart(parts: list[tuple[str, str, str, bytes]]) -> tuple[str, bytes]:
    """(name, filename, content_type, body) parts -> (content-type, body)."""
    out = bytearray()
    for name, filename, ctype, data in parts:
        out += f"--{_UPLOAD_BOUNDARY}\r\n".encode()
        out += (f'Content-Disposition: form-data; name="{name}"; '
                f'filename="{filename}"\r\n').encode()
        out += f"Content-Type: {ctype}\r\n\r\n".encode()
        out += data
        out += b"\r\n"
    out += f"--{_UPLOAD_BOUNDARY}--\r\n".encode()
    return (f"multipart/form-data; boundary={_UPLOAD_BOUNDARY}", bytes(out))


def _parse_multipart(body: bytes) -> list[tuple[dict[str, str], bytes]]:
    """Split a `multipart/mixed; boundary=ace-batch-boundary` response.

    One audio part and one `latent` part per generated track, paired in wire
    order. Not a general MIME parser: the boundary is a fixed ASCII token the
    server never negotiates, which is the same assumption every multipart
    reader makes about its own boundary.
    """
    parts: list[tuple[dict[str, str], bytes]] = []
    for chunk in body.split(_BOUNDARY):
        chunk = chunk.lstrip(b"\r\n")
        if not chunk or chunk.startswith(b"--"):
            continue  # preamble or the closing "--"
        head, sep, data = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        headers = {}
        for line in head.decode("latin-1").splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()
        parts.append((headers, data[:-2] if data.endswith(b"\r\n") else data))
    return parts


class AceStepCppAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.models_dir: str | None = None
        self.adapters_dir: str | None = None
        self._proc: subprocess.Popen | None = None
        self._port: int | None = None
        self._tail: deque[str] = deque(maxlen=40)
        # Whatever the current phase wants done with each stderr line. One job
        # at a time in the supervisor, one worker thread in the server, so a
        # single slot is the whole of the synchronisation needed.
        self._line_cb = None
        # The (DiT, adapter, scale) the running server has actually loaded, or
        # None while it holds nothing. See the module docstring.
        self._resident_key: tuple[str, str, float] | None = None
        # One source file's VAE latents, keyed by content digest. One entry is
        # enough for the flow this pays for: the same track covered or extended
        # several times in a row.
        self._latent: tuple[str, bytes] | None = None
        self._atexit_registered = False

    # MARK: lifecycle

    @property
    def _runtime(self) -> str:
        return str(self.settings.get("runtime") or "server")

    @property
    def _keep_loaded(self) -> bool:
        return bool(self.settings.get("keep_loaded", True))

    @property
    def _pidfile(self) -> str:
        return os.path.join(self.work_dir, "ace-server.pid")

    def load(self, progress_cb: ProgressCb) -> None:
        bin_dir = _bin_dir()
        tools = (("ace-server",) if self._runtime == "server"
                 else ("ace-lm", "ace-synth"))
        for tool in tools:
            if not os.access(bin_dir / tool, os.X_OK):
                raise RuntimeError(
                    f"acestep.cpp binary missing: {bin_dir / tool} — run "
                    f"scripts/build_acestep_cpp.sh (needs cmake)")
        # By repo id, not "the first one": an entry that also declares LoRA
        # repos has several snapshots and only one of them holds the GGUFs.
        self.models_dir = next(
            (path for repo, path in self.model_paths.items()
             if "GGUF" in repo or "gguf" in repo),
            next(iter(self.model_paths.values())))
        for key in ("lm_model", "synth_model", "vae"):
            name = self.settings.get(key)
            if name and not os.path.exists(os.path.join(self.models_dir, name)):
                raise RuntimeError(f"model file missing from snapshot: {name}")
        self.adapters_dir = self._stage_adapters()
        # Before the runtime branch, not inside it: a server stranded by a
        # previous session is holding ~10 GB whichever runtime *this* entry
        # uses, and reclaiming it costs one file read.
        self._kill_stale_server()
        if self._runtime != "server":
            progress_cb(None, "acestep.cpp ready (models load per generation)")
            return
        progress_cb(None, "starting the acestep.cpp server")
        self._start_server()
        progress_cb(None, "acestep.cpp server ready"
                          + (" (models stay resident)" if self._keep_loaded else ""))

    def unload(self) -> None:
        self._stop_server()
        self._latent = None

    def _stage_adapters(self) -> str | None:
        """Give the binary an adapters directory it can scan, or None.

        `registry_scan_adapters` identifies an adapter by its FILENAME, and
        every LoRA snapshot on the Hub calls its weights `model.safetensors` —
        so four snapshots would present as four copies of one name. Symlinking
        each into a directory of our own under the name the catalog uses is
        the whole trick, and it is also what lets the catalog's enum values be
        readable words rather than repo ids.
        """
        loras = {key: os.path.join(path, "model.safetensors")
                 for key, repo in (self.settings.get("adapters") or {}).items()
                 for name, path in self.model_paths.items() if name == repo}
        loras = {k: v for k, v in loras.items() if os.path.exists(v)}
        if not loras:
            return None
        staged = os.path.join(self.work_dir, "adapters")
        os.makedirs(staged, exist_ok=True)
        for key, source in loras.items():
            link = os.path.join(staged, f"{key}.safetensors")
            clear_stale_link(link)
            if not os.path.exists(link):
                try:
                    os.symlink(source, link)
                except OSError:
                    pass
        return staged

    # MARK: the server process

    def _start_server(self) -> None:
        assert self.models_dir is not None
        bin_dir = _bin_dir()
        last_error = ""
        for _attempt in range(3):
            port = _free_port()
            cmd = [str(bin_dir / "ace-server"),
                   "--models", self.models_dir,
                   "--host", "127.0.0.1", "--port", str(port)]
            if self.adapters_dir:
                cmd += ["--adapters", self.adapters_dir]
            if self._keep_loaded:
                cmd += ["--keep-loaded"]
            self._tail.clear()
            # No start_new_session: staying in the worker's process group is
            # what lets the supervisor's killpg (worker.py `kill`) and the
            # parent watchdog's killpg reach this process. Detaching it would
            # strand 8–12 GB of resident models on every hard kill.
            proc = subprocess.Popen(cmd, cwd=self.work_dir,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, text=True,
                                    bufsize=1)
            self._proc, self._port = proc, port
            threading.Thread(target=self._read_stderr, args=(proc,),
                             daemon=True).start()
            if self._wait_ready():
                self._write_pidfile()
                if not self._atexit_registered:
                    atexit.register(self._stop_server)
                    self._atexit_registered = True
                return
            last_error = " | ".join(list(self._tail)[-3:])
            self._stop_server()
        raise RuntimeError(f"ace-server did not start: {last_error}")

    def _wait_ready(self) -> bool:
        deadline = time.monotonic() + _START_TIMEOUT_S
        while time.monotonic() < deadline:
            proc = self._proc
            if proc is None or proc.poll() is not None:
                return False
            try:
                self._get("/health", timeout=2.0)
                return True
            except (urllib.error.URLError, OSError):
                time.sleep(0.1)
        return False

    def _stop_server(self) -> None:
        proc, self._proc = self._proc, None
        self._port = None
        self._resident_key = None
        if proc is not None and proc.poll() is None:
            # SIGTERM is handled: `on_signal` stops the listener, the worker
            # thread finishes its current job, and `store_free` releases the
            # models. SIGKILL only if that does not happen.
            try:
                proc.terminate()
            except OSError:
                pass
            deadline = time.monotonic() + _STOP_GRACE_S
            while proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if proc.poll() is None:
                try:
                    proc.kill()
                except OSError:
                    pass
            try:  # reap it, so the worker never accumulates zombies
                proc.wait(timeout=2.0)
            except (OSError, subprocess.TimeoutExpired):
                pass
        self._clear_pidfile()

    def _ensure_server(self, key: tuple[str, str, float]) -> None:
        """One DiT resident at a time (module docstring, hazard 1)."""
        proc = self._proc
        if proc is not None and proc.poll() is None:
            if (not self._keep_loaded or self._resident_key is None
                    or self._resident_key == key):
                self._resident_key = key
                return
            was, now = self._resident_key, key
            print(f"[acestep.cpp] restarting the server: the model it holds "
                  f"({was[0]}, adapter {was[1] or 'none'} @ {was[2]:.2f}) is "
                  f"not the one this take needs ({now[0]}, adapter "
                  f"{now[1] or 'none'} @ {now[2]:.2f})",
                  file=sys.stderr, flush=True)
        self._stop_server()
        self._start_server()
        # Recorded on the way in, not on the way out. A take that fails after
        # the DiT has loaded would otherwise leave this at None, and the next
        # take with a *different* key would see "nothing resident", skip the
        # restart, and pin a second DiT beside the first — the exact
        # accumulation the restart exists to prevent. The cost of being
        # pessimistic is one unnecessary restart after a failure that never
        # loaded anything; the cost of being optimistic is 5 GB.
        self._resident_key = key

    def _read_stderr(self, proc: subprocess.Popen) -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            line = line.rstrip()
            if not line:
                continue
            self._tail.append(line)
            # Forward before parsing, for the same reason the CLI path did:
            # these are the richest per-step lines any family in this app
            # produces, the worker's stderr is mirrored to the render card's
            # log pane (contract §6), and this is the only thing standing
            # between the two.
            print(line, file=sys.stderr, flush=True)
            handler = self._line_cb
            if handler is None:
                continue
            try:
                handler(line)
            except Exception:  # noqa: BLE001
                # A progress callback raises CancelledError when the job has
                # been cancelled; that unwinds the *generate* call, and there
                # is nothing for it to unwind here. `_await` reads the cancel
                # token itself, so dropping it costs nothing and keeps the
                # reader alive for the shutdown lines.
                pass

    def _write_pidfile(self) -> None:
        try:
            with open(self._pidfile, "w") as f:
                json.dump({"pid": self._proc.pid if self._proc else None,
                           "port": self._port, "started": time.time()}, f)
        except OSError:
            pass

    def _clear_pidfile(self) -> None:
        try:
            os.unlink(self._pidfile)
        except OSError:
            pass

    def _kill_stale_server(self) -> None:
        """Reclaim a server left behind by a worker that died without unwinding.

        The identity check matters more than the kill: pids are reused, and the
        one thing worse than 12 GB of stranded models is SIGKILLing a stranger.
        """
        try:
            with open(self._pidfile) as f:
                pid = int(json.load(f).get("pid") or 0)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            self._clear_pidfile()
            return
        if pid > 0 and self._is_our_server(pid):
            print(f"[acestep.cpp] killing a leftover ace-server (pid {pid})",
                  file=sys.stderr, flush=True)
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                self._clear_pidfile()
                return
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except OSError:
                    break
                time.sleep(0.1)
            else:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        self._clear_pidfile()

    @staticmethod
    def _is_our_server(pid: int) -> bool:
        ps = shutil.which("ps")
        if not ps:
            return False
        try:
            out = subprocess.run([ps, "-p", str(pid), "-o", "command="],
                                 capture_output=True, text=True, timeout=5.0)
        except (OSError, subprocess.SubprocessError):
            return False
        return "ace-server" in out.stdout

    # MARK: HTTP

    def _url(self, path: str) -> str:
        return f"http://127.0.0.1:{self._port}{path}"

    def _get(self, path: str, timeout: float = 30.0) -> bytes:
        with urllib.request.urlopen(self._url(path), timeout=timeout) as r:
            return r.read()

    def _post(self, path: str, data: bytes, content_type: str,
              timeout: float = 600.0) -> bytes:
        req = urllib.request.Request(self._url(path), data=data, method="POST")
        req.add_header("Content-Type", content_type)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()

    def _post_job(self, path: str, data: bytes, content_type: str) -> str:
        try:
            body = self._post(path, data, content_type)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"ace-server rejected the request: "
                               f"{self._http_error(e)}") from None
        job_id = json.loads(body).get("id")
        if not job_id:
            raise RuntimeError("ace-server returned no job id")
        return str(job_id)

    @staticmethod
    def _http_error(e: urllib.error.HTTPError) -> str:
        try:
            return str(json.loads(e.read()).get("error") or e.reason)
        except Exception:  # noqa: BLE001 — an error path must not raise
            return str(e.reason)

    def _await(self, job_id: str, cancel: CancelToken) -> tuple[str, bytes]:
        """Poll one job to a terminal state, then fetch its result.

        Cancel is cooperative here, which is the headline of the swap: the
        pipelines poll the job's flag between steps, the process survives, and
        the models it holds stay loaded for the next take.
        """
        cancel_deadline: float | None = None
        while True:
            proc = self._proc
            if proc is None or proc.poll() is not None:
                raise RuntimeError(
                    "the acestep.cpp server exited mid-job: "
                    + " | ".join(list(self._tail)[-3:]))
            if cancel.cancelled and cancel_deadline is None:
                cancel_deadline = time.monotonic() + _CANCEL_GRACE_S
                try:
                    self._post(f"/job?id={job_id}&cancel=1", b"",
                               "application/json", timeout=10.0)
                except (urllib.error.URLError, OSError):
                    pass
            try:
                status = json.loads(self._get(f"/job?id={job_id}"))["status"]
            except urllib.error.HTTPError as e:
                # A status the server answered, not a transport hiccup: a job
                # it has forgotten will never appear, so retrying is a hang.
                raise RuntimeError(f"ace-server lost the job: "
                                   f"{self._http_error(e)}") from None
            except (urllib.error.URLError, OSError):
                # The socket went away between the liveness check above and
                # this call; go round again and let that check say why.
                time.sleep(_POLL_S)
                continue
            if status == "done":
                req = urllib.request.Request(self._url(f"/job?id={job_id}&result=1"))
                with urllib.request.urlopen(req, timeout=600.0) as r:
                    return r.headers.get("Content-Type", ""), r.read()
            if status == "cancelled":
                raise CancelledError()
            if status == "failed":
                raise RuntimeError("acestep.cpp failed: "
                                   + " | ".join(list(self._tail)[-3:]))
            if cancel_deadline is not None and time.monotonic() > cancel_deadline:
                # It did not stop where it promised to. Take the process rather
                # than the worker: the models are the server's, not ours.
                self._stop_server()
                raise CancelledError()
            time.sleep(_POLL_S)

    # MARK: generation

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.models_dir is not None
        duration_s = float(params.get("duration_s", 60.0))
        seed = params.get("seed")
        # Drawn here rather than left at -1 for the runtime to resolve, so that
        # every take reports a seed that reproduces it. The runtime resolves
        # `seed` and `lm_seed` independently, so an unpinned text2music take
        # used to report a DiT seed that could not reproduce its own *plan*;
        # and the source-audio tasks, which skip the LM, reported no seed at
        # all because nothing wrote the resolved value anywhere we read.
        # Range matches AceRequest's documented [0, UINT32_MAX].
        seed = int(seed) if seed is not None else random.randrange(0, 1 << 32)

        # The six source-audio tasks. Every one of them exists in the binary's
        # own request schema and dispatch table (`pipeline-synth.cpp`), and
        # none was reachable: the adapter only ever sent text2music.
        task_type = str(params.get("task_type") or "text2music")
        src_audio = params.get("src_audio")
        src_audio = src_audio if src_audio and os.path.isfile(src_audio) else None
        ref_audio = params.get("reference_audio")
        ref_audio = ref_audio if ref_audio and os.path.isfile(ref_audio) else None
        if task_type != "text2music" and src_audio is None:
            raise RuntimeError(
                f"'{task_type}' works on existing audio — add a source file")

        request = {
            "caption": prompt,
            "lyrics": lyrics or "",
            "duration": duration_s,
            "seed": seed,
            "lm_seed": seed,
            "inference_steps": int(params.get("steps", 0)),
            "guidance_scale": float(params.get("guidance_scale", 0.0)),
            "use_cot_caption": bool(params.get("thinking", True)),
            "output_format": "wav16",
            "task_type": task_type,
            "lm_model": self.settings.get("lm_model", ""),
            "synth_model": self.settings.get("synth_model", ""),
            "vae": self.settings.get("vae", ""),
        }
        if params.get("bpm"):
            request["bpm"] = int(params["bpm"])
        # Facts the composer LM would otherwise invent, and the planner's own
        # sampler — the same surface the Python ACE-Step family exposes, which
        # this runtime had in its request struct all along.
        for key in ("keyscale", "timesignature", "vocal_language", "track"):
            value = str(params.get(key) or "").strip()
            if value:
                request[key] = value
        for key in ("lm_temperature", "lm_cfg_scale", "lm_top_p"):
            if params.get(key) is not None:
                request[key] = float(params[key])
        negative = str(params.get("negative_prompt") or "").strip()
        if negative:
            # The LM's negative branch, not the DiT's: this steers the plan
            # (what the song is) rather than the render (how it sounds).
            request["lm_negative_prompt"] = negative
        if params.get("audio_cover_strength") is not None:
            request["audio_cover_strength"] = float(
                params["audio_cover_strength"])
        if params.get("repainting_start") is not None:
            request["repainting_start"] = float(params["repainting_start"])
        if params.get("repainting_end") is not None:
            request["repainting_end"] = float(params["repainting_end"])

        # LoRA. The runtime merges the adapter into the quantised GGUF weights
        # before upload (`adapter-merge.h`, which names Q8_0 and the K-quants
        # explicitly), so this is a real merge and not a second model.
        adapter = str(params.get("adapter") or "").strip()
        if adapter and adapter != "none":
            if not self.adapters_dir:
                raise RuntimeError(
                    "this model has no LoRA pack installed — reinstall the "
                    "entry to fetch it")
            request["adapter"] = f"{adapter}.safetensors"
            # `or 1.0` ate a legal 0.0 — the bottom of the declared 0.0-2.0
            # range, and the one value that means "merge nothing" — and sent
            # full strength instead (audit 09-B4).
            scale = params.get("adapter_scale")
            request["adapter_scale"] = float(scale) if scale is not None else 1.0

        lm_total = max(1, int(duration_s * LM_CODE_RATE))

        def lm_progress(line: str) -> None:
            if m := _LM1_RE.search(line):
                # pass 1 prints a step number but no total (the CoT metadata
                # runs to an end token), so it reports the phase alone
                progress_cb(0.05, f"language model: pass 1 (step {m.group(1)})",
                            phase="lm_reasoning")
            elif m := _LM2_RE.search(line):
                step = int(m.group(1))
                frac = min(1.0, step / lm_total)
                # `step` is read straight out of the tool; `lm_total` is a
                # projection from the requested duration, which the `min(1.0,
                # ...)` two lines up already admits `step` can exceed. It is
                # good enough to drive a fraction and not good enough to print
                # as a total, so the phase carries the step alone — the same
                # way pass 1 above drops what it does not know. (`_DIT_RE`
                # below is the honest shape: the tool prints its own total.)
                progress_cb(0.1 + 0.45 * frac,
                            f"language model: composing ({step} codes)",
                            phase="lm_reasoning", step=step)

        def synth_progress(line: str) -> None:
            if m := _DIT_RE.search(line):
                step, total = int(m.group(1)), max(1, int(m.group(2)))
                progress_cb(0.55 + 0.4 * min(1.0, step / total),
                            f"denoising: step {step}/{total}",
                            phase="diffusion", step=step, steps=total)
            elif "[VAE]" in line:
                # The binary announces the decode as "[VAE] Tiled decode:" /
                # "[VAE] Decoded:" — the old "[Ace-Synth] … Write" match
                # never fired, so the UI parked on Diffusion through the
                # whole decode (audit §5).
                progress_cb(0.97, "decoding audio", phase="vocoder")

        runner = (self._run_server if self._runtime == "server" else self._run_cli)
        seed_used = runner(request, task_type, src_audio, ref_audio, out_path,
                           lm_progress, synth_progress, progress_cb, cancel)

        # The fp16 weight-norm vocoder failure mode is an all-NaN latent
        # written as a silent WAV that passes every existence check
        # (audit §3) — fail loudly instead of shipping silence.
        check, _sr = sf.read(out_path, dtype="float32", always_2d=True)
        if check.size and float(abs(check).max()) < 1e-5:
            raise RuntimeError(
                "the vocoder produced silence (a known fp16 overflow "
                "symptom) — try the render again; if it repeats, report "
                "the model variant")
        progress_cb(1.0, "writing audio", phase="master")
        info = sf.info(out_path)
        return GenerateResult(wav_path=out_path,
                              duration_s=float(info.frames) / info.samplerate,
                              sample_rate=int(info.samplerate),
                              seed_used=int(seed_used) if seed_used >= 0 else None)

    def _run_server(self, request: dict, task_type: str, src_audio: str | None,
                    ref_audio: str | None, out_path: str, lm_progress,
                    synth_progress, progress_cb: ProgressCb,
                    cancel: CancelToken) -> int:
        # Same `is not None` rule as the request above, and it matters more
        # here: this key decides whether the resident server is restarted, so
        # coercing 0.0 to 1.0 collided two different merged-weight sets into
        # one key and kept the wrong DiT loaded (audit 09-B4).
        scale = request.get("adapter_scale")
        key = (str(request.get("synth_model") or ""),
               str(request.get("adapter") or ""),
               float(scale) if scale is not None else 1.0)
        self._ensure_server(key)

        if task_type == "text2music":
            self._line_cb = lm_progress
            try:
                job = self._post_job("/lm", json.dumps(request).encode(),
                                     "application/json")
                _mime, body = self._await(job, cancel)
            finally:
                self._line_cb = None
            plans = json.loads(body)
            if not plans:
                raise RuntimeError("the composer produced no plan")
            # The enriched request the LM wrote: metadata, lyrics, audio codes
            # and the resolved seeds, which is the handoff `request0.json`
            # performs on the CLI path.
            synth_request = plans[0]
        else:
            # The source-audio tasks skip the composer entirely — the plan is
            # the audio you handed over, and the DiT reads its codes from the
            # source. The Python family does the same, for the same reason.
            progress_cb(0.05, f"reading the source ({task_type})",
                        phase="lm_reasoning")
            synth_request = request

        self._line_cb = synth_progress
        try:
            parts: list[tuple[str, str, str, bytes]] = []
            if src_audio:
                latents = self._source_latents(src_audio, task_type, cancel,
                                               progress_cb)
                if latents is not None:
                    parts.append(("src_latents", "source.vae",
                                  "application/octet-stream", latents))
                else:
                    with open(src_audio, "rb") as f:
                        parts.append(("audio", os.path.basename(src_audio),
                                      "application/octet-stream", f.read()))
            if ref_audio:
                with open(ref_audio, "rb") as f:
                    parts.append(("ref_audio", os.path.basename(ref_audio),
                                  "application/octet-stream", f.read()))
            payload = json.dumps(synth_request).encode()
            if parts:
                ctype, data = _encode_multipart(
                    [("request", "request.json", "application/json", payload)]
                    + parts)
            else:
                ctype, data = "application/json", payload
            job = self._post_job("/synth", data, ctype)
            _mime, body = self._await(job, cancel)
        finally:
            self._line_cb = None

        audio = next((data for headers, data in _parse_multipart(body)
                      if headers.get("content-type", "").startswith("audio/")),
                     None)
        if not audio:
            raise RuntimeError("ace-server returned no audio")
        tmp = out_path + ".part"
        with open(tmp, "wb") as f:
            f.write(audio)
        os.replace(tmp, out_path)
        return int(synth_request.get("seed", -1))

    def _source_latents(self, path: str, task_type: str, cancel: CancelToken,
                        progress_cb: ProgressCb) -> bytes | None:
        """The source file's VAE latents, encoded once and kept.

        `/synth` would encode the same file again for every take; `/vae` does
        it once and hands back bytes we can send instead, and the pipeline says
        so — "[Encode-Src] Latents in: …, VAE encode skipped". The first take
        pays exactly what it paid before (one encode, in a job of its own);
        every later take on the same source pays nothing.

        Returns None when the source must travel as audio — see `_LATENT_TASKS`
        — or when the encode did not produce a usable buffer, in which case the
        caller falls back to sending the file and nothing is lost but the
        cache.
        """
        if task_type not in _LATENT_TASKS:
            return None
        try:
            digest = _file_digest(path)
        except OSError:
            return None
        if self._latent is not None and self._latent[0] == digest:
            progress_cb(0.06, "reusing the source latents",
                        phase="lm_reasoning")
            return self._latent[1]
        progress_cb(0.06, "encoding the source", phase="lm_reasoning")
        try:
            with open(path, "rb") as f:
                audio = f.read()
            ctype, data = _encode_multipart([
                ("request", "request.json", "application/json",
                 json.dumps({"vae": self.settings.get("vae", "")}).encode()),
                ("audio", os.path.basename(path), "application/octet-stream",
                 audio)])
            job = self._post_job("/vae", data, ctype)
            _mime, body = self._await(job, cancel)
        except CancelledError:
            raise
        except (RuntimeError, OSError, urllib.error.URLError,
                json.JSONDecodeError):
            return None
        # An empty or ragged body is not a latent buffer. Checked rather than
        # trusted: a fallback that only fires on an exception is a fallback
        # that does not fire.
        if not body or len(body) % _LATENT_FRAME_BYTES != 0:
            return None
        self._latent = (digest, body)
        return body

    # MARK: the CLI runtime (rollback path)

    def _run_cli(self, request: dict, task_type: str, src_audio: str | None,
                 ref_audio: str | None, out_path: str, lm_progress,
                 synth_progress, progress_cb: ProgressCb,
                 cancel: CancelToken) -> int:
        assert self.models_dir is not None
        bin_dir = _bin_dir()
        req_path = os.path.join(self.work_dir, "request.json")
        with open(req_path, "w") as f:
            json.dump(request, f)

        if task_type == "text2music":
            self._run_tool([str(bin_dir / "ace-lm"),
                            "--models", self.models_dir,
                            "--request", req_path],
                           lm_progress, cancel, "ace-lm")
            codes_path = os.path.join(self.work_dir, "request0.json")
            if not os.path.exists(codes_path):
                raise RuntimeError("ace-lm produced no output request")
        else:
            progress_cb(0.05, f"reading the source ({task_type})",
                        phase="lm_reasoning")
            codes_path = req_path

        synth_cmd = [str(bin_dir / "ace-synth"),
                     "--models", self.models_dir, "--request", codes_path]
        if src_audio:
            synth_cmd += ["--src-audio", src_audio]
        if ref_audio:
            synth_cmd += ["--ref-audio", ref_audio]
        if self.adapters_dir and request.get("adapter"):
            synth_cmd += ["--adapters", self.adapters_dir]
        self._run_tool(synth_cmd, synth_progress, cancel, "ace-synth")

        # ace-synth names its output `<request basename><index>.wav`, so which
        # request it was handed decides the filename: `request0.json` from the
        # LM gives `request00.wav`, the original `request.json` gives
        # `request0.wav`.
        wav_src = os.path.splitext(codes_path)[0] + "0.wav"
        if not os.path.exists(wav_src):
            raise RuntimeError("ace-synth produced no audio")
        os.replace(wav_src, out_path)
        with open(codes_path) as f:
            return int(json.load(f).get("seed", -1))

    def _run_tool(self, cmd: list[str], on_line, cancel: CancelToken,
                  name: str) -> None:
        proc = subprocess.Popen(cmd, cwd=self.work_dir,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True, bufsize=1)
        tail: list[str] = []
        assert proc.stderr is not None
        try:
            for line in proc.stderr:
                if cancel.cancelled:
                    proc.kill()
                    raise CancelledError()
                line = line.rstrip()
                if line:
                    tail = (tail + [line])[-8:]
                    # Forward before parsing. These are the richest per-step
                    # lines any family in this app produces — `[DiT] Step 6/8`,
                    # the LM's own counters — and until now they were read for
                    # their numbers and then dropped on the floor, so the one
                    # runtime with real output had the emptiest log pane. The
                    # worker's stderr is mirrored to that pane (contract §6);
                    # this is the only thing standing between the two.
                    print(line, file=sys.stderr, flush=True)
                    on_line(line)
            proc.wait()
        finally:
            if proc.poll() is None:
                proc.kill()
        if cancel.cancelled:
            raise CancelledError()
        if proc.returncode != 0:
            raise RuntimeError(f"{name} failed (exit {proc.returncode}): "
                               + " | ".join(tail[-3:]))

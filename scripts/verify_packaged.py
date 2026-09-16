#!/usr/bin/env python3
"""First-run verification of the PACKAGED app's engine.

Spawns build/LocalMusicGen.app's bundled engine shim against an empty data dir — the
same thing the app does on a fresh machine: sources copied out of the bundle, uv
installs CPython 3.11, the supervisor venv syncs, then a real download + generation
runs through a freshly provisioned adapter venv. Slow on first run by design.
"""

from __future__ import annotations

import json
import os
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from contractlib import Client, SSEListener, check, report  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# build.sh's APP_PATH. This pointed at a `dist/` folder that no build has
# written and told you to run a script that does not exist, so
# `make verify-packaged` — the only first-run test of the packaged engine —
# failed before it started, every time.
SHIM = os.path.join(ROOT, "build", "LocalMusicGen.app", "Contents", "Resources",
                    "backend", "bin", "local-music-gen-engine")


def main() -> int:
    if not os.path.exists(SHIM):
        print(f"no packaged app at {SHIM}: run ./build.sh first")
        return 1
    tmp = tempfile.mkdtemp(prefix="localmusicgen-packaged-")
    handshake = os.path.join(tmp, "hs.json")
    token = secrets.token_hex(16)
    proc = subprocess.Popen(
        [SHIM, "--handshake-file", handshake, "--parent-pid", str(os.getpid()),
         "--data-dir", os.path.join(tmp, "data"),
         "--output-dir", os.path.join(tmp, "outputs"),
         "--log-level", "warning"],
        env={**os.environ, "LOCALMUSICGEN_AUTH_TOKEN": token,
             "LOCALMUSICGEN_TEST_CATALOG": "1"},
        stderr=subprocess.STDOUT, stdout=subprocess.PIPE, text=True)

    try:
        print("• first-run bootstrap (python install + supervisor venv — minutes)")
        deadline = time.time() + 900
        while not os.path.exists(handshake) and time.time() < deadline:
            if proc.poll() is not None:
                print(proc.stdout.read()[-3000:])
                check("bundled engine started", False)
                return report()
            time.sleep(0.5)
        check("handshake appears", os.path.exists(handshake))
        if not os.path.exists(handshake):
            return report()
        hs = json.load(open(handshake))
        c = Client(hs["port"], token)
        status, _ = c.req("GET", "/healthz", auth=False)
        check("healthz OK", status == 200)
        check("sources copied out of bundle",
              os.path.isdir(os.path.join(tmp, "data", "engine-src", "adapters")))
        check("python installed under data dir",
              os.path.isdir(os.path.join(tmp, "data", "python")))

        sse = SSEListener(hs["port"], token)
        sse.start()
        print("• download + generate through fresh adapter venv (first run: slow)")
        status, _ = c.req("POST", "/v1/models/test-tiny/download")
        # the install now builds the family's venv before fetching weights
        # (contract 4.2), so this wait covers a cold torch sync — minutes on a
        # fresh machine, and it used to be charged to the job below instead
        done = sse.wait_for("download.completed", 1800,
                            lambda d: d["model_id"] == "test-tiny")
        check("download completes", done is not None)
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["test-tiny"], "prompt": "packaged smoke",
            "duration_s": 2})
        check("job accepted", status == 202)
        job_id = body["jobs"][0]["job_id"]
        outcome = None
        end = time.time() + 1800
        while time.time() < end:
            if sse.wait_for("job.completed", 2, lambda d: d["job_id"] == job_id):
                outcome = "ok"
                break
            failed = sse.wait_for("job.failed", 0.1,
                                  lambda d: d["job_id"] == job_id)
            if failed:
                outcome = str(failed.get("error"))
                break
        check("generation completes in packaged engine", outcome == "ok",
              str(outcome))
        wav_path = None
        if outcome == "ok":
            _, job = c.req("GET", f"/v1/jobs/{job_id}")
            wav_path = job["result"]["outputs"][0]["path"]
            with wave.open(wav_path) as w:
                dur = w.getnframes() / w.getframerate()
            check("output WAV valid",
                  os.path.getsize(wav_path) > 1000 and dur > 0.5)

        print("• task job through fresh dsp venv (weightless install)")
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/models/test-split/download")
        # weightless, so this wait is entirely the dsp venv being built
        done = sse.wait_for("download.completed", 900,
                            lambda d: d["model_id"] == "test-split", since=mark)
        check("weightless task model installs", status == 202 and done)
        if wav_path:
            with open(wav_path, "rb") as f:
                wav_bytes = f.read()
            status, up = c.req_raw("POST", "/v1/uploads?filename=in.wav",
                                   wav_bytes)
            check("upload for mix accepted", status == 201)
            spec = json.dumps({"target": {"sample_rate": 32000},
                               "tracks": [{"source": up["upload_id"],
                                           "role": "a",
                                           "stretch": {"mode": "none"}}]})
            status, body = c.req("POST", "/v1/jobs", {
                "model_ids": ["test-split"], "task": "mix",
                "params": {"mix_spec": spec}})
            check("mix job accepted", status == 202)
            mix_id = body["jobs"][0]["job_id"]
            mix_outcome = None
            end = time.time() + 900
            while time.time() < end:
                if sse.wait_for("job.completed", 2,
                                lambda d: d["job_id"] == mix_id):
                    mix_outcome = "ok"
                    break
                failed = sse.wait_for("job.failed", 0.1,
                                      lambda d: d["job_id"] == mix_id)
                if failed:
                    mix_outcome = str(failed.get("error"))
                    break
            check("mix task completes in packaged engine (dsp venv provisions)",
                  mix_outcome == "ok", str(mix_outcome))
            if mix_outcome == "ok":
                _, job = c.req("GET", f"/v1/jobs/{mix_id}")
                arts = (job.get("result") or {}).get("artifacts") or []
                check("mix artifact valid",
                      len(arts) == 1 and arts[0]["kind"] == "audio"
                      and os.path.getsize(arts[0]["path"]) > 1000)
        sse.stop()

        status, _ = c.req("POST", "/v1/shutdown")
        try:
            proc.wait(timeout=15)
            check("clean shutdown", True)
        except subprocess.TimeoutExpired:
            check("clean shutdown", False)
        return report()
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())

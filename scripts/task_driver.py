#!/usr/bin/env python3
"""Generic task-job driver for tasks smoke_test.py doesn't cover.

Usage: task_driver.py --model ID --task TASK [--file key=path ...] [--param key=jsonvalue ...]
Boots its own engine (like smoke_test), submits, follows SSE, prints progress
events, artifacts and result meta. Exit 0 iff the job completed.
"""
import argparse, json, os, secrets, signal, subprocess, sys, time
from urllib.parse import quote

ROOT = "/Users/nwf/build/local-music-gen/src"
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from contractlib import Client, SSEListener  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--model", required=True)
ap.add_argument("--task", required=True)
ap.add_argument("--file", action="append", default=[], help="param key=path (uploaded)")
ap.add_argument("--param", action="append", default=[], help="param key=jsonvalue")
ap.add_argument("--timeout", type=float, default=1800)
args = ap.parse_args()

token = secrets.token_hex(16)
data_dir = os.path.expanduser("~/Library/Application Support/LocalMusicGen")
hs_path = os.path.join(data_dir, "Backend", "audit-task-handshake.json")
if os.path.exists(hs_path):
    os.unlink(hs_path)
proc = subprocess.Popen(
    ["uv", "run", "local-music-gen-engine", "--handshake-file", hs_path,
     "--parent-pid", str(os.getpid()), "--data-dir", data_dir,
     "--output-dir", os.path.join(data_dir, "Outputs"), "--log-level", "warning"],
    cwd=os.path.join(ROOT, "engine", "supervisor"),
    env={**os.environ, "LOCALMUSICGEN_AUTH_TOKEN": token},
    stdout=subprocess.DEVNULL)
try:
    deadline = time.time() + 60
    while not os.path.exists(hs_path) and time.time() < deadline:
        if proc.poll() is not None:
            print("engine died"); sys.exit(1)
        time.sleep(0.2)
    hs = json.load(open(hs_path))
    c = Client(hs["port"], token)
    sse = SSEListener(hs["port"], token)
    sse.start()

    params = {}
    for kv in args.file:
        k, _, p = kv.partition("=")
        with open(p, "rb") as f:
            data = f.read()
        st, up = c.req_raw("POST", f"/v1/uploads?filename={quote(os.path.basename(p))}", data)
        assert st == 201, (st, up)
        params[k] = up["upload_id"]
    for kv in args.param:
        k, _, v = kv.partition("=")
        # "{key}" placeholders inside string params resolve to that upload id
        for fk, fid in params.items():
            if isinstance(fid, str):
                v = v.replace("{%s}" % fk, fid)
        try:
            params[k] = json.loads(v)
        except json.JSONDecodeError:
            params[k] = v

    st, resp = c.req("POST", "/v1/jobs",
                     {"model_ids": [args.model], "task": args.task, "params": params})
    if st != 202:
        print("SUBMIT FAILED:", st, json.dumps(resp)); sys.exit(1)
    job_id = resp["jobs"][0]["job_id"]
    print("job", job_id)

    seen, last = 0, ""
    end = time.time() + args.timeout
    outcome = None
    while time.time() < end:
        done = sse.wait_for("job.completed", 2, lambda d: d["job_id"] == job_id)
        if done is not None:
            outcome = "completed"; break
        failed = sse.wait_for("job.failed", 0.1, lambda d: d["job_id"] == job_id)
        if failed is not None:
            outcome = f"FAILED: {failed.get('error')}"; break
        with sse.lock:
            chunk = list(sse.events[seen:]); seen = len(sse.events)
        for _, e, d in chunk:
            if e == "job.progress" and d.get("job_id") == job_id:
                msg = f"{d.get('fraction')} {d.get('message')}"
                if msg != last:
                    last = msg
                    print("  prog:", msg)
    print("outcome:", outcome)
    if outcome != "completed":
        sys.exit(1)
    _, job = c.req("GET", f"/v1/jobs/{job_id}")
    res = job.get("result") or {}
    for a in res.get("artifacts") or []:
        sz = os.path.getsize(a["path"]) if os.path.exists(a["path"]) else -1
        print(f"  artifact: {a['kind']}/{a['label']} {a['format']} {sz}B -> {a['path']}")
    meta = res.get("meta") or {}
    if meta:
        print("  meta:", json.dumps(meta)[:600])
    sys.exit(0)
finally:
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

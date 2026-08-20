"""JSONL messages exchanged between supervisor and worker over stdio.

One JSON object per line. Supervisor → worker: load / generate / task / cancel /
shutdown. Worker → supervisor: ready / loaded / progress / preview / result /
task_result / error (plus the mem sampler's "mem").

`preview` carries `path` / `sample_rate` / `duration_s` / `step` for a partial
take the adapter has decoded mid-render. It is not terminal: a job may send any
number of them, or none, and one is only ever sent when the job asked for
previews.

`progress` carries `progress` (null when the adapter does not know) and `message`,
plus the optional staged fields `phase` / `step` / `steps`. Those three are
omitted rather than nulled when the adapter did not supply them, so "this phase
counts no steps" stays distinguishable from "step 0".

`mem` carries whichever of `bytes` / `backend` / `working_set_bytes` the worker
can see: a CPU-only worker names its backend and has no byte count, and an
absent field never overwrites what the supervisor already knows.
"""

from __future__ import annotations

import json
import sys
import threading
from typing import IO, Any

# The worker writes from more than one thread (protocol loop + memory sampler);
# a torn line would corrupt the JSONL stream.
_send_lock = threading.Lock()


def send(stream: IO[str], t: str, **fields: Any) -> None:
    with _send_lock:
        stream.write(json.dumps({"t": t, **fields}) + "\n")
        stream.flush()


def recv(stream: IO[str]) -> dict | None:
    """Read one message; None on EOF. Non-JSON lines are ignored (stray prints from
    research-repo imports must not kill the protocol)."""
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            print(f"protocol: ignoring non-JSON line: {line[:200]}", file=sys.stderr)
            continue
        if isinstance(msg, dict) and "t" in msg:
            return msg
        print(f"protocol: ignoring malformed message: {line[:200]}", file=sys.stderr)

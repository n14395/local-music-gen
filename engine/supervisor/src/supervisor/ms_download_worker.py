# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Subprocess entrypoint for one ModelScope repo download.

Run as: python -m supervisor.ms_download_worker --repo <ns/name> --dest <dir>

The HF twin (`download_worker`) leans on huggingface_hub; ModelScope needs no
SDK — the public API serves an anonymous file listing and plain HTTPS blobs:

    GET https://modelscope.cn/api/v1/models/<ns>/<name>/repo/files?Recursive=true
    GET https://modelscope.cn/models/<ns>/<name>/resolve/master/<path>

Being a subprocess is what makes pause/resume/cancel trivial for the
supervisor: SIGSTOP / SIGCONT / SIGKILL. Partial files download to `.part`
and resume with a Range header on the next attempt; a repo is only marked
complete (COMPLETE_MARKER, read by the registry) once every listed file is on
disk at its listed size.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://modelscope.cn/api/v1/models/{repo}/repo/files?Recursive=true"
RESOLVE = "https://modelscope.cn/models/{repo}/resolve/master/{path}"
COMPLETE_MARKER = ".ms-complete.json"
CHUNK = 1 << 20


def list_files(repo: str) -> list[dict]:
    """The repo's blobs as [{"Path": ..., "Size": ...}]. Raises on any
    API-shaped failure — an empty repo and an unreachable one must both stop
    the download, not complete it vacuously."""
    with urllib.request.urlopen(API.format(repo=repo), timeout=60) as resp:
        data = json.load(resp)
    if data.get("Code") != 200:
        raise RuntimeError(f"ModelScope listing failed for {repo}: "
                           f"{data.get('Message') or data.get('Code')}")
    files = [f for f in data["Data"]["Files"] if f.get("Type") == "blob"]
    if not files:
        raise RuntimeError(f"ModelScope repo {repo} lists no files")
    return files


def fetch(repo: str, path: str, size: int, dest: str) -> None:
    final = os.path.join(dest, path)
    os.makedirs(os.path.dirname(final), exist_ok=True)
    if os.path.exists(final) and os.path.getsize(final) == size:
        return
    part = final + ".part"
    done = os.path.getsize(part) if os.path.exists(part) else 0
    if done > size:
        # upstream file changed under a stale partial; start over
        os.unlink(part)
        done = 0
    url = RESOLVE.format(repo=repo, path=urllib.parse.quote(path))
    req = urllib.request.Request(url)
    if done:
        req.add_header("Range", f"bytes={done}-")
    mode = "ab" if done else "wb"
    with urllib.request.urlopen(req, timeout=120) as resp:
        # A server that ignores Range answers 200 with the whole file; append
        # would corrupt, so start the file over.
        if done and resp.status == 200:
            mode = "wb"
        with open(part, mode) as f:
            while True:
                chunk = resp.read(CHUNK)
                if not chunk:
                    break
                f.write(chunk)
    got = os.path.getsize(part)
    if got != size:
        raise RuntimeError(f"{repo}/{path}: got {got} bytes, expected {size}")
    os.replace(part, final)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="ModelScope <namespace>/<name>")
    ap.add_argument("--dest", required=True, help="directory the files land in")
    ap.add_argument("--patterns", default=None,
                    help="JSON list of allow patterns (repos that bundle "
                         "sibling checkpoints an entry does not want)")
    args = ap.parse_args()
    files = list_files(args.repo)
    if args.patterns:
        import fnmatch

        allow = json.loads(args.patterns)
        files = [f for f in files
                 if any(fnmatch.fnmatch(f["Path"], p) for p in allow)]
        if not files:
            raise RuntimeError(
                f"{args.repo}: allow_patterns match no file upstream")
    os.makedirs(args.dest, exist_ok=True)
    for f in files:
        fetch(args.repo, f["Path"], int(f.get("Size") or 0), args.dest)
    # Written last, atomically: its presence is the registry's completeness
    # check, so it must never exist above files that are not all there.
    marker = {"repo": args.repo,
              "files": {f["Path"]: int(f.get("Size") or 0) for f in files}}
    tmp = os.path.join(args.dest, COMPLETE_MARKER + ".tmp")
    with open(tmp, "w") as f:
        json.dump(marker, f)
    os.replace(tmp, os.path.join(args.dest, COMPLETE_MARKER))
    return 0


if __name__ == "__main__":
    sys.exit(main())

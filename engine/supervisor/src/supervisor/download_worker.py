# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Subprocess entrypoint for one repo snapshot download.

Run as: python -m supervisor.download_worker --repo <repo_id> [--revision r]
HF_HOME and (optionally) HF_TOKEN arrive via the environment. Being a subprocess is
what makes pause/resume/cancel trivial for the supervisor: SIGSTOP / SIGCONT / SIGKILL.
Partial files stay in the cache and resume via etags on the next attempt.
"""

from __future__ import annotations

import argparse
import json
import sys

from huggingface_hub import HfApi, snapshot_download

# Many repos ship the same weights as both .bin and .safetensors; transformers and
# diffusers prefer safetensors, so skip the duplicates. .pt/.pth stay: they are often
# auxiliary files (VAEs, latents, codecs), not duplicates.
DUPLICATE_PATTERNS = ["*.bin", "*.msgpack", "*.h5"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--revision", default=None)
    ap.add_argument("--patterns", default=None,
                    help="JSON list of allow patterns (huge multi-quant repos "
                         "list exactly the files a catalog entry needs)")
    args = ap.parse_args()
    allow = json.loads(args.patterns) if args.patterns else None
    ignore = None
    if allow is None:
        try:
            files = [s.rfilename for s in HfApi().model_info(args.repo).siblings]
            if any(f.endswith(".safetensors") for f in files):
                ignore = DUPLICATE_PATTERNS
        except Exception:  # noqa: BLE001 — sizing is best-effort; download everything
            pass
    snapshot_download(args.repo, revision=args.revision, ignore_patterns=ignore,
                      allow_patterns=allow)
    return 0


if __name__ == "__main__":
    sys.exit(main())

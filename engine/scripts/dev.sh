#!/bin/bash
# Run the real supervisor with dev paths. Extra args pass through.
set -euo pipefail
cd "$(dirname "$0")/../supervisor"

RUN_DIR="${TMPDIR:-/tmp}/localmusic-engine"
mkdir -p "$RUN_DIR"

uv sync --quiet
exec uv run local-music-engine \
    --handshake-file "$RUN_DIR/handshake.json" \
    --data-dir "$RUN_DIR/data" \
    --output-dir "$RUN_DIR/outputs" \
    --parent-pid "$PPID" \
    "$@"

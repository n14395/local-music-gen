#!/bin/bash
# Run the stub engine. Usage: run-stub.sh [--handshake-file F] [--data-dir D] [--output-dir O]
# Defaults suit manual dev; the app passes explicit paths when it spawns us.
set -euo pipefail
cd "$(dirname "$0")"

RUN_DIR="${TMPDIR:-/tmp}/localmusicgen-stub"
mkdir -p "$RUN_DIR"

# Deterministic dev token so the app's attach mode can connect without plumbing.
export LOCALMUSICGEN_AUTH_TOKEN="${LOCALMUSICGEN_AUTH_TOKEN:-localmusicgen-dev}"

ARGS=(--handshake-file "$RUN_DIR/handshake.json" \
      --data-dir "$RUN_DIR/data" \
      --output-dir "$RUN_DIR/outputs" \
      --parent-pid "$PPID")

uv sync --quiet
# The venv's python, not `uv run`: uv would fork the stub as a child and stay
# resident as its parent, so the pid the app tracks — and the one the
# supervision tests kill — would be uv's. Same fix as packaging/engine-shim.sh.
exec "$PWD/.venv/bin/python" stub_server.py "${ARGS[@]}" "$@"

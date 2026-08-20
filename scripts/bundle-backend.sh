#!/bin/bash
# Stage the engine into a built LocalMusic.app:
#   Contents/Resources/backend/bin/{local-music-engine,uv}
#   Contents/Resources/engine/{supervisor,protocol,adapters,catalog}
# Usage: bundle-backend.sh /path/to/LocalMusic.app
set -euo pipefail
APP="${1:?usage: bundle-backend.sh /path/to/LocalMusic.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$APP/Contents/Resources"

rm -rf "$RES/backend" "$RES/engine"
mkdir -p "$RES/backend/bin"

# launcher shim
install -m 755 "$ROOT/packaging/engine-shim.sh" "$RES/backend/bin/local-music-engine"

# the uv binary (single static executable). Prefer a repo-local pinned copy;
# fall back to the host's uv for dev packaging.
if [[ -x "$ROOT/packaging/bin/uv" ]]; then
    install -m 755 "$ROOT/packaging/bin/uv" "$RES/backend/bin/uv"
else
    install -m 755 "$(command -v uv)" "$RES/backend/bin/uv"
fi

# engine sources: pyprojects, lockfiles, code, catalog — no venvs, no vendor
rsync -a \
    --exclude '.venv' --exclude 'vendor' --exclude '__pycache__' \
    --exclude '*.pyc' --exclude '.python-version' \
    "$ROOT/engine/supervisor" "$ROOT/engine/protocol" \
    "$ROOT/engine/adapters" "$ROOT/engine/catalog" \
    "$RES/engine/"

echo "bundled engine into $RES"

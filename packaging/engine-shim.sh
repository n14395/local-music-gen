#!/bin/bash
# LocalMusic bundled-engine launcher. Installed at
# Contents/Resources/backend/bin/local-music-engine inside the .app.
#
# The bundle is read-only, so on each launch this shim rsyncs the engine sources
# into the app's data dir, lets the bundled uv provision CPython 3.11 and the
# supervisor venv there (fast no-ops after the first run), and then execs the
# supervisor with the arguments the app passed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"          # …/Resources/backend/bin
RESOURCES="$(dirname "$(dirname "$HERE")")"    # …/Resources
UV="$HERE/uv"

# --data-dir is among the args the app passes; find it.
DATA_DIR=""
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--data-dir" ]]; then
        DATA_DIR="${args[$((i + 1))]}"
    fi
done
if [[ -z "$DATA_DIR" ]]; then
    echo "engine-shim: --data-dir argument required" >&2
    exit 64
fi
mkdir -p "$DATA_DIR"

export UV_PYTHON_INSTALL_DIR="$DATA_DIR/python"
export UV_CACHE_DIR="$DATA_DIR/uv-cache"
export LOCALMUSIC_UV="$UV"

SRC="$DATA_DIR/engine-src"
mkdir -p "$SRC"
# --delete keeps upgrades clean; venvs/vendor live inside SRC and are excluded.
rsync -a --delete \
    --exclude '.venv' --exclude 'vendor' --exclude '__pycache__' \
    "$RESOURCES/engine/" "$SRC/"
export LOCALMUSIC_ADAPTERS_DIR="$SRC/adapters"

cd "$SRC/supervisor"
"$UV" python install 3.11 --quiet
"$UV" sync --frozen --quiet
exec "$UV" run --frozen local-music-engine "$@"

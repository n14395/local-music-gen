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
#
# So is `build-src` — the vendored acestep.cpp clone. build.sh already keeps it
# out of the bundle, and it is excluded again here so an app built before that
# change does not pay for it either. It matters more than it looks: this rsync
# runs on EVERY launch, and the app's whole model catalog is unknown until the
# engine it starts answers. With build-src the sweep was ~280 ms of a ~1 s
# launch; without it, ~30 ms.
#
# One-time reclaim: rsync's --delete deliberately spares excluded paths, so a
# build-src copied in by an earlier version would otherwise sit in the data dir
# forever. Costs a stat once it is gone.
rm -rf "$SRC/adapters/acestepcpp/build-src"
rsync -a --delete \
    --exclude '.venv' --exclude 'vendor' --exclude 'build-src' \
    --exclude '__pycache__' \
    "$RESOURCES/engine/" "$SRC/"
export LOCALMUSIC_ADAPTERS_DIR="$SRC/adapters"

cd "$SRC/supervisor"

# These two are no-ops after the first run and take tens of seconds on it —
# uv fetches a standalone CPython and then builds the supervisor's venv, both
# over the network. That wait is the app's entire startup on a first launch, so
# it is narrated rather than spent in silence: the app tails this stream and the
# onboarding sheet shows the last `engine-setup:` line. Also lands in the engine
# log, which is where a first run that failed has to be diagnosable from.
say() { echo "engine-setup: $1" >&2; }

say "Preparing the Python runtime"
"$UV" python install 3.11 --quiet
say "Installing the engine's dependencies"
"$UV" sync --frozen --quiet
say "Starting the engine"
exec "$UV" run --frozen local-music-engine "$@"

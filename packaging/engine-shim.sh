#!/bin/bash
# LocalMusicGen bundled-engine launcher. Installed at
# Contents/Resources/backend/bin/local-music-gen-engine inside the .app.
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
export LOCALMUSICGEN_UV="$UV"

SRC="$DATA_DIR/engine-src"
mkdir -p "$SRC"
# --delete keeps upgrades clean; venvs live inside SRC and are excluded.
#
# No blanket `vendor` exclude — see the note in build.sh's bundle_engine. A
# directory called `vendor` under an adapter's `src/` is Python the adapter
# imports, and excluding it here made a bundled model fail at load with
# "No module named 'adapter_captioning.vendor'".
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
#
# `.venv-decoder` is LeVo's second runtime, provisioned beside its `.venv` on
# first use. build.sh keeps it out of the bundle; this list used not to name it,
# so --delete removed it (and its marker) on every launch and the next LeVo job
# rebuilt several GB of wheels. Excluded here too, which is what spares it.
rm -rf "$SRC/adapters/acestepcpp/build-src"
# `.cache` is ACE-Step's learned per-step timings, written by the engine into
# its own source tree. --delete spares excluded paths, so excluding it is what
# stops this rsync overwriting the user's measured timings with the bundle's
# on every launch. `.DS_Store` is excluded for the same reason it is in
# build.sh: Finder's, never ours.
rsync -a --delete \
    --exclude '.venv' --exclude '.venv-decoder' --exclude 'build-src' \
    --exclude '__pycache__' --exclude '.cache' --exclude '.DS_Store' \
    "$RESOURCES/engine/" "$SRC/"
export LOCALMUSICGEN_ADAPTERS_DIR="$SRC/adapters"

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
# The venv's own console script, not `uv run`. uv forks the command as a child
# and stays resident as its parent, so the process the app spawned, tracked,
# pid-filed and signalled was uv: "Restart engine now" SIGKILLed uv, the real
# supervisor lived on holding the data-dir lock and the port, and every respawn
# died on "another engine already serves this data dir" until the app was quit.
# `uv sync` above has just built the venv this script lives in, so exec'ing it
# makes the app's child *be* the supervisor — one pid in the handshake, the pid
# file and `ps`, and every signal lands where it is aimed.
exec "$SRC/supervisor/.venv/bin/local-music-gen-engine" "$@"

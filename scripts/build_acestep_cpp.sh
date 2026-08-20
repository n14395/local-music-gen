#!/bin/bash
# Build the acestep.cpp binaries (GGML + Metal) for the acestepcpp adapter.
#
# The adapter runs ace-lm / ace-synth as subprocesses; this script produces them
# in engine/adapters/acestepcpp/bin/. Requires cmake and the Xcode toolchain.
# Idempotent: skips the build when the pinned revision is already built.
#
# Usage: scripts/build_acestep_cpp.sh [--force]

set -euo pipefail

REPO="https://github.com/ServeurpersoCom/acestep.cpp"
REV="9761469d95fc204b5468623c68a1a2203e50b1f9"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/engine/adapters/acestepcpp"
SRC="$DEST/build-src"
BIN="$DEST/bin"

if [ "${1:-}" != "--force" ] && [ -x "$BIN/ace-synth" ] \
   && [ "$(cat "$BIN/.revision" 2>/dev/null)" = "$REV" ]; then
    echo "acestep.cpp $REV already built at $BIN"
    exit 0
fi

if ! command -v cmake >/dev/null; then
    echo "error: cmake is required (brew install cmake)" >&2
    exit 1
fi

if [ ! -d "$SRC/.git" ]; then
    git clone --recurse-submodules "$REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$REV" 2>/dev/null || git -C "$SRC" fetch --quiet
git -C "$SRC" checkout --quiet "$REV"
git -C "$SRC" submodule update --init --recursive --quiet

mkdir -p "$SRC/build"
# Metal is GGML's default GPU backend on Apple Silicon; no extra flags needed.
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$SRC/build" --config Release -j "$(sysctl -n hw.ncpu)"

mkdir -p "$BIN"
for tool in ace-lm ace-synth ace-server; do
    cp "$SRC/build/$tool" "$BIN/$tool"
done
echo "$REV" > "$BIN/.revision"
echo "→ $BIN (ace-lm, ace-synth, ace-server)"

#!/bin/bash
# Build the acestep.cpp binaries (GGML + Metal) for the acestepcpp adapter.
#
# The adapter runs ace-lm / ace-synth as subprocesses; this script produces them
# in engine/adapters/acestepcpp/bin/. Requires cmake and the Xcode toolchain.
# Idempotent: skips the build when the pinned revision is already built.
#
# Usage: scripts/build_acestep_cpp.sh [--force | --relink]
#   --force   rebuild even when the pinned revision is already built
#   --relink  re-stage bin/ from an existing build tree, no compile

set -euo pipefail

REPO="https://github.com/ServeurpersoCom/acestep.cpp"
REV="9761469d95fc204b5468623c68a1a2203e50b1f9"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/engine/adapters/acestepcpp"
SRC="$DEST/build-src"
BIN="$DEST/bin"


# Stage the tools next to the shared libraries they load, and repoint them at
# that directory rather than at this machine's build tree.
#
# cmake bakes an ABSOLUTE LC_RPATH to $SRC/build into every tool, and copying
# the executables out on their own left them loading libggml*.dylib across that
# path. It survived exactly as long as nobody moved the checkout — and then the
# repo moved into src/, the path stopped existing, and every acestep.cpp
# generation died with `dyld: Library not loaded: @rpath/libggml.0.dylib` and
# exit -6. It was never sound: the .app ships bin/ and cannot ship a build tree
# from the developer's home directory.
#
# So bin/ carries the five GGML dylibs (~2.5 MB) and every Mach-O in it looks
# for its siblings at @loader_path. The directory is then relocatable — repo,
# ~/Library/Application Support/.../engine-src, or inside the .app — which is
# what all three of those actually need.
GGML_LIBS=(libggml libggml-base libggml-cpu libggml-blas libggml-metal)

stage_binaries() {
    mkdir -p "$BIN"
    for tool in ace-lm ace-synth ace-server; do
        cp "$SRC/build/$tool" "$BIN/$tool"
    done
    # `cp` follows the symlink, so each versioned name lands as a real file —
    # rsync into the app bundle and a code-signed .app both prefer that to a
    # symlink farm.
    for lib in "${GGML_LIBS[@]}"; do
        cp "$SRC/build/$lib.0.dylib" "$BIN/$lib.0.dylib"
    done

    for macho in "$BIN"/ace-lm "$BIN"/ace-synth "$BIN"/ace-server "$BIN"/*.dylib; do
        # Drop whatever absolute rpaths cmake left, whatever they were: this
        # has to repair a bin/ built before this function existed, not just
        # produce a good one.
        while read -r old; do
            [ -n "$old" ] && install_name_tool -delete_rpath "$old" "$macho" 2>/dev/null
        done < <(otool -l "$macho" \
                 | awk '/LC_RPATH/ {f=1} f && $1 == "path" {print $2; f=0}')
        install_name_tool -add_rpath @loader_path "$macho"
        # install_name_tool invalidates the signature, and macOS on Apple
        # silicon refuses to run an unsigned Mach-O. build.sh re-signs the lot
        # with a real identity when it bundles the app; this keeps the repo
        # copy runnable in the meantime.
        codesign --force --sign - "$macho" 2>/dev/null
    done
    echo "$REV" > "$BIN/.revision"
    echo "→ $BIN (ace-lm, ace-synth, ace-server + ${#GGML_LIBS[@]} GGML dylibs)"
}

# Re-stage from an existing build tree without recompiling. This is what
# repairs a bin/ whose rpaths point somewhere that no longer exists.
if [ "${1:-}" = "--relink" ]; then
    [ -x "$SRC/build/ace-synth" ] || {
        echo "error: no build at $SRC/build — run without --relink first" >&2
        exit 1
    }
    stage_binaries
    exit 0
fi

# The revision alone is not proof any more: a bin/ from before the dylibs were
# staged has the right revision and still cannot load.
if [ "${1:-}" != "--force" ] && [ -x "$BIN/ace-synth" ] \
   && [ -f "$BIN/libggml.0.dylib" ] \
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

stage_binaries

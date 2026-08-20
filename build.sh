#!/bin/bash
# Rebuild LocalMusic.
#
#   ./build.sh              regenerate Xcode project, build app (Debug), sync engine
#   ./build.sh --test       …then run the app test suite + stub contract checks
#   ./build.sh --reset      wipe app state first — prefs, library, install markers —
#                           so the next launch starts at onboarding. Keeps every
#                           downloaded model (quit the app first)
#   ./build.sh --adapters   …also sync every adapter venv (first run downloads torch etc.)
#   ./build.sh --package    …then produce dist/LocalMusic.app (Release + bundled engine)
#   ./build.sh --dmg        …package + wrap dist/LocalMusic-<version>.dmg (production;
#                           set IDENTITY="Developer ID Application: …" to distribute)
#   ./build.sh --all        everything above
#
# Flags combine; order doesn't matter. Any failing step aborts the script.
set -euo pipefail
cd "$(dirname "$0")"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
export DEVELOPER_DIR

RUN_TEST=0 RUN_ADAPTERS=0 RUN_PACKAGE=0 RUN_DMG=0 RUN_RESET=0
for arg in "$@"; do
    case "$arg" in
        --test)     RUN_TEST=1 ;;
        --reset)    RUN_RESET=1 ;;
        --adapters) RUN_ADAPTERS=1 ;;
        --package)  RUN_PACKAGE=1 ;;
        --dmg)      RUN_PACKAGE=1 RUN_DMG=1 ;;
        # Deliberately NOT part of --all: everything else here is additive, and
        # a flag that means "and also delete my library" has no business riding
        # along with "build everything".
        --all)      RUN_TEST=1 RUN_ADAPTERS=1 RUN_PACKAGE=1 RUN_DMG=1 ;;
        -h|--help)  sed '1d' "$0" | grep '^#' | sed 's/^# \{0,1\}//' | head -14
                    exit 0 ;;
        *) echo "unknown flag: $arg (try --help)" >&2; exit 64 ;;
    esac
done

step() { printf '\n\033[1m• %s\033[0m\n' "$1"; }

# xcodebuild is chatty, so we grep its output down — but a plain
# `xcodebuild | grep || true` swallows the exit code and lets the script march
# on past a failed build. Filter AND propagate.
xcb() {
    local log
    # BSD mktemp only substitutes X's at the END of the template: a ".log"
    # suffix makes it create one literal "…XXXXXX.log" file, which then
    # collides on the next failed build.
    log="$(mktemp "${TMPDIR:-/tmp}/localmusic-xcodebuild.XXXXXX")"
    xcodebuild "$@" > "$log" 2>&1 || {
        grep -E "error:|warning: .*failed|BUILD|TEST" "$log" | tail -20
        echo "xcodebuild failed — full log: $log" >&2
        return 1
    }
    grep -E "BUILD|TEST " "$log" || true
    rm -f "$log"
}

# Before anything else: a reset that ran after a build would still be correct,
# but this way a cancelled confirmation costs you nothing.
if [[ $RUN_RESET -eq 1 ]]; then
    step "resetting app state"
    ./scripts/reset_app.sh
fi

step "regenerating Xcode project (app/project.yml)"
(cd app && xcodegen generate)

# A plain `build` rewrites the app bundle without the embedded test bundle and can
# race a following `test` invocation — so when testing, build via `test` alone.
if [[ $RUN_TEST -eq 0 ]]; then
    step "building app (Debug)"
    xcb -project app/LocalMusic.xcodeproj -scheme LocalMusic \
        -destination 'platform=macOS,arch=arm64' build
fi

step "syncing engine supervisor venv"
(cd engine/supervisor && uv sync --quiet)
(cd stub-backend && uv sync --quiet)

if [[ $RUN_ADAPTERS -eq 1 ]]; then
    for dir in engine/adapters/*/; do
        [[ -f "$dir/pyproject.toml" ]] || continue
        step "syncing adapter venv: $(basename "$dir")"
        (cd "$dir" && uv sync --quiet)
    done
fi

if [[ $RUN_TEST -eq 1 ]]; then
    step "building + running app test suite"
    xcb -project app/LocalMusic.xcodeproj -scheme LocalMusic \
        -destination 'platform=macOS,arch=arm64' test
    step "stub contract checks"
    out="$(python3 scripts/verify_stub.py)" || {
        printf '%s\n' "$out" | tail -20
        echo "stub contract checks failed" >&2
        exit 1
    }
    printf '%s\n' "$out" | tail -1
fi

if [[ $RUN_PACKAGE -eq 1 ]]; then
    step "packaging dist/LocalMusic.app"
    ./scripts/package_app.sh
fi

if [[ $RUN_DMG -eq 1 ]]; then
    step "wrapping dist dmg"
    ./scripts/make_dmg.sh
fi

printf '\n\033[1m✓ done\033[0m\n'

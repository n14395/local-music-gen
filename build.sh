#!/bin/bash
# LocalMusic — build, package, sign and publish.
#
#   ./build.sh                 build the production build/LocalMusic.app
#   ./build.sh --dmg           …and package it into build/LocalMusic.dmg
#   ./build.sh --sign          …Developer ID sign the .app and .dmg, notarize and staple
#   ./build.sh --publish vN.N  tag, push and cut a GitHub release from build/LocalMusic.dmg
#
#   ./build.sh --debug         fast Debug dev build instead of the production one
#   ./build.sh --test          …then run the app test suite + stub contract checks
#   ./build.sh --adapters      …also sync every adapter venv (first run pulls torch)
#   ./build.sh --reset         wipe app state first — prefs, library, install markers
#                              — so the next launch starts at onboarding. Keeps every
#                              downloaded model (quit the app first)
#
# Flags combine — `./build.sh --sign --publish v1.2` signs, notarizes and releases in
# one go. `--publish` on its own does not rebuild: it requires build/LocalMusic.dmg to
# already exist.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LocalMusic"
BUILD_DIR="$PWD/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
BUNDLE_ID="com.n14395.localmusic"
ENTITLEMENTS="$PWD/packaging/entitlements.plist"

# Exported from ~/.zshrc. The literal fallback keeps the script working when it is
# run from a shell that never sourced it (cron, a GUI runner, `env -i`).
DEV_TEAM_IDENTITY="${DEV_TEAM_IDENTITY:-Developer ID Application: Nicholas Fay (P52946XHRJ)}"
NOTARY_PROFILE="notary-profile"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

WANT_DMG=0
WANT_SIGN=0
PUBLISH_VERSION=""
WANT_DEBUG=0
WANT_TEST=0
WANT_ADAPTERS=0
WANT_RESET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)   WANT_DMG=1 ;;
        --sign)  WANT_SIGN=1 ;;
        --publish)
            [[ $# -ge 2 ]] || die "--publish needs a version argument, e.g. --publish v1.2"
            PUBLISH_VERSION="$2"; shift ;;
        --publish=*) PUBLISH_VERSION="${1#*=}" ;;
        --debug)    WANT_DEBUG=1 ;;
        --test)     WANT_TEST=1 ;;
        --adapters) WANT_ADAPTERS=1 ;;
        --reset)    WANT_RESET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
    shift
done

# vN.N or vN.N.N — anything else is a typo we would rather catch before tagging.
if [[ -n "$PUBLISH_VERSION" ]]; then
    [[ "$PUBLISH_VERSION" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
        || die "--publish needs a version like v1.2 or v1.2.3 (got: '$PUBLISH_VERSION')"
    VERSION_NUM="${PUBLISH_VERSION#v}"
fi

# Full Xcode, not the bare Command Line Tools: xcodebuild refuses to run under
# CLT, and even SwiftPM needs Xcode's toolchain for the SwiftUI macro plugins.
# Set DEVELOPER_DIR for this process only — the system default is left alone.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcode-select -p 2>/dev/null | grep -q '\.app'; then
    for xc in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [[ -d "$xc" ]]; then export DEVELOPER_DIR="$xc/Contents/Developer"; break; fi
    done
fi

# xcodebuild is extremely chatty, and `xcodebuild | grep` throws away its exit
# status — which would let a failed compile fall through to packaging whatever
# stale bundle happened to be lying around. Filter the noise, keep the status.
xcb() {
    local log
    log="$(mktemp "${TMPDIR:-/tmp}/xcodebuild.XXXXXX")"
    if ! xcodebuild "$@" >"$log" 2>&1; then
        grep -E "error:|BUILD FAILED" "$log" | tail -30
        echo "xcodebuild failed — full log: $log" >&2
        return 1
    fi
    grep -E "^\*\* BUILD" "$log" || true
    rm -f "$log"
}

# The bundled uv binary is nested Mach-O code, so it must be signed before the
# enclosing bundle — codesign does not recurse. Defaults to the same stable
# Apple Development identity as app/project.yml: ad-hoc signatures change every
# build, so keychain "Always Allow" grants for the HF token never stick.
dev_sign() {
    local id
    id="${CODESIGN_IDENTITY:-${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development/ {print $2; exit}')}}"
    id="${id:--}"
    step "Signing (identity: $id)"
    if [[ -x "$APP_PATH/Contents/Resources/backend/bin/uv" ]]; then
        codesign --force --options runtime --timestamp=none \
            --entitlements "$ENTITLEMENTS" \
            --sign "$id" "$APP_PATH/Contents/Resources/backend/bin/uv"
    fi
    codesign --force --deep --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" --sign "$id" "$APP_PATH"
}

# A plain drag-to-install image: the app plus an /Applications symlink, nothing
# else. Staged under build/ so the volume contains exactly those two items and
# no stray DerivedData.
DMG_STAGING="$BUILD_DIR/.dmg-staging"
cleanup() { rm -rf "$DMG_STAGING"; return 0; }
trap cleanup EXIT

make_dmg() {
    [[ -d "$APP_PATH" ]] || die "$APP_PATH not found — build it first"
    step "Packaging $APP_NAME.dmg"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    # ditto, not cp: it preserves the code signature and extended attributes.
    ditto "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGING/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" \
        -fs HFS+ -format UDZO -ov -quiet "$DMG_PATH"
    rm -rf "$DMG_STAGING"
    echo "    $DMG_PATH"
}

# codesign never recurses into nested code, and the notary service rejects a
# bundle whose frameworks / app extensions / bundled helper binaries still carry
# an older signature. So sign inside-out, deepest path first, then the bundle
# itself. Entitlements are read back off each item and re-applied: a bare
# --force re-sign silently drops them, which would break sandboxing and TCC.
sign_one() {
    local target="$1" ent="" args=()
    if [[ "$target" == "$APP_PATH" && -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
        args+=(--entitlements "$ENTITLEMENTS")
    else
        ent="$(mktemp "${TMPDIR:-/tmp}/entitlements.XXXXXX")"
        if codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q '<plist'; then
            codesign -d --entitlements - --xml "$target" 2>/dev/null >"$ent"
            # get-task-allow is the debugger entitlement Xcode injects into
            # development-signed builds. The notary service rejects any binary
            # that still requests it, so drop it before re-signing.
            /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' \
                "$ent" >/dev/null 2>&1 || true
            args+=(--entitlements "$ent")
        else
            rm -f "$ent"; ent=""
        fi
    fi
    codesign --force --options runtime --timestamp \
        ${args[@]+"${args[@]}"} --sign "$DEV_TEAM_IDENTITY" "$target"
    [[ -n "$ent" ]] && rm -f "$ent"
    echo "    signed ${target#$BUILD_DIR/}"
}

sign_bundle() {
    local inner
    while IFS= read -r inner; do
        sign_one "$inner"
    done < <(
        {
            find "$APP_PATH/Contents" \
                \( -name '*.framework' -o -name '*.appex' -o -name '*.xpc' \
                   -o -name '*.app' -o -name '*.bundle' -o -name '*.dylib' \
                   -o -name '*.so' \) 2>/dev/null
            # Loose Mach-O helpers: bundled CLIs in Resources, login items…
            find "$APP_PATH/Contents" -type f -perm -u+x 2>/dev/null \
                | while IFS= read -r f; do
                      file -b "$f" 2>/dev/null | grep -q 'Mach-O' && printf '%s\n' "$f"
                  done
        } | grep -v "/Contents/MacOS/[^/]*$" \
          | sort -u | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-
    )
    sign_one "$APP_PATH"
}

sign_and_notarize() {
    step "Developer ID signing $APP_NAME.app"
    echo "    identity: $DEV_TEAM_IDENTITY"
    sign_bundle

    make_dmg

    step "Developer ID signing $APP_NAME.dmg"
    codesign --force --timestamp --sign "$DEV_TEAM_IDENTITY" "$DMG_PATH"

    step "Verifying the .dmg signature"
    if ! codesign --verify --verbose=2 "$DMG_PATH"; then
        die "codesign --verify failed for $DMG_PATH — not submitting for notarization"
    fi

    step "Notarizing (this waits on Apple; usually a few minutes)"
    local out rc=0 status uuid
    out="$(xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || rc=$?
    printf '%s\n' "$out"
    [[ $rc -eq 0 ]] || die "notarytool submit failed (exit $rc)"

    status="$(printf '%s\n' "$out" | awk -F': *' '/^ *status:/ {print $2; exit}')"
    uuid="$(printf '%s\n' "$out"   | awk -F': *' '/^ *id:/     {print $2; exit}')"
    if [[ "$status" != "Accepted" ]]; then
        if [[ -n "$uuid" ]]; then
            step "Fetching the notarization log"
            xcrun notarytool log "$uuid" --keychain-profile "$NOTARY_PROFILE" \
                "$BUILD_DIR/notary-log.json" || true
            echo "    log written to $BUILD_DIR/notary-log.json"
        fi
        die "notarization returned status: ${status:-unknown}"
    fi

    step "Stapling the ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    step "Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

    step "Notarized and stapled: $DMG_PATH"
}

publish() {
    step "Publishing $PUBLISH_VERSION"
    [[ -f "$DMG_PATH" ]] \
        || die ".dmg not found: $DMG_PATH — run ./build.sh --dmg (or --sign) first"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$PWD is not inside a git repository — cannot tag or release"
    command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed"
    git remote get-url origin >/dev/null 2>&1 \
        || die "this repository has no 'origin' remote — cannot push the tag"

    local versioned="$BUILD_DIR/$APP_NAME-$VERSION_NUM.dmg"
    cp -f "$DMG_PATH" "$versioned"
    echo "    $versioned"

    git tag -a "$PUBLISH_VERSION" -m "Release $PUBLISH_VERSION"
    git push origin "$PUBLISH_VERSION"
    gh release create "$PUBLISH_VERSION" "$versioned" --verify-tag --generate-notes
}

# Regenerate the Xcode project when app/project.yml has moved ahead of it.
# xcodegen's source discovery is stale by default, and the symptom of a drifted
# project file is a phantom "Cannot find type" for a file that is plainly there.
regen_project() {
    # Unconditional, and it used to be `project.yml -nt project.pbxproj`.
    # `sources:` declares whole directories, so ADDING or REMOVING a Swift file
    # changes the project without touching project.yml — the old check could
    # not see it, and a deleted test left the test target compiling a file that
    # was no longer on disk (the app target built fine, so nothing said so
    # until `make app-test`). xcodegen is deterministic — same inputs, byte
    # identical output — and takes about 60 ms, so there is nothing to save by
    # guessing when to run it.
    step "Regenerating app/LocalMusic.xcodeproj"
    (cd app && xcodegen generate >/dev/null)
}

sync_engine_venvs() {
    step "Syncing engine supervisor venv"
    (cd engine/supervisor && uv sync --quiet)
    (cd stub-backend && uv sync --quiet)
    if [[ $WANT_ADAPTERS -eq 1 ]]; then
        for dir in engine/adapters/*/; do
            [[ -f "$dir/pyproject.toml" ]] || continue
            step "Syncing adapter venv: $(basename "$dir")"
            (cd "$dir" && uv sync --quiet)
        done
    fi
}

# Stage the Python engine into the built bundle:
#   Contents/Resources/backend/bin/{local-music-engine,uv}
#   Contents/Resources/engine/{supervisor,protocol,adapters,catalog}
bundle_engine() {
    step "Bundling the engine"
    local res="$APP_PATH/Contents/Resources"
    rm -rf "$res/backend" "$res/engine"
    mkdir -p "$res/backend/bin"

    install -m 755 packaging/engine-shim.sh "$res/backend/bin/local-music-engine"

    # uv is a single static executable. Prefer a repo-local pinned copy; fall
    # back to whatever the host has for dev packaging.
    if [[ -x packaging/bin/uv ]]; then
        install -m 755 packaging/bin/uv "$res/backend/bin/uv"
    else
        install -m 755 "$(command -v uv)" "$res/backend/bin/uv"
    fi

    # Engine sources: pyprojects, lockfiles, code, catalog — no venvs, no vendor.
    #
    # `build-src` is the acestep.cpp clone that scripts/build_acestep_cpp.sh
    # compiles into acestepcpp/bin/. It is 98 MB and 3,126 of the engine's
    # 3,239 files, and nothing reads it at runtime — only the binaries it
    # produced. Shipping it made the bundle 98 MB larger and, because the shim
    # re-syncs the engine into the data dir on every launch, cost ~280 ms of
    # every single app start for files no process would ever open.
    rsync -a \
        --exclude '.venv' --exclude 'vendor' --exclude '__pycache__' \
        --exclude 'build-src' \
        --exclude '*.pyc' --exclude '.python-version' \
        engine/supervisor engine/protocol engine/adapters engine/catalog \
        "$res/engine/"
}

build_app() {
    regen_project

    if [[ $WANT_DEBUG -eq 1 ]]; then
        step "Building $APP_NAME (Debug — fast dev build, no bundled engine)"
        xcb -project app/LocalMusic.xcodeproj -scheme LocalMusic \
            -destination 'platform=macOS,arch=arm64' build
        sync_engine_venvs
        return
    fi

    step "Building $APP_NAME (Release)"
    local derived="$BUILD_DIR/.derived"
    xcb -project app/LocalMusic.xcodeproj -scheme LocalMusic \
        -configuration Release -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived" build

    local built="$derived/Build/Products/Release/LocalMusic.app"
    [[ -d "$built" ]] || die "Release build missing at $built"
    rm -rf "$APP_PATH"
    ditto "$built" "$APP_PATH"

    bundle_engine
    dev_sign
    codesign --verify --strict "$APP_PATH" && echo "    signature verifies"
    echo "    $APP_PATH"
}

run_tests() {
    step "Building + running the app test suite"
    # A plain `build` rewrites the bundle without the embedded test bundle and
    # can race a following `test`, so when testing we build via `test` alone.
    xcb -project app/LocalMusic.xcodeproj -scheme LocalMusic \
        -destination 'platform=macOS,arch=arm64' test
    step "Stub contract checks"
    local out
    if ! out="$(python3 scripts/verify_stub.py)"; then
        printf '%s\n' "$out" | tail -20
        die "stub contract checks failed"
    fi
    printf '%s\n' "$out" | tail -1
}

mkdir -p "$BUILD_DIR"

# Before anything else: a reset that ran after a build would still be correct,
# but this way a cancelled confirmation costs you nothing.
if [[ $WANT_RESET -eq 1 ]]; then
    step "Resetting app state"
    ./scripts/reset_app.sh
fi

if [[ $WANT_SIGN -eq 1 ]]; then
    build_app
    sign_and_notarize
elif [[ $WANT_DMG -eq 1 ]]; then
    build_app
    make_dmg
elif [[ -z "$PUBLISH_VERSION" ]]; then
    build_app
fi

if [[ $WANT_TEST -eq 1 ]]; then
    run_tests
fi

if [[ -n "$PUBLISH_VERSION" ]]; then
    publish
fi

exit 0

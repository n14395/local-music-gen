#!/bin/bash
# Build a distributable LocalMusic.app into dist/.
#
#   scripts/package_app.sh                      # Apple Development signed (local)
#   IDENTITY="Developer ID Application: …" scripts/package_app.sh   # distribution
#
# Notarization (after signing with a Developer ID identity):
#   ditto -c -k --keepParent dist/LocalMusic.app dist/LocalMusic.zip
#   xcrun notarytool submit dist/LocalMusic.zip --keychain-profile localmusic --wait
#   xcrun stapler staple dist/LocalMusic.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
# Default to the same stable dev identity as app/project.yml — ad-hoc ("-")
# signatures change every build, so keychain "Always Allow" grants for the HF
# token never stick. Update the hash when the certificate rotates.
IDENTITY="${IDENTITY:-F67DC1F6A8F864CD087F247CC9F624EE441898A4}"
DIST="$ROOT/dist"
DERIVED="$DIST/derived"

mkdir -p "$DIST"
echo "• building Release app"
LOG="$(mktemp /tmp/localmusic-release.XXXXXX.log)"
# filter xcodebuild chatter but PROPAGATE failures — `| grep || true` let a
# broken build fall through to packaging a stale previous Release bundle
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
    -project "$ROOT/app/LocalMusic.xcodeproj" -scheme LocalMusic \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" build > "$LOG" 2>&1 || {
        grep -E "error:|BUILD" "$LOG" | tail -20
        echo "Release build failed — full log: $LOG" >&2
        exit 1
    }
grep -E "BUILD" "$LOG" || true
rm -f "$LOG"

APP_SRC="$DERIVED/Build/Products/Release/LocalMusic.app"
[[ -d "$APP_SRC" ]] || { echo "Release build missing at $APP_SRC" >&2; exit 1; }
rm -rf "$DIST/LocalMusic.app"
cp -R "$APP_SRC" "$DIST/LocalMusic.app"

echo "• bundling engine"
"$ROOT/scripts/bundle-backend.sh" "$DIST/LocalMusic.app"

echo "• signing (identity: $IDENTITY)"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/packaging/entitlements.plist" \
    --sign "$IDENTITY" "$DIST/LocalMusic.app/Contents/Resources/backend/bin/uv"
codesign --force --deep --options runtime --timestamp=none \
    --entitlements "$ROOT/packaging/entitlements.plist" \
    --sign "$IDENTITY" "$DIST/LocalMusic.app"

codesign --verify --strict "$DIST/LocalMusic.app" && echo "✓ signature verifies"
echo "→ $DIST/LocalMusic.app"
if [[ "$IDENTITY" == "-" ]]; then
    echo "  (ad-hoc signed: fine locally; use IDENTITY=… + notarytool for distribution)"
fi

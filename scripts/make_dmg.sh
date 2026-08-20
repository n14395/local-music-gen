#!/bin/bash
# Wrap dist/LocalMusic.app in a compressed, signed .dmg for distribution.
#
#   scripts/make_dmg.sh                    # uses the identity the app was built with
#   IDENTITY="Developer ID Application: …" scripts/make_dmg.sh
#
# Produces dist/LocalMusic-<version>.dmg with the standard drag-to-/Applications
# layout. For real distribution, notarize the dmg itself (see
# packaging/notarize_notes.md) — notarytool accepts a dmg directly and the
# staple travels with it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${IDENTITY:-F67DC1F6A8F864CD087F247CC9F624EE441898A4}"
APP="$ROOT/dist/LocalMusic.app"

[[ -d "$APP" ]] || { echo "dist/LocalMusic.app missing — run scripts/package_app.sh first" >&2; exit 1; }
codesign --verify --strict "$APP" || { echo "app signature invalid — repackage first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/LocalMusic-$VERSION.dmg"

STAGING="$(mktemp -d /tmp/localmusic-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
echo "• staging (version $VERSION)"
cp -R "$APP" "$STAGING/LocalMusic.app"
ln -s /Applications "$STAGING/Applications"

echo "• creating dmg"
rm -f "$DMG"
hdiutil create -volname "LocalMusic $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"

echo "• signing dmg (identity: $IDENTITY)"
codesign --force --timestamp=none --sign "$IDENTITY" "$DMG"
codesign --verify --strict "$DMG" && echo "✓ dmg signature verifies"

echo "• verifying image"
MOUNT="$(hdiutil attach -readonly -nobrowse -noautoopen "$DMG" \
    | awk -F'\t' '/\/Volumes\//{print $NF}')"
[[ -d "$MOUNT/LocalMusic.app" && -L "$MOUNT/Applications" ]] \
    && echo "✓ image mounts with app + /Applications link"
hdiutil detach -quiet "$MOUNT"

du -h "$DMG" | awk '{print "→ " $2 " (" $1 ")"}'
if [[ "$IDENTITY" != Developer\ ID* ]]; then
    echo "  (dev-signed: Gatekeeper will block on other Macs — for distribution"
    echo "   rebuild with IDENTITY=\"Developer ID Application: …\" and notarize"
    echo "   the dmg; see packaging/notarize_notes.md)"
fi

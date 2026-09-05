# Distribution notes

## What ships

`scripts/package_app.sh` produces `dist/LocalMusicGen.app`:

- The SwiftUI app (arm64, macOS 14+).
- `Contents/Resources/backend/bin/` — the engine launcher shim + the `uv` binary
  (the only bundled Mach-O besides the app itself).
- `Contents/Resources/engine/` — supervisor/protocol/adapter sources, lockfiles,
  and the model catalog. No Python, no wheels: at first launch the shim has uv
  install CPython 3.11 and provision venvs under
  `~/Library/Application Support/LocalMusicGen/`, pinned by the shipped `uv.lock`
  files. First launch therefore needs internet — as does every model download.

This keeps the app ~50 MB with two artifacts to sign, instead of a 12–15 GB
bundle with tens of thousands of dylibs to re-sign.

## Signing & notarizing (needs a Developer ID)

```sh
# one-time: store notary credentials
xcrun notarytool store-credentials localmusicgen \
    --apple-id YOU@example.com --team-id TEAMID --password app-specific-pw

IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh --dmg
xcrun notarytool submit dist/LocalMusicGen-*.dmg --keychain-profile localmusicgen --wait
xcrun stapler staple dist/LocalMusicGen-*.dmg
spctl -a -t open --context context:primary-signature -vv dist/LocalMusicGen-*.dmg
# stapling the dmg covers the download; optionally also staple the app inside:
#   xcrun stapler staple dist/LocalMusicGen.app  (then rebuild the dmg, or ship as-is —
#   the dmg staple is what Gatekeeper checks on first open)

# zip alternative (app-only distribution, e.g. Sparkle feeds):
#   ditto -c -k --keepParent dist/LocalMusicGen.app dist/LocalMusicGen.zip
#   xcrun notarytool submit dist/LocalMusicGen.zip --keychain-profile localmusicgen --wait
#   xcrun stapler staple dist/LocalMusicGen.app
```

For real releases change `--timestamp=none` to `--timestamp` in
`scripts/package_app.sh` (notarization requires secure timestamps).

## Constraints

- **Mac App Store is off the table permanently**: the app downloads and runs
  Python code at runtime and needs `com.apple.security.cs.disable-library-validation`
  (runtime-installed wheels are unsigned). Distribution is Developer ID +
  notarization; add Sparkle later if auto-updates are wanted.
- The entitlements in `packaging/entitlements.plist` are the minimum for
  torch/MLX workers; keep `allow-unsigned-executable-memory` unless verified
  unnecessary on all supported models.
- App Sandbox is not enabled (spawned Python workers + Application Support data
  layout). Revisit only with a concrete need.

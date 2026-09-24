#!/bin/bash
# Put LocalMusicGen back to a first-run install — without re-downloading anything.
#
# The point is to be able to exercise onboarding (and every other "first time
# you see this" affordance) on a machine that already has hundreds of gigabytes
# of weights on it. Everything expensive to fetch lives OUTSIDE the app's data
# directory, so all of it survives:
#
#   the model library            model weights — wherever Settings points HF_HOME
#   the aux cache                weights the adapters fetch themselves: the
#                                separators, timbre models, torch hub checkouts
#                                and the MuseScore SoundFont. It moves with the
#                                library, so it is resolved, never guessed.
#   …/LocalMusicGen/ms-cache         ModelScope-hosted weights
#   …/LocalMusicGen/engine-src       the adapter venvs (torch and friends)
#   …/LocalMusicGen/envs             the engine's runtime dirs
#   …/LocalMusicGen/uv-cache         the wheel cache
#   …/LocalMusicGen/python           the bundled interpreter
#   Keychain                     the Hugging Face token
#
# The first two used to be printed as ~/.cache/huggingface and
# ~/.cache/localmusic-soundfonts, which on a machine with a relocated library
# is a 33 GB directory the app does not use.
#
# What goes is the app's own state: preferences (which is what makes the
# welcome sheet reappear), the library and its audio, scratch outputs, logs,
# and the engine's install markers.
#
# The markers are the subtle one. Install state is a marker file per model
# (registry.py), NOT bytes on disk — so deleting them makes the app show every
# model as "not installed" while the weights stay exactly where they are.
# That is the only way onboarding has anything to offer, and re-installing is
# close to instant: the download finds every blob already in the HF cache.
#
# Usage: scripts/reset_app.sh [--yes]     (or LOCALMUSICGEN_RESET_YES=1)
set -euo pipefail

ROOT="$HOME/Library/Application Support/LocalMusicGen"
DOMAIN="com.n14395.LocalMusicGen"
ASSUME_YES="${LOCALMUSICGEN_RESET_YES:-0}"
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# Where the weights really live, resolved the way the engine resolves them: the
# app's own preference first (Settings writes it, and passes it to the engine as
# HF_HOME), then an inherited HF_HOME, then the shared default. The aux root
# travels with the library rather than sitting beside it, so it gets the same
# treatment — its default is inside the data dir.
pref() { defaults read "$DOMAIN" "$1" 2>/dev/null || true; }
HF_ROOT="$(pref settings.engine.hfHome)"
HF_ROOT="${HF_ROOT:-${HF_HOME:-$HOME/.cache/huggingface}}"
AUX_ROOT="$(pref settings.engine.auxCache)"
AUX_ROOT="${AUX_ROOT:-${LOCALMUSICGEN_AUX_CACHE:-$ROOT/aux-cache}}"

# A running app would undo this: macOS caches preferences in cfprefsd and the
# app rewrites them as it quits, so a `defaults delete` underneath a live
# process buys nothing. A live engine is worse — it owns the directories we are
# about to remove.
for pattern in "LocalMusicGen.app" "local-music-gen-engine"; do
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        echo "LocalMusicGen is still running ($pattern). Quit it first — a reset" >&2
        echo "underneath a live process is silently undone." >&2
        exit 1
    fi
done

if [[ ! -d "$ROOT" ]]; then
    echo "Nothing to reset: $ROOT does not exist."
    exit 0
fi

# Order matters only for the report; the removals are independent.
REMOVE=(Database Library Outputs installed uploads Backend Logs)
# Everything under the data dir that a reset deliberately spares. aux-cache,
# ms-cache, envs and engine.lock were missing from this list, so the output
# could not answer the one question a reader has: do the expensive auxiliary
# weights survive? (They do.) aux-cache is reported by its resolved path below,
# because after a library relocate it is not in here at all.
KEEP=(engine-src uv-cache python ms-cache envs engine.lock)

size_of() { du -sh "$1" 2>/dev/null | cut -f1; }

# An absent root is reported as absent rather than as a blank size: with the
# library drive unmounted `du` prints nothing, and "  of model weights" reads
# like zero bytes when it means "cannot see it from here".
report_root() {
    if [[ -e "$2" ]]; then
        printf '    %-14s %-6s %s\n' "$1" "$(size_of "$2")" "$2"
    else
        printf '    %-14s %-6s %s\n' "$1" "—" "$2 (not mounted)"
    fi
}

bold "Reset LocalMusicGen to a first-run install"
echo
echo "  REMOVES"
printf '    %-14s %s\n' "preferences" "defaults domain $DOMAIN"
for dir in "${REMOVE[@]}"; do
    [[ -e "$ROOT/$dir" ]] || continue
    printf '    %-14s %s\n' "$dir" "$(size_of "$ROOT/$dir")"
done
echo
echo "  KEEPS"
report_root "model library" "$HF_ROOT"
report_root "aux weights" "$AUX_ROOT"
for dir in "${KEEP[@]}"; do
    [[ -e "$ROOT/$dir" ]] || continue
    printf '    %-14s %-6s %s\n' "$dir" "$(size_of "$ROOT/$dir")" "$ROOT/$dir"
done
echo
echo "  Your models stay on disk. They will read as \"not installed\" until you"
echo "  install them again, which re-uses the cache and costs almost nothing."
echo

if [[ "$ASSUME_YES" != "1" ]]; then
    if [[ ! -t 0 ]]; then
        echo "Refusing to reset without a terminal to confirm at." >&2
        echo "Pass --yes (or set LOCALMUSICGEN_RESET_YES=1) if you meant it." >&2
        exit 1
    fi
    # The library is the one thing here that cannot be re-fetched.
    read -r -p "This deletes generated songs and parts permanently. Continue? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Cancelled."; exit 1; }
fi

for dir in "${REMOVE[@]}"; do
    rm -rf "${ROOT:?}/$dir"
done
# Absent domain is not an error — a machine that has never run the app.
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

bold "✓ reset — next launch starts at onboarding"

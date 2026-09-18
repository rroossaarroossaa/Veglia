#!/bin/sh
# Veglia installer — one line from the terminal:
#   curl -fsSL https://raw.githubusercontent.com/rroossaarroossaa/veglia/main/install.sh | sh
#
# Downloads the latest release, puts Veglia.app into /Applications (or $VEGLIA_DIR),
# removes the quarantine flag so macOS does not show the "unidentified developer" dialog,
# and launches it. Re-running upgrades in place.
set -e
REPO="rroossaarroossaa/veglia"
DIR="${VEGLIA_DIR:-/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(uname)" = "Darwin" ] || { echo "Veglia is a macOS app." >&2; exit 1; }

echo "Downloading the latest Veglia…"
curl -fsSL -o "$TMP/Veglia.zip" "https://github.com/$REPO/releases/latest/download/Veglia.zip"
ditto -x -k "$TMP/Veglia.zip" "$TMP"
[ -d "$TMP/Veglia.app" ] || { echo "Download did not contain Veglia.app" >&2; exit 1; }

# Stop a running copy, replace it, drop the quarantine flag.
pkill -x Veglia 2>/dev/null || true
mkdir -p "$DIR"
rm -rf "$DIR/Veglia.app"
ditto "$TMP/Veglia.app" "$DIR/Veglia.app"
xattr -dr com.apple.quarantine "$DIR/Veglia.app" 2>/dev/null || true

open "$DIR/Veglia.app"
echo "Veglia is installed in $DIR and running. Look for the candle in the menu bar."

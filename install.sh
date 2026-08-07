#!/usr/bin/env bash
# One-line installer for Transcribe.
#
#   curl -fsSL https://raw.githubusercontent.com/J3012B/Transcribe_Mac/main/install.sh | bash
#
# Downloads the latest release DMG, copies the app to /Applications, and clears
# the quarantine flag so it opens without a Gatekeeper prompt.
set -euo pipefail

REPO="J3012B/Transcribe_Mac"
DMG_URL="https://github.com/$REPO/releases/latest/download/Transcribe.dmg"
APP="/Applications/Transcribe.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Transcribe is a macOS app; this installer only runs on macOS." >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "Transcribe requires an Apple Silicon (arm64) Mac." >&2
  exit 1
fi

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() {
  hdiutil detach "$MNT" -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> Downloading Transcribe…"
curl -fL# -o "$TMP/Transcribe.dmg" "$DMG_URL"

echo "==> Mounting…"
mkdir -p "$MNT"
hdiutil attach "$TMP/Transcribe.dmg" -nobrowse -readonly -mountpoint "$MNT" >/dev/null

echo "==> Installing to /Applications…"
rm -rf "$APP"
cp -R "$MNT/Transcribe.app" /Applications/
hdiutil detach "$MNT" -quiet

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✅ Installed. Launch it from Spotlight or:  open -a Transcribe"

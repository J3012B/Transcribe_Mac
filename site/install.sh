#!/bin/bash
# Transcribe installer. Downloads the latest release from GitHub, installs it to
# /Applications, and clears the download quarantine so the bundled engine can run.
#
#   curl -fsSL https://transcribe.heliconsolutions.net/install.sh | bash
set -e
DMG_URL="https://github.com/J3012B/Transcribe_Mac/releases/latest/download/Transcribe.dmg"
APP="/Applications/Transcribe.app"
BLUE='\033[1;34m'; GRN='\033[1;32m'; NC='\033[0m'

printf "${BLUE}Transcribe${NC}  installing...\n"

# Apple Silicon check
if [ "$(uname -m)" != "arm64" ]; then
  echo "This build needs an Apple Silicon Mac (M1 or newer)."; exit 1
fi

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

printf "  downloading the latest version...\n"
curl -fsSL "$DMG_URL" -o "$TMP/Transcribe.dmg"

printf "  installing to /Applications...\n"
mkdir -p "$MNT"
hdiutil attach "$TMP/Transcribe.dmg" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
osascript -e 'quit app "Transcribe"' >/dev/null 2>&1 || true
rm -rf "$APP"
cp -R "$MNT/Transcribe.app" /Applications/
hdiutil detach "$MNT" -quiet || true

# Clear quarantine so the bundled whisper engine is not killed by Gatekeeper.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

printf "${GRN}  done.${NC} opening Transcribe...\n"
printf "  (first launch downloads the speech model once, about 650 MB)\n"
open "$APP"

# Anonymous install count (privacy-friendly Plausible, no personal data).
# Best-effort and non-blocking: a short timeout, and failures are ignored.
curl -s -m 5 -X POST https://plausible.io/api/event \
  -H "Content-Type: application/json" \
  -H "User-Agent: Transcribe-Installer/1.0 (macOS; arm64)" \
  --data '{"name":"install","domain":"transcribe.heliconsolutions.net","url":"https://transcribe.heliconsolutions.net/install.sh"}' \
  >/dev/null 2>&1 || true

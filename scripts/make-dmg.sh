#!/usr/bin/env bash
# Package build/Transcribe.app into a distributable DMG.
#
# Optional signing / notarization (needed for a clean public download):
#   SIGN_IDENTITY   "Developer ID Application: ..."  -> sign the DMG
#   NOTARY_PROFILE  name saved via `xcrun notarytool store-credentials`
#     -- or --
#   AC_APPLE_ID / AC_PASSWORD (app-specific) / AC_TEAM_ID
# When notarization creds are present the DMG is notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Transcribe.app"
[ -d "$APP" ] || { echo "No $APP — run ./build.sh first."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Transcribe-${VERSION}.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

echo "==> Staging"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Transcribe.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Building $DMG"
rm -f "$DMG"
hdiutil create -volname "Transcribe" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing DMG"
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
fi

notarize() {
  echo "==> Notarizing (this can take a few minutes)"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_PASSWORD:-}" ] && [ -n "${AC_TEAM_ID:-}" ]; then
    xcrun notarytool submit "$DMG" --apple-id "$AC_APPLE_ID" \
      --password "$AC_PASSWORD" --team-id "$AC_TEAM_ID" --wait
  else
    echo "    No notarization credentials — skipping (DMG is signed but not notarized)."
    return 1
  fi
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
}

if [ -n "$SIGN_IDENTITY" ]; then
  notarize || true
else
  echo "==> Ad-hoc build: DMG is not signed or notarized."
  echo "    Recipients must right-click > Open, or run:"
  echo "      xattr -dr com.apple.quarantine /Applications/Transcribe.app"
fi

# Stable-named copy so release-'latest' download links never change.
# (A byte copy of the signed/stapled DMG keeps the notarization ticket.)
cp -f "$DMG" "build/Transcribe.dmg"

echo "==> Done: $DMG (and build/Transcribe.dmg)"

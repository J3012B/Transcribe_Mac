#!/usr/bin/env bash
# Build Transcribe.app from source.
# Compiles TranscribeApp.swift and assembles a self-contained .app bundle that
# ships whisper.cpp (CoreML + Metal). The Whisper model is downloaded on first
# launch; the yt-dlp/deno/ffmpeg helpers for the optional "transcribe from a URL"
# feature are downloaded on demand the first time that feature is used. Neither is
# part of the build, which keeps the app small.
#
# Signing:
#   - By default the bundle is ad-hoc signed (fine for local use; other Macs will
#     need a right-click > Open or `xattr -dr com.apple.quarantine`).
#   - Set SIGN_IDENTITY to a "Developer ID Application: ..." identity to produce a
#     Hardened-Runtime, distributable build. Pair with scripts/make-dmg.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Transcribe.app"
SDK="$(xcrun --show-sdk-path)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"          # "-" = ad-hoc

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling (swiftc)"
swiftc -parse-as-library -swift-version 5 -O \
  -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit \
  TranscribeApp.swift \
  -o "$APP/Contents/MacOS/Transcribe"

echo "==> Assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"
# Optional version stamping from CI (must happen before signing).
if [ -n "${MARKETING_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/MicGlyph.png Resources/MicGlyph@2x.png "$APP/Contents/Resources/"
cp -R vendor/whisper "$APP/Contents/Resources/whisper"
chmod +x "$APP/Contents/Resources/whisper/bin/whisper-cli"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> Ad-hoc codesign"
  find "$APP/Contents/Resources/whisper" \( -name '*.dylib' -o -name 'whisper-cli' \) \
    -exec codesign --force -s - {} \; 2>/dev/null || true
  codesign --force --deep -s - "$APP"
  echo "    NOTE: ad-hoc build — not notarized. For public distribution set"
  echo "          SIGN_IDENTITY and run scripts/make-dmg.sh."
else
  echo "==> Codesign (Developer ID: $SIGN_IDENTITY)"
  # Inside-out: nested code first, then the app with the Hardened Runtime.
  find "$APP/Contents/Resources/whisper" \( -name '*.dylib' -o -name 'whisper-cli' \) \
    -exec codesign --force --timestamp --options runtime -s "$SIGN_IDENTITY" {} \;
  codesign --force --timestamp --options runtime -s "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP" && echo "    signature verified"
fi

echo "==> Done: $APP"
echo "    Install with: cp -R \"$APP\" /Applications/ && lsregister -f /Applications/Transcribe.app"

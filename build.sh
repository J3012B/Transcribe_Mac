#!/usr/bin/env bash
# Build Transcribe.app from source.
# Compiles TranscribeApp.swift and assembles a self-contained .app bundle that
# ships whisper.cpp (CoreML + Metal). The Whisper model is downloaded on first
# launch, so it is not part of the build.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Transcribe.app"
SDK="$(xcrun --show-sdk-path)"

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
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/MicGlyph.png Resources/MicGlyph@2x.png "$APP/Contents/Resources/"
cp -R vendor/whisper "$APP/Contents/Resources/whisper"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc codesign"
codesign --force -s - "$APP/Contents/Resources/whisper/bin/whisper-cli" 2>/dev/null || true
codesign --force --deep -s - "$APP"

echo "==> Done: $APP"
echo "    Install with: cp -R \"$APP\" /Applications/ && lsregister -f /Applications/Transcribe.app"

# Transcribe

A self-contained macOS app that transcribes audio and video files **locally** on your Mac. No cloud upload, no ffmpeg, no dependencies to install. Drop a file in, get text out.

Built with SwiftUI and [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (CoreML + Metal accelerated), bundled inside the `.app`.

## Features

- 100% offline transcription (audio never leaves the machine)
- Bundles whisper.cpp with CoreML + Metal acceleration
- Converts audio via AVFoundation (no ffmpeg required)
- Downloads the Whisper model automatically on first launch (~650MB, cached)
- Supports `m4a, mp3, wav, aiff, caf, flac, mp4, mov, m4v, aac, 3gp, amr, au`

## Requirements

- macOS 14.0 or later
- Apple Silicon (arm64)
- Xcode command line tools (`xcode-select --install`) for building

## Build

```bash
./build.sh
```

This compiles `TranscribeApp.swift` and assembles `build/Transcribe.app`. To install:

```bash
cp -R build/Transcribe.app /Applications/
lsregister -f /Applications/Transcribe.app
```

## Project layout

| Path | Purpose |
|---|---|
| `TranscribeApp.swift` | The entire app (SwiftUI, single file) |
| `build.sh` | Compiles + assembles the `.app` bundle |
| `Info.plist` | App bundle metadata (`net.heliconsolutions.transcribe`) |
| `Resources/` | App icon (`.icns`), mic glyphs, icon master |
| `vendor/whisper/` | Bundled whisper.cpp runtime (`whisper-cli` + dylibs) |
| `icon/` | Python scripts that regenerate the icon and glyph assets |
| `scripts/` | CLI helpers — `transcribe.sh` (headless whisper wrapper), notify + AppleScript |

## CLI usage

For scripted / headless transcription without the GUI:

```bash
scripts/transcribe.sh <file-path> [language] [--copy]
```

#!/usr/bin/env bash
# Local audio/video transcription via whisper.cpp (whisper-cli).
# Usage: transcribe.sh <path-to-audio-or-video> [language]
#   language: ISO code (en, de, ...) or "auto" (default)
# Prints the transcript to stdout. All progress/diagnostics go to stderr.
set -euo pipefail

log() { echo "[transcribe] $*" >&2; }

SRC="${1:-}"
LANG="${2:-auto}"

if [[ -z "$SRC" ]]; then
  echo "Usage: transcribe.sh <path-to-audio-or-video> [language]" >&2
  exit 2
fi
if [[ ! -f "$SRC" ]]; then
  echo "[transcribe] File not found: $SRC" >&2
  exit 2
fi

# --- dependencies -----------------------------------------------------------
if ! command -v ffmpeg >/dev/null 2>&1; then
  log "ffmpeg not found. Install with: brew install ffmpeg"
  exit 3
fi
# Prefer a locally-built CoreML+Metal whisper-cli (Apple Neural Engine + GPU).
# It is ~20x faster than the x86/Rosetta Homebrew build on Apple Silicon,
# with identical output. Fall back to whatever is on PATH.
WHISPER_BIN="whisper-cli"
if [[ -x "$HOME/.local/bin/whisper-cli" ]]; then
  WHISPER_BIN="$HOME/.local/bin/whisper-cli"
elif ! command -v whisper-cli >/dev/null 2>&1; then
  log "whisper-cli not found. Installing via brew..."
  brew install whisper-cpp >&2
fi

# --- locate a GGML model ----------------------------------------------------
# Order: $WHISPER_MODEL > CoreML-ready model in cache > cached path >
# recursive find > download. The recursive find over ~/Library/Application
# Support is SLOW (100k+ files), so we cache the resolved path.
# A "CoreML-ready" model has a sibling <name>-encoder.mlmodelc, which lets
# whisper-cli run the encoder on the Neural Engine.
CACHE="$HOME/.cache/whisper"
CACHE_FILE="$CACHE/model_path"
mkdir -p "$CACHE"

MODEL="${WHISPER_MODEL:-}"
if [[ -z "$MODEL" ]]; then
  for m in "$CACHE"/ggml-*.bin; do
    [[ -e "$m" ]] || continue
    [[ -d "${m%.bin}-encoder.mlmodelc" ]] && { MODEL="$m"; break; }
  done
fi
if [[ -z "$MODEL" && -f "$CACHE_FILE" ]]; then
  cand="$(cat "$CACHE_FILE" 2>/dev/null)"
  [[ -n "$cand" && -f "$cand" ]] && MODEL="$cand"
fi
if [[ -z "$MODEL" ]]; then
  log "Locating a model (one-time scan) ..."
  MODEL="$(find \
      "$HOME/Library/Application Support" \
      "$HOME/.cache/whisper" \
      "$HOME/Library/Caches/whisper" \
      -type f -iname 'ggml*.bin' 2>/dev/null \
    | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi
if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
  MODEL="$CACHE/ggml-base.bin"
  if [[ ! -f "$MODEL" ]]; then
    log "No local model found. Downloading ggml-base.bin (~148MB) to $CACHE ..."
    curl -L --fail -o "$MODEL" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" >&2
  fi
fi
# Cache the resolved path for next time.
printf '%s' "$MODEL" > "$CACHE_FILE" 2>/dev/null || true
log "Using model: $MODEL"

# --- convert to 16kHz mono wav ---------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WAV="$TMP/audio.wav"
log "Converting to 16kHz mono wav ..."
ffmpeg -y -i "$SRC" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV" >/dev/null 2>&1

# --- transcribe -------------------------------------------------------------
# Use the performance-core count (falls back to all cores). On Apple Silicon,
# threads beyond the P-cores actually slow whisper.cpp down.
THREADS="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
log "Transcribing (lang=$LANG, threads=$THREADS, bin=$WHISPER_BIN) ..."
OUT="$TMP/transcript"
"$WHISPER_BIN" -m "$MODEL" -f "$WAV" -l "$LANG" -t "$THREADS" -otxt -of "$OUT" >&2

# Emit clean transcript to stdout (strip leading space per line, drop blanks).
sed 's/^ //' "$OUT.txt" | sed '/^[[:space:]]*$/d'

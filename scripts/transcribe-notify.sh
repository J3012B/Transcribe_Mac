#!/usr/bin/env bash
# Transcribe ONE file in the background for Transcribe.app:
# save <name>.txt next to the source, copy to clipboard, post notifications.
# Runs detached so the app stays responsive and can quit immediately.
set -uo pipefail
export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH

SRC="${1:-}"
[ -z "$SRC" ] && exit 2
DIR="$(cd "$(dirname "$0")" && pwd)"
base="$(basename "$SRC")"
out="${SRC%.*}.txt"

notify() {
  # $1 = message, $2 = title. Strip double quotes to keep osascript happy.
  local m="${1//\"/}" t="${2//\"/}"
  osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1
}

notify "Transcribing $base …" "Transcribe"

if bash "$DIR/transcribe.sh" "$SRC" auto > "$out" 2>/dev/null && [ -s "$out" ]; then
  pbcopy < "$out"
  notify "Saved $(basename "$out") · copied to clipboard" "Transcribe done"
else
  rm -f "$out" 2>/dev/null
  notify "Could not transcribe $base" "Transcribe failed"
  exit 1
fi

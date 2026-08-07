#!/usr/bin/env bash
# Bump the marketing version in Info.plist, e.g. `scripts/bump-version.sh 1.1`.
# The CI appends the build number automatically (1.1.<run>), so you only set the
# marketing part here. Commit + push to main to ship it.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-}"
[ -n "$NEW" ] || { echo "usage: scripts/bump-version.sh <marketing-version>  e.g. 1.1"; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" Info.plist
echo "Marketing version set to $NEW in Info.plist."
echo "Next: git commit -am \"Release $NEW\" && git push  (CI builds $NEW.<run> and publishes)."

#!/bin/bash
# End-to-end tests of the helper's recording, Save Full Log and SIGTERM paths (see HelperE2E.swift). Needs Screen
# Recording for the terminal it runs from. Records the whole screen into a scratch folder for a few seconds and
# deletes it afterwards (pass a folder to keep the output); shows nothing and presses no key.
#
#   app/tests/e2e/helper.sh [out dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
KEEP="${1:-}"
OUT="${KEEP:-$(mktemp -d -t deskmind-helper)}"
mkdir -p "$OUT"
BIN="$OUT/HelperE2E"
# The helper's sources as build.sh compiles them, without its @main (HandsHelper.swift).
SOURCES=$(grep -A1 'DeskMindHands" \\' build.sh | tail -1 | tr ' ' '\n' | grep -v '^Helper/HandsHelper.swift$' | grep -v '^$')
if ! swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$BIN" $SOURCES tests/e2e/HelperE2E.swift \
     > "$OUT/build.log" 2>&1; then
  cat "$OUT/build.log"; exit 1
fi
status=0
"$BIN" "$OUT" || status=$?
[ -z "$KEEP" ] && rm -rf "$OUT"
exit $status

#!/bin/bash
# End-to-end test of the live view on this Mac's desktop (see LiveViewE2E.swift). Needs Screen Recording and
# Automation for TextEdit for the terminal it runs from. Opens one scratch document in TextEdit in the background
# (never in front), moves its window, and closes it after; nothing else is touched and no key is pressed.
#
#   app/tests/e2e/live_view.sh [out dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-$(mktemp -d -t deskmind-liveview)}"
mkdir -p "$OUT"
BIN="$OUT/LiveViewE2E"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$BIN" \
  Shared/L10n.swift Shared/LiveView.swift Helper/LiveCard.swift tests/e2e/LiveViewE2E.swift
DOC="liveview-e2e-$$.txt"
printf 'Date,Customer,Order,Amount\n2026-09-02,Mark Chen,R-1180,560\n2026-09-27,Lisa Wong,R-3307,96\n' > "$OUT/$DOC"
open -g -a TextEdit "$OUT/$DOC"
for _ in $(seq 1 50); do
  osascript -e "tell application \"TextEdit\" to count (windows whose name contains \"$DOC\")" 2>/dev/null | grep -q '^1$' && break
  sleep 0.2
done
status=0
"$BIN" "$DOC" "$OUT" || status=$?
osascript -e "tell application \"TextEdit\" to close (every document whose path contains \"$OUT\") saving no" >/dev/null 2>&1 || true
echo "pictures: $OUT"
exit $status

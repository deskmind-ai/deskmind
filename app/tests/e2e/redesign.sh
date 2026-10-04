#!/bin/bash
# End-to-end test of the home screen's 小方 and the GIF export on this Mac's desktop (see RedesignE2E.swift). Needs
# Screen Recording for the terminal it runs from. Shows one small window of its own for a few seconds; no key is pressed.
#
#   app/tests/e2e/redesign.sh [out dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-$(mktemp -d -t deskmind-redesign)}"
mkdir -p "$OUT"
BIN="$OUT/RedesignE2E"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$BIN" \
  Shared/L10n.swift Shared/ExportName.swift Shared/XiaoFangMotion.swift Main/Brand.swift Main/Listening.swift \
  Main/ReplayGIF.swift tests/e2e/RedesignE2E.swift
status=0
"$BIN" "$OUT" || status=$?
echo "pictures and GIFs: $OUT"
exit $status

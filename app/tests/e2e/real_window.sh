#!/bin/bash
# The main window as a real window (U4 §3: what the offscreen PNGs cannot see -- the frame a launch restores, the
# window's least size, the columns where AppKit puts them). Builds the app from build.sh's own source list under
# another bundle id (ai.deskmind.app.e2e: its own defaults, its own saved state, never ai.deskmind.app's), starts it
# in the background (open -g: nothing comes to the front) with a temp support folder and no helper
# (WindowOnlyE2E: nothing is installed, started or stopped -- a DeskMind already running is left alone), and checks it
# with tests/e2e/RealWindowE2E.swift: launched fresh, then again from a saved 900 × 500 frame. The installed
# /Applications/DeskMind.app is never opened or read. Its screenshots go to the out folder (real-*.png).
#
#   app/tests/e2e/real_window.sh [out dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-$(mktemp -d -t deskmind-realwindow)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ID=ai.deskmind.app.e2e
WORK="$(mktemp -d -t deskmind-realwindow-build)"
APP="$WORK/DeskMind E2E.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  pkill -f "$APP/Contents/MacOS/DeskMind" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/$ID.savedState"
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
# the main app's sources, as build.sh compiles DeskMind.app
FILES=$(sed -n '/-o "\$MAIN\/Contents\/MacOS\/DeskMind"/{n;p;}' build.sh)
[ -n "$FILES" ] || { echo "real_window.sh: no main source list in build.sh" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Main-Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "DeskMind E2E" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "DeskMind E2E" "$APP/Contents/Info.plist"
cp Resources/brand/*.png Resources/models.json "$APP/Contents/Resources/"
if ! swiftc -j 2 -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$APP/Contents/MacOS/DeskMind" $FILES \
     > "$OUT/build-app.log" 2>&1; then cat "$OUT/build-app.log"; exit 1; fi
if ! swiftc -swift-version 5 -target arm64-apple-macos15 -o "$WORK/RealWindowE2E" tests/e2e/RealWindowE2E.swift \
     > "$OUT/build-check.log" 2>&1; then cat "$OUT/build-check.log"; exit 1; fi
defaults delete "$ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Saved Application State/$ID.savedState"
"$WORK/RealWindowE2E" "$APP" "$ID" "$OUT" "$WORK/support"

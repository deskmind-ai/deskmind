#!/bin/bash
# The main window, offscreen, each state to a PNG in light and dark (tests/snapshot/MainWindowSnapshot.swift): the
# render a designer compares with the boards before review. Built from the app's own source list (build.sh's main
# line), DeskMindApp.swift without its @main; run as a small accessory app bundle (小方's images are its resources).
# Draws in its own offscreen window only: no real app is driven, nothing comes to the front.
#
# usage: tests/snapshot.sh <out dir>   (from app/)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT_PNG="${1:?usage: tests/snapshot.sh <out dir>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FILES=$(sed -n '/-o "\$MAIN\/Contents\/MacOS\/DeskMind"/{n;p;}' build.sh)
SRC=()
for f in $FILES; do
  if [ "$f" = "Main/DeskMindApp.swift" ]; then sed '/^@main$/d' "$f" > "$WORK/DeskMindApp.swift"; SRC+=("$WORK/DeskMindApp.swift"); else SRC+=("$f"); fi
done
APP="$WORK/MainWindowSnapshot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/brand/*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.deskmind.snapshot</string>
<key>CFBundleExecutable</key><string>MainWindowSnapshot</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -j 2 -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$APP/Contents/MacOS/MainWindowSnapshot" \
  "${SRC[@]}" tests/snapshot/MainWindowSnapshot.swift
mkdir -p "$OUT_PNG"
"$APP/Contents/MacOS/MainWindowSnapshot" "$(cd "$OUT_PNG" && pwd)"

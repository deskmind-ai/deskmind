#!/usr/bin/env bash
# Build the two-app prototype: DeskMind.app with DeskMind Hands.app inside Contents/Library/LoginItems, and the
# LaunchAgent plist that SMAppService registers. Signs both with one identity (same Team ID).
#
#   SIGN_ID="Apple Development: ..." ./app/build.sh      (default: the first Apple Development identity)
#   DIST=1 ./app/build.sh                                  (a release: see below)
#
# DIST=1 signs with the Developer ID Application identity and a secure timestamp, then packages DeskMind.dmg,
# notarizes it with `notarytool` (keychain profile NOTARY_PROFILE, default "deskmind", created once with
# `xcrun notarytool store-credentials deskmind --apple-id <id> --team-id <team> --password <app-specific>`) and
# staples the ticket. NOTARIZE=0 stops after the signed DMG.
set -euo pipefail
cd "$(dirname "$0")"
DIST="${DIST:-0}"
# A release is built apart from the development app: opening it would install its helper over the development one,
# and a helper signed by another team loses the permissions granted to the one before.
if [ "$DIST" = 1 ]; then OUT=../build/release; else OUT=../build; fi
MAIN="$OUT/DeskMind.app"
HELPER="$MAIN/Contents/Library/LoginItems/DeskMind Hands.app"
if [ "$DIST" = 1 ]; then
  SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
  TS="--timestamp"          # notarization requires a secure timestamp on every binary
else
  SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
  TS="--timestamp=none"     # a development build: no round trip to Apple's timestamp server per binary
fi
[ -n "$SIGN_ID" ] || { echo "build: no signing identity found (DIST=$DIST; SIGN_ID=- signs ad hoc)" >&2; exit 1; }
# Ad hoc (SIGN_ID=-, CI without a certificate): no timestamp is possible.
if [ "$SIGN_ID" = "-" ]; then TS="--timestamp=none"; fi

rm -rf "$MAIN"
mkdir -p "$OUT"
mkdir -p "$MAIN/Contents/MacOS" "$MAIN/Contents/Library/LaunchAgents" "$HELPER/Contents/MacOS"

# Unit tests first (what needs no screen): a failure stops the build.
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$OUT/decision-tests" \
  Shared/L10n.swift Shared/Decision.swift Shared/Island.swift Shared/AppMention.swift Shared/Routing.swift Shared/FileMention.swift Shared/DownloadSource.swift Shared/LiveView.swift Shared/IssueReport.swift Shared/AppWindow.swift tests/DecisionTests.swift
"$OUT/decision-tests"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$HELPER/Contents/MacOS/DeskMindHands" \
  Shared/Protocol.swift Shared/Models.swift Shared/Routing.swift Shared/L10n.swift Shared/Decision.swift Helper/ServerAuth.swift Helper/BrainServer.swift Helper/EyesServer.swift Helper/ScreenRecorder.swift Shared/LiveView.swift Shared/AppWindow.swift Helper/LiveCard.swift Helper/Runner.swift Helper/HandsHelper.swift
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$MAIN/Contents/MacOS/DeskMind" \
  Shared/Protocol.swift Shared/Models.swift Shared/Routing.swift Shared/L10n.swift Main/Brand.swift Main/GrantPanel.swift Main/RunView.swift Main/RunOverlay.swift Main/ModelDownloader.swift Shared/AppMention.swift Shared/FileMention.swift Shared/DownloadSource.swift Main/AppScope.swift Main/History.swift Main/GoalRunView.swift Main/HomeView.swift Shared/Decision.swift Shared/Island.swift Main/Recording.swift Main/IslandView.swift Shared/LiveView.swift Shared/IssueReport.swift Main/DeskMindApp.swift

cp Resources/Main-Info.plist "$MAIN/Contents/Info.plist"
mkdir -p "$MAIN/Contents/Resources" "$HELPER/Contents/Resources"
cp Resources/brand/*.png "$MAIN/Contents/Resources/"
cp Resources/models.json "$MAIN/Contents/Resources/"
# App icons from the brand avatar (the square with the dot).
ICONSET="$OUT/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/brand/avatar.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/brand/avatar.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$MAIN/Contents/Resources/AppIcon.icns"
cp "$MAIN/Contents/Resources/AppIcon.icns" "$HELPER/Contents/Resources/AppIcon.icns"
cp Resources/Helper-Info.plist "$HELPER/Contents/Info.plist"
# VERSION (e.g. from a v1.2.3 tag) and BUILD_NUMBER (e.g. the CI run number) override the plists' own. A pre-release
# (v1.2.3-rc.1) names its DMG in full; the bundle's version is the numbers alone (1.2.3), the form macOS expects.
for plist in "$MAIN/Contents/Info.plist" "$HELPER/Contents/Info.plist"; do
  if [ -n "${VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$plist"; fi
  if [ -n "${BUILD_NUMBER:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"; fi
done
cp Resources/models.json "$HELPER/Contents/Resources/"
cp Resources/ai.deskmind.hands.plist "$MAIN/Contents/Library/LaunchAgents/ai.deskmind.hands.plist"

# The Python runtime, with every Mach-O in it signed by us: under the hardened runtime the helper may only load
# code signed by its own team.
./runtime.sh
# Every third-party component shipped, with its licence (fails if one has none).
python3 tools/make_notices.py ../build/cache/runtime ../build/cache/pbs-licenses/python/licenses \
  "${PEEKABOO_SRC:-$HOME/.local/share/deskmind/peekaboo-vendor/src}" "$MAIN/Contents/Resources/THIRD_PARTY_NOTICES.txt" >/dev/null
cp "$MAIN/Contents/Resources/THIRD_PARTY_NOTICES.txt" "$HELPER/Contents/Resources/"
# Signing the hundreds of binaries in the runtime took most of every build: sign a copy once per runtime version
# and identity, and reuse it.
SIGNED=../build/cache/runtime-signed
# Not $( [ ... ] && ... ): under set -e a false test there ended every development build, silently.
if [ "$DIST" = 1 ]; then SIGNED="$SIGNED-dist"; fi
want="$(cat ../build/cache/runtime/.stamp)|$SIGN_ID|$TS"
if [ ! -f "$SIGNED/.signed" ] || [ "$(cat "$SIGNED/.signed")" != "$want" ]; then
  rm -rf "$SIGNED"; cp -R ../build/cache/runtime "$SIGNED"; rm -f "$SIGNED/.stamp"
  find "$SIGNED" -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime $TS -s "$SIGN_ID" "$f" 2>/dev/null \
        || { echo "build: could not sign $f" >&2; exit 1; }
    fi
  done
  echo "$want" > "$SIGNED/.signed"
fi
cp -R "$SIGNED" "$HELPER/Contents/Resources/runtime"
rm -f "$HELPER/Contents/Resources/runtime/.signed"

# Inner bundle first, then the outer one.
codesign --force --options runtime $TS --entitlements Resources/Helper.entitlements -s "$SIGN_ID" "$HELPER"
codesign --force --options runtime $TS -s "$SIGN_ID" "$MAIN"
codesign --verify --deep --strict "$MAIN" && echo "built and signed: $MAIN ($SIGN_ID)"

[ "$DIST" = 1 ] || exit 0

# The release: a DMG with the app and a link to /Applications, signed, notarized and stapled.
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAIN/Contents/Info.plist")}"
DMG="$OUT/DeskMind-$VERSION.dmg"
STAGE="$OUT/dmg"; rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
ditto "$MAIN" "$STAGE/DeskMind.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "DeskMind" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force $TS -s "$SIGN_ID" "$DMG"
echo "release: $DMG (signed)"
[ "${NOTARIZE:-1}" = 1 ] || exit 0
# An App Store Connect API key (CI: NOTARY_KEY = path to the .p8, NOTARY_KEY_ID, NOTARY_ISSUER), else the keychain
# profile stored once on this Mac.
if [ -n "${NOTARY_KEY:-}" ]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-deskmind}")
fi
OUTPUT="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 45m --output-format json)"
echo "$OUTPUT"
ID="$(echo "$OUTPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
STATUS="$(echo "$OUTPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  echo "release: notarization $STATUS" >&2; exit 1
fi
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "release: $DMG (notarized, stapled)"

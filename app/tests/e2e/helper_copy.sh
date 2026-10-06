#!/bin/bash
# End-to-end test of which DeskMind Hands copy runs (Shared/HelperLocation.swift), on this Mac, with the development
# build from build.sh running (../build/DeskMind.app, which installs its helper in Application Support). It starts the
# helper copy nested in DeskMind.app the way macOS's "Quit & Reopen" does (by opening that bundle), and checks that the
# nested copy hands over and exits, and that the helper answering the app is the installed copy. Presses no key.
#
#   app/tests/e2e/helper_copy.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
APP="$(cd .. && pwd)/build/DeskMind.app"
NESTED="$APP/Contents/Library/LoginItems/DeskMind Hands.app"
INSTALLED="$HOME/Library/Application Support/DeskMind/DeskMind Hands.app"
SOCK="$HOME/Library/Application Support/DeskMind/hands.sock"
fail=0
check() { if eval "$1"; then echo "PASS $2"; else echo "FAIL $2"; fail=$((fail + 1)); fi; }
running_from() { pgrep -fl "DeskMind Hands.app/Contents/MacOS/DeskMindHands" | grep -c "$1"; }
helper_path() {
  python3 - "$SOCK" <<'PY'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
    s.sendall(b'{"op":"status"}\n'); print(json.loads(s.recv(65536).split(b"\n")[0]).get("path", ""))
except Exception: print("")
PY
}
pgrep -f "$APP/Contents/MacOS/DeskMind" >/dev/null || { echo "start the development build first: open -g \"$APP\""; exit 2; }
[ -d "$INSTALLED" ] || { echo "no installed helper at $INSTALLED"; exit 2; }

open -g -n "$NESTED"                       # what LaunchServices does for "Quit & Reopen"
for _ in $(seq 1 40); do [ "$(running_from "LoginItems")" = 0 ] && break; sleep 0.5; done
sleep 3                                   # let the hand-over (or the app) start the installed copy
check '[ "$(running_from "LoginItems")" = 0 ]' "the nested copy is not left running"
check '[ "$(running_from "Application Support")" -ge 1 ]' "the installed copy is running"
for _ in $(seq 1 20); do p="$(helper_path)"; [ -n "$p" ] && break; sleep 0.5; done
check '[ "$p" = "$INSTALLED" ]' "the helper answering the app is the installed copy ($p)"
echo "helper_copy: $([ $fail = 0 ] && echo all passed || echo "$fail failed")"
exit $fail

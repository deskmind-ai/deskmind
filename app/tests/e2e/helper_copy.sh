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
count_helpers() { pgrep -f "DeskMind Hands.app/Contents/MacOS/DeskMindHands" | wc -l | tr -d " "; }
# A helper started while another runs waits up to 15 s for it to go (HelperLock), so the count settles after that.
settles_to_one() { for _ in $(seq 1 50); do [ "$(count_helpers)" = 1 ] && return 0; sleep 0.5; done; return 1; }
wait_answering() { for _ in $(seq 1 120); do p="$(helper_path)"; [ -n "$p" ] && return 0; sleep 0.5; done; return 1; }
send_restart() {
python3 - "$SOCK" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); s.sendall(b'{"op":"restart"}\n'); s.recv(4096)
PY
}
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
# The hand-over copies the shipped helper first when the installed one differs (1.1 GB, ~10 s after a rebuild).
for _ in $(seq 1 120); do [ "$(running_from "LoginItems")" = 0 ] && break; sleep 0.5; done
check '[ "$(running_from "LoginItems")" = 0 ]' "the nested copy is not left running"
wait_answering
check '[ "$(running_from "Application Support")" -ge 1 ]' "the installed copy is running"
check '[ "$p" = "$INSTALLED" ]' "the helper answering the app is the installed copy ($p)"
# With no installed copy (a first launch, or an update the app has not copied out yet): the nested copy installs the
# version it shipped with, then hands over to it. The app is quit for this, and opened again after.
osascript -e 'tell application id "ai.deskmind.app" to quit' >/dev/null 2>&1; sleep 2
pkill -TERM -f "DeskMind Hands.app/Contents/MacOS/DeskMindHands"; sleep 2
rm -rf "$INSTALLED"
open -g -n "$NESTED"
wait_answering
check '[ -d "$INSTALLED" ]' "with none installed, the nested copy installs one"
check 'cmp -s "$NESTED/Contents/MacOS/DeskMindHands" "$INSTALLED/Contents/MacOS/DeskMindHands"' "the installed copy is the one this app shipped"
check '[ "$(running_from "LoginItems")" = 0 ] && [ "$(running_from "Application Support")" -ge 1 ]' "and it hands over to it"
# Restart with the app closed: the helper starts its own successor (Restart button, restart for a grant).
before="$(pgrep -f "Application Support/DeskMind/DeskMind Hands.app/Contents/MacOS/DeskMindHands" | head -1)"
send_restart
after=""
for _ in $(seq 1 30); do
  after="$(pgrep -f "Application Support/DeskMind/DeskMind Hands.app/Contents/MacOS/DeskMindHands" | head -1)"
  [ -n "$after" ] && [ "$after" != "$before" ] && break; sleep 0.5
done
check '[ -n "$before" ] && [ -n "$after" ] && [ "$after" != "$before" ]' "with the app closed, a restart brings the helper back ($before -> $after)"
check '! pgrep -f "$APP/Contents/MacOS/DeskMind\$" >/dev/null' "and the app was not needed for it"
check 'settles_to_one' "exactly one helper runs after it"

# Restart with the app open: the helper's own relaunch and the app's must not leave two helpers.
open -g "$APP"; sleep 8; wait_answering
send_restart
sleep 3
check 'settles_to_one' "with the app open, a restart leaves exactly one helper"
wait_answering
check '[ "$p" = "$INSTALLED" ]' "and it answers the app ($p)"
echo "helper_copy: $([ $fail = 0 ] && echo all passed || echo "$fail failed")"
exit $fail

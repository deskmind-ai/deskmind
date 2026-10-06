#!/bin/bash
# End-to-end test of the app replacing a hung helper (Shared/HelperLocation.swift, hungAction), on this Mac, with the
# development build from build.sh running (../build/DeskMind.app). It stops the helper with SIGSTOP -- alive, holding
# its socket and its lock, answering nothing, the way a hung one is -- and checks that the app quits it, kills it
# when it does not go, and that a fresh helper answers. The app's own launch could not do it: it only brings the
# running instance forward. Presses no key; takes about a minute.
#
#   app/tests/e2e/hung_helper.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
APP="$(cd .. && pwd)/build/DeskMind.app"
SOCK="$HOME/Library/Application Support/DeskMind/hands.sock"
fail=0
check() { if eval "$1"; then echo "PASS $2"; else echo "FAIL $2"; fail=$((fail + 1)); fi; }
helper_pid() {
  python3 - "$SOCK" <<'PY'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1])
    s.sendall(b'{"op":"status"}\n'); print(json.loads(s.recv(65536).split(b"\n")[0]).get("pid", ""))
except Exception: print("")
PY
}
pgrep -f "$APP/Contents/MacOS/DeskMind" >/dev/null || { echo "start the development build first: open -g \"$APP\""; exit 2; }
# macOS's "DeskMind Hands is not responding" alerts, one per attempt to open a hung helper (10-06: a stack of them).
alerts() { osascript -e 'tell application "System Events" to count windows of (processes whose name is "CoreServicesUIAgent")' 2>/dev/null | tr -d ' ,' ; }
alerts_before="$(alerts)"
before=""
for _ in $(seq 1 60); do before="$(helper_pid)"; [ -n "$before" ] && break; sleep 0.5; done
[ -n "$before" ] || { echo "no helper answers"; exit 2; }

kill -STOP "$before"
t0=$(date +%s)
after=""
for _ in $(seq 1 120); do
  if [ "$(alerts)" != "$alerts_before" ]; then   # the app opened the hung helper: stop at the first alert, not a stack
    kill -CONT "$before"; kill -KILL "$before"; echo "FAIL an alert came up; the hung helper was killed by the test"
    exit 1
  fi
  after="$(helper_pid)"
  [ -n "$after" ] && [ "$after" != "$before" ] && break
  sleep 1
done
took=$(( $(date +%s) - t0 ))
check '[ -n "$after" ] && [ "$after" != "$before" ]' "a fresh helper answers after the old one hung ($before -> $after, ${took}s)"
check '! kill -0 "$before" 2>/dev/null' "the hung helper is gone"
check '[ "$took" -ge 25 ]' "and not before it had been silent for a while (${took}s)"
sleep 3
check '[ "$(pgrep -f "DeskMind Hands.app/Contents/MacOS/DeskMindHands" | wc -l | tr -d " ")" = 1 ]' "exactly one helper runs"
check '[ "$(alerts)" = "$alerts_before" ]' "no \"not responding\" alert came up ($alerts_before -> $(alerts))"
kill -0 "$before" 2>/dev/null && { kill -CONT "$before"; kill -KILL "$before"; }   # leave nothing stopped behind
echo "hung_helper: $([ $fail = 0 ] && echo all passed || echo "$fail failed")"
exit $fail

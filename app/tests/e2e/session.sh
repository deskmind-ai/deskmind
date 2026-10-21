#!/bin/bash
# End-to-end test of the helper's chat sessions (Helper/SessionHost.swift) through a socket: session.open / send /
# end, sessions.list, sessions.watch with cursors (no duplicates, no gaps, a reply in progress caught up), a question
# card answered over a task on the simulated computer, the machine lock, idle sessions closing, and a session's task
# stopping when the helper goes. Needs the built runtime (app/runtime.sh: ../build/cache/runtime); no model service
# (a fake one on localhost), no permissions, no window; drives nothing on this Mac.
#
#   app/tests/e2e/session.sh [out dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
KEEP="${1:-}"
OUT="${KEEP:-$(mktemp -d -t deskmind-session)}"
mkdir -p "$OUT"
RUNTIME="${RUNTIME:-../build/cache/runtime}"
[ -x "$RUNTIME/node/bin/node" ] && [ -f "$RUNTIME/harness/harness.mjs" ] || { echo "session.sh: no runtime at $RUNTIME (run app/runtime.sh)" >&2; exit 1; }
RUNTIME="$(cd "$RUNTIME" && pwd)"
BIN="$OUT/SessionE2E"
# The helper's sources as build.sh compiles them, without its @main (HandsHelper.swift).
SOURCES=$(grep -A1 'DeskMindHands" \\' build.sh | tail -1 | tr ' ' '\n' | grep -v '^Helper/HandsHelper.swift$' | grep -v '^$')
if ! swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$BIN" $SOURCES tests/e2e/SessionE2E.swift \
     > "$OUT/build.log" 2>&1; then
  cat "$OUT/build.log"; exit 1
fi
status=0
"$BIN" lock "$OUT/lock" || status=$?
python3 -I tests/e2e/session_e2e.py "$BIN" "$RUNTIME/node/bin/node" "$RUNTIME/harness/harness.mjs" "$OUT" || status=$((status + $?))
[ -z "$KEEP" ] && [ "$status" = 0 ] && rm -rf "$OUT"
[ "$status" = 0 ] || echo "session.sh: output kept in $OUT"
exit $status

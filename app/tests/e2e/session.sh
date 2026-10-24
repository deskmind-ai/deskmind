#!/bin/bash
# End-to-end test of the helper's chat sessions (Helper/SessionHost.swift) through a socket: session.open / send /
# end, sessions.list, sessions.watch with cursors (no duplicates, no gaps, a reply in progress caught up), a question
# card answered over a task on the simulated computer, the machine lock, idle sessions closing, and a session's task
# stopping when the helper goes; then the app's own session client (tests/e2e/SessionClientE2E.swift) against it, and
# the 0.5 main window's model on that client (tests/e2e/ShellE2E.swift: a conversation across a quit and a helper
# restart, a missing key, delete). Needs the built runtime (app/runtime.sh: ../build/cache/runtime); no model service
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
# the app's session client (Shared/SessionClient.swift and its reducer) against the same helper
CLIENT="$OUT/SessionClientE2E"
if ! swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$CLIENT" Shared/L10n.swift Shared/Protocol.swift \
     Shared/ProtocolEvent.swift Shared/SessionReducer.swift Shared/ResultCard.swift Shared/CardModel.swift Shared/CardStore.swift Shared/CardLayout.swift Shared/SessionClient.swift tests/e2e/PathTransport.swift \
     tests/e2e/SessionClientE2E.swift > "$OUT/build-client.log" 2>&1; then
  cat "$OUT/build-client.log"; exit 1
fi
# the 0.5 window's model (Shared/Shell.swift) on that client, against the same helper
SHELL_BIN="$OUT/ShellE2E"
if ! swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$SHELL_BIN" Shared/L10n.swift Shared/Protocol.swift \
     Shared/ProtocolEvent.swift Shared/SessionReducer.swift Shared/ResultCard.swift Shared/CardModel.swift Shared/CardStore.swift Shared/CardLayout.swift Shared/SessionClient.swift Shared/Shell.swift Shared/GoalRun.swift \
     tests/e2e/PathTransport.swift tests/e2e/ShellE2E.swift > "$OUT/build-shell.log" 2>&1; then
  cat "$OUT/build-shell.log"; exit 1
fi
# the helper's own op run (the old window's task, HarnessRun.run) against models.off, hermetic: its runtime is a node
# wrapper (tests/e2e/node-wrapper.sh) that refuses anything but the helper's driver hands and runs it on sim, with a
# clean environment and the fake model; a support folder of its own (DeskMindIPC.supportOverride)
OPRUN="$OUT/oprun"
mkdir -p "$OPRUN/bin/runtime/node/bin" "$OPRUN/bin/runtime/harness" "$OPRUN/logs" "$OPRUN/home" "$OPRUN/tmp"
OPRUN_BIN="$OPRUN/bin/OpRunE2E"
if ! swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$OPRUN_BIN" $SOURCES tests/e2e/OpRunE2E.swift \
     > "$OUT/build-oprun.log" 2>&1; then
  cat "$OUT/build-oprun.log"; exit 1
fi
cp tests/e2e/node-wrapper.sh "$OPRUN/bin/runtime/node/bin/node"
chmod +x "$OPRUN/bin/runtime/node/bin/node"
ln -sf "$RUNTIME/harness/harness.mjs" "$OPRUN/bin/runtime/harness/harness.mjs"
mkdir -p "$OPRUN/bin/runtime/hands"
printf 'e2e' > "$OPRUN/bin/runtime/hands/.version"     # (the work copy OpRunE2E lays out says the same: nothing to copy)
[ -e "$RUNTIME/bin" ] && ln -sfn "$RUNTIME/bin" "$OPRUN/bin/runtime/bin"
oprun() {   # oprun <scenario> [fake model mode]
  local port="$OPRUN/port-$1" fake pid code=0
  rm -f "$port"
  python3 -I tests/e2e/fake2.py "$port" ${2:-} & fake=$!
  for _ in $(seq 100); do [ -s "$port" ] && break; sleep 0.05; done
  printf 'REAL_NODE=%q\nLOGDIR=%q\nFAKE_HOME=%q\nFAKE_TMP=%q\nLOCAL_URL=%q\n' "$RUNTIME/node/bin/node" "$OPRUN/logs" "$OPRUN/home" \
    "$OPRUN/tmp" "http://127.0.0.1:$(cat "$port")" > "$OPRUN/bin/runtime/wrapper.env"
  "$OPRUN_BIN" "$1" "http://127.0.0.1:$(cat "$port")" || code=$?
  kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null || true
  return $code
}
status=0
for scenario in stop gate race twice; do oprun "$scenario" || status=$((status + $?)); done
oprun undo undo || status=$((status + $?))
"$BIN" lock "$OUT/lock" || status=$((status + $?))
"$BIN" linger "$OUT/linger" || status=$((status + $?))
python3 -I tests/e2e/session_e2e.py "$BIN" "$RUNTIME/node/bin/node" "$RUNTIME/harness/harness.mjs" "$OUT" "$CLIENT" "$SHELL_BIN" || status=$((status + $?))
[ -z "$KEEP" ] && [ "$status" = 0 ] && rm -rf "$OUT"
[ "$status" = 0 ] || echo "session.sh: output kept in $OUT"
exit $status

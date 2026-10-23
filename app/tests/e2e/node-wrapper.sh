#!/bin/bash
# The op-run e2e's stand-in for runtime/node/bin/node (tests/e2e/OpRunE2E.swift, laid out by session.sh): the helper's
# op run (HarnessRun.run) unchanged, but the harness it starts runs on the simulated computer with a clean environment
# and the fake model. Refuses to start anything unless the request line names driver "hands" and is rewritten to "sim"
# (so nothing on this Mac can be driven); with no request line (a run that is not started) it exits at once.
CONF="$(dirname "$0")/../../wrapper.env"
. "$CONF" || exit 3
IFS= read -r first || exit 3
case "$first" in *'"driver":"hands"'*) ;; *) echo "wrapper: request has no driver hands: refusing" >&2; exit 3;; esac
first="${first//\"driver\":\"hands\"/\"driver\":\"sim\"}"
case "$first" in *'"driver":"sim"'*) ;; *) exit 3;; esac
case "$first" in *'"driver":"hands"'*) exit 3;; esac
echo "$first" >> "$LOGDIR/requests.log"
exec /usr/bin/env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin TMPDIR="$FAKE_TMP" LOCAL_URL="$LOCAL_URL" LOCAL_API_KEY=test-key \
  "$REAL_NODE" "$@" < <(printf '%s\n' "$first"; exec cat)

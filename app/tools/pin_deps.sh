#!/bin/bash
# Pin app/deps.lock to the pushed HEAD (origin/main) of each sibling checkout: ../hands, ../bench, ../brain,
# ../eyes, or HANDS_REPO etc. A commit that is not on GitHub could not be checked out by CI, so origin/main it is.
set -euo pipefail
cd "$(dirname "$0")/.."
SIBLINGS="$(cd .. && pwd)/.."
{
  sed -n '/^#/p' deps.lock
  for name in HANDS BENCH BRAIN EYES HARNESS; do
    var="${name}_REPO"; repo="${!var:-$SIBLINGS/$(echo "$name" | tr '[:upper:]' '[:lower:]')}"
    git -C "$repo" fetch -q origin
    # the harness's 0.5 line is its 0.5-runtime branch until it is merged (HARNESS_BRANCH overrides)
    branch=main; [ "$name" = HARNESS ] && branch="${HARNESS_BRANCH:-0.5-runtime}"
    echo "$name=$(git -C "$repo" rev-parse "origin/$branch")"
  done
} > deps.lock.new
mv deps.lock.new deps.lock
cat deps.lock

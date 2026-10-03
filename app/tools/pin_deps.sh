#!/bin/bash
# Pin app/deps.lock to the pushed HEAD (origin/main) of each sibling checkout: ../hands, ../bench, ../brain,
# ../eyes, or HANDS_REPO etc. A commit that is not on GitHub could not be checked out by CI, so origin/main it is.
set -euo pipefail
cd "$(dirname "$0")/.."
SIBLINGS="$(cd .. && pwd)/.."
{
  sed -n '/^#/p' deps.lock
  for name in HANDS BENCH BRAIN EYES; do
    var="${name}_REPO"; repo="${!var:-$SIBLINGS/$(echo "$name" | tr '[:upper:]' '[:lower:]')}"
    git -C "$repo" fetch -q origin
    echo "$name=$(git -C "$repo" rev-parse origin/main)"
  done
} > deps.lock.new
mv deps.lock.new deps.lock
cat deps.lock

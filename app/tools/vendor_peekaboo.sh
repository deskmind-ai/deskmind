#!/usr/bin/env bash
# Publish the Peekaboo build the app ships as a release asset of this repo, for CI to download.
#
#   app/tools/vendor_peekaboo.sh <Peekaboo checkout>      (or PEEKABOO_CHECKOUT=<dir>)
#
# The app ships a Peekaboo CLI built from a checkout (today a fork with a local commit, until an official
# release carries openclaw/Peekaboo#839). CI cannot rebuild that checkout, so the binary and the licence files of
# everything linked into it are uploaded once, as release "vendor-peekaboo-<version>-<commit>", and
# app/vendor.env names that release. Switching to an official Peekaboo release later means pointing CI at
# upstream's own release asset instead.
#
# Build the checkout so the binary names no path of the machine it was built on (the first vendored build carried
# /Users/<name>/... 3,126 times, in #file strings and debug-map entries): from a neutral copy of the checkout, with
# the source prefix mapped away --
#
#   rsync -a --exclude .build <checkout>/ /private/tmp/pkb/Peekaboo/ && cd /private/tmp/pkb/Peekaboo/Apps/CLI
#   rm -rf ../../.swiftpm/peekaboo-workspace; find ../.. -path '*/configuration/mirrors.json' -delete
#   W=/private/tmp/pkb/Peekaboo; python3 ../../scripts/setup-swift-workspace.py run -- swift build -c release \
#     -Xswiftc -file-prefix-map -Xswiftc $W=. -Xswiftc -debug-prefix-map -Xswiftc $W=. -Xlinker -oso_prefix -Xlinker $W
#
# and publish from that copy. Debug symbols are stripped here, and the upload refuses a binary that still names the
# builder's home folder or user name, or the build directory.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-${PEEKABOO_CHECKOUT:-}}"
[ -n "$SRC" ] || { echo "usage: $0 <Peekaboo checkout> (or set PEEKABOO_CHECKOUT)" >&2; exit 1; }
BIN="$SRC/Apps/CLI/.build/release/peekaboo"
[ -x "$BIN" ] || { echo "no release build at $BIN" >&2; exit 1; }
VER="$("$BIN" --version | awk '{print $2}')"
SHA="$(git -C "$SRC" rev-parse --short=9 HEAD)"
TAG="vendor-peekaboo-$VER-$SHA"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$BIN" "$TMP/peekaboo"
strip -S "$TMP/peekaboo"                     # the debug map names every object file by its build path
codesign -f -s - "$TMP/peekaboo" 2>/dev/null   # strip invalidates the ad hoc signature; the app re-signs it anyway
# The builder's home and user name, and the build directory ("/Users/" alone is in Peekaboo's own help text).
for leak in "$HOME" "/$(id -un)/" "$(cd "$SRC" && pwd -P)"; do
  n="$( (LC_ALL=C grep -a -o -- "$leak" "$TMP/peekaboo" || true) | wc -l | tr -d ' ')"
  [ "$n" = 0 ] || { echo "peekaboo still names $leak ($n times): build it as described at the top" >&2; exit 1; }
done
# The Swift back-deployment library it loads through @loader_path on macOS 15 (see runtime.sh).
cp "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib" "$TMP/"
# The licence files, in the layout tools/make_notices.py reads from a checkout.
( cd "$SRC" && find . -maxdepth 2 \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
    -not -path './.build/*' -not -path './Apps/*' -print0
  find Apps/CLI/.build/checkouts -maxdepth 2 \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0
) | (cd "$SRC" && tar -czf "$TMP/peekaboo-licenses.tar.gz" --null -T -)
( cd "$TMP" && shasum -a 256 peekaboo libswiftCompatibilitySpan.dylib peekaboo-licenses.tar.gz > SHA256SUMS )
if env -u GITHUB_TOKEN gh release view "$TAG" -R deskmind-ai/deskmind >/dev/null 2>&1; then
  env -u GITHUB_TOKEN gh release upload "$TAG" -R deskmind-ai/deskmind --clobber \
    "$TMP/peekaboo" "$TMP/libswiftCompatibilitySpan.dylib" "$TMP/peekaboo-licenses.tar.gz" "$TMP/SHA256SUMS"
  echo "$TAG updated"
else
  env -u GITHUB_TOKEN gh release create "$TAG" -R deskmind-ai/deskmind --prerelease \
    --title "Peekaboo $VER ($SHA) for DeskMind builds" \
    --notes "The Peekaboo CLI shipped in DeskMind builds (built from $SHA), and the licence files of what is linked into it. Used by CI; not an app release." \
    "$TMP/peekaboo" "$TMP/libswiftCompatibilitySpan.dylib" "$TMP/peekaboo-licenses.tar.gz" "$TMP/SHA256SUMS"
fi
printf 'PEEKABOO_RELEASE=%s\n' "$TAG" > vendor.env
echo "vendor.env -> $TAG"

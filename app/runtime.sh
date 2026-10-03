#!/usr/bin/env bash
# Assemble the helper's Python runtime once, into build/cache/runtime:
#   python/  a relocatable CPython (python-build-standalone, as uv installs it), trimmed
#   site/    its dependencies: pyyaml, pillow, deskmind-bench
#   hands/   the deskmind-hands source tree (tasks and fixtures included), with a .version stamp, and its OCR helper
#   site-brain/  DeskMind Brain (the local planner server) and its MLX dependencies
#   site-eyes/   DeskMind Eyes' grounding server and mlx-vlm, for apps with no accessibility tree
# Rebuilt only when a source changes; build.sh copies it into DeskMind Hands.app and signs every binary in it.
set -euo pipefail
cd "$(dirname "$0")"
CACHE=../build/cache/runtime
# The uv-managed python-build-standalone install itself -- never a venv (an active VIRTUAL_ENV made `uv python
# find` return one, whose lib/ is a stub and whose python is a symlink to somewhere else).
PY_SRC="${PY_SRC:-$(ls -d "$(uv python dir)"/cpython-3.12.*-macos-aarch64-none 2>/dev/null | tail -1)}"
if [ ! -x "$PY_SRC/bin/python3.12" ] || [ -f "$PY_SRC/pyvenv.cfg" ] || [ ! -f "$PY_SRC/lib/python3.12/os.py" ]; then
  echo "runtime: $PY_SRC is not a standalone CPython 3.12 (set PY_SRC)" >&2; exit 1
fi
# The source checkouts: set HANDS_REPO, BENCH_REPO, BRAIN_REPO and EYES_REPO, or clone deskmind-ai/hands, bench,
# brain and eyes next to this repo (../hands, ../bench, ... relative to its root).
SIBLINGS="$(cd .. && pwd)/.."
HANDS_REPO="${HANDS_REPO:-$SIBLINGS/hands}"
BENCH_REPO="${BENCH_REPO:-$SIBLINGS/bench}"
BRAIN_REPO="${BRAIN_REPO:-$SIBLINGS/brain}"
EYES_REPO="${EYES_REPO:-$SIBLINGS/eyes}"
for v in HANDS_REPO BENCH_REPO BRAIN_REPO EYES_REPO; do
  git -C "${!v}" rev-parse HEAD >/dev/null 2>&1 \
    || { echo "runtime: $v=${!v} is not a git checkout (set $v, or clone the repo next to this one)" >&2; exit 1; }
done
# A release is built from the commits in deps.lock and nothing else, so its sources can be checked out again; a
# development build only says where it differs.
eval "$(grep -E '^[A-Z]+=[0-9a-f]{40}$' deps.lock)"
for name in HANDS BENCH BRAIN EYES; do
  repo_var="${name}_REPO"; want="${!name}"; have="$(git -C "${!repo_var}" rev-parse HEAD)"
  if [ "$have" != "$want" ]; then
    if [ "${DIST:-0}" = 1 ]; then
      echo "runtime: ${!repo_var} is at ${have:0:7}, deps.lock pins ${want:0:7} (check it out, or run tools/pin_deps.sh)" >&2
      exit 1
    fi
    echo "runtime: note: ${!repo_var} is at ${have:0:7}, deps.lock pins ${want:0:7} (fine for a development build)" >&2
  elif [ -n "$(git -C "${!repo_var}" status --porcelain --untracked-files=no)" ] && [ "${DIST:-0}" = 1 ]; then
    echo "runtime: ${!repo_var} has uncommitted changes; a release is built from committed sources only" >&2
    exit 1
  fi
done
# The vendored build (tools/vendor_peekaboo.sh, downloaded to ~/.local/share/deskmind/peekaboo-vendor) unless a
# local checkout's release build is asked for: a checkout's .build can vanish in a disk clean-up.
PEEKABOO_BIN="${PEEKABOO_BIN:-$HOME/.local/share/deskmind/peekaboo-vendor/peekaboo}"
# layout2: + libswiftCompatibilitySpan.dylib; layout3: + site-eyes and hands/tools/native/ocr; layout4: + ScreenCaptureKit; layout5: + ApplicationServices; layout6: Brain's MLX stack pinned (brain-constraints.txt); layout7: no build-machine paths; layout8: hands' runtime files only
stamp="$(git -C "$HANDS_REPO" rev-parse HEAD)-$(git -C "$BENCH_REPO" rev-parse HEAD)-$(basename "$PY_SRC")-$(shasum "$PEEKABOO_BIN" | cut -c1-12)-$(git -C "$BRAIN_REPO" rev-parse HEAD)-$(git -C "$EYES_REPO" rev-parse HEAD)-layout8-$(shasum brain-constraints.txt | cut -c1-8)"

if [ -f "$CACHE/.stamp" ] && [ "$(cat "$CACHE/.stamp")" = "$stamp" ]; then
  echo "runtime: up to date ($CACHE)"; exit 0
fi
rm -rf "$CACHE"; mkdir -p "$CACHE"

# CPython, without what a headless helper never loads.
cp -R "$PY_SRC" "$CACHE/python"
find "$CACHE/python" -type l -exec sh -c 'case "$(readlink "$1")" in /*) echo "absolute symlink: $1" >&2; exit 1;; esac' _ {} \;
rm -rf "$CACHE/python/lib/python3.12/test" "$CACHE/python/lib/python3.12/idlelib" \
       "$CACHE/python/lib/python3.12/tkinter" "$CACHE/python/lib/python3.12/turtledemo" \
       "$CACHE/python/lib/python3.12/ensurepip" "$CACHE/python/lib/tcl"* "$CACHE/python/lib/tk"* \
       "$CACHE/python/lib/itcl"* "$CACHE/python/lib/thread"* "$CACHE/python/share"
# The interpreter's own site-packages is whatever else was installed into this uv Python (1.4 GB here): the
# helper's dependencies live in site/ instead.
rm -rf "$CACHE/python/lib/python3.12/site-packages"; mkdir -p "$CACHE/python/lib/python3.12/site-packages"
find "$CACHE/python" -name "__pycache__" -type d -prune -exec rm -rf {} +

uv pip install --quiet --no-compile --python "$CACHE/python/bin/python3.12" \
  --target "$CACHE/site" pyyaml pillow "$BENCH_REPO" pyobjc-framework-Quartz pyobjc-framework-Cocoa \
  pyobjc-framework-ScreenCaptureKit pyobjc-framework-ApplicationServices
# Some PyObjC wrappers ship without their licence file (their METADATA says MIT; the same project and text as the
# Quartz wrapper's, which has it): copied in, so the notices can name it.
for d in "$CACHE"/site/pyobjc_framework_*-*.dist-info; do
  [ -e "$d/licenses/LICENSE.txt" ] || { mkdir -p "$d/licenses"; cp "$CACHE"/site/pyobjc_framework_quartz-*.dist-info/licenses/LICENSE.txt "$d/licenses/"; }
done
# pyobjc: the brief foreground click and the clipboard round trip for apps without accessibility (hands' vision
# mode) post CGEvents and use NSPasteboard; without it the first such step ended the run (ModuleNotFoundError).
# ScreenCaptureKit: window captures in process (hands' drivers/capture.py), ~2x faster than screencapture.
# Every module hands imports from PyObjC, checked here: a missing one fails quietly at run time, where a check that
# cannot read is no check.
PYTHONPATH="$CACHE/site" PYTHONNOUSERSITE=1 "$CACHE/python/bin/python3.12" -c \
  "import AppKit, Quartz, ScreenCaptureKit, ApplicationServices" \
  || { echo "runtime: a PyObjC module hands needs is missing" >&2; exit 1; }
# ApplicationServices: hands reads accessibility structure itself (drivers/axchrome.py: a browser's address bar;
# drivers/axpopup.py: a pop-up's choices). Missing, both read nothing -- and nothing refused: in the app a parts row
# was typed into Safari's address bar and sent to a search engine (10-01).

mkdir -p "$CACHE/hands"
# Only what the app runs: the package, the smoke set and its fixtures, the OCR helper's source and the licence.
# Not the repository's tools (data collection and labelling), tests, docs or training task sets.
git -C "$HANDS_REPO" archive HEAD deskmind_hands tasks/smoke fixtures tools/native/ocr.swift pyproject.toml LICENSE NOTICE \
  | tar -x -C "$CACHE/hands"
# The diag suite lives in bench: its tasks and fixtures go into the hands tree, where the CLI looks for sets.
mkdir -p "$CACHE/hands/tasks/diag"
git -C "$BENCH_REPO" archive HEAD tasks/diag fixtures | tar -x -C "$CACHE/hands"
# The OCR helper vision mode reads the screen with (macOS Vision, on-device). Built here, not committed, so it is
# signed with the rest of the runtime: an unsigned binary next to the hardened helper would not be allowed to run.
swiftc -O -target arm64-apple-macos15 "$CACHE/hands/tools/native/ocr.swift" -o "$CACHE/hands/tools/native/ocr"
# "+ocr": the helper copies the tree to its working folder only when this changes, and a copy made before the
# OCR helper shipped would go on without it for as long as hands and bench stay on the same commits.
echo "$(git -C "$HANDS_REPO" rev-parse --short HEAD)+$(git -C "$BENCH_REPO" rev-parse --short HEAD)+ocr" > "$CACHE/hands/.version"

# Peekaboo, the macOS automation layer hands drives (MIT). A release build of the CLI.
mkdir -p "$CACHE/bin"
cp "$PEEKABOO_BIN" "$CACHE/bin/peekaboo"
# Built by a newer Swift than macOS 15 carries: the binary needs the Span back-deployment library, found through
# its @loader_path rpath. Without it Peekaboo aborted at launch on macOS 15 (dyld: libswiftCompatibilitySpan.dylib
# not loaded) -- the app's minimum system. Next to a vendored binary, or from this Mac's Xcode toolchain.
SPAN="$(dirname "$PEEKABOO_BIN")/libswiftCompatibilitySpan.dylib"
[ -f "$SPAN" ] || SPAN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if otool -L "$PEEKABOO_BIN" | grep -q "@rpath/libswiftCompatibilitySpan.dylib"; then
  cp "$SPAN" "$CACHE/bin/"
fi
if otool -L "$PEEKABOO_BIN" | grep "@rpath/" | grep -v libswiftCompatibilitySpan >&2; then
  echo "runtime: peekaboo needs another @rpath library (above); ship it next to the binary" >&2; exit 1
fi

# DeskMind Brain (the local planner server) and its MLX dependencies, in their own site dir: the helper runs it as
# a separate child, and it shares only the interpreter with hands.
uv pip install --quiet --no-compile --python "$CACHE/python/bin/python3.12" \
  --constraint brain-constraints.txt --target "$CACHE/site-brain" "$BRAIN_REPO[mlx]"

# DeskMind Eyes, the grounder vision mode asks where a described control is, in a site dir of its own like Brain.
# Not "$EYES_REPO[mlx]": the package's base dependencies are its training stack (tinker-cookbook), which pins a
# transformers older than mlx-vlm accepts, so the two do not resolve together (09-28). The server needs only
# deskmind_eyes itself, mlx-vlm and Pillow -- the [mlx] extra's pin, repeated here.
uv pip install --quiet --no-compile --python "$CACHE/python/bin/python3.12" \
  --target "$CACHE/site-eyes" --no-deps "$EYES_REPO"
uv pip install --quiet --no-compile --python "$CACHE/python/bin/python3.12" \
  --target "$CACHE/site-eyes" "mlx-vlm>=0.7.1" pillow

# Licence texts of what python-build-standalone links into CPython (OpenSSL, SQLite, zlib, ...): the install-only
# build above leaves them out, the "full" archive of the same release has them. Kept next to the runtime for
# tools/make_notices.py. The release is pinned to the interpreter: a different CPython build needs its own tag.
PBS_TAG=20250723
PBS_LIC=../build/cache/pbs-licenses
if [ "$(basename "$PY_SRC")" != "cpython-3.12.11-macos-aarch64-none" ]; then
  echo "runtime: $(basename "$PY_SRC") is not the build PBS_TAG=$PBS_TAG describes; update PBS_TAG" >&2; exit 1
fi
if [ ! -f "$PBS_LIC/python/licenses/LICENSE.cpython.txt" ]; then
  mkdir -p "$PBS_LIC"
  curl -sfL "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-3.12.11%2B$PBS_TAG-aarch64-apple-darwin-pgo%2Blto-full.tar.zst" \
    | tar --zstd -x -C "$PBS_LIC" python/licenses python/PYTHON.json
fi

# Nothing of the build machine in what ships. The 0.3.0 build carried the builder's home 71 times: the console
# scripts pip writes into each site dir's bin/ (their #! is the build's interpreter; nothing runs them -- the servers
# start with -m), the direct_url.json of the three local packages (the checkout they came from), and the interpreter's
# sysconfig (where uv installed it; python-build-standalone's own prefix is /install).
rm -rf "$CACHE"/site*/bin
find "$CACHE"/site* -path "*.dist-info/direct_url.json" -delete
for f in "$CACHE"/python/lib/python3.12/_sysconfigdata_*.py; do
  sed -i '' -e "s|$PY_SRC|/install|g" "$f"
done
# Wheels' own SBOMs (*.dist-info/sboms) name the machine that built the wheel upstream -- on GitHub's runners that is
# /Users/runner, which is also the home folder of this build on CI: theirs, not ours, and not searched.
if grep -rIl --exclude-dir=sboms "$HOME" "$CACHE" >&2; then
  echo "runtime: the files above name this machine's home folder ($HOME); they must not ship" >&2; exit 1
fi

echo "$stamp" > "$CACHE/.stamp"
du -sh "$CACHE" | awk '{print "runtime: built", $1}'

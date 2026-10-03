# DeskMind for Mac

[简体中文](README.zh-CN.md)

> This folder is the Mac app's source. For what DeskMind is and how its parts fit, start with the [main README](../README.md).

DeskMind is a local computer-use agent for macOS. Type a goal ("Make a folder called Receipts and move
expenses.csv into it", "Open Safari and search for the weather in Singapore"), confirm which apps it may use, and
it operates those apps for you. It asks before anything that sends or deletes, asks you when it is unsure, and
shows each step it takes and why.

The planner and vision models run on your Mac with MLX. Nothing you see on screen is uploaded.

**[Download DeskMind for Mac](https://github.com/deskmind-ai/deskmind/releases/latest)** · macOS 15+ · Apple Silicon ·
signed and notarized

<img src="../docs/images/asks-first.gif" width="720" alt="DeskMind finds two orders for Lisa Wong and asks which one to use">

*A real run: two rows match the goal, so DeskMind asks which one to use instead of guessing.*

## Get started

1. Download the latest `DeskMind-<version>.dmg` from [Releases](https://github.com/deskmind-ai/deskmind/releases/latest), open it and
   drag DeskMind to Applications. The release notes give the DMG's SHA-256.
2. Open DeskMind and grant the helper, DeskMind Hands, Accessibility and Screen Recording. The app walks you through it.
3. The first launch downloads the planner models once: about 5.3 GB, from Hugging Face or, if that is slow, from
   ModelScope.
4. Click **Try examples** for a run in a sandbox folder, or type your own goal, pick the apps it may use, and start.
   ⌘. stops a run; touching the mouse or keyboard pauses it until you let go.

## Requirements

- A Mac with Apple Silicon
- macOS 15 or later
- Permissions for the helper, **DeskMind Hands**: Accessibility and Screen Recording (and Automation for the apps
  it scripts). The app walks you through granting them.
- Disk and memory for the models: about 5.3 GB for the planner (0.8B + 4B), plus about 3.3 GB for the optional
  vision model.

## Models

On first use the app downloads the release models (DeskMind Brain G18b, routing threshold 0.96) from Hugging Face,
pinned to exact revisions and checked against SHA-256 hashes listed in
[`app/Resources/models.json`](Resources/models.json). Where Hugging Face fails or is too slow (under
about 200 KB/s for the first 30 seconds of a file), the download switches to the same files on ModelScope
(`gxcsoccer/brain-0.8b`, `gxcsoccer/brain-4b`, `gxcsoccer/eyes-4b`), checked against the same hashes:

| Role | Repository | Used for |
| --- | --- | --- |
| fast | `deskmind/brain-0.8b` | most planning steps |
| strong | `deskmind/brain-4b` | steps the router escalates |
| eyes | `deskmind/eyes-4b` | finding controls in apps without an accessibility tree (optional) |

The model repositories are public; no Hugging Face token is read or sent.

## Building

The build assembles the helper's Python runtime from the sibling source repositories and signs everything.

1. Install Xcode (for `swiftc`, `codesign`, `iconutil`) and [uv](https://docs.astral.sh/uv/), then
   `uv python install 3.12.11` (the python-build-standalone build `app/runtime.sh` expects).
2. Clone `deskmind-ai/hands`, `deskmind-ai/bench`, `deskmind-ai/brain` and `deskmind-ai/eyes` next to this
   repository, or point `HANDS_REPO`, `BENCH_REPO`, `BRAIN_REPO` and `EYES_REPO` at your checkouts.
3. Get the Peekaboo CLI the app ships: download the release named in `app/vendor.env` from this repository (deskmind-ai/deskmind)
   into `~/.local/share/deskmind/peekaboo-vendor` and unpack `peekaboo-licenses.tar.gz` into its `src/` folder
   (as `.github/workflows/app.yml` does), or set `PEEKABOO_BIN` and `PEEKABOO_SRC`.
4. Build:

   ```sh
   ./app/build.sh                 # signs with your first "Apple Development" identity
   SIGN_ID=- ./app/build.sh       # ad hoc signing
   ```

   The app is written to `build/DeskMind.app`. `DIST=1` makes a Developer ID signed, notarized DMG in
   `build/release/` (see the header of `build.sh` for the notarization settings); `VERSION` and `BUILD_NUMBER`
   override the version in the plists.

The unit tests (`app/tests`) are compiled and run at the start of every build.

See [docs/architecture.md](../docs/architecture.md) for how the app, the helper and the local servers fit together.

## Privacy

- Everything runs locally. Screens, screenshots, run traces and recordings stay on your Mac.
- The planner and vision servers listen on `127.0.0.1` only and run offline. They answer only requests that carry
  the app's own random token, so another program on the Mac cannot use them, or pass for them.
- The only network requests are the model downloads from huggingface.co (or, when it is unreachable, modelscope.cn).

What stays on your Mac, and for how long:

| What | Where | Kept |
| --- | --- | --- |
| Recent tasks (the list) | `~/Library/Application Support/DeskMind/history.json` | the last 10 |
| Each run's step screenshots, trace and log | `~/Library/Application Support/DeskMind/work/hands/runs/` | the last 10 runs |
| Your 👍/👎 on a result | `~/Library/Application Support/DeskMind/feedback.jsonl` | until cleared |
| Routing log (which model answered each step and why; no screen content) | `~/Library/Application Support/DeskMind/routing.jsonl` | until you delete it |
| Recordings | `~/Movies/DeskMind/` | yours: never deleted by the app |
| Models | `~/Library/Application Support/DeskMind/models/` | until you delete them |

**Clear all** in Recent deletes the list, the run folders and the 👍/👎 file. Recordings stay.

## License

The code is licensed under the [Apache License 2.0](LICENSE); see also [NOTICE](NOTICE). Bundled third-party
components are listed with their licences in `THIRD_PARTY_NOTICES.txt` inside the app. The DeskMind name, 得心,
the logo and Xiaofang are not covered by the code licence.

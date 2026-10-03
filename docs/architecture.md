# Architecture

DeskMind for Mac is two app bundles and three local runtimes. Everything runs on the Mac; the only network traffic
is the one-time model download from Hugging Face.

```
DeskMind.app (main app, SwiftUI)                 DeskMind Hands.app (helper, LSUIElement)
  goal entry, confirmation sheet,    <-- JSON lines over a Unix socket -->   holds Accessibility, Screen Recording
  progress, questions/approvals,          (~/Library/Application Support/     and Automation; runs everything below
  history, model download                  DeskMind/hands.sock)
                                                        |
                          +-----------------------------+------------------------------+
                          |                             |                              |
                 python -m deskmind_hands.cli   python -m deskmind_brain.serve   python -m deskmind_eyes.ground_server
                 (one child per run)            127.0.0.1:18850                  127.0.0.1:18851 (on demand)
```

Source: `app/Main` (main app), `app/Helper` (helper), `app/Shared` (IPC protocol, model manifest,
localisation, decision-panel logic).

## Main app and helper

- **DeskMind.app** (`ai.deskmind.app`) is the window the user sees. It needs no privacy permissions itself.
- **DeskMind Hands.app** (`ai.deskmind.hands`) ships inside `Contents/Library/LoginItems` and is started by launchd
  from a LaunchAgent the main app registers with `SMAppService`. Because it is its own bundle, macOS attributes
  the Accessibility, Screen Recording and Automation grants to "DeskMind Hands", not to the main app, and it can
  be restarted after a grant without closing the main window. The installed copy lives in
  `~/Library/Application Support/DeskMind/`; a small panel next to System Settings lets the user drag it into the
  privacy list.
- The two talk over a Unix socket, one JSON object per line (`Shared/Protocol.swift`). Every request carries the
  UI language so the helper words its steps and errors to match.

## Running a task (hands)

The helper bundles a relocatable CPython 3.12 with the `deskmind_hands` source tree, the Peekaboo CLI (macOS
automation) and an on-device OCR helper (macOS Vision) in `Contents/Resources/runtime`. For a goal typed by the
user it runs

```
python -m deskmind_hands.cli do "<goal>" --app <bundle id> --apps <name=bundle,...> [--in <folder>]
       --ask stdin --adapter systemone --systemone-url http://127.0.0.1:18850 ...
```

The apps a run may touch are resolved from the instruction against the installed apps (`Main/AppScope.swift`) and
confirmed by the user before it starts; file work is limited to an attached folder. Steps are streamed back to the
main app from the run's `trace.jsonl`; screenshots stay in the helper's working folder and only the last few runs
are kept.

## Questions and approvals

When the agent needs the user, `deskmind_hands` prints a `HANDS_ASK {...}` line on stdout: either a question to
answer in words, or an approval (`"approval": true`) before an action that sends, deletes or otherwise cannot be
taken back. The helper forwards it to the main app, which shows a card; the reply goes back on the run's stdin as
`{"reply": "...", "approve": true|false}`. `HANDS_WAIT` / `HANDS_RESUME` lines report when a step that must briefly bring an app to the front is paused
because the user is using the Mac, so the app can say what it is waiting to do.

## Planner (brain)

`Helper/BrainServer.swift` starts `deskmind_brain.serve` once the models are downloaded, on `127.0.0.1:18850`,
with the fast model (`deskmind/brain-0.8b`) as the default predictor and the strong one (`deskmind/brain-4b`)
behind `--escalate-to`: the router answers most steps with 0.8B and escalates to 4B when its rules call for it.
hands talks to it over `/v1/systemone`. Routing decisions (metadata only, no request contents) are logged to
`routing.jsonl` in Application Support. The server runs with `HF_HUB_OFFLINE=1`.

## Vision grounding (eyes)

For apps without a usable accessibility tree, hands asks `deskmind_eyes.ground_server` (`POST /ground`,
`127.0.0.1:18851`) where a described control is on screen. It is optional: downloaded only when the user asks,
started before a run that may need it and stopped after ten minutes without a run, since it holds about 4 GB.

## Models

`app/Resources/models.json` lists every file of the release models (roles `fast`, `strong`, `eyes`) with
a Hugging Face URL pinned to a commit revision, its size and SHA-256. `Main/ModelDownloader.swift` downloads them
into `~/Library/Application Support/DeskMind/models/<role>`, one file at a time, resumable, and verifies each
checksum before moving it into place. The model repos are public, so no token is read or sent.

## Recording (optional)

"Record this run" uses the system content-sharing picker and ScreenCaptureKit to write a movie to
`~/Movies/DeskMind`, with an on-screen panel showing each step's decision (`Main/Recording.swift`,
`Shared/Decision.swift`). The movie stays on the Mac.

## Privacy

- Screens, screenshots, traces, recordings and model inputs never leave the Mac.
- The brain and eyes servers bind to `127.0.0.1` only and run offline.
- The only outbound requests are the model downloads listed in `models.json`.

## Build

`app/build.sh` compiles both apps with `swiftc`, runs the unit tests first, assembles the Python runtime
(`app/runtime.sh`), writes `THIRD_PARTY_NOTICES.txt` (`app/tools/make_notices.py`), and signs every
binary. See the README for the steps.

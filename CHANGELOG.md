# Changelog

What changed in each version of DeskMind for Mac, in short. Every version's full notes, with the known limitations, are
on the [Releases](https://github.com/deskmind-ai/deskmind/releases) page. Models are named when they change.
[中文](CHANGELOG.zh-CN.md)

## 0.4.1 (in testing)

Pre-releases [v0.4.1-rc.1](https://github.com/deskmind-ai/deskmind/releases/tag/v0.4.1-rc.1),
[v0.4.1-rc.2](https://github.com/deskmind-ai/deskmind/releases/tag/v0.4.1-rc.2) and
[v0.4.1-rc.3](https://github.com/deskmind-ai/deskmind/releases/tag/v0.4.1-rc.3), 2026-10-06. 0.4.0 stays the latest version
until this one is released.

**Fixes**
- Writing text into a document no longer loops. After the right text was written and saved, a step that "replaced" part
  of it with the whole text nested the document inside itself. That step now counts as a rewrite, and the task
  finishes. On the benchmark task for this (G04), 3 of 3 runs finish in 4 steps, against 20 steps and 2 of 6 before. The
  whole diag suite passes 39 of 39 (diag-v27).
- On a French (AZERTY) or Dvorak keyboard, select-all and paste press the right keys. On AZERTY, cmd+A could arrive as
  cmd+Q and quit the app.
- The background helper no longer crashes when macOS stops it while it is quitting, and it stops its model servers.
- Screen Recording is recognised as soon as you turn it on during the first setup. macOS's "Quit & Reopen" had started a
  copy of the helper whose permission didn't count; the right copy now always runs, and restarts itself once the
  permission is granted.
- The whole setup fits on screen, and the background helper's row has a Restart button.
- An approval covers one step. When DeskMind asks before a step that may not be undoable (deleting, sending, paying,
  publishing, sharing), your yes covers that step and the confirmation it opens. Before, it could also cover another step
  of the same kind a step or two later in the same app: approving one deletion could let a second, different item be
  deleted without asking.
- DeskMind acts only on the options it offered the model. Every answer is checked against them; an answer outside them
  stops the run with the reason, instead of being turned into one of the options.

**New**
- **Save Full Log…** after a failed run: a .zip kept on your Mac, for you to check before you share it.
- Reports open a GitHub form already filled in. You check it and submit it yourself.
- **View › Smooth Recordings (30 fps).** Recording now takes ten pictures a second by default, which slows each decision
  by about 3% (about 10% with the 30 fps stream).

**Changes**
- The app follows your system language unless you've chosen one in the language menu (it used to start in English).
- A mistake in `~/.config/deskmind/apps.yaml` is reported by name.
- The models are the same as in 0.4.0.

## 0.4.0 (2026-10-05)

**New**
- **A live view of the task.** A small card shows the window the task works in, live, even behind your other windows,
  with the current step in words. It moves out of the way, never takes the keyboard, and says when the task needs you.
- **Tell us when it gets it wrong.** 👎 after a task, or Report on GitHub after a failed run, opens a GitHub issue filled
  in with your instruction, the result and the steps in words, and nothing read from your screen.
- When a task gives an answer, the DeskMind window comes back with it.

**Fixes**
- Organising a large or nested folder ("整理目录" on Downloads) no longer fails at once. The model is shown a bounded
  part at a time and gets up to 2 minutes a step.
- A rename in your own folder waits for your approval, as deleting and sending do.
- Keys typed in another app no longer go into a question's answer.
- An app the task needs is opened, or its window brought back, before the task starts.

**Changes**
- The models are the same as in 0.3.x. The app's source moved to this repository (`app/`).
- Benchmark: diag-v26, 38 of 39.

## 0.3.1 (2026-10-03)

**Fixes**
- "Try examples" no longer closes your open TextEdit documents.
- An approval covers one step: each send, delete, pay, publish or share asks again.
- The local model servers answer only to DeskMind (a token made on your Mac).
- Clear all also deletes the runs' screenshots and records.
- Vision clicks near the edge of the screen land where they should.

## 0.3.0 (2026-10-02)

First public release.
- Local decision models: DeskMind Brain G18b, 0.8B first and 4B when the 0.8B isn't sure (threshold 0.96), with MLX on
  your Mac.
- The vision model, Eyes-4B, is optional.
- Signed and notarized.
- Benchmark: bench v25, 39 of 39.

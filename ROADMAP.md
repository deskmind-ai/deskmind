# DeskMind roadmap

[Project overview](README.md) · [中文概览](README.zh-CN.md) · [Contributing](https://deskmind.dev/docs/project/contributing/)

**Updated October 5, 2026.** What we are working on, roughly in order. There are no dates, and plans change when the measurements say so.

## Where we are

The current release is the Brain **G18b** router (0.8B → 4B, 8-bit, threshold 0.96), shipped in the Mac app v0.4.0, which adds a live view of the window DeskMind is working in. On Bench v25 (13 tasks × 3 runs, one Mac) it passed 39/39 with 0 false "done"; re-run through app 0.4.0 it passed 38/39, again with 0 false "done" (one run of the Chinese exact-text task ended on a wrong write). Its known weak spots: most steps (about 70%) still go to the 4B, long or filtered table copies and receipt-to-form tasks are not reliable, and the 4B lost some general judgement on JevBench's hard tier. Numbers and sample sizes: [README](README.md#results-with-the-sample-size).

## Next in the app: 0.5

- **Answer in the live view:** reply to DeskMind's questions from the card, with a few seconds to undo, without the card taking focus.
- **Replay and GIF export** of a finished run, built from its step screenshots (no screen recording, so no slowdown).
- **A shorter first setup:** permissions and the model download side by side, then the first task.
- **Ask when the goal is unclear:** a file named in the goal that isn't in the folder, or a vague goal like "organise this folder", gets a question before anything changes.

## Next: G19

The next Brain round targets the failures we see today:

- **Long and filtered table copies:** 4 to 14 rows, 3 to 5 columns, Chinese and English, only the rows that match a condition, and no stopping early. The offline gate uses a held-out set whose templates the training data never saw.
- **Forms from a photographed receipt,** including values that text recognition misread.
- **Finishing cleanly:** save, then say "done" (including after exact text that is already right); append when asked to append instead of replacing the document; open a file from a folder, edit, save and close it.
- **Media states:** do not pause a track that is already playing, recognise when playback means the task is done, and tell a song from its MV or live version.
- **Speed:** widen the 0.8B's fast path (distil the 4B into the 0.8B, recalibrate, retune the threshold) so fewer steps wait for the 4B.
- **General judgement:** JevBench public items stay a monitored check, so desktop gains do not cost the hard tier again.

G19 replaces G18b only if it does better on the same bench. We publish the comparison either way.

## Measurement

- **A bigger bench:** an English system language, more apps (Mail, Calendar, Notes, web forms) and held-out task families, not just 13 tasks on one Mac. Report confidence intervals, and full-task time and interventions next to decision time.
- **Eyes where it runs:** benchmark the setting the app ships (4-bit MLX, up to 2 MP) on Apple Silicon, kept separate from GPU numbers.
- **A sealed score:** a JevBench sealed-set result for the G18b 4B, next to the public-item numbers.

## Later

- **Pluggable escalation:** an optional third tier behind the 4B (a larger local model or a cloud model). Off by default; a cloud tier sends the steps routed to it off your Mac, so it is opt-in.
- **Per-app lesson notes:** short, human-reviewed notes about an app, looked up at run time and removable without retraining.
- **More apps and platforms** through Hands. Contributions are welcome.

## What counts as progress

Independent reproductions (including ones that disagree with ours), working integrations through `/v1/systemone` and more reliable complete tasks matter more to us than stars or downloads. An honest negative result is worth publishing too.

Questions and ideas: [Discussions](https://github.com/deskmind-ai/deskmind/discussions).

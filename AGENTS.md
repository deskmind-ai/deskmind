# AGENTS.md — DeskMind app

Instructions for coding agents (Codex, Claude Code) and reviewers working in this repo. The app is in `app/`, a main
app plus a helper (`DeskMind Hands.app`), Swift, built by `app/build.sh`.

## Running the tests

- **Unit tests.** `app/build.sh` compiles and runs `decision-tests` before building, and a failure stops the build.
  For a quick run, use the first `swiftc … -o "$OUT/decision-tests"` line in `build.sh`.
- **Concurrency changes.** For changes that involve threads, queues or the helper protocol, run that binary 8 copies
  at once a few times, and once compiled with `-sanitize=thread`. A crash in CI that doesn't happen locally is
  usually a data race.
- **End to end.** `app/runtime.sh` builds the runtime into `../build/cache/runtime` from `app/deps.lock`; then run
  `app/tests/e2e/session.sh` (and `helper.sh` and `live_view.sh` when you touch those parts). They need no
  permissions, no window and no model service; a fake model runs on localhost.
  - Run them from a short directory under `/tmp`, because Unix socket paths have a length limit.
  - Use canonical absolute paths: `pgrep -f` misses paths with `..`.
- **Never touch the real `~/Library/Application Support`.** Tests use temp dirs and their own UserDefaults domains.
  Never drive a real GUI app.

## Rules for this repo

- **The helper owns the facts about what it runs.** The app asks the helper and never guesses. That covers:
  - which session processes exist (the helper's process table, not the session files on disk);
  - which models key each one started with (the digest of the one read that built its environment);
  - whether cloud models are off (the `models-off` bit, which the helper enforces).
- **Session process lifecycle:** spawning (registered before it reads the keys), then started but not stored yet,
  then running, then ending (asked to end when idle), then closing, then gone. Any code that answers "which
  processes…" has to cover every one of these states.
- **Restart only through `end_if_idle`.** A restart never cuts a reply, a task or its undo window.
- **Cloud off means nothing more goes to the cloud.** No path may reopen or reconfigure a session with a cloud config
  while the switch is off.
- **One switch source.** There is one `ModelsOffSync` per process. Never wait on its own queue.

## How we change code here (shared across deskmind-ai repos)

These rules come from the review rounds of hands#62 and deskmind#107 (10-22/23). In those rounds the same family of bug
was patched one case at a time for many rounds, until the fix was redesigned around where the fact really lives.

### Before writing a fix

- **Write the invariant first.** State, in one sentence in the PR description, what must always hold. For example:
  "a key the user typed into a task's app is never counted less than main counts it", or "every process the helper
  runs ends up on the current key". Then turn it into a test that checks it across many cases: a table against the
  old behaviour, or random interleavings. Don't rely only on one test per reported scenario.
- **List the states.** For anything with a lifecycle (a process, a watch, a request, a session), write down every
  state it passes through, from created to registered, started, stored, ending, closing and gone. For each reader of
  that thing, say what it sees in each state. Most of the bugs in those rounds were one state a reader forgot.
- **Stop patching after the second bug of a family.** When a review finds a second case of the same kind of bug, stop
  adding cases. Find the fact's source of truth and derive from it:
  - The side that owns a fact reports it. The other side doesn't keep its own record of what it thinks happened.
  - Derive related values from a single read. Example: a process's environment and the digest reported for it come
    from the same read of the file.
  - Register first, then read. An item becomes visible to readers before it reads the data that can change under it.
  - Record something as done only after the other side confirmed it. A failed or unanswered request stays owed and
    is retried.
- **Classify every finding before working on it.**
  - A **bug** is any of: a gate breaks (a false completion, an unconsented change or send, no stop or rollback); a
    core function no longer works; a crash or hang; a regression; two checks that contradict each other. Bugs are
    always fixed.
  - An **effect** is friction: an extra card, an extra stale, slowness, wording. Effects are rated and recorded in
    deskmind#90 for later.
  - A state that can stay wrong forever, like a session left on a revoked key, is a bug. That holds even if the first
    example you find looks harmless.

### Adding a mechanism is where new bugs come from

When a fix adds a cache, a lock, a wait, a shared object or a retry, go through this list:

- **Cache.** Only cache success, never a failure. Something must invalidate the entry, for example a reused pid needs
  its start time checked. When an entry is reused, recheck that it still matches what holds now (permissions, an
  enabled tap, a live thread).
- **Shared or process-wide object.** Check whether state leaks from one user to the next, and check its health on
  every reuse. Never set a process-wide setting to fix one caller.
- **Wait.** A wait is always bounded. Never wait for work that is queued on the queue you are running on.
- **Lock.** Never hold a lock across a callback, IO or a run loop. Keep one lock order.
- **Teardown.** A thread that arrives late must find out that it was given up and return. Stopping twice is harmless.
- **Retry.** A retry is bounded or backed off. A record of success is written only after the whole job succeeded.

### Tests

- A new regression test must fail on the previous head. Say so in the PR or the commit.
- Fakes model the real lifecycle and the real failure replies. That includes the window between spawn and start, a
  lost or refused request, and a service that checks credentials. A fake that skips a state hides the bug in that
  state.
- A property test's oracle comes from the simulated ground truth. It must not repeat the implementation's own
  algorithm.
- For changes that involve threads or concurrency, run the suite several times in parallel under load. Use a race
  detector if one exists for the language.

### PRs and review rounds

- **One PR, one invariant.** When a second concern shows up, such as a new ownership question or a new sync problem,
  split it into its own PR.
- **One round fixes the whole family.** Fix every finding of a review round together. Before pushing, grep for other
  places with the same pattern and fix them in the same round.
- **Our re-reviews look only at what changed since the last reviewed head.** The external review covers the whole PR.
  Don't run two reviews on different heads at the same time.
- **Merging into main needs the `reviewed` label.** Merge with `--merge` at the reviewed head
  (`--match-head-commit`), after posting a review record on the PR.

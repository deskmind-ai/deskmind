# The DeskMind agent protocol, version 0

How a harness (DeskMind Hands) asks a decision model (DeskMind Brain) for the next step of a desktop task, and what
it does with the answer. Version 0 writes down what ships today — hands 89be730, brain 4767186, the Mac app 0.4.1 —
without changing it. Where the two sides disagree, or a rule lives only in code, it is listed under
[Known gaps](#known-gaps) with an id (G1…). Version 1 will close them; the [proposals](#towards-version-1) are at the
end.

The protocol has two layers:

| Layer | What it fixes | Machine-readable |
|---|---|---|
| Transport | `POST /v1/systemone`: a state and typed questions in, one probability per option out | [`schema/request.schema.json`](schema/request.schema.json), [`schema/response.schema.json`](schema/response.schema.json) |
| Agent profile | Which questions an agent step asks, what their options look like, what the state holds, what the harness does with the answer | [`agent/operations.yaml`](agent/operations.yaml), [`schema/agent-state.schema.json`](schema/agent-state.schema.json) |

Any client that keeps to the transport can use Brain for any decision. A harness that also keeps to the agent profile
gets the model's trained behaviour; a model that serves the agent profile can drive hands.
[`tools/check.py`](tools/check.py) checks a request or a reply against both layers.

## 1. Transport

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/systemone` | Answer a set of questions about one state |
| `GET` | `/v1/models` | `{"data": [{"id", "object": "model", "criteria_forms"?, "routing"?}]}`; `criteria_forms` lists the forms of choice options the server reads (`["object", "list"]` from brain#9); `routing` (reason → count) only with two tiers |

Brain listens on `127.0.0.1:8787` by default; the Mac app runs it on `18850`, hands defaults to `8793` (G6). With
`DESKMIND_BRAIN_TOKEN` set, every request needs `Authorization: Bearer <token>`; hands sends `SYSTEMONE_API_KEY` as
that header (the app sets both to one per-install token). Requests are answered one at a time.

### Request

`{"state", "questions", "model"?}` ([schema](schema/request.schema.json)).

- `state` is any JSON value. An object is rendered compactly into the prompt; a string is used as is.
- `questions` maps an id to `{"type", "instructions", "criteria"}`:

| `type` | `criteria` | Options |
|---|---|---|
| `choice` | 1–255 options: a list of `{"key", "description"}` (v1), or an object, key → description (v0) | the keys, in the order given ([Option order](#option-order)) |
| `score` | list of 2–10 level descriptions | `"0"`…`"K-1"` |
| `noul` | anything | `false` / `true` |

- `instructions` is required, any JSON value; agent requests send `{"goal", "rules", "operation"?}`.
- `model` is accepted and ignored.

### Option order

The order of a `choice` question's options is part of the request: it sets the option letters the model answers
with. The same model on the same steps with its options re-sorted chose a valid action about 130 times in 223 instead
of 220 (brain#8).

- **v0** sends the options as an object and relies on its key order. JSON does not guarantee key order, and any tool
  that sorts keys on the way reorders the options without a trace — `'1', '10', '11', '2'`. A fixture builder
  (brain#8), hands' replay snapshots (hands#13) and Brain's answer cache key (brain#9) all did (G22).
- **v1** sends a list: `[{"key": "CLICK", "description": "…"}, …]`. Keys are unique non-empty strings; a description
  is any JSON value, as in v0 (agent heads use objects such as `{"element": "[3] Save"}`). A server that reads the
  list form says so with `criteria_forms` in `GET /v1/models`; a client sends it only to such a server.
- A server shows the options in the order sent and never reorders them. A harness keeps the agent profile's order
  rules ([Heads and their options](#heads-and-their-options)); `tools/check.py` checks them, a server does not.

### Request identity

From v1 (deskmind#36 item 4) a request can say which step of which run it is for. Every field is optional; a server
that does not know them ignores them (Brain does: it drops fields it does not read), so a client sends them to any server.

| Field | Content |
|---|---|
| `request_id` | unique per request; a retry of the same request keeps it, so a server or a log can tell a duplicate |
| `session_id` | one per run of a task |
| `step` | the harness's step, from 1; requests for the same step share it (hands asks again for an overridden operation's heads) |
| `observation_id` | the harness's id of the observation the state and the options were built from; opaque to the server |
| `state_digest` | `"sha256:"` and the hex SHA-256 of `state` as compact JSON in the order sent (`json.dumps(state, ensure_ascii=False, separators=(",", ":"))`, UTF-8) |

- The digest keeps the order on purpose: the order of the state is part of what the model sees, so two states that
  differ only in order are two inputs. `tools/check.py` recomputes it.
- The digest is the client's, defined by that serialization. A server that serializes JSON another way may not get the
  same bytes, so it logs the digest and never rejects a request because it disagrees.
- A server echoes `request_id`, `session_id` and `step` in its reply, and writes them in its routing log. They are
  not part of the answer cache key: the cache answers equal state and questions, whatever the request is called.
- An approval (item 7) names the `observation_id` it was given for.

### Reply

`{"id", "model", "answers", "usage", "latency_ms", "routing"?, "cached"?, "request_id"?, "session_id"?, "step"?}`
([schema](schema/response.schema.json)); the last three echo the request's ([Request identity](#request-identity)).

- `answers` has one entry per question, scored or not. A `choice` answer is `{"type", "choice", "probabilities",
  "confidence"}`: `choice` is the argmax, `probabilities` covers every option, `confidence` is `(K·p_max − 1)/(K − 1)`.
  Clients decide from `probabilities` (hands takes its own argmax and ignores `confidence`).
- A server running **two-stage** scores `operation` first and then only that operation's heads. Questions it did not
  score come back **uniform** with confidence 0; they are not answers (G1, G2, G4).
- `routing` appears when two tiers are served: `{"by": "fast"|"strong", "reason", "fast_conf", "confirmed"?}`. The fast
  tier answers; the strong tier re-answers when `fast_conf` (the lowest top probability over `operation` and its heads)
  is under the threshold (0.96 in the app) or the step is risky: `risky_DONE`, `risky_BLOCKED`, `risky_KEY` (a chord
  outside `cmd+s cmd+f cmd+c tab escape`), `risky_undo` (a click on a target whose option text contains 撤销/undo),
  `unverified_last` (DONE right after an unverifiable or no-op effect). `confirmed: true` means both tiers chose the
  same terminal operation. hands then does not override it with another operation (the low-confidence override
  below); its DONE check still runs and can still send a DONE back.
- A cache hit (identical state and questions) returns the stored reply with a new `id` and `cached: true`, including
  the original `latency_ms` and `routing` (G18). Latency measurements must leave cached replies out.

### Errors

| Status | Body | When |
|---|---|---|
| 400 | `{"error": {"message"}}` | invalid JSON or request, or a `ValueError`/`TypeError` anywhere in answering (G5) |
| 401 | `{"error": "unauthorized"}` (a string, G5) | missing or wrong token |
| 404 | `{"error": {"message": "not found"}}` | any other path or method |
| 500 | `{"error": {"message": "<Type>: <message>"}}` | any other failure |

hands keeps the server's message (up to 300 characters) in its error, ends the run as `PROVIDER_UNAVAILABLE`, and
records a `request_failed` trace line with the request's shape (question → type and option count). It does not retry.
The planner timeout is `HANDS_PLANNER_TIMEOUT` (60 s; the app sets 120 s).

## 2. Agent profile

A request is an **agent request** when it has a question with the id `operation`. Its options are operation names; for
each operation it offers, the request also carries that operation's **heads**: the questions that choose its
arguments. [`agent/operations.yaml`](agent/operations.yaml) lists them; this section explains them.

### Operations

| Operation | Heads | Class | What the harness does |
|---|---|---|---|
| `CLICK` | `click_target` | act | clicks the element |
| `OPEN` | `open_target` | act | double-clicks it (rows, cells, items, links, folders, documents) |
| `RENAME` | `rename_target`, `type_text_value` | write | types the value as the row's new name; refused if it is another file's name |
| `TYPE_TEXT` | `type_text_target`, `type_text_value` | write | sets the field to the value; refused when that would replace a multi-line document with one line |
| `APPEND_TEXT` | `append_text_target`, `type_text_value` | write | adds the value at the end (a newline added when the field ends in one) |
| `REPLACE_TEXT` | `replace_text_target`, `replace_from`, `type_text_value` | write | sets the field to the edit described below |
| `SCROLL` | `scroll_target` | navigate | scrolls 3 lines at the element |
| `SELECT` | `select_target` | write | sets the dropdown to the option |
| `FOCUS_APP` | `focus_app_target` | focus | observes another app instead; offered only with more than one candidate (G12). With the app's background driver (Peekaboo over MCP) nothing is brought forward; the command-line driver activates the app |
| `KEY` | `key_target` | act | presses the chord in the focused window |
| `DONE` | — | terminal | ends the task; the harness may send it back (the DONE check) |
| `BLOCKED` | — | terminal | gives up |
| `TYPE_FOCUSED` | `type_text_value` | write | types where the keyboard focus is; offered right after `cmd+n`/`cmd+shift+n` (G1) |
| `ASK` | — | dialogue | asks the user; the question comes from the harness, not from a head |
| `FOCUS_WINDOW` | `focus_window_target` | focus | observes another window of the app; as with `FOCUS_APP`, the background driver does not raise it |
| `ANSWER` | `answer_value` | terminal | ends the task with the chosen on-screen text as the answer (G3) |

Operations are offered in this order, so their option letters are stable: a request offers a subset, and the ones it
offers keep this relative order. `goal_complete` (yes/no) is an extra question
some runs add (G2). The `class` column is v0's grouping for risk: `write` and `terminal` steps are the ones a wrong
answer is costly for.

**REPLACE_TEXT** is applied by the harness, not by the model: every pair of `replace_from` and `type_text_value` options
is tried in order of `p(from) × p(value)`, and the first that is a valid edit of the field's full text is made. A value
that already contains the whole field rewrites it instead of splicing it in (hands#9: a document had been nesting
inside itself); a goal's "from X" inside the chosen span replaces only X; a `Label: value` line keeps its label. The
action is then a `TYPE_TEXT` of the whole edited field.

**DONE and BLOCKED** at a top probability under 0.8 are overridden by the best non-terminal operation when its
`p(op) × p(top target)` is at least 0.2 (DONE) or 0.1 (BLOCKED) — unless the reply is `confirmed`, or DONE was already
top on the previous step or is at least 0.5.

### Heads and their options

| Format | Key | Description | Order | Used by |
|---|---|---|---|---|
| element | `"N"`, an element's `index` in the state | `{"element": "[N] <label>", "role", "current_value"}` | ascending | every `*_target` except below |
| dropdown option | `"N:k"`, an option's index | `{"element": "[N:k] <label> → <option>", "current_value"}` | ascending by N, then k | `select_target` |
| value | `"1"`…, position in the candidate list | `{"value"}` | `1`…`N`, no gaps | `type_text_value`, `answer_value` |
| replace span | `"1"`… | `{"text"}` | `1`…`N`, no gaps | `replace_from` |
| chord | lowercase, `+`-joined | the chord's description | as sent | `key_target` |
| app / window | name or bundle id / window id | a short description or the title | as sent | `focus_app_target` / `focus_window_target` |

The harness maps a chosen key back by position or index; a key that was not offered is refused. Limits per head are in
the registry (40 elements, 40 dropdown options in a state, 24 values, 16 replace spans, 120 answers).

`instructions`: `operation` gets `{goal, rules: [NEXT_ACTION, DESKTOP_RULES]}`; each target head gets `{goal,
operation, rules: [NEXT_ACTION, DESKTOP_RULES, TARGET]}`; `type_text_value` gets `{goal, rules: VALUE_CHOICE}` (a
string). The rule texts are prompt text the model was trained with (hands `rules.py`, `DESKTOP_RULES`).

### Where value options come from

`type_text_value` options are text the goal or the screen already contains — the model chooses, it never writes:
dictated lines after a colon (except a list of numbered file-operation steps, hands#12), inline dictation, runs of
quoted lines, search queries, works and artists, names the goal gives, file names, template fills and table rows read
from the screen, quoted strings, change targets, identifiers and numbers, and form values. A text a field refused as
already there is dropped while the field still holds it. Up to 24, in that order.

### The state

[`schema/agent-state.schema.json`](schema/agent-state.schema.json) gives every field. In short:

| Field | Content |
|---|---|
| `page` | `url` (the app's display name), `title` (the window's), `text` (labels and values, about 2500 characters) |
| `elements` | up to 40: `index`, `id`, `role` (the driver's), `label`, `operations` offered on it, `options`?, `current_value`?, `focused`? |
| `recent_actions` | the last 6: `action` (target label), `kind`, `text`, `page_changed`, and `ok: false` + `error` for failures |
| `effects_so_far` | what the driver confirmed the run did: moved, created, renamed, saved, removed |
| `modal_dialog_open`, `user_answers`, `read_in_other_windows` | as named |
| `note` | the modal's text, driver notes, the DONE check's sentences, and this step's notice from the loop |

Sections behind flags (`last_effect`, `environment`, `lessons`, `progress`) are not sent by the app. Key order is part
of the trained prompt.

### What the harness tells the model back

A refused answer is not executed. The next state's `note` says why ("Your previous output was not a valid action:
…"); three refusals in a run end it. Other notices: an unchanged screen after an action ("That step achieved nothing"),
the same action repeated, back-and-forth between two actions, a DONE sent back by the DONE check ("Not finished yet:
… save it before finishing"), a step the user declined. Risky steps — sending, deleting, paying, publishing, sharing,
and in the user's own folders renaming — wait for the user's approval first; a declined one is reported and not retried
another way.

## 3. The model side

What a model must match to behave as trained, beyond the request. These settings travel with the weights in
`deskmind.json`; the app's G18b tiers use the values below.

| Setting | Value | Meaning |
|---|---|---|
| system prompt | "You are a decision function inside a software system. Read the state, then answer the question with exactly one of the allowed labels and nothing else." | |
| `prompt_format` | 3 | compact JSON state; instructions shared by all questions shown once, before `<state>`; decorative elements (`scrollBar`, `scrollArea`, `group`, `image`) pruned (G17) |
| `compact_targets` | true | element options shown as `element <key>`, since the state already describes them |
| `round_size` | 52 | more options than this are scored as a tournament of 52-option rounds |
| labels | `A`–`Z`, `a`–`z`; `0`–`9`; `Yes`/`No` | options are read from the logits at the answer position, never generated |

## 4. Conformance

`python protocol/tools/check.py <requests>` checks recorded requests. A request or reply that fails its schema is
reported as such and not read further, so any JSON gives a report rather than a crash. An agent request asks the
operation and every head as a `choice`. An offered operation needs all its heads; the only exceptions are the heads
the registry's `may_lack` names, each with the gap that excuses it (G13, G19), and they are warnings. On 10-06 it was run over 440 real requests,
with the option order rules:

| Corpus | Requests | Conform | Warnings |
|---|---|---|---|
| hands `tests/replay` (3 recorded app runs, as of hands#13) | 25 | 25 | 0 |
| brain `fixtures/replay/v1/gym.jsonl.gz` | 150 | 150 | 11 (G19) |
| brain `fixtures/replay/v1/pairs.jsonl.gz` | 42 | 42 | 0 |
| brain `fixtures/replay/v2/closedloop.jsonl.gz` (as of brain#8) | 223 | 223 | 33 (G19) |

Before hands#13, hands' snapshots were stored with sorted keys and none of the 25 kept the order the model was shown;
the checker without the order rules passed them all.

Brain's `large.jsonl.gz` is padded on purpose to 240 options per target head, to stress the server; it is outside the
harness profile (40 elements) and is not part of this corpus.

## Known gaps

| Id | Gap |
|---|---|
| G1 | `TYPE_FOCUSED`'s `type_text_value` is not among the heads a two-stage server scores for it, so it comes back uniform and hands types candidate 1 whatever the model would have chosen. |
| G2 | `goal_complete` is not scored under two-stage unless the operation is terminal; it is uniform (p(yes) = 0.5) otherwise. |
| G3 | `ANSWER` ends the task but is not treated as terminal by the router: it is not escalated for being terminal, as DONE and BLOCKED are, and two tiers agreeing on it is not `confirmed`. It is still escalated on low confidence like any step (`answer_value` counts in `fast_conf`). |
| G4 | The two-tier merge fills heads from the fast tier only when both tiers chose a terminal operation; otherwise the strong tier's unscored heads are uniform. |
| G5 | Error bodies differ (401 is a string), and a `ValueError` inside the predictor is a 400, not a 500. |
| G6 | Defaults and names differ: port 8787 vs 8793, `DESKMIND_BRAIN_TOKEN` vs `SYSTEMONE_API_KEY`, the ignored `model` field with different defaults. |
| G8 | Comments in hands and Brain describe older behaviour (two calls per step; format-3 pruning keeping option elements). |
| G9 | Sharing instructions: the `operation` question's own instructions render as `Question: {}`; a `replace_from`, `answer_value` or `goal_complete` question stops the rules from being shared, so they repeat in every head. |
| G10 | Value candidates include Brain's own span extractor only when Brain is importable, so they differ between environments. |
| G11 | `KEY`: the rules tell the model to confirm with Return where Return is not offered; a chosen chord is checked against all chords rather than the offered ones; key names are not normalised. |
| G12 | `FOCUS_APP` needs two candidate apps, `FOCUS_WINDOW` one. |
| G13 | `REPLACE_TEXT` can be offered without `replace_from` (no span found); choosing it is then always refused. |
| G14 | Operation names differ across the two sides: `SELECT` is recorded as `fill`; Brain's replay counts `DELETE`, `MOVE`, `SEND` as writes, which hands never offers, and not `SELECT` or `TYPE_FOCUSED`. |
| G15 | Some state fields have no hard limit: `page.text` (soft), `read_in_other_windows`, `user_answers`, `note`, and the focus targets' option counts. |
| G16 | `user_answers` includes the harness's own approval questions, and any of them withdraws `ASK`. |
| G17 | Element roles are the driver's raw names; Brain prunes by exact strings, so a driver's renaming changes what the model sees. |
| G18 | Cached replies repeat the original `latency_ms` and `routing`. |
| G19 | `TYPE_TEXT`, `APPEND_TEXT` and `RENAME` are offered when there is no value candidate; `type_text_value` is then absent and choosing them is refused. |
| G20 | Nothing in a request or reply says which protocol version it follows. |
| G21 | A Finder state can carry folder names from outside the task's folder (the path bar, column view's ancestors), which matters when the planner is remote (deskmind#33). |
| G22 | Option order rested on JSON object key order, which JSON does not guarantee, and nothing checked it: a fixture builder (brain#8), hands' replay snapshots (hands#13) and Brain's answer cache key (brain#9) sorted keys. The order rules are checked now; the list form (v1) closes it. |

## Towards version 1

Proposals, to be decided with both sides:

1. **Versioning (G20).** A request carries `"protocol": "deskmind-agent/1"`; `GET /v1/models` lists the versions a
   server supports; training data records the version its requests followed, and a model serves only versions it was
   trained on. Changing an operation, a head, the state or a rule text is a new version, with a new replay baseline.
2. **Heads from the registry (G1–G4, G13, G14, G19).** Both sides read the heads of each operation from
   `operations.yaml` instead of naming conventions, so `TYPE_FOCUSED`, `ANSWER` and `goal_complete` are scored; an
   operation is offered only with all its heads present.
3. **Unscored is not uniform.** A two-stage reply marks unscored questions (`"scored": false`) instead of returning a
   uniform distribution that reads like an answer.
4. **How sure, beyond softmax.** Room in the answer for a reliability signal and an "escalate" verdict (similarity to
   past correct decisions, distance from the calibration data — deskmind#12), and a `class`-dependent threshold for
   writes and terminal steps.
5. **A handoff.** A way for the harness to hand a step or a stretch of steps to another model (a cloud tier) and back,
   as the Skill design describes.
6. **Hard limits everywhere (G15) and privacy (G21).** Every list and text in the state capped; a state confined to the
   task's scope, or refused, for a remote planner.
7. **One error shape (G5)** and one set of names and defaults (G6).

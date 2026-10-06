# protocol/

The contract between DeskMind's harness (Hands) and its decision models (Brain): [SPEC.md](SPEC.md), and the files a
program can load to keep to it.

| File | For |
|---|---|
| [`SPEC.md`](SPEC.md) | people: the transport, the agent profile, the model-side settings, known gaps (G1…) and what version 1 changes |
| [`schema/request.schema.json`](schema/request.schema.json), [`schema/response.schema.json`](schema/response.schema.json) | `POST /v1/systemone` requests and replies (JSON Schema 2020-12) |
| [`schema/agent-state.schema.json`](schema/agent-state.schema.json) | the `state` of an agent request |
| [`agent/operations.yaml`](agent/operations.yaml) | the operations, their heads (questions), option formats, limits and what the harness does with each |
| [`tools/check.py`](tools/check.py) | checks requests or replies against all of the above |
| [`examples/`](examples/) | a real agent request, in both forms of its options (v0 object, v1 list) |

Version 0 describes what ships (hands 89be730, brain 4767186, the Mac app 0.4.1) and changes nothing.

## Using it

Check recorded requests, for example hands' replays and Brain's replay fixtures:

```bash
pip install jsonschema pyyaml
python protocol/tools/check.py ../hands/tests/replay/*/expected.json ../brain/fixtures/replay/v1/gym.jsonl.gz
```

In code, `check_request(request)` and `check_reply(reply, request)` return errors and warnings; `options(question)`
reads a choice question's options in order, in either form. A harness can run them
on what it sends in its tests; a server on what it receives; a model's training pipeline on its data.

## Changing it

A change to an operation, a head, the state or a rule text is a protocol change: it goes here first, with the checker
and its tests, and both sides follow. `python -m unittest discover -s protocol/tests` must pass.

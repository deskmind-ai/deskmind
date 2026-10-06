`agent-request.json` is a real agent request: the first step of hands' recorded replay `d1en-app-open-save-close`
(hands `tests/replay/`, sanitized: the sandbox's names only). `protocol/tests` check it, and `tools/check.py` can be
pointed at any other recorded requests.

`agent-request.json` is in the order hands sent it (operations in the registry's order, element keys ascending). Until
hands#13 the snapshots it came from were stored with sorted keys, and so was this example. `agent-request.list.json`
is the same request with every choice question's options as a list of `{"key", "description"}`, the v1 form; the
tests check that both read the same options in the same order.

"""Check /v1/systemone requests (and replies) against the protocol: the transport schemas, and for agent requests the
agent state schema and the operations registry (protocol/agent/operations.yaml).

    python protocol/tools/check.py requests.json|requests.jsonl[.gz] ...     # a list, {"requests": [...]}, or one per line
    python protocol/tools/check.py --reply reply.json

Exit status 1 when any request has an error. Warnings name the known gaps (SPEC.md) a request runs into.
A harness or a server can import `check_request` / `check_reply` to check what it sends or receives, and `options`
to read a choice question's options in order, whichever form (v0 object, v1 list) they come in.
Needs PyYAML and jsonschema.
"""
from __future__ import annotations

import argparse
import gzip
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[1]


def _load(name: str) -> dict:
    return json.loads((ROOT / "schema" / name).read_text(encoding="utf-8"))


REQUEST = jsonschema.Draft202012Validator(_load("request.schema.json"))
REPLY = jsonschema.Draft202012Validator(_load("response.schema.json"))
STATE = jsonschema.Draft202012Validator(_load("agent-state.schema.json"))
REGISTRY = yaml.safe_load((ROOT / "agent" / "operations.yaml").read_text(encoding="utf-8"))


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def _schema_errors(validator, value, where: str) -> list[str]:
    return [f"{where}{'/' + '/'.join(map(str, e.absolute_path)) if e.absolute_path else ''}: {e.message[:200]}"
            for e in sorted(validator.iter_errors(value), key=lambda e: list(map(str, e.absolute_path)))]


def options(question) -> list[tuple]:
    """A choice question's options in the order they are shown: (key, description) pairs. v1 sends a list of
    {"key", "description"}; v0 an object, whose key order is the order."""
    crit = question.get("criteria") if isinstance(question, dict) else None
    if isinstance(crit, dict):
        return list(crit.items())
    if isinstance(crit, list):
        return [(o.get("key"), o.get("description")) for o in crit if isinstance(o, dict)]
    return []


def _number(key: str) -> tuple:
    return tuple(int(part) for part in key.split(":"))


def _order_errors(qid: str, keys: list[str], order: str, fmt_name: str) -> list[str]:
    """The option order a head's format asks for (operations.yaml, option_formats.*.order)."""
    if order == "one_to_n" and keys != [str(i) for i in range(1, len(keys) + 1)]:
        return [f"{qid}: options are {', '.join(keys[:6])}{', …' if len(keys) > 6 else ''}, not 1..{len(keys)} in order"]
    if order == "ascending":
        nums = [_number(k) for k in keys]
        for (a, na), (b, nb) in zip(zip(keys, nums), zip(keys[1:], nums[1:])):
            if nb <= na:
                return [f"{qid}: option {b!r} comes after {a!r}; {fmt_name} options ascend"]
    return []


def check_request(req: dict, registry: dict = REGISTRY) -> Report:
    r = Report()
    r.errors += _schema_errors(REQUEST, req, "request")
    if r.errors:
        return r          # the rest reads the request's structure, which the schema has just said is not there
    questions = req.get("questions") or {}
    for qid, q in questions.items():
        if isinstance(q, dict) and isinstance(q.get("criteria"), list) and q.get("type") == "choice":
            keys = [k for k, _ in options(q) if isinstance(k, str)]   # any other key is the schema's error
            r.errors += [f"{qid}: option {k!r} appears more than once" for k in sorted({k for k in keys if keys.count(k) > 1}, key=str)]
    op_q = questions.get(registry["operation_question"])
    if not isinstance(op_q, dict):
        return r                                    # not an agent request: the transport is all there is to check
    state = req.get("state")
    r.errors += _schema_errors(STATE, state, "state")
    if r.errors:
        return r
    ops, heads, formats = registry["operations"], registry["heads"], registry["option_formats"]

    offered = [k for k, _ in options(op_q) if isinstance(k, str)]   # any other key is the schema's error
    for op in offered:
        if op not in ops:
            r.errors.append(f"operation {op!r} is not in the registry")
    rank = {op: i for i, op in enumerate(ops)}
    known_ops = [op for op in offered if op in rank]
    for a, b in zip(known_ops, known_ops[1:]):
        if rank[b] < rank[a]:
            r.errors.append(f"operation: {b!r} is offered after {a!r}; operations keep the registry's order")
            break
    known = {registry["operation_question"], *heads}
    for qid, q in questions.items():
        if qid not in known:
            r.errors.append(f"question {qid!r} is neither the operation nor a known head")
        elif q.get("type") != "choice":
            r.errors.append(f"{qid}: an agent request asks it as a choice, not a {q.get('type')}")
    if any(e.endswith(", not a noul") or e.endswith(", not a score") for e in r.errors):
        return r
    for op in offered:
        for h in (ops.get(op) or {}).get("heads", []):
            if h not in questions:
                gap = ((ops.get(op) or {}).get("may_lack") or {}).get(h)
                (r.warnings if gap else r.errors).append(
                    f"{op} is offered without its head {h!r}" + (f" (known gap {gap})" if gap else ""))

    elements = state.get("elements", []) if isinstance(state, dict) else []
    indexes = {e.get("index") for e in elements if isinstance(e, dict)}
    dropdown = {o.get("index") for e in elements if isinstance(e, dict) for o in (e.get("options") or [])}
    for qid, q in questions.items():
        spec = heads.get(qid)
        if not spec or not isinstance(q, dict):
            continue
        keys = [k for k, _ in options(q)]
        fmt = formats[spec["format"]]
        cap = spec.get("max_options")
        if cap and len(keys) > cap:
            r.errors.append(f"{qid}: {len(keys)} options, more than its {cap}")
        well_formed = all(isinstance(k, str) and re.fullmatch(fmt["key"], k) for k in keys)
        if well_formed:
            r.errors += _order_errors(qid, keys, fmt.get("order", "as_sent"), spec["format"])
        for key in keys:
            if not isinstance(key, str) or not re.fullmatch(fmt["key"], key):
                r.errors.append(f"{qid}: option key {key!r} is not a {spec['format']} key")
            elif fmt.get("refers_to") == "state.elements.index" and key not in indexes:
                r.errors.append(f"{qid}: option {key!r} names no element in the state")
            elif fmt.get("refers_to") == "state.elements.options.index" and key not in dropdown:
                r.errors.append(f"{qid}: option {key!r} names no dropdown option in the state")

    for e in elements:
        for op in (e.get("operations") or []) if isinstance(e, dict) else []:
            if op not in ops:
                r.errors.append(f"element {e.get('index')}: operation {op!r} is not in the registry")
    limits = registry["limits"]
    if isinstance(state, dict):
        n_opts = sum(len(e.get("options") or []) for e in elements if isinstance(e, dict))
        if n_opts > limits["dropdown_options_in_state"]:
            r.errors.append(f"state: {n_opts} dropdown options, more than {limits['dropdown_options_in_state']}")
    return r


def check_reply(reply: dict, req: dict | None = None) -> Report:
    r = Report(errors=_schema_errors(REPLY, reply, "reply"))
    if req is not None and not r.errors and isinstance(req.get("questions") if isinstance(req, dict) else None, dict):
        missing = set(req.get("questions") or {}) - set(reply.get("answers") or {})
        r.errors += [f"no answer for question {q!r}" for q in sorted(missing)]
        for qid, a in (reply.get("answers") or {}).items():
            offered = [k for k, _ in options((req.get("questions") or {}).get(qid))]
            if a.get("type") == "choice" and offered and a.get("choice") not in offered:
                r.errors.append(f"{qid}: answered {a.get('choice')!r}, which was not offered")
    return r


def load_requests(path: Path) -> list[dict]:
    raw = gzip.open(path, "rt", encoding="utf-8").read() if path.suffix == ".gz" else path.read_text(encoding="utf-8")
    if path.name.endswith((".jsonl", ".jsonl.gz")):
        rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
    else:
        data = json.loads(raw)
        rows = data.get("requests", [data]) if isinstance(data, dict) else data
    # Brain's replay fixtures carry the request's state and questions at the top level, beside their labels.
    return [{"state": x["state"], "questions": x["questions"], **({"model": x["model"]} if "model" in x else {})}
            for x in rows]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("--reply", action="store_true", help="the files are replies, not requests")
    ap.add_argument("--quiet", action="store_true", help="only the summary")
    args = ap.parse_args(argv)
    bad = total = warned = 0
    for f in args.files:
        items = [json.loads(f.read_text())] if args.reply else load_requests(f)
        for i, item in enumerate(items):
            try:
                rep = check_reply(item) if args.reply else check_request(item)
            except Exception as exc:   # a record the checker cannot read is an error, and the rest are still checked
                rep = Report(errors=[f"unreadable: {type(exc).__name__}: {exc}"])
            total += 1
            bad += not rep.ok
            warned += bool(rep.warnings)
            if not args.quiet:
                for m in rep.errors:
                    print(f"{f.name}[{i}] ERROR {m}")
                for m in rep.warnings:
                    print(f"{f.name}[{i}] warning {m}")
    print(f"{total} checked: {total - bad} conform, {bad} with errors, {warned} with warnings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

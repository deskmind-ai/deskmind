"""Check /v1/systemone requests (and replies) against the protocol: the transport schemas, and for agent requests the
agent state schema and the operations registry (protocol/agent/operations.yaml).

    python protocol/tools/check.py requests.json|requests.jsonl[.gz] ...     # a list, {"requests": [...]}, or one per line
    python protocol/tools/check.py --reply reply.json

Exit status 1 when any request has an error. Warnings name the known gaps (SPEC.md) a request runs into.
A harness or a server can import `check_request` / `check_reply` to check what it sends or receives.
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


def check_request(req: dict, registry: dict = REGISTRY) -> Report:
    r = Report()
    r.errors += _schema_errors(REQUEST, req, "request")
    questions = req.get("questions") or {}
    op_q = questions.get(registry["operation_question"])
    if not isinstance(op_q, dict):
        return r                                    # not an agent request: the transport is all there is to check
    state = req.get("state")
    r.errors += _schema_errors(STATE, state, "state")
    ops, heads, formats = registry["operations"], registry["heads"], registry["option_formats"]

    offered = list((op_q.get("criteria") or {}).keys())
    for op in offered:
        if op not in ops:
            r.errors.append(f"operation {op!r} is not in the registry")
    known = {registry["operation_question"], *heads}
    for qid in questions:
        if qid not in known:
            r.errors.append(f"question {qid!r} is neither the operation nor a known head")
    for op in offered:
        for h in (ops.get(op) or {}).get("heads", []):
            if h not in questions:
                gaps = (ops.get(op) or {}).get("gaps", [])
                (r.warnings if gaps else r.errors).append(
                    f"{op} is offered without its head {h!r}" + (f" (known gap {', '.join(gaps)})" if gaps else ""))

    elements = state.get("elements", []) if isinstance(state, dict) else []
    indexes = {e.get("index") for e in elements if isinstance(e, dict)}
    dropdown = {o.get("index") for e in elements if isinstance(e, dict) for o in (e.get("options") or [])}
    for qid, q in questions.items():
        spec = heads.get(qid)
        if not spec or not isinstance(q, dict):
            continue
        crit = q.get("criteria") or {}
        fmt = formats[spec["format"]]
        cap = spec.get("max_options")
        if cap and isinstance(crit, dict) and len(crit) > cap:
            r.errors.append(f"{qid}: {len(crit)} options, more than its {cap}")
        for key in crit if isinstance(crit, dict) else []:
            if not re.fullmatch(fmt["key"], key):
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
    if req is not None:
        missing = set(req.get("questions") or {}) - set(reply.get("answers") or {})
        r.errors += [f"no answer for question {q!r}" for q in sorted(missing)]
        for qid, a in (reply.get("answers") or {}).items():
            crit = ((req.get("questions") or {}).get(qid) or {}).get("criteria")
            if a.get("type") == "choice" and isinstance(crit, dict) and a.get("choice") not in crit:
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
            rep = check_reply(item) if args.reply else check_request(item)
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

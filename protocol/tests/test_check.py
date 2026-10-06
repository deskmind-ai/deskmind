"""The checker against a real request, and against requests broken one way at a time."""
from __future__ import annotations

import copy
import hashlib
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from check import REGISTRY, check_reply, check_request, options   # noqa: E402

REQ = json.loads((ROOT / "examples" / "agent-request.json").read_text(encoding="utf-8"))
LIST = json.loads((ROOT / "examples" / "agent-request.list.json").read_text(encoding="utf-8"))


def _edit(req, edit):
    r = copy.deepcopy(req)
    edit(r)
    return r


def broken(edit):
    return check_request(_edit(REQ, edit))


class Requests(unittest.TestCase):
    def test_a_real_request_conforms(self):
        rep = check_request(REQ)
        self.assertTrue(rep.ok, rep.errors)

    def test_a_non_agent_request_is_checked_as_transport_only(self):
        self.assertTrue(check_request({"state": "s", "questions": {"q": {"type": "noul", "instructions": "x"}}}).ok)

    def test_unknown_operation_and_question(self):
        rep = broken(lambda r: r["questions"]["operation"]["criteria"].update({"TELEPORT": "go"}))
        self.assertIn("operation 'TELEPORT' is not in the registry", rep.errors)
        rep = broken(lambda r: r["questions"].update(
            {"mystery": {"type": "choice", "criteria": {"a": "b"}, "instructions": {}}}))
        self.assertTrue(any("'mystery'" in e for e in rep.errors), rep.errors)

    def test_an_offered_operation_needs_its_heads(self):
        rep = broken(lambda r: r["questions"].pop("click_target"))
        self.assertIn("CLICK is offered without its head 'click_target'", rep.errors)

    def test_a_known_gap_is_a_warning_not_an_error(self):
        rep = broken(lambda r: r["questions"].pop("type_text_value"))
        self.assertTrue(rep.ok, rep.errors)
        self.assertTrue(any("G19" in w for w in rep.warnings), rep.warnings)

    def test_target_options_must_name_elements_in_the_state(self):
        rep = broken(lambda r: r["questions"]["click_target"]["criteria"].update({"99": {"element": "[99] ghost"}}))
        self.assertIn("click_target: option '99' names no element in the state", rep.errors)

    def test_limits(self):
        def many(r):
            r["questions"]["operation"]["criteria"] = {f"OP{i}": "x" for i in range(256)}
        self.assertTrue(any("questions/operation/criteria" in e for e in broken(many).errors))

        def wide(r):
            r["questions"]["type_text_value"]["criteria"] = {str(i): {"value": str(i)} for i in range(1, 30)}
        self.assertIn("type_text_value: 29 options, more than its 24", broken(wide).errors)

    def test_the_state_shape(self):
        rep = broken(lambda r: r["state"].update({"surprise": 1}))
        self.assertTrue(any("surprise" in e for e in rep.errors), rep.errors)
        rep = broken(lambda r: r["state"]["elements"][0].pop("operations"))
        self.assertTrue(any("operations" in e for e in rep.errors), rep.errors)


class Hardening(unittest.TestCase):
    """From an outside review of v0 (10-06): what the checker crashed on, and what it let through."""

    def test_any_json_is_a_report_not_a_crash(self):
        for req in ([], 3, "x", None, {"state": {}, "questions": [1]}, {"state": {}, "questions": {"q": 3}},
                    {"state": [], "questions": {"operation": {"type": "choice", "instructions": {}, "criteria": {"CLICK": "c"}}}}):
            self.assertFalse(check_request(req).ok, repr(req))
        for reply in ([], {"answers": {"operation": 3}}, {"answers": []}):
            self.assertFalse(check_reply(reply, REQ).ok, repr(reply))

    def test_agent_questions_are_choices(self):
        rep = broken(lambda r: r["questions"].update({"operation": {"type": "noul", "instructions": {}}}))
        self.assertIn("operation: an agent request asks it as a choice, not a noul", rep.errors)
        rep = broken(lambda r: r["questions"].update({"click_target": {"type": "score", "instructions": {},
                                                                        "criteria": ["a", "b"]}}))
        self.assertIn("click_target: an agent request asks it as a choice, not a score", rep.errors)

    def test_a_gap_excuses_only_the_head_it_is_about(self):
        rep = broken(lambda r: r["questions"]["operation"]["criteria"].update({"ANSWER": "answer"}))
        self.assertIn("ANSWER is offered without its head 'answer_value'", rep.errors, "G3 is about routing, not heads")
        rep = broken(lambda r: r["questions"].pop("type_text_target"))
        self.assertIn("TYPE_TEXT is offered without its head 'type_text_target'", rep.errors,
                      "G19 is about the value head only")
        rep = broken(lambda r: r["questions"].pop("type_text_value"))
        self.assertTrue(rep.ok, rep.errors)
        self.assertIn("TYPE_TEXT is offered without its head 'type_text_value' (known gap G19)", rep.warnings)

    def test_the_registry_says_which_head_a_gap_excuses(self):
        for op, spec in REGISTRY["operations"].items():
            for head, gap in (spec.get("may_lack") or {}).items():
                self.assertIn(head, spec["heads"], op)
                self.assertIn(gap, spec.get("gaps", []), op)


class OptionOrder(unittest.TestCase):
    """The order of a question's options sets the letters the model answers with (deskmind#36 item 1). brain#8: the
    same model on re-sorted fixtures fell from 220 to about 130 of 223 valid steps, and v0's checker passed them."""

    def test_the_list_form_is_the_same_request(self):
        self.assertTrue(check_request(LIST).ok, check_request(LIST).errors)
        self.assertEqual(list(LIST["questions"]), list(REQ["questions"]))
        for qid, q in REQ["questions"].items():
            self.assertEqual(options(LIST["questions"][qid]), options(q), qid)

    def test_sorted_keys_are_caught(self):
        """What a json.dumps(..., sort_keys=True) on the way does to an object-form request."""
        rep = check_request(json.loads(json.dumps(REQ, sort_keys=True)))
        self.assertIn("operation: 'CLICK' is offered after 'BLOCKED'; operations keep the registry's order",
                      rep.errors)
        self.assertIn("click_target: option '2' comes after '19'; element options ascend", rep.errors)
        self.assertTrue(any(e.startswith("type_text_value: options are 1, 10, 11") for e in rep.errors), rep.errors)

    def test_the_same_rules_hold_for_the_list_form(self):
        def swap(r):
            ops = r["questions"]["operation"]["criteria"]
            ops[0], ops[1] = ops[1], ops[0]
        rep = check_request(_edit(LIST, swap))
        self.assertIn("operation: 'CLICK' is offered after 'OPEN'; operations keep the registry's order", rep.errors)

    def test_a_subset_of_the_operations_keeps_their_relative_order(self):
        def fewer(r):
            for op in ("CLICK", "SCROLL"):
                r["questions"]["operation"]["criteria"].pop(op)
                r["questions"].pop(op.lower() + "_target")
        self.assertTrue(broken(fewer).ok, broken(fewer).errors)

    def test_candidates_are_numbered_from_one_without_gaps(self):
        rep = broken(lambda r: r["questions"]["type_text_value"]["criteria"].pop("2"))
        self.assertTrue(any(e.startswith("type_text_value: options are 1, 3,") for e in rep.errors), rep.errors)

    def test_a_key_appears_once_in_the_list_form(self):
        rep = check_request(_edit(LIST, lambda r: r["questions"]["operation"]["criteria"].append(
            {"key": "DONE", "description": "again"})))
        self.assertIn("operation: option 'DONE' appears more than once", rep.errors)

    def test_a_key_that_is_not_a_string_is_a_schema_error_not_a_crash(self):
        """Review of #38: a list key like ["x"] made the duplicate and order checks raise TypeError."""
        def odd(r):
            r["questions"]["operation"]["criteria"][0]["key"] = ["x"]
            r["questions"]["click_target"]["criteria"].append({"key": {"n": 1}, "description": "x"})
        rep = check_request(_edit(LIST, odd))
        self.assertTrue(any(e.startswith("request/questions/operation/criteria") for e in rep.errors), rep.errors)
        self.assertTrue(any(e.startswith("request/questions/click_target/criteria") for e in rep.errors), rep.errors)

    def test_a_list_entry_is_a_key_and_a_description(self):
        rep = check_request(_edit(LIST, lambda r: r["questions"]["operation"]["criteria"][0].pop("description")))
        self.assertTrue(any("questions/operation/criteria" in e for e in rep.errors), rep.errors)


def state_digest(state) -> str:
    """As SPEC.md defines it, written out here rather than imported: compact JSON in the order sent, SHA-256."""
    return "sha256:" + hashlib.sha256(json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


class Identity(unittest.TestCase):
    """Which step of which run a request is for (deskmind#36 item 4), and that a reply says it back."""

    def with_ids(self, **extra):
        r = copy.deepcopy(REQ)
        r.update({"request_id": "r-1", "session_id": "run-1", "step": 3, "observation_id": "obs-0007",
                  "state_digest": state_digest(r["state"])}, **extra)
        return r

    def test_a_request_with_its_identity_conforms(self):
        self.assertTrue(check_request(self.with_ids()).ok, check_request(self.with_ids()).errors)

    def test_the_digest_is_of_the_state_as_sent(self):
        r = self.with_ids()
        r["state"]["page"]["title"] = "another window"
        self.assertIn("state_digest is not the digest of this state (SPEC.md, Request identity)", check_request(r).errors)
        reordered = self.with_ids()
        reordered["state"] = dict(reversed(list(reordered["state"].items())))
        self.assertFalse(check_request(reordered).ok, "the same state in another order is another input")

    def test_bad_identity_fields(self):
        for bad in ({"step": 0}, {"step": "3"}, {"request_id": ""}, {"state_digest": "md5:abc"}):
            self.assertFalse(check_request(self.with_ids(**bad)).ok, bad)

    def test_a_reply_echoes_it(self):
        req = self.with_ids()
        answers = {q: {"type": "choice", "choice": options(v)[0][0], "probabilities": {options(v)[0][0]: 1.0}}
                   for q, v in req["questions"].items()}
        echoed = {"answers": answers, "request_id": "r-1", "session_id": "run-1", "step": 3}
        self.assertTrue(check_reply(echoed, req).ok)
        self.assertEqual(check_reply(echoed, req).warnings, [])
        self.assertIn("reply request_id is 'r-2', the request's is 'r-1'",
                      check_reply({**echoed, "request_id": "r-2"}, req).errors)
        self.assertIn("the reply does not echo step", check_reply({"answers": answers}, req).warnings,
                      "a server from before the echo: a warning, not an error")


class Replies(unittest.TestCase):
    def test_a_reply_must_answer_every_question_with_an_offered_option(self):
        answers = {q: {"type": "choice", "choice": next(iter(v["criteria"])),
                       "probabilities": {next(iter(v["criteria"])): 1.0}}
                   for q, v in REQ["questions"].items()}
        self.assertTrue(check_reply({"answers": answers}, REQ).ok)
        bad = copy.deepcopy(answers)
        bad.pop("operation")
        bad["click_target"]["choice"] = "nope"
        rep = check_reply({"answers": bad}, REQ)
        self.assertIn("no answer for question 'operation'", rep.errors)
        self.assertIn("click_target: answered 'nope', which was not offered", rep.errors)
        self.assertIn("click_target: answered 'nope', which was not offered",
                      check_reply({"answers": bad}, LIST).errors, "the list form's options are read too")


class Registry(unittest.TestCase):
    def test_every_head_an_operation_uses_is_defined(self):
        for op, spec in REGISTRY["operations"].items():
            for h in spec["heads"]:
                self.assertIn(h, REGISTRY["heads"], f"{op} uses {h}")

    def test_every_head_format_is_defined(self):
        for h, spec in REGISTRY["heads"].items():
            self.assertIn(spec["format"], REGISTRY["option_formats"], h)


if __name__ == "__main__":
    unittest.main()

"""The checker against a real request, and against requests broken one way at a time."""
from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from check import REGISTRY, check_reply, check_request   # noqa: E402

REQ = json.loads((ROOT / "examples" / "agent-request.json").read_text(encoding="utf-8"))


def broken(edit):
    r = copy.deepcopy(REQ)
    edit(r)
    return check_request(r)


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

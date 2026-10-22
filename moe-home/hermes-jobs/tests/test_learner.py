#!/usr/bin/env python3
"""The learner (moe-home/lib/learner.py): what the person did with offers,
turned into how sure Alfie is next time. Run: python3 test_learner.py"""

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib"))
NOW = 1790280000.0


def load(name):
    if LIB not in sys.path:
        sys.path.insert(0, LIB)
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIB, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


SITS = {
    "old1": {"kind": "Payment dispute", "source": "native/whatsapp", "thread": "t1", "p_wanted": 0.8},
    "old2": {"kind": "payment disputes", "source": "composio/gmail", "thread": "t9", "p_wanted": 0.8},
    "other": {"kind": "haircut booking", "source": "native/whatsapp", "thread": "t5", "p_wanted": 0.8},
}
NEW = {"kind": "Payment Dispute", "source": "native/whatsapp", "thread": "t7", "p_wanted": 0.7}


class LearnerTest(unittest.TestCase):
    def setUp(self):
        self.l = load("learner")

    def fb(self, *rows):
        return [{"at": NOW - 3600, "id": i, "action": a} for i, a in rows]

    def test_with_no_history_the_sensors_guess_stands(self):
        self.assertEqual(self.l.adjusted(NEW, SITS, [], NOW), 0.7)

    def test_using_offers_of_a_kind_raises_it_declining_lowers_it(self):
        up = self.l.adjusted(NEW, SITS, self.fb(("old1", "used"), ("old2", "used")), NOW)
        down = self.l.adjusted(NEW, SITS, self.fb(("old1", "not-now"), ("old2", "not-now")), NOW)
        self.assertGreater(up, 0.7)
        self.assertLess(down, 0.7)

    def test_done_is_handled_and_weighs_nothing(self):
        """Done on an offer card is "I dealt with it another way" — recorded
        as `handled`, never `not-now` (docs/INBOX-QUIET.md), and it moves
        nothing either way."""
        self.assertIn("handled", self.l.WEIGHTS)
        done = self.l.adjusted(NEW, SITS, self.fb(("old1", "handled"), ("old2", "handled")), NOW)
        self.assertEqual(done, 0.7)

    def test_asking_moe_to_send_counts_a_little_less_than_a_confirmed_send(self):
        """The island records "used" only when the send went (the WhatsApp
        path sees the connector's answer); asking Alfie to send it through the
        brain is "chose-to-send", since the gate's answer is not seen here."""
        sent = self.l.adjusted(NEW, SITS, self.fb(("old1", "used")), NOW)
        chose = self.l.adjusted(NEW, SITS, self.fb(("old1", "chose-to-send")), NOW)
        self.assertGreater(chose, 0.7)
        self.assertLess(chose, sent)

    def test_not_this_kind_silences_the_kind_for_a_month_and_nothing_else(self):
        fb = self.fb(("old1", "not-this-kind"))
        self.assertEqual(self.l.adjusted(NEW, SITS, fb, NOW), 0.0)
        haircut = {"kind": "Haircut booking", "source": "composio/gmail", "thread": "t8", "p_wanted": 0.7}
        self.assertEqual(self.l.adjusted(haircut, SITS, fb, NOW), 0.7)
        later = NOW + 31 * 86400
        self.assertGreater(self.l.adjusted(NEW, SITS, fb, later), 0.0, "a month later it may come back")

    def test_the_same_conversation_counts_even_as_another_kind(self):
        same_thread = {"kind": "scheduling", "source": "native/whatsapp", "thread": "t5", "p_wanted": 0.7}
        self.assertLess(self.l.adjusted(same_thread, SITS, self.fb(("other", "not-now")) * 3, NOW), 0.7)

    def test_the_file_is_read_tolerantly(self):
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, "f.jsonl")
            with open(path, "w") as f:
                f.write('{"at": 1, "id": "a", "action": "used"}\nnot json\n{"id": "b", "action": "shout"}\n')
            self.assertEqual([r["id"] for r in self.l.read_feedback(path)], ["a"])
        finally:
            shutil.rmtree(tmp)


class EngineUsesItTest(unittest.TestCase):
    """The engine offers by the learned estimate, not the sensor's alone."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-learner-")
        os.environ["MOE_HOME"] = self.tmp
        self.s = load("situations")
        load("learner")
        os.makedirs(os.path.join(self.tmp, "proactive"))

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_silenced_kind_is_not_offered(self):
        prepared = {"offer": "ready", "for": "x", "draft": ""}
        data = {"old": dict(SITS["old1"], status="offered"),
                "new": dict(NEW, status="prepared", next_move="owner", prepared=prepared, p_wanted=0.95)}
        with open(self.s.situations_path(), "w") as f:
            json.dump(data, f)
        offered = []
        with open(os.path.join(self.tmp, "proactive", "offer-feedback.jsonl"), "w") as f:
            f.write(json.dumps({"at": NOW - 60, "id": "old", "action": "not-this-kind"}) + "\n")
        self.s._offer_pass(lambda s: offered.append(s["id"]) or True, {}, NOW)
        self.assertEqual(offered, [])
        os.remove(os.path.join(self.tmp, "proactive", "offer-feedback.jsonl"))
        self.s._offer_pass(lambda s: offered.append(s["id"]) or True, {}, NOW)
        self.assertEqual(offered, ["new"], "without that answer it would have been offered")


if __name__ == "__main__":
    unittest.main()

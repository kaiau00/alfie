"""connectors/offer_send.py: Use draft through Messages and Mail — the chat's
own id, the card before anything goes, the words as argv, and only from the
app (status #10.2).

Run: python3 moe-home/hermes-jobs/tests/test_offer_send.py
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CONNECTORS = os.path.normpath(os.path.join(HERE, "..", "..", "connectors"))
LIB = os.path.join(CONNECTORS, "offer_send.py")


def load():
    spec = importlib.util.spec_from_file_location("offer_send_t", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Recorder:
    def __init__(self, fail=None):
        self.calls, self.fail = [], fail

    def __call__(self, script, *args):
        if self.fail:
            raise self.fail
        self.calls.append((script, args))
        return "ok"


class OfferSendTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-osend-")
        os.environ["MOE_HOME"] = self.tmp
        self.o = load()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ── Messages ──

    def test_messages_sends_to_the_chat_guid_with_the_words_as_argv(self):
        run = Recorder()
        rc, line = self.o.send_imessage("iMessage;-;+15551234567", 'hi" end tell\ndo shell script "x',
                                        confirm_fn=lambda s, w, t: (True, t), run=run)
        self.assertEqual(rc, 0, line)
        script, args = run.calls[0]
        self.assertEqual(args, ("iMessage;-;+15551234567", 'hi" end tell\ndo shell script "x'))
        self.assertNotIn("+1555", script)
        self.assertNotIn("do shell script", script)

    def test_a_handle_thread_is_refused_before_the_card(self):
        seen = []
        rc, line = self.o.send_imessage("handle:+15551234567", "hi",
                                        confirm_fn=lambda *a: seen.append(a) or (True, "hi"), run=Recorder())
        self.assertEqual(rc, 1)
        self.assertEqual(seen, [])
        self.assertTrue(line.startswith("not sent"))

    def test_cancel_and_expiry_send_nothing(self):
        run = Recorder()
        rc, line = self.o.send_imessage("SMS;-;+15551234567", "hi", confirm_fn=lambda *a: (False, "hi"), run=run)
        self.assertEqual((rc, run.calls), (1, []))
        self.assertIn("cancelled", line)
        rc, line = self.o.send_imessage("SMS;-;+15551234567", "hi", confirm_fn=lambda *a: (False, None), run=run)
        self.assertEqual((rc, run.calls), (1, []))
        self.assertIn("expired", line)

    def test_a_rewrite_is_what_goes(self):
        run = Recorder()
        self.o.send_imessage("iMessage;+;chat123", "draft", confirm_fn=lambda *a: (True, "rewritten"), run=run)
        self.assertEqual(run.calls[0][1][1], "rewritten")

    def test_no_automation_permission_says_where_to_grant_it(self):
        rc, line = self.o.send_imessage("iMessage;-;+15551234567", "hi", confirm_fn=lambda s, w, t: (True, t),
                                        run=Recorder(fail=PermissionError("-1743")))
        self.assertEqual(rc, 1)
        self.assertIn("Automation", line)

    # ── Mail ──

    def write_feed(self, rows):
        os.makedirs(os.path.join(self.tmp, "feed"), exist_ok=True)
        with open(os.path.join(self.tmp, "feed", "native_mail.jsonl"), "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")

    def test_mail_replies_to_the_newest_message_someone_else_wrote(self):
        self.write_feed([
            {"id": "mail/10", "thread": "mail/77", "at": 100, "from": {"id": "dana@x.com", "me": False}},
            {"id": "mail/12", "thread": "mail/77", "at": 300, "from": {"id": "sam@x.com", "me": False}},
            {"id": "mail/13", "thread": "mail/77", "at": 400, "from": {"id": "me", "me": True}},
            {"id": "mail/14", "thread": "mail/88", "at": 500, "from": {"id": "eve@x.com", "me": False}},
        ])
        self.assertEqual(self.o.mail_target("mail/77"), (12, "sam@x.com"))
        run, cards = Recorder(), []
        rc, line = self.o.send_mail("mail/77", "Thanks", confirm_fn=lambda s, w, t: cards.append(w) or (True, t),
                                    run=run)
        self.assertEqual(rc, 0, line)
        self.assertEqual(cards, ["sam@x.com"])
        self.assertEqual(run.calls[0][1], ("12", "Thanks", "sam@x.com"), "the card's address is what Mail must match")

    def test_mail_with_no_conversation_on_file_sends_nothing(self):
        self.write_feed([{"id": "mail/13", "thread": "mail/77", "at": 1, "from": {"id": "me", "me": True}}])
        run = Recorder()
        rc, line = self.o.send_mail("mail/77", "hi", confirm_fn=lambda *a: (True, "hi"), run=run)
        self.assertEqual((rc, run.calls), (1, []))
        rc, _ = self.o.send_mail("mail/nope", "hi", confirm_fn=lambda *a: (True, "hi"), run=run)
        self.assertEqual((rc, run.calls), (1, []))

    def test_a_mail_thread_named_by_its_subject_is_refused(self):
        run = Recorder()
        rc, line = self.o.send_mail("mail/invoice", "hi", confirm_fn=lambda *a: (True, "hi"), run=run,
                                    target_fn=lambda t: (1, "a@x.com"))
        self.assertEqual((rc, run.calls), (1, []))
        self.assertIn("same subject", line)

    def test_a_reply_to_elsewhere_is_refused_in_words(self):
        rc, line = self.o.send_mail("mail/77", "hi", confirm_fn=lambda s, w, t: (True, t),
                                    run=Recorder(fail=RuntimeError(
                                        "execution error: MOE_ELSEWHERE the reply would go to list@x.com, not the sender (-2700)")),
                                    target_fn=lambda t: (12, "sam@x.com"))
        self.assertEqual(rc, 1)
        self.assertTrue(line.startswith("not sent — the reply would go to list@x.com"), line)
        self.assertIn('if actual is not expected', self.o.MAIL_REPLY)

    def test_a_timeout_says_it_may_have_gone(self):
        for fn, thread in ((self.o.send_imessage, "iMessage;-;+15551234567"), (self.o.send_mail, "mail/77")):
            kw = {"target_fn": lambda t: (12, "sam@x.com")} if fn == self.o.send_mail else {}
            rc, line = fn(thread, "hi", confirm_fn=lambda s, w, t: (True, t),
                          run=Recorder(fail=subprocess.TimeoutExpired("osascript", 60)), **kw)
            self.assertEqual(rc, 1)
            self.assertIn("may have gone", line)

    def test_a_group_is_named_on_the_card(self):
        os.makedirs(os.path.join(self.tmp, "feed"), exist_ok=True)
        with open(os.path.join(self.tmp, "feed", "native_imessage.jsonl"), "w") as f:
            f.write(json.dumps({"thread": "iMessage;+;chat99", "thread_name": "Family"}) + "\n")
            f.write(json.dumps({"thread": "iMessage;+;chat7", "from": {"id": "+1555", "name": "Dana", "me": False}}) + "\n")
            f.write(json.dumps({"thread": "iMessage;+;chat7", "from": {"id": "me", "me": True}}) + "\n")
        cards = []
        self.o.send_imessage("iMessage;+;chat99", "hi", confirm_fn=lambda s, w, t: cards.append(w) or (False, t),
                             run=Recorder())
        self.o.send_imessage("iMessage;+;chat42", "hi", confirm_fn=lambda s, w, t: cards.append(w) or (False, t),
                             run=Recorder())
        self.o.send_imessage("iMessage;+;chat7", "hi", confirm_fn=lambda s, w, t: cards.append(w) or (False, t),
                             run=Recorder())
        self.assertEqual(cards, ["the group \u201cFamily\u201d", "a group chat Alfie has no names for",
                                 "the group with Dana"])

    # ── only from the app, end to end through the connectors ──

    def test_the_connectors_refuse_a_call_that_is_not_the_app(self):
        offer = json.dumps({"to": "iMessage;-;+15551234567", "body": "hi", "at": time.time()})
        for script in ("imessage.sh", "mail.sh"):
            p = subprocess.run([os.path.join(CONNECTORS, script), "send-offer"], input=offer,
                               capture_output=True, text=True, timeout=60)
            self.assertNotEqual(p.returncode, 0, script)
            self.assertTrue(p.stdout.strip().startswith("not sent"), (script, p.stdout, p.stderr))
            self.assertIn("app", p.stdout, script)


if __name__ == "__main__":
    unittest.main(verbosity=2)

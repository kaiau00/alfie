"""lib/composio_send.py: Use draft for any Composio service — the plan held
to code, the reply addressed from what the engine read, the card, and only
from the app (status #10.2).

Run: python3 moe-home/hermes-jobs/tests/test_composio_send.py
"""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib", "composio_send.py"))

def params(*names):
    return {n: {"type": "string", "description": ""} for n in names}


TOOLS = [
    {"name": "GMAIL_REPLY_TO_THREAD", "tags": [], "required": ["thread_id", "recipient_email", "message_body"],
     "parameters": params("thread_id", "recipient_email", "message_body", "is_html", "user_id", "cc")},
    {"name": "GMAIL_SEND_EMAIL", "tags": [], "required": ["recipient_email", "body"]},
    {"name": "GMAIL_DELETE_MESSAGE", "tags": ["destructiveHint"], "required": ["message_id"]},
    {"name": "GMAIL_FETCH_EMAILS", "tags": ["readOnlyHint"], "required": []},
]
GOOD = {"tool": "GMAIL_REPLY_TO_THREAD",
        "args": {"thread_id": "{thread}", "recipient_email": "{reply_to}", "message_body": "{body}", "is_html": False}}


def load():
    spec = importlib.util.spec_from_file_location("composio_send_t", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class SendTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-csend-")
        os.environ["MOE_HOME"] = self.tmp
        self.c = load()
        os.makedirs(os.path.join(self.tmp, "feed"))
        with open(os.path.join(self.tmp, "feed", "composio_gmail.jsonl"), "w") as f:
            for it in ({"id": "1", "thread": "T1", "thread_name": "Invoice", "at": 1,
                        "from": {"id": "dana@acme.io", "name": "Dana", "me": False}},
                       {"id": "2", "thread": "T1", "thread_name": "Invoice", "at": 2,
                        "from": {"id": "me@x.io", "name": "", "me": True}}):
                f.write(json.dumps(it) + "\n")
        self.sent = []

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def plan(self, answer):
        return self.c.ensure_plan("gmail", tools_fn=lambda s: TOOLS, call=lambda m: json.dumps(answer))

    def test_a_good_plan_is_kept_and_a_bad_one_never_runs(self):
        plan, why = self.plan(GOOD)
        self.assertEqual(why, "")
        self.assertEqual(plan["tool"], "GMAIL_REPLY_TO_THREAD")
        os.remove(self.c.plan_path("gmail"))
        for bad in ({"tool": "GMAIL_DELETE_MESSAGE", "args": {"message_id": "{thread}", "x": "{body}"}},
                    {"tool": "GMAIL_FETCH_EMAILS", "args": {"q": "{body}", "t": "{thread}"}},
                    {"tool": "GMAIL_REPLY_TO_THREAD", "args": {"thread_id": "{thread}", "message_body": "{body}"}},
                    {"tool": "GMAIL_REPLY_TO_THREAD", "args": dict(GOOD["args"], recipient_email="boss@evil.io")},
                    {"tool": "GMAIL_REPLY_TO_THREAD", "args": dict(GOOD["args"], cc="{body}")}):
            plan, why = self.plan(bad)
            self.assertIsNone(plan, bad)

    def test_a_format_word_is_a_constant_and_a_place_never_is(self):
        tools = [{"name": "SLACK_SEND_MESSAGE", "tags": [], "required": ["channel", "text"],
                  "parameters": params("channel", "text", "format", "thread_ts")}]
        ok = {"tool": "SLACK_SEND_MESSAGE", "args": {"channel": "{thread}", "text": "{body}", "format": "markdown"}}
        self.assertEqual(self.c.validate(ok, tools), "")
        fixed = {"tool": "SLACK_SEND_MESSAGE", "args": {"channel": "general", "text": "{body}", "thread_ts": "{thread}"}}
        self.assertIn("not a plain format word", self.c.validate(fixed, tools))

    def test_review_redirects_are_refused(self):
        """Review of offer-send #2: each of these passed the first validate."""
        tg = [{"name": "TELEGRAM_SEND_MESSAGE", "tags": [], "required": ["chat_id", "text"],
               "parameters": params("chat_id", "text", "reply_to_message_id", "username", "destination")}]
        for bad in ({"chat_id": 123456789, "text": "{body}", "reply_to_message_id": "{thread}"},
                    {"chat_id": "{subject}", "text": "{body}", "reply_to_message_id": "{thread}"},
                    {"chat_id": "{body}", "text": "{subject}", "reply_to_message_id": "{thread}"},
                    {"chat_id": "{thread}", "text": "{body}", "username": "attacker"},
                    {"chat_id": "{thread}", "text": "{body}", "destination": "someone_else"}):
            self.assertNotEqual(self.c.validate({"tool": "TELEGRAM_SEND_MESSAGE", "args": bad}, tg), "", bad)

    def test_second_review_redirects_are_refused(self):
        """Re-review of offer-send #2: key names the first fix did not know."""
        tools = [{"name": "X_SEND_MESSAGE", "tags": [], "required": [],
                  "parameters": params("chat_id", "text", "username", "recipientId", "dm", "room", "reply_all",
                                       "reply_broadcast", "cc", "subject", "user_id", "is_html", "format")}]
        base = {"chat_id": "{thread}", "text": "{body}"}
        for extra in ({"username": "{subject}"}, {"recipientId": "{subject}"}, {"dm": "default"},
                      {"room": "general"}, {"reply_all": True}, {"reply_broadcast": True}, {"cc": "{body}"}):
            self.assertNotEqual(self.c.validate({"tool": "X_SEND_MESSAGE", "args": dict(base, **extra)}, tools), "",
                                extra)
        for fine in ({"subject": "{subject}"}, {"user_id": "me"}, {"is_html": False}, {"format": "markdown"}):
            self.assertEqual(self.c.validate({"tool": "X_SEND_MESSAGE", "args": dict(base, **fine)}, tools), "",
                             fine)

    def test_third_review_non_sends_are_never_candidates(self):
        """Review of offer-send, round 3: tools that edit, delete, move, pin,
        schedule or forward had a send word in their name."""
        p = params("channel", "ts", "text", "chat_id", "message_id", "note", "x")
        for name, tags in (("SLACK_UPDATES_A_SLACK_MESSAGE", ["updateHint"]), ("TELEGRAM_EDIT_MESSAGE", []),
                           ("GMAIL_MOVE_TO_TRASH_MESSAGE", []), ("SLACK_DELETES_A_MESSAGE_FROM_A_CHAT", []),
                           ("SLACK_PINS_A_MESSAGE_TO_A_CHANNEL", []), ("LINEAR_DELETE_MESSAGE", []),
                           ("SLACK_SCHEDULES_A_MESSAGE", []), ("GMAIL_FORWARD_MESSAGE", []),
                           ("X_SEND_MESSAGE", ["mcpIgnore"])):
            self.assertEqual(self.c.candidates([{"name": name, "tags": tags, "parameters": p}]), [], name)
        self.assertEqual(len(self.c.candidates(TOOLS)), 2)

    def test_the_words_go_only_where_the_tool_takes_text(self):
        tools = [{"name": "GMAIL_SEND_EMAIL", "tags": [], "required": ["recipient_email"],
                  "parameters": params("recipient_email", "body", "thread_id", "subject", "to_email")}]
        base = {"thread_id": "{thread}"}
        for bad in ({"recipient_email": "{body}", "body": "text"},            # the words as the address
                    {"recipient_email": "{reply_to}", "x": "{body}"},          # a key the tool does not take
                    {"recipient_email": "{reply_to}", "body": "{body}", "to_email": "me"}):
            self.assertNotEqual(self.c.validate({"tool": "GMAIL_SEND_EMAIL", "args": dict(base, **bad)}, tools),
                                "", bad)
        ok = dict(base, recipient_email="{reply_to}", body="{body}", subject="{subject}")
        self.assertEqual(self.c.validate({"tool": "GMAIL_SEND_EMAIL", "args": ok}, tools), "")
        no_schema = [dict(tools[0], parameters={})]
        self.assertIn("did not say", self.c.validate({"tool": "GMAIL_SEND_EMAIL", "args": ok}, no_schema))

    def test_the_card_says_what_the_tool_does(self):
        self.assertEqual(self.c.service_label("gmail", "GMAIL_REPLY_TO_THREAD"), "Gmail (reply to thread)")
        self.run_offer()
        self.assertEqual(self.card[0], "Gmail (reply to thread)")

    def test_a_kept_plan_is_checked_against_the_live_tools_not_its_own_list(self):
        self.plan(GOOD)
        with open(self.c.plan_path("gmail")) as f:
            kept = json.load(f)
        kept["tool"] = "GMAIL_DELETE_MESSAGE"
        kept["args"] = {"message_id": "{thread}", "x": "{body}"}
        kept["checked_against"] = [{"name": "GMAIL_DELETE_MESSAGE", "tags": [], "required": ["message_id"]}]
        with open(self.c.plan_path("gmail"), "w") as f:
            json.dump(kept, f)
        plan, why = self.c.ensure_plan("gmail", tools_fn=lambda s: TOOLS)
        self.assertIsNone(plan)
        plan, why = self.c.ensure_plan("gmail", tools_fn=lambda s: None)
        self.assertIsNone(plan)

    def test_an_unreadable_or_slow_answer_may_have_gone(self):
        self.plan(GOOD)
        for exc in (self.c.Unsure("the service answered in a way Alfie could not read"), TimeoutError()):
            def boom(slug, tool, args, exc=exc):
                raise exc
            rc, line = self.c.send_offer("{}", check=lambda _: (("composio/gmail|T1", "hi"), ""),
                                         plan_fn=lambda s: self.c.ensure_plan(s, tools_fn=lambda _: TOOLS),
                                         confirm_fn=lambda s, w, t: (True, t), execute_fn=boom)
            self.assertEqual(rc, 1)
            self.assertIn("may have gone", line)
        self.assertIn("NOT_FOUND", self.c.refused({"data": None, "errors": [{"message": "NOT_FOUND"}]}))

    def test_a_plan_lives_where_the_shell_cannot_write(self):
        self.assertIn(os.path.join("composio", "send-plans"), self.c.plan_path("gmail"))

    def test_a_failure_inside_the_results_is_not_a_send(self):
        self.assertEqual(self.c.refused({"data": {"results": [{"response": {"successful": True, "data": {}}}]}}), "")
        self.assertIn("scope", self.c.refused({"data": {"results": [{"response": {"successful": False,
                                                                                  "error": "missing scope"}}]}}))
        self.assertTrue(self.c.refused([{"error": "bad recipient"}]))

    def test_a_failed_send_says_not_sent(self):
        self.plan(GOOD)
        def boom(slug, tool, args):
            raise RuntimeError("missing scope")
        rc, line = self.c.send_offer("{}", check=lambda _: (("composio/gmail|T1", "hi"), ""),
                                     plan_fn=lambda s: self.c.ensure_plan(s, tools_fn=lambda _: TOOLS),
                                     confirm_fn=lambda s, w, t: (True, t), execute_fn=boom)
        self.assertEqual(rc, 1)
        self.assertIn("missing scope", line)

    def test_a_named_sender_is_reduced_to_the_address(self):
        with open(os.path.join(self.tmp, "feed", "composio_gmail.jsonl"), "a") as f:
            f.write(json.dumps({"id": "3", "thread": "T2", "thread_name": "News", "at": 3,
                                "from": {"id": "Anthropic <no-reply@mail.anthropic.com>", "me": False}}) + "\n")
        self.assertEqual(self.c.facts("gmail", "T2")["{reply_to}"], "no-reply@mail.anthropic.com")

    def test_addressed_from_what_the_engine_read(self):
        f = self.c.facts("gmail", "T1")
        self.assertEqual((f["{reply_to}"], f["{subject}"]), ("dana@acme.io", "Invoice"),
                         "the last person who wrote, never the owner")

    def run_offer(self, check_ok=True, approve=(True, None), plan=GOOD):
        self.plan(plan)
        def check(_):
            return (("composio/gmail|T1", "Paid today, thanks"), "") if check_ok else (None, "not sent — not the app")
        def confirm(service, who, text):
            self.card = (service, who, text)
            ok, new = approve
            return ok, (new if new is not None else (None if not ok and new is None and approve == (False, None) else text))
        return self.c.send_offer("{}", check=check, confirm_fn=confirm,
                                 plan_fn=lambda s: self.c.ensure_plan(s, tools_fn=lambda _: TOOLS),
                                 execute_fn=lambda slug, tool, args: self.sent.append((slug, tool, args)))

    def test_sent_to_that_thread_after_the_card(self):
        rc, line = self.run_offer()
        self.assertEqual(rc, 0, line)
        self.assertEqual(self.card[1], "dana@acme.io")
        slug, tool, args = self.sent[0]
        self.assertEqual((slug, tool), ("gmail", "GMAIL_REPLY_TO_THREAD"))
        self.assertEqual(args, {"thread_id": "T1", "recipient_email": "dana@acme.io",
                                "message_body": "Paid today, thanks", "is_html": False})

    def test_never_without_the_app_or_the_click(self):
        self.assertEqual(self.run_offer(check_ok=False)[0], 1)
        rc, line = self.run_offer(approve=(False, "Paid today, thanks"))
        self.assertEqual(rc, 1)
        self.assertIn("cancelled", line)
        self.assertEqual(self.sent, [])

    def test_the_rewrite_is_what_goes(self):
        self.run_offer(approve=(True, "Paid this morning"))
        self.assertEqual(self.sent[0][2]["message_body"], "Paid this morning")


if __name__ == "__main__":
    unittest.main()

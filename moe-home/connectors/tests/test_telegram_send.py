#!/usr/bin/env python3
"""`telegram.py send` — the request parser and the gate in front of it.

The session file is a full delegated login, so this verb can write to other
people as the user. Everything here is about the two properties that make
that safe: the request cannot carry its own approval, and the dialog is
refused rather than skipped when anything is unclear.

Run: python3 -m unittest moe-home/connectors/tests/test_telegram_send.py
"""

import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "telegram.py")
spec = importlib.util.spec_from_file_location("moe_telegram", SRC)
tg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tg)

BIDI_OVERRIDE = "a\u202eb"
BIDI_ISOLATE = "a\u2066b"
NUL = "a\x00b"
LINE_SEP = "a\u2028b"


def req(**kw):
    return json.dumps(kw)


class TestParse(unittest.TestCase):
    def test_a_plain_message_parses(self):
        self.assertEqual(tg.parse_send_request(req(to="@bob", text="hello")), ("@bob", "hello"))

    def test_whitespace_around_the_recipient_is_not_a_new_recipient(self):
        self.assertEqual(tg.parse_send_request(req(to="  @bob  ", text="hi"))[0], "@bob")

    def test_anything_but_one_object_is_refused(self):
        for raw in ["", "not json", "[]", '"a string"', "null"]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                tg.parse_send_request(raw)

    def test_an_unknown_key_is_an_error_not_something_ignored(self):
        # The whole point: text Moe reads in your own chats can talk a model
        # into writing "confirmed": true. It must not be quietly dropped.
        with self.assertRaises(ValueError) as e:
            tg.parse_send_request(req(to="@bob", text="hi", confirmed=True))
        self.assertIn("confirmed", str(e.exception))

    def test_incomplete_or_wrongly_typed_requests_are_refused(self):
        cases = [
            {"text": "hi"},
            {"to": "", "text": "hi"},
            {"to": "   ", "text": "hi"},
            {"to": "@bob"},
            {"to": "@bob", "text": ""},
            {"to": "@bob", "text": "   "},
            {"to": 12345, "text": "hi"},
            {"to": "@bob", "text": 5},
            {"to": ["@bob", "@eve"], "text": "hi"},
        ]
        for kw in cases:
            with self.subTest(kw=kw), self.assertRaises(ValueError):
                tg.parse_send_request(req(**kw))

    def test_a_message_longer_than_telegram_allows_is_refused_here(self):
        with self.assertRaises(ValueError):
            tg.parse_send_request(req(to="@bob", text="x" * (tg.MAX_TEXT + 1)))

    def test_the_longest_allowed_message_still_goes(self):
        _, text = tg.parse_send_request(req(to="@bob", text="x" * tg.MAX_TEXT))
        self.assertEqual(len(text), tg.MAX_TEXT)

    def test_text_that_would_display_as_something_else_is_refused(self):
        # A bidi override shows the human one message and sends another.
        for bad in [BIDI_OVERRIDE, BIDI_ISOLATE, NUL, LINE_SEP]:
            with self.subTest(bad=repr(bad)), self.assertRaises(ValueError):
                tg.parse_send_request(req(to="@bob", text=bad))

    def test_newlines_and_tabs_are_ordinary_message_text(self):
        _, text = tg.parse_send_request(req(to="@bob", text="one\ntwo\tthree"))
        self.assertEqual(text, "one\ntwo\tthree")

    def test_a_recipient_cannot_smuggle_a_second_line(self):
        for bad in ["@bob\nto: @eve", "@bob\u202e", "@bob\x00"]:
            with self.subTest(bad=repr(bad)), self.assertRaises(ValueError):
                tg.parse_send_request(req(to=bad, text="hi"))


class TestGate(unittest.TestCase):
    def setUp(self):
        self._real = tg.confirm_script

    def tearDown(self):
        tg.confirm_script = self._real

    def test_the_gate_is_found_beside_this_file_not_from_the_environment(self):
        os.environ["MOE_HOME"] = "/tmp/somewhere-else"
        try:
            expected = os.path.normpath(os.path.join(
                os.path.dirname(os.path.realpath(SRC)), os.pardir, "tools", "confirm.sh"))
            self.assertEqual(tg.confirm_script(), expected)
        finally:
            os.environ.pop("MOE_HOME", None)

    def test_no_dialog_on_disk_is_a_refusal(self):
        tg.confirm_script = lambda: "/nonexistent/confirm.sh"
        approved, _ = tg.confirm("Bob", "hi")
        self.assertFalse(approved)

    def _stub(self, tmp, script_body):
        path = os.path.join(tmp, "confirm.sh")
        with open(path, "w") as f:
            f.write(script_body)
        os.chmod(path, 0o755)
        tg.confirm_script = lambda: path
        return path

    def test_a_dialog_that_crashes_is_a_refusal(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self._stub(tmp, "#!/bin/bash\nexit 3\n")
            # confirm() returns (approved, text) since dbb0bb8; a non-empty
            # tuple is truthy, so the old assertFalse on the whole value could
            # never fail. Ask about the approval.
            approved, _ = tg.confirm("Bob", "hi")
            self.assertFalse(approved)

    def test_a_dialog_that_is_not_executable_is_a_refusal(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "confirm.sh")
            with open(path, "w") as f:
                f.write("#!/bin/bash\nexit 0\n")
            os.chmod(path, 0o644)
            tg.confirm_script = lambda: path
            approved, _ = tg.confirm("Bob", "hi")
            self.assertFalse(approved)

    def test_only_a_clean_yes_is_a_yes(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self._stub(tmp, "#!/bin/bash\nexit 0\n")
            self.assertTrue(tg.confirm("Bob", "hi"))

    def test_the_dialog_is_shown_the_resolved_name_and_the_real_text(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "args.txt")
            self._stub(tmp, '#!/bin/bash\nprintf "%%s\\n%%s\\n%%s" "$1" "$2" "$3" > "%s"\n' % out)
            self.assertTrue(tg.confirm("Dan Whitfield (@danw)", "see you at six"))
            with open(out) as f:
                self.assertEqual(f.read().split("\n"),
                                 ["Telegram", "Dan Whitfield (@danw)", "see you at six"])


class TestDescribe(unittest.TestCase):
    """What the person approving actually reads. A bare id is unverifiable."""

    class E:
        def __init__(self, **kw):
            for k, v in kw.items():
                setattr(self, k, v)

    def test_name_and_handle_together(self):
        self.assertEqual(
            tg.describe(self.E(first_name="Dan", last_name="Whitfield", username="danw"), "x"),
            "Dan Whitfield (@danw)")

    def test_a_name_with_no_handle(self):
        self.assertEqual(tg.describe(self.E(first_name="Dan", last_name=None, username=None), "x"), "Dan")

    def test_a_handle_with_no_name(self):
        self.assertEqual(tg.describe(self.E(first_name=None, last_name=None, username="danw"), "x"), "@danw")

    def test_a_group_shows_its_title(self):
        self.assertEqual(tg.describe(self.E(title="Ops", username=None), "x"), "Ops")

    def test_an_entity_with_nothing_falls_back_to_what_was_asked_for(self):
        self.assertEqual(tg.describe(self.E(), "12345"), "12345")



class TestSendOffer(unittest.TestCase):
    """`send-offer`: the app's Use draft (review of offer-send #3 — the feed
    names a chat "telegram/<id>", and nothing tested this verb)."""

    def run_offer(self, to):
        sent, orig_check, orig_send = [], tg.offer_check, tg.cmd_send
        tg.offer_check = lambda text: ((to, "hi"), "")
        tg.cmd_send = lambda argv, offer=None: sent.append(offer) or 0
        try:
            rc = tg.cmd_send_offer("{}")
        finally:
            tg.offer_check, tg.cmd_send = orig_check, orig_send
        return rc, sent

    def test_the_chat_as_the_feed_names_it_goes_to_its_id(self):
        self.assertEqual(self.run_offer("telegram/-1001234567"), (0, [("-1001234567", "hi")]))
        self.assertEqual(self.run_offer("42"), (0, [("42", "hi")]))

    def test_a_name_is_never_a_chat(self):
        for to in ("@bob", "telegram/@bob", "Team chat", "telegram/12 34"):
            with self.subTest(to=to):
                self.assertEqual(self.run_offer(to), (1, []))

    def test_a_refused_check_sends_nothing(self):
        sent, orig_check, orig_send = [], tg.offer_check, tg.cmd_send
        tg.offer_check = lambda text: (None, "not sent — not the app")
        tg.cmd_send = lambda argv, offer=None: sent.append(offer) or 0
        try:
            self.assertEqual(tg.cmd_send_offer("{}"), 1)
        finally:
            tg.offer_check, tg.cmd_send = orig_check, orig_send
        self.assertEqual(sent, [])

if __name__ == "__main__":
    unittest.main()

"""The activity hook: what it records, and what it refuses to record."""

import asyncio
import importlib.util
import json
import os
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HANDLER = os.path.join(os.path.dirname(HERE), "moe-activity", "handler.py")


def load(moe_home):
    """Fresh import per test: _PATH is resolved at import time from MOE_HOME.

    The caller restores the previous value — this module sets a process-wide
    variable, and a suite sharing the interpreter would otherwise inherit a
    temp directory that no longer exists."""
    os.environ["MOE_HOME"] = moe_home
    spec = importlib.util.spec_from_file_location("moe_activity_%d" % id(moe_home), HANDLER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


TELEGRAM = {
    "platform": "telegram", "chat_type": "dm", "chat_id": "5550001107",
    "session_id": "sess-abc", "model": "haiku", "provider": "claude-code-cli",
    "message": "what is on my calendar", "response": "Two things today.",
}


class ActivityHookTest(unittest.TestCase):
    def setUp(self):
        self._saved = os.environ.get("MOE_HOME")
        self.home = tempfile.mkdtemp(prefix="moe-activity-test-")
        self.mod = load(self.home)

    def tearDown(self):
        if self._saved is None:
            os.environ.pop("MOE_HOME", None)
        else:
            os.environ["MOE_HOME"] = self._saved

    def rows(self):
        if not os.path.exists(self.mod._PATH):
            return []
        with open(self.mod._PATH, encoding="utf-8") as f:
            return [json.loads(l) for l in f if l.strip()]

    def test_a_platform_turn_is_recorded(self):
        run(self.mod.handle("agent:end", TELEGRAM))
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["platform"], "telegram")
        self.assertEqual(rows[0]["session_id"], "sess-abc")

    def test_no_message_or_response_text_is_ever_written(self):
        """Alfie's own confirm-send hook says it plainly — "a log of message
        bodies is a liability" — and this file would be the better prize,
        holding both sides of every conversation on every platform. Lengths
        answer "a turn happened, this big"; the session id is how anyone who
        needs the words asks Hermes's own store for them."""
        run(self.mod.handle("agent:end", TELEGRAM))
        blob = open(self.mod._PATH, encoding="utf-8").read()
        self.assertNotIn("what is on my calendar", blob)
        self.assertNotIn("Two things today", blob)
        row = self.rows()[0]
        self.assertEqual(row["in_chars"], str(len(TELEGRAM["message"])))
        self.assertEqual(row["out_chars"], str(len(TELEGRAM["response"])))

    def test_a_clamped_size_says_so(self):
        """The gateway truncates message/response to 500 chars before a hook
        sees them, so a long turn arrives as exactly 500. Recording that as a
        length is a quiet lie on every substantial turn — and the old test used
        a 22-char string, so it passed without ever touching the case."""
        run(self.mod.handle("agent:end", dict(TELEGRAM, message="x" * 500,
                                              response="y" * 500)))
        row = self.rows()[0]
        self.assertEqual(row["in_chars"], "500+")
        self.assertEqual(row["out_chars"], "500+")

    def test_the_file_is_private(self):
        """chat ids are personal data even with no words beside them."""
        run(self.mod.handle("agent:end", TELEGRAM))
        self.assertEqual(stat.S_IMODE(os.stat(self.mod._PATH).st_mode), 0o600)

    def test_moes_own_channel_is_not_recorded(self):
        """api_server IS Alfie. It already knows its own turns, and writing them
        here would bury the ones it does not know about."""
        run(self.mod.handle("agent:end", dict(TELEGRAM, platform="api_server")))
        run(self.mod.handle("agent:end", dict(TELEGRAM, platform="")))
        self.assertEqual(self.rows(), [])

    def test_only_finished_turns(self):
        for event in ("agent:start", "agent:step", "session:end", "gateway:startup"):
            run(self.mod.handle(event, TELEGRAM))
        self.assertEqual(self.rows(), [])

    def test_a_missing_context_never_raises(self):
        """gateway/hooks.py catches what a handler raises, but a hook that
        throws on every turn is noise in a log somebody has to read."""
        for ctx in (None, {}, {"platform": "telegram"}):
            run(self.mod.handle("agent:end", ctx))

    def test_the_file_is_trimmed_from_the_front(self):
        """A day of chat is a few hundred lines; a runaway loop is not. Newest
        last, so a reader tailing it sees the most recent."""
        self.mod._MAX_LINES = 5
        for i in range(9):
            run(self.mod.handle("agent:end", dict(TELEGRAM, session_id="s%d" % i)))
        rows = self.rows()
        self.assertEqual(len(rows), 5)
        self.assertEqual([r["session_id"] for r in rows],
                         ["s4", "s5", "s6", "s7", "s8"])


class EmptyMoeHomeTest(unittest.TestCase):
    def test_an_empty_moe_home_is_not_a_relative_path(self):
        """`.get(k, default)` returns "" for a set-but-empty variable, and
        expanduser("") is "" — which put the log at the relative path
        logs/activity.jsonl, inside the gateway's cwd."""
        saved = os.environ.get("MOE_HOME")
        try:
            mod = load("")
            self.assertTrue(os.path.isabs(mod._PATH), mod._PATH)
        finally:
            if saved is None:
                os.environ.pop("MOE_HOME", None)
            else:
                os.environ["MOE_HOME"] = saved


if __name__ == "__main__":
    unittest.main(verbosity=2)

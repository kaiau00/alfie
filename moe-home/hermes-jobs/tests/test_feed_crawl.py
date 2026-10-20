"""lib/feed_crawl.py: what connected services' messages say, for the daily
learning pass, from the engine's own feed (status #8; owner, 2026-09-29:
"everything in the inbox, and make it cheap") — and the consent sentence
that says so.

Run: python3 moe-home/hermes-jobs/tests/test_feed_crawl.py
"""

import importlib.util
import json
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MOE_SRC = os.path.normpath(os.path.join(HERE, "..", ".."))
NOW = 1_790_700_000.0


def load(rel, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(MOE_SRC, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def item(i, thread, text, *, me=False, at=None, name="Dana"):
    return {"id": "i%d" % i, "thread": thread, "thread_name": "Thread %s" % thread,
            "at": at or NOW - 1000 + i, "from": {"id": name.lower(), "name": "" if me else name, "me": me},
            "to_me": True, "kind": "mail", "text": text}


class FeedCrawlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-feed-crawl-")
        os.environ["MOE_HOME"] = self.tmp
        self.f = load("lib/feed_crawl.py", "feed_crawl_t")

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_people_in_automated_out_newest_conversation_first(self):
        text = self.f.render([
            item(1, "a", "Old thread, still a person", at=NOW - 5000),
            item(2, "b", "Your verification code is 123456", name="Bank"),
            item(3, "c", "Newest: can we move the call to Thursday?", at=NOW - 10),
            item(4, "c", "Sure, Thursday works", me=True, at=NOW - 5),
            item(3, "c", "Newest: can we move the call to Thursday?", at=NOW - 10),   # the same item twice
        ])
        self.assertNotIn("verification code", text)
        self.assertLess(text.index("Thread c"), text.index("Thread a"))
        self.assertEqual(text.count("move the call"), 1)
        self.assertIn("] me: Sure, Thursday works", text)

    def test_every_cap_holds(self):
        long_text = "word " * 1000
        many = [item(i, "t", "message %d %s" % (i, long_text), at=NOW - 100 + i) for i in range(20)]
        text = self.f.render(many)
        lines = [l for l in text.splitlines() if l.startswith("[")]
        self.assertEqual(len(lines), self.f.MAX_PER_THREAD, "only a conversation's newest messages")
        self.assertIn("message 19", text, "…the newest ones")
        self.assertTrue(all(len(l.split(": ", 1)[1]) <= self.f.ITEM_CAP for l in lines))
        threads = [item(i, "t%d" % i, "x" * 600) for i in range(100)]
        self.assertLessEqual(len(self.f.render(threads, max_bytes=5000).encode()), 5000)

    def test_reads_the_feed_within_the_window_only(self):
        os.makedirs(os.path.join(self.tmp, "feed"))
        with open(os.path.join(self.tmp, "feed", "composio_gmail.jsonl"), "w") as fh:
            for it in (item(1, "a", "inside", at=NOW - 3600), item(2, "b", "outside", at=NOW - 3 * 86400)):
                fh.write(json.dumps(it) + "\n")
        got = self.f.feed_items("composio/gmail", 1, NOW)
        self.assertEqual([i["text"] for i in got], ["inside"])
        self.assertEqual(self.f.feed_items("composio/nothing", 1, NOW), [])

    def test_only_what_the_pass_has_not_read_and_only_once_it_merged(self):
        import io
        import contextlib
        os.makedirs(os.path.join(self.tmp, "feed"))
        feed = os.path.join(self.tmp, "feed", "composio_gmail.jsonl")
        state = os.path.join(self.tmp, "learn", "feed-read.json")

        def new():
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                self.f.main(["x", "composio/gmail", "--new", state])
            return buf.getvalue()
        with open(feed, "w") as fh:
            fh.write(json.dumps(item(1, "a", "the first message", at=NOW - 100)) + "\n")
        self.assertIn("the first message", new())
        self.assertIn("the first message", new(), "not committed: read again")
        self.f.main(["x", "composio/gmail", "--commit", state])
        self.assertEqual(new(), "", "committed: never read again")
        with open(feed, "a") as fh:
            fh.write(json.dumps(item(2, "b", "a newer one", at=NOW - 50)) + "\n")
        out = new()
        self.assertIn("a newer one", out)
        self.assertNotIn("the first message", out)


class ConsentSentenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-consent-words-")
        os.environ["MOE_HOME"] = self.tmp
        self.c = load("learn/consent_list.py", "consent_list_t")

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_watched_service_says_its_messages_are_learned_from(self):
        os.makedirs(os.path.join(self.tmp, "gather"))
        with open(os.path.join(self.tmp, "gather", "composio-gmail.items.json"), "w") as fh:
            json.dump({"tool": "GMAIL_FETCH_EMAILS"}, fh)
        gmail = self.c.describe("gmail", "composio")
        self.assertIn("what they say", gmail)
        self.assertNotIn("never rows, messages", gmail)
        airtable = self.c.describe("airtable", "composio")
        self.assertIn("where it holds messages, what they say", airtable,
                      "said before the engine knows: a yes to 'metadata only' never becomes one to text")
        self.assertNotIn("metadata only", airtable)


if __name__ == "__main__":
    unittest.main()

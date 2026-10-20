#!/usr/bin/env python3
"""The situations engine's one adapter for every Composio toolkit
(moe-home/lib/composio_items.py): plan once with no tools, run the plan
deterministically, read the answer by shape. No network, no model.

Run: python3 moe-home/hermes-jobs/tests/test_composio_items.py

The tool rows are the shape `composio.py tools <slug> --json --schemas`
returns; GMAIL_FETCH_EMAILS's parameters are copied from that call on the
owner's Mac (2026-09-24). The payloads are the shapes Gmail and GitHub
answer with, trimmed.
"""

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib", "composio_items.py"))


def load():
    spec = importlib.util.spec_from_file_location("composio_items_under_test", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GMAIL_TOOLS = [
    {"slug": "GMAIL_SEND_EMAIL", "tags": ["important", "openWorldHint"], "required": [], "parameters": {}},
    {"slug": "GMAIL_DELETE_MESSAGE", "tags": ["destructiveHint", "readOnlyHint"], "required": [], "parameters": {}},
    {"slug": "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", "tags": ["readOnlyHint"], "required": ["message_id"], "parameters": {}},
    {"slug": "GMAIL_FETCH_EMAILS", "tags": ["important", "openWorldHint", "readOnlyHint"], "required": [],
     "description": "Fetches a list of email messages from a gmail account",
     "parameters": {"query": {"type": "string", "description": "Gmail advanced search query"},
                    "max_results": {"type": "integer", "description": "Maximum number of messages"},
                    "include_payload": {"type": "boolean", "description": "full payload or metadata"},
                    "verbose": {"type": "boolean", "description": "optimized metadata fetching"}}},
]

GMAIL_PAYLOAD = {"data": {"results": [{"response": {"data": {"messages": [
    {"messageId": "18a1", "threadId": "t77", "messageTimestamp": "2026-09-24T19:00:00Z",
     "sender": "Acme Billing <billing@acme.example>", "subject": "Final notice",
     "messageText": "Full payment of $4,200 is due Friday."},
    {"messageId": "18a2", "threadId": "t77", "messageTimestamp": "2026-09-24T19:30:00Z",
     "sender": "Izzy <izzy@example.com>", "subject": "Re: Final notice",
     "messageText": "We received 250 of 700. I will pay half."},
    {"messageId": "18a3", "threadId": "t80", "messageTimestamp": "2026-09-24T19:40:00Z",
     "sender": "someone", "subject": "", "messageText": ""},
]}}}]}}

GITHUB_PAYLOAD = [
    {"id": "901", "updated_at": "2026-09-24T19:10:00Z",
     "subject": {"title": "Release blocked on signing", "url": "https://api.github.com/x/1"},
     "repository": {"full_name": "Izzy-Gottz/moe"}, "reason": "mention"},
]


CALENDAR_PAYLOAD = {"data": {"items": [
    {"id": "ev1", "summary": "Call with Acme about the balance", "created": "2026-09-23T10:00:00Z",
     "updated": "2026-09-24T18:00:00Z", "start": {"dateTime": "2026-09-30T15:00:00Z"},
     "organizer": {"email": "dana@acme.example"}},
]}}


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-composio-items-")
        os.environ["MOE_HOME"] = self.tmp
        self.m = load()

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_only_listers_that_only_read_are_offered(self):
        self.assertEqual([t["slug"] for t in self.m.read_tools(GMAIL_TOOLS)], ["GMAIL_FETCH_EMAILS"])

    def test_a_plan_is_held_to_the_reads_their_arguments_and_a_window(self):
        tools = self.m.read_tools(GMAIL_TOOLS)
        good = {"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_epoch}", "max_results": 25}}
        self.assertEqual(self.m.validate_plan(json.dumps(good), tools)[1], "planned")
        for bad, why in (({"tool": "GMAIL_SEND_EMAIL", "args": {"query": "{since_iso}"}}, "not a read"),
                         ({"tool": "GMAIL_FETCH_EMAILS", "args": {"to": "{since_iso}"}}, "does not take"),
                         ({"tool": "GMAIL_FETCH_EMAILS", "args": {"max_results": 25}}, "no time window")):
            plan, got = self.m.validate_plan(json.dumps(bad), tools)
            self.assertIsNone(plan)
            self.assertIn(why, got)

    def test_the_plan_is_made_once_and_cached(self):
        asked = []

        def call(messages):
            asked.append(messages)
            return json.dumps({"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_epoch}"}})
        p1 = self.m.ensure_plan("gmail", tools_fn=lambda s: GMAIL_TOOLS, call=call, now=1000)
        p2 = self.m.ensure_plan("gmail", tools_fn=lambda s: GMAIL_TOOLS, call=call, now=2000)
        self.assertEqual(p1["tool"], "GMAIL_FETCH_EMAILS")
        self.assertEqual(p2["tool"], "GMAIL_FETCH_EMAILS")
        self.assertEqual(len(asked), 1)
        self.assertTrue(os.path.exists(self.m.plan_path("gmail")))
        # The planner never sees a tool that writes.
        self.assertNotIn("GMAIL_SEND_EMAIL", asked[0][1]["content"])

    def test_a_plan_from_before_whole_bodies_is_made_again_once(self):
        """2026-09-25: the owner's Gmail plan read subject + preview only
        (include_payload false). A plan without the current version is
        replanned, asking for the whole text; the new one is then kept."""
        old = {"tool": "GMAIL_FETCH_EMAILS", "args": {"include_payload": False,
                                                      "query": "after:{since_slash_date}"}, "at": 500}
        os.makedirs(os.path.dirname(self.m.plan_path("gmail")), exist_ok=True)
        with open(self.m.plan_path("gmail"), "w") as f:
            json.dump(old, f)
        asked = []

        def call(messages):
            asked.append(messages)
            return json.dumps({"tool": "GMAIL_FETCH_EMAILS",
                               "args": {"include_payload": True, "query": "after:{since_slash_date}"}})
        p1 = self.m.ensure_plan("gmail", tools_fn=lambda s: GMAIL_TOOLS, call=call, now=1000)
        p2 = self.m.ensure_plan("gmail", tools_fn=lambda s: GMAIL_TOOLS, call=call, now=2000)
        self.assertEqual(len(asked), 1)
        self.assertTrue(p1["args"]["include_payload"])
        self.assertEqual(p2["v"], self.m.PLAN_VERSION)
        self.assertIn("WHOLE text", asked[0][0]["content"])

    def test_a_failed_replan_keeps_the_old_plan_working(self):
        old = {"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_slash_date}"}, "at": 500}
        os.makedirs(os.path.dirname(self.m.plan_path("gmail")), exist_ok=True)
        with open(self.m.plan_path("gmail"), "w") as f:
            json.dump(old, f)
        p = self.m.ensure_plan("gmail", tools_fn=lambda s: GMAIL_TOOLS, call=lambda m: "no idea", now=1000)
        self.assertEqual(p["tool"], "GMAIL_FETCH_EMAILS")
        p = self.m.ensure_plan("gmail", tools_fn=lambda s: None, call=lambda m: "", now=1000)
        self.assertEqual(p["tool"], "GMAIL_FETCH_EMAILS")

    def test_a_failed_replan_is_retried_later_not_every_tick(self):
        old = {"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_slash_date}"}, "at": 500}
        os.makedirs(os.path.dirname(self.m.plan_path("gmail")), exist_ok=True)
        with open(self.m.plan_path("gmail"), "w") as f:
            json.dump(old, f)
        fetched = []

        def tools(s):
            fetched.append(s)
            return None
        for t in (1000, 1300, 1600):
            self.assertEqual(self.m.ensure_plan("gmail", tools_fn=tools, call=lambda m: "", now=t)["tool"],
                             "GMAIL_FETCH_EMAILS")
        self.assertEqual(len(fetched), 1)
        self.m.ensure_plan("gmail", tools_fn=tools, call=lambda m: "", now=1000 + self.m.TRANSIENT_RETRY_S + 1)
        self.assertEqual(len(fetched), 2)

    def test_a_toolkit_with_nothing_to_watch_is_asked_again_a_week_later(self):
        n = []
        nothing = lambda messages: (n.append(1), '{"tool": null, "why": "no time filter"}')[1]
        self.m.ensure_plan("figma", tools_fn=lambda s: GMAIL_TOOLS, call=nothing, now=0)
        self.m.ensure_plan("figma", tools_fn=lambda s: GMAIL_TOOLS, call=nothing, now=3600)
        self.m.ensure_plan("figma", tools_fn=lambda s: GMAIL_TOOLS, call=nothing, now=8 * 86400)
        self.assertEqual(len(n), 2)


class CloudTest(unittest.TestCase):
    """One Moe in two places: the machine reads with the Mac's plan."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-composio-items-")
        os.environ["MOE_HOME"] = self.tmp
        self.m = load()

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        os.environ.pop("MOE_RUNS_IN", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_mac_plans_with_who_me_is_and_the_machine_never_plans(self):
        os.environ["MOE_RUNS_IN"] = "mac"
        call = lambda messages: json.dumps({"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_epoch}"}})
        plan = self.m.ensure_plan("gmail", tools_fn=lambda s: GMAIL_TOOLS, call=call, now=1000,
                                  owners_fn=lambda s: ["izzy@example.com"])
        self.assertEqual(plan["owner_ids"], ["izzy@example.com"])
        os.remove(self.m.plan_path("gmail"))
        os.environ["MOE_RUNS_IN"] = "cloud"
        asked = []
        plan = self.m.ensure_plan("gmail", tools_fn=lambda s: asked.append(s) or GMAIL_TOOLS,
                                  call=lambda m: asked.append(m) or "{}", now=2000)
        self.assertEqual((plan["tool"], asked), (None, []), "no plan on the machine until the Mac's arrives")

    def test_the_machine_knows_the_persons_own_mail_from_the_plan(self):
        os.environ["MOE_RUNS_IN"] = "cloud"
        plan = {"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_epoch}"},
                "owner_ids": ["izzy@example.com"]}
        found, _ = self.m.items("gmail", json.dumps({"t": 1790270000, "ids": []}),
                                reader=lambda r: GMAIL_PAYLOAD, plan_fn=lambda s: plan, now=1790280000)
        self.assertEqual([i["from"]["me"] for i in found], [False, True])


class ReadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-composio-items-")
        os.environ["MOE_HOME"] = self.tmp
        self.m = load()

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_window_fills_every_placeholder(self):
        since = 1790276400  # 2026-09-24T19:00:00Z
        self.assertEqual(self.m.fill({"q": "after:{since_epoch}", "n": "{since_epoch}", "d": "{since_date}",
                                      "s": "{since_slash_date}", "i": ["{since_iso}"]}, since),
                         {"q": "after:1790276400", "n": 1790276400, "d": "2026-09-24",
                          "s": "2026/09/24", "i": ["2026-09-24T19:00:00Z"]})

    def test_mail_is_read_by_shape(self):
        items = self.m.extract(GMAIL_PAYLOAD, owner_ids=["izzy@example.com"])
        self.assertEqual([i["id"] for i in items], ["18a1", "18a2"], "the empty record is not an item")
        self.assertEqual(items[0]["thread"], "t77")
        self.assertIn("Final notice", items[0]["text"])
        self.assertIn("$4,200", items[0]["text"])
        self.assertFalse(items[0]["from"]["me"])
        self.assertTrue(items[1]["from"]["me"], "the owner's own reply is known as theirs")
        self.assertEqual(items[0]["from"]["name"], "Acme Billing")

    def test_a_different_service_by_the_same_rule(self):
        (item,) = self.m.extract(GITHUB_PAYLOAD)
        self.assertEqual(item["id"], "901")
        self.assertIn("Release blocked on signing", item["text"])

    def test_an_event_is_new_when_it_changed_not_when_it_happens(self):
        (item,) = self.m.extract(CALENDAR_PAYLOAD)
        self.assertEqual(item["at"], 1790272800.0, "updated 2026-09-24T18:00Z, not the start on the 30th")
        self.assertIn("Call with Acme", item["text"])
        self.assertIn("dana@acme.example", item["from"]["id"])

    def test_first_look_then_only_new_then_nothing_twice(self):
        plan = lambda slug: {"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_epoch}"}}
        reads = []
        reader = lambda read: (reads.append(read), GMAIL_PAYLOAD)[1]
        found, c0 = self.m.items("gmail", "", reader=reader, plan_fn=plan, owners=[], now=1790276000)
        self.assertEqual((found, reads), ([], []), "a first look reads nothing")
        found, c1 = self.m.items("gmail", c0, reader=reader, plan_fn=plan, owners=[], now=1790280000)
        self.assertEqual([i["id"] for i in found], ["18a1", "18a2"])
        self.assertEqual(reads[0]["args"]["query"], "after:%d" % (1790276000 - self.m.OVERLAP_SECONDS))
        found, _ = self.m.items("gmail", c1, reader=reader, plan_fn=plan, owners=[], now=1790281000)
        self.assertEqual(found, [], "the overlap is not read twice")

    def test_an_unwatchable_toolkit_reads_nothing_and_keeps_up(self):
        reads = []
        found, cur = self.m.items("figma", json.dumps({"t": 100, "ids": []}),
                                  reader=lambda r: reads.append(r), plan_fn=lambda s: {"tool": None},
                                  owners=[], now=5000)
        self.assertEqual((found, reads), ([], []))
        self.assertEqual(json.loads(cur)["t"], 5000)

    def test_a_failed_read_raises_so_no_cursor_moves(self):
        def boom(read):
            raise RuntimeError("401")
        with self.assertRaises(RuntimeError):
            self.m.items("gmail", json.dumps({"t": 100, "ids": []}), reader=boom,
                         plan_fn=lambda s: {"tool": "GMAIL_FETCH_EMAILS", "args": {"q": "{since_epoch}"}},
                         owners=[])



class GeneralityTest(unittest.TestCase):
    """2026-09-25, on the owner's Mac: of five connected toolkits only two were
    watched. GitHub's notifications lister was hidden (tagged mcpIgnore), and
    once read, a notification took its repository's owner as its sender and
    the repository as its conversation."""

    def setUp(self):
        self.m = load()

    def test_mcp_ignore_tools_may_be_planned_and_news_listers_come_first(self):
        rows = [{"slug": "X_GET_A_BLOB", "tags": ["readOnlyHint"], "required": []}] * 70 + [
            {"slug": "X_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER",
             "tags": ["readOnlyHint", "mcpIgnore"], "required": []},
            {"slug": "X_DELETE_REPO", "tags": ["destructiveHint", "readOnlyHint"], "required": []}]
        tools = self.m.read_tools(rows)
        self.assertIn("X_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER", [t["slug"] for t in tools])
        self.assertNotIn("X_DELETE_REPO", [t["slug"] for t in tools])
        shown = self.m.plan_messages("x", tools)[1]["content"]
        self.assertIn("X_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER", shown)

    def test_a_notification_is_its_own_thread_from_no_one_and_to_the_person(self):
        payload = {"data": {"notifications": [
            {"id": "n1", "reason": "review_requested", "updated_at": "2026-09-25T10:00:00Z",
             "subject": {"title": "Review: fix the invoice total", "type": "PullRequest"},
             "repository": {"html_url": "https://example/acme/app", "owner": {"login": "izzy"}}},
            {"id": "n2", "reason": "mention", "updated_at": "2026-09-25T11:00:00Z",
             "subject": {"title": "Can you check the $1,200 refund?", "type": "Issue"},
             "repository": {"html_url": "https://example/acme/app", "owner": {"login": "izzy"}}}]}}
        items = self.m.extract(payload, ["izzy"], now=1_900_000_000, addressed=True)
        self.assertEqual([i["thread"] for i in items], ["n1", "n2"])
        self.assertEqual(items[1]["text"], "Can you check the $1,200 refund?")
        self.assertTrue(all(i["to_me"] and not i["from"]["me"] for i in items))

    def test_the_plan_carries_whether_every_result_is_addressed(self):
        tools = [{"slug": "X_LIST_INBOX", "parameters": {"since": {"type": "string"}}}]
        found, _ = self.m.validate_plan(json.dumps({"tool": "X_LIST_INBOX", "args": {"since": "{since_iso}"},
                                                    "addressed": True}), tools)
        self.assertTrue(found["addressed"])
        found, _ = self.m.validate_plan(json.dumps({"tool": "X_LIST_INBOX", "args": {"since": "{since_iso}"}}),
                                        tools)
        self.assertFalse(found["addressed"])

    def test_text_and_senders_inside_objects_are_read(self):
        """Second review: Notion's properties.Name.title[0].plain_text, an
        html-only body, and Outlook's from.emailAddress{name,address}."""
        payload = {"results": [
            {"id": "n1", "last_edited_time": "2026-09-25T10:00:00Z",
             "properties": {"Name": {"title": [{"plain_text": "Quarterly plan"}]}}},
            {"id": "o1", "receivedDateTime": "2026-09-25T10:00:00Z", "conversationId": "c1",
             "from": {"emailAddress": {"name": "Al", "address": "al@x.com"}},
             "body": {"contentType": "html", "html": "<p>Please send the <b>$300</b> today</p>"}}]}
        items = {i["id"]: i for i in self.m.extract(payload, ["al@x.com"], now=1_900_000_000)}
        self.assertEqual(items["n1"]["text"], "Quarterly plan")
        self.assertIn("Please send the  $300  today", items["o1"]["text"].replace("\n", " "))
        self.assertEqual(items["o1"]["from"]["id"], "Al <al@x.com>")
        self.assertTrue(items["o1"]["from"]["me"])

if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""lib/mcp_autoread.py — the auto-read gather engine — with Hermes stubbed.

Run: python3 moe-home/hermes-jobs/tests/test_mcp_autoread.py

Covers the safety-critical name classifier (MCP gives no reliable readOnlyHint,
so this is the only thing keeping gather off run_sql / rows / writes), the plan
validation (a model can never widen past what the classifier allowed), resolve
precedence (hand recipe > cached > fresh auto plan), crawl tolerance (a read
that fails is skipped, not fatal), the --since window (it reaches a read only
through a placeholder in its args, so an auto plan is the same read whatever
the number), and the gather distil profile (claims forced to identity). Plus
the seed-memory id-scrub backstop at the write point.
"""

import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
JOBS = os.path.normpath(os.path.join(HERE, ".."))
MOE_SRC = os.path.normpath(os.path.join(JOBS, ".."))
LIB_SRC = os.path.join(MOE_SRC, "lib")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


A = load(os.path.join(LIB_SRC, "mcp_autoread.py"), "moe_mcp_autoread")


class ClassifierTest(unittest.TestCase):
    """The linchpin: measured 2026-09-02, every Pulse/Supabase/Cloudflare tool
    sets readOnlyHint=False, so only these name rules keep gather safe."""

    def test_pulse_resolves_to_metadata_only(self):
        deny = ["run_sql", "fetch_result", "list_values", "search_messages",
                "search_files", "read_document", "person_card", "my_calendar",
                "define_metric", "request_data_access"]
        for t in deny:
            self.assertFalse(A.classify(t), "%s must be denied" % t)
        for t in ("find_definitions", "search_schema"):
            self.assertTrue(A.classify(t), "%s must be allowed" % t)

    def test_write_verbs_denied(self):
        for t in ("create_project", "delete_branch", "apply_migration",
                  "execute_sql", "deploy_edge_function", "post_accounts",
                  "put_zone", "patch_dns_record", "update_record",
                  "generate_typescript_types", "merge_branch", "reset_branch"):
            self.assertFalse(A.classify(t), "%s must be denied" % t)

    def test_content_and_secret_tokens_denied(self):
        for t in ("get_messages", "list_files", "read_email", "get_document",
                  "get_publishable_keys", "list_api_keys", "get_user",
                  "list_members", "get_invoice", "search_documents",
                  "get_transaction", "list_contacts", "query_logs"):
            self.assertFalse(A.classify(t), "%s must be denied" % t)

    def test_structure_reads_allowed(self):
        for t in ("get_accounts", "list_projects", "list_tables",
                  "list_extensions", "get_zones", "list_organizations",
                  "describe_table_schema", "get_advisors", "list_migrations",
                  "list_branches", "get_project_url"):
            self.assertTrue(A.classify(t), "%s must be allowed" % t)

    def test_default_deny(self):
        self.assertFalse(A.classify(""))
        self.assertFalse(A.classify("frobnicate"))     # no read verb
        self.assertFalse(A.classify("do_thing"))
        self.assertFalse(A.classify("run_report"))     # run is not a read verb

    def test_description_phrase_backstop(self):
        self.assertFalse(A.classify("get_thing", "Retrieves file contents for X"))
        self.assertFalse(A.classify("list_stuff", "Returns rows from the table"))
        self.assertTrue(A.classify("get_thing", "Lists the projects you own"))


def _tmp_home_with_prompt(prefix):
    tmp = tempfile.mkdtemp(prefix=prefix)
    os.makedirs(os.path.join(tmp, "prompts"))
    shutil.copy(os.path.join(MOE_SRC, "prompts", "learn-gather-plan.md"),
                os.path.join(tmp, "prompts", "learn-gather-plan.md"))
    return tmp


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = _tmp_home_with_prompt("moe-autoread-plan-")
        self._home = os.environ.get("MOE_HOME")
        os.environ["MOE_HOME"] = self.tmp

    def tearDown(self):
        if self._home is None:
            os.environ.pop("MOE_HOME", None)
        else:
            os.environ["MOE_HOME"] = self._home
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _plan(self, cands, proposed):
        def chat(system, user, key, enabled_toolsets=None):
            return json.dumps({"reads": proposed})
        return A.plan("svc", cands, chat=chat, extract=json.loads)

    def test_only_allowed_tools_survive(self):
        cands = [("list_projects", "p"), ("get_accounts", "a")]
        proposed = [{"tool": "list_projects", "args": {}},
                    {"tool": "run_sql", "args": {"q": "x"}},     # not a candidate
                    {"tool": "delete_project", "args": {}}]      # not a candidate
        reads = self._plan(cands, proposed)
        self.assertEqual([r["tool"] for r in reads], ["list_projects"])

    def test_hallucinated_tool_dropped(self):
        reads = self._plan([("list_projects", "p")], [{"tool": "made_up", "args": {}}])
        self.assertEqual(reads, [])

    def test_reads_cap(self):
        cands = [("list_%d" % i, "d") for i in range(20)]
        proposed = [{"tool": "list_%d" % i, "args": {}} for i in range(20)]
        self.assertLessEqual(len(self._plan(cands, proposed)), A.PLAN_READS_CAP)

    def test_empty_candidates_short_circuits(self):
        called = []
        A.plan("svc", [], chat=lambda *a, **k: called.append(1) or "{}", extract=json.loads)
        self.assertEqual(called, [])


class ResolveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = _tmp_home_with_prompt("moe-autoread-")
        os.environ["MOE_HOME"] = self.tmp
        os.environ["MOE_GATHER_DIR"] = os.path.join(self.tmp, "gather")
        os.makedirs(os.environ["MOE_GATHER_DIR"])

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        os.environ.pop("MOE_GATHER_DIR", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, name, obj):
        with open(os.path.join(os.environ["MOE_GATHER_DIR"], name), "w") as f:
            json.dump(obj, f)

    def test_hand_recipe_wins(self):
        self._write("svc.json", {"connector": "svc", "reads": [{"tool": "find_definitions", "args": {}}]})
        reads, how = A.resolve("svc")
        self.assertEqual(how, "recipe")
        self.assertEqual(reads[0]["tool"], "find_definitions")

    def test_cached_reused_without_replanning(self):
        self._write("svc.reads.json", {"reads": [{"tool": "list_projects", "args": {}}]})
        reads, how = A.resolve("svc", chat=lambda *a, **k: self.fail("should not replan"))
        self.assertEqual(how, "cached")
        self.assertEqual(reads[0]["tool"], "list_projects")

    def test_auto_plans_validates_and_caches(self):
        orig = A.candidates
        A.candidates = lambda c: [("list_projects", "p"), ("get_accounts", "a")]
        try:
            def chat(*a, **k):
                return json.dumps({"reads": [{"tool": "get_accounts", "args": {}},
                                             {"tool": "run_sql", "args": {}}]})
            reads, how = A.resolve("svc", chat=chat, extract=json.loads)
        finally:
            A.candidates = orig
        self.assertEqual(how, "auto")
        self.assertEqual([r["tool"] for r in reads], ["get_accounts"])   # run_sql dropped
        self.assertTrue(os.path.exists(os.path.join(os.environ["MOE_GATHER_DIR"], "svc.reads.json")))


class CrawlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-autoread-crawl-")
        os.environ["MOE_HOME"] = self.tmp
        os.environ["MOE_GATHER_DIR"] = os.path.join(self.tmp, "gather")
        os.makedirs(os.environ["MOE_GATHER_DIR"])
        with open(os.path.join(os.environ["MOE_GATHER_DIR"], "svc.reads.json"), "w") as f:
            json.dump({"reads": [{"tool": "good", "args": {}},
                                 {"tool": "bad", "args": {}},
                                 {"tool": "good2", "args": {}}]}, f)
        self._orig = A._mcp_read

    def tearDown(self):
        A._mcp_read = self._orig
        os.environ.pop("MOE_HOME", None)
        os.environ.pop("MOE_GATHER_DIR", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_failing_read_is_skipped_not_fatal(self):
        class FakeMR(object):
            def read_connector(self, conn, reads, maxc, hermes_pair=None, task=None):
                if reads[0]["tool"] == "bad":
                    raise RuntimeError("boom")
                return "## %s\n\nOK\n" % reads[0]["tool"]
        A._mcp_read = lambda: FakeMR()
        out = A.crawl("svc")
        self.assertIn("good", out)
        self.assertIn("good2", out)
        self.assertNotIn("boom", out)

    def test_a_crawl_where_every_read_failed_is_a_failure_not_nothing(self):
        # 2026-10-11/12: every read said "No module named 'ruamel'", the crawl
        # returned "" and learn.sh filed it as "nothing to read (exit 0)".
        class FakeMR(object):
            def read_connector(self, conn, reads, maxc, hermes_pair=None, task=None):
                raise ModuleNotFoundError("No module named 'ruamel'")
        A._mcp_read = lambda: FakeMR()
        with self.assertRaises(RuntimeError) as cm:
            A.crawl("svc")
        self.assertIn("all 3 read(s) failed", str(cm.exception))
        self.assertIn("ruamel", str(cm.exception))


class WindowTest(unittest.TestCase):
    """`--since N` reaches a read through its placeholders — and only
    through them: a read with none is the same read whatever N is."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-autoread-window-")
        os.environ["MOE_HOME"] = self.tmp
        os.environ["MOE_GATHER_DIR"] = os.path.join(self.tmp, "gather")
        os.environ["MOE_TODAY"] = "2026-09-02"
        os.makedirs(os.environ["MOE_GATHER_DIR"])
        self.calls = []
        self._orig = A._mcp_read
        tests = self

        class FakeMR(object):
            def read_connector(self, conn, reads, maxc, hermes_pair=None, task=None):
                tests.calls.append((reads[0]["tool"], reads[0].get("args")))
                return "## %s\n\nOK\n" % reads[0]["tool"]
        A._mcp_read = lambda: FakeMR()

    def tearDown(self):
        A._mcp_read = self._orig
        for k in ("MOE_HOME", "MOE_GATHER_DIR", "MOE_TODAY"):
            os.environ.pop(k, None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _recipe(self, reads, name="svc.json"):
        with open(os.path.join(os.environ["MOE_GATHER_DIR"], name), "w") as f:
            json.dump({"connector": "svc", "reads": reads}, f)

    def test_placeholders_get_the_days_and_the_date(self):
        self._recipe([{"tool": "search", "args": {"days": "{since_days}",
                                                 "q": "updated after {since_date}",
                                                 "nested": {"from": "{since_date}"},
                                                 "list": ["{since_days}", "x"]}}])
        A.crawl("svc", since_days=7)
        self.assertEqual(self.calls[0][1], {"days": 7,                       # typed: the int
                                            "q": "updated after 2026-08-27",  # spliced: 7 days ending today
                                            "nested": {"from": "2026-08-27"},
                                            "list": [7, "x"]})

    def test_since_1_is_today(self):
        self._recipe([{"tool": "search", "args": {"from": "{since_date}"}}])
        A.crawl("svc", since_days=1)
        self.assertEqual(self.calls[0][1], {"from": "2026-09-02"})

    def test_a_read_without_a_placeholder_is_the_same_whatever_since_says(self):
        self._recipe([{"tool": "find_definitions", "args": {"question": "revenue"}}])
        A.crawl("svc", since_days=1)
        A.crawl("svc", since_days=1095)
        A.crawl("svc")
        self.assertEqual([c[1] for c in self.calls], [{"question": "revenue"}] * 3)

    def test_an_auto_plan_is_untouched_by_since(self):
        # the cached auto plan: what auto-read wrote, no placeholder anywhere
        self._recipe([{"tool": "list_projects", "args": {"limit": 5}}], name="svc.reads.json")
        A.crawl("svc", since_days=3)
        self.assertEqual(self.calls, [("list_projects", {"limit": 5})])

    def test_no_since_leaves_a_placeholder_as_it_is(self):
        self._recipe([{"tool": "search", "args": {"days": "{since_days}"}}])
        A.crawl("svc")
        self.assertEqual(self.calls[0][1], {"days": "{since_days}"})

    def test_the_literal_cannot_be_escaped(self):
        # N12: documented, not fixed — a read that wants the literal text
        # gets the substitution like any other.
        self._recipe([{"tool": "search", "args": {"q": "the string {since_days} itself"}}])
        A.crawl("svc", since_days=2)
        self.assertEqual(self.calls[0][1], {"q": "the string 2 itself"})

    def test_bad_since_is_refused_not_read_whole(self):
        self._recipe([{"tool": "search", "args": {"days": "{since_days}"}}])
        for bad in (0, -3, "7", True):
            with self.assertRaises(ValueError):
                A.crawl("svc", since_days=bad)
        self.assertEqual(self.calls, [])
        self.assertEqual(A.parse_since(["--since", "12"]), 12)
        self.assertEqual(A.parse_since(["--since=3"]), 3)
        self.assertIsNone(A.parse_since([]))
        for argv in (["--since", "0"], ["--since", "x"], ["--since"]):
            with self.assertRaises(ValueError):
                A.parse_since(argv)
        self.assertEqual(A.main("svc", ["crawl", "--since", "0"]), 2)
        self.assertEqual(self.calls, [])

    def test_main_passes_since_through(self):
        self._recipe([{"tool": "search", "args": {"days": "{since_days}"}}])
        buf, old = io.StringIO(), sys.stdout
        sys.stdout = buf
        try:
            rc = A.main("svc", ["crawl", "--since", "4"])
        finally:
            sys.stdout = old
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls[0][1], {"days": 4})
        self.assertIn("## search", buf.getvalue())


class GatherDistilTest(unittest.TestCase):
    def setUp(self):
        self.distil = load(os.path.join(MOE_SRC, "learn", "distil.py"), "moe_distil_gather")

    def test_gather_profile_uses_gather_prompt(self):
        self.assertEqual(self.distil.PROFILE_PROMPTS["gather"], "learn-gather.md")

    def test_claims_forced_to_identity(self):
        reply = json.dumps({"claims": [
            {"key": "service:supabase",
             "text": "Runs a Supabase project called Nexertise on Postgres 17",
             "confidence": "high"}],
            "questions": []})
        claims, _ = self.distil.parse_reply(reply, "2026-09-02", force_file="identity")
        self.assertEqual(len(claims), 1)
        self.assertEqual(claims[0]["file"], "identity")


class ClaimDateTest(unittest.TestCase):
    """A claim is dated when it was observed — never in the future. Caught in a
    live run: Pulse's metric catalog says "valid until 2026-09-24", and every
    gathered claim came out dated ahead of today, which merge.py expire would
    never age out and which beats a genuinely newer claim on newer-wins."""

    def setUp(self):
        self.distil = load(os.path.join(MOE_SRC, "learn", "distil.py"), "moe_distil_dates")
        os.environ["MOE_TODAY"] = "2026-09-03"

    def tearDown(self):
        os.environ.pop("MOE_TODAY", None)

    def test_future_date_in_crawl_is_not_used(self):
        text = ("[2] total revenue — certified (external); proven 20 August; "
                "valid until 2026-09-24; v5\nseen 2026-08-30")
        self.assertEqual(self.distil.latest_date_in(text), "2026-08-30")

    def test_all_future_dates_fall_back_to_today(self):
        claims, _ = self.distil.parse_reply(
            json.dumps({"claims": [{"file": "identity", "key": "k",
                                    "text": "Pulse tracks certified metrics",
                                    "confidence": "high"}]}),
            self.distil.latest_date_in("valid until 2026-09-24") or self.distil.today())
        self.assertEqual(claims[0]["date"], "2026-09-03")

    def test_model_supplied_future_date_is_clamped(self):
        claims, _ = self.distil.parse_reply(
            json.dumps({"claims": [{"file": "identity", "key": "k", "date": "2026-09-08",
                                    "text": "Pulse integrates with Sage Intacct",
                                    "confidence": "med"}]}),
            "2026-09-01")
        self.assertEqual(claims[0]["date"], "2026-09-01")

    def test_a_normal_past_date_is_untouched(self):
        claims, _ = self.distil.parse_reply(
            json.dumps({"claims": [{"file": "people", "key": "person:dani", "date": "2026-08-12",
                                    "text": "**Dani** — sister", "confidence": "high"}]}),
            "2026-09-01")
        self.assertEqual(claims[0]["date"], "2026-08-12")


# ── Composio toolkits as gather sources ──────────────────────────────────
# The rows below are MEASURED, not invented: taken on 2026-09-20 from
# `GET /api/v3/tools?toolkit_slug=<slug>` with this Mac's project key, tags
# and required-argument lists verbatim. A closed loop of made-up constants
# agrees with itself, so the fixture is the artefact.
#
#   github  823 tools  411 readOnlyHint  670 mcpIgnore  →  3 candidates
#   gmail    23 tools   11 readOnlyHint    1 mcpIgnore  →  2 candidates
GITHUB_TOOLS = [
    {"slug": "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER",
     "description": "Lists repositories the authenticated user has access to.",
     "tags": ["openWorldHint", "readOnlyHint", "important"], "required": []},
    {"slug": "GITHUB_LIST_ORGANIZATIONS_FOR_THE_AUTHENTICATED_USER",
     "description": "Lists organizations for the authenticated user.",
     "tags": ["openWorldHint", "readOnlyHint", "important"], "required": []},
    {"slug": "GITHUB_LIST_REPOSITORIES_STARRED_BY_THE_AUTHENTICATED_USER",
     "description": "Lists repositories the authenticated user has starred.",
     "tags": ["readOnlyHint", "idempotentHint", "openWorldHint", "important"], "required": []},
    # readOnly, but hidden from the tool router: a read that cannot be
    # dispatched is not a read.
    {"slug": "GITHUB_CHECK_PRIVATE_VULNERABILITY_REPORTING_STATUS",
     "description": "Returns whether private vulnerability reporting is enabled.",
     "tags": ["readOnlyHint", "mcpIgnore"], "required": ["owner", "repo"]},
    # readOnly and visible, but needs an id nobody can guess.
    {"slug": "GITHUB_ACTIVITY_LIST_STARGAZERS_FOR_REPO",
     "description": "Lists the people who starred a repository.",
     "tags": ["readOnlyHint", "openWorldHint"], "required": ["owner", "repo"]},
    {"slug": "GITHUB_CREATE_AN_ISSUE", "description": "Creates an issue.",
     "tags": ["openWorldHint", "important"], "required": ["owner", "repo"]},
    {"slug": "GITHUB_DELETE_A_REPOSITORY", "description": "Deletes a repository.",
     "tags": ["destructiveHint", "openWorldHint"], "required": ["owner", "repo"]},
    {"slug": "GITHUB_ACCEPT_A_REPOSITORY_INVITATION",
     "description": "Accepts a pending repository invitation.",
     "tags": ["destructiveHint", "idempotentHint", "openWorldHint", "mcpIgnore"],
     "required": ["invitation_id"]},
]
GMAIL_TOOLS = [
    {"slug": "GMAIL_LIST_LABELS", "description": "Lists the labels in the mailbox.",
     "tags": ["readOnlyHint", "openWorldHint"], "required": []},
    {"slug": "GMAIL_LIST_DRAFTS", "description": "Lists the drafts in the mailbox.",
     "tags": ["important", "openWorldHint", "readOnlyHint"], "required": []},
    # All readOnly, all no-argument, and all of them the person's mail —
    # the content backstop, not the annotation, is what keeps these out.
    {"slug": "GMAIL_FETCH_EMAILS", "description": "Fetches a list of email messages.",
     "tags": ["important", "openWorldHint", "readOnlyHint"], "required": []},
    {"slug": "GMAIL_GET_CONTACTS", "description": "Fetches contacts.",
     "tags": ["openWorldHint", "readOnlyHint"], "required": []},
    {"slug": "GMAIL_GET_PEOPLE", "description": "Fetches people.",
     "tags": ["readOnlyHint", "openWorldHint"], "required": []},
    {"slug": "GMAIL_LIST_THREADS", "description": "Lists threads.",
     "tags": ["readOnlyHint", "openWorldHint"], "required": []},
    {"slug": "GMAIL_SEND_EMAIL", "description": "Sends an email.",
     "tags": ["important", "openWorldHint"], "required": ["recipient_email"]},
]


class ComposioSourceTest(unittest.TestCase):
    """Spelling, server and file stem for a brokered service."""

    def test_bare_name_is_still_an_mcp_server(self):
        self.assertEqual(A.split("notion"), ("mcp", "notion"))
        self.assertEqual(A.split("mcp/notion"), ("mcp", "notion"))
        self.assertEqual(A.split("hermes:mcp:notion"), ("mcp", "notion"))

    def test_composio_spelling(self):
        self.assertEqual(A.split("composio/github"), ("composio", "github"))
        self.assertEqual(A.split("hermes:composio:github"), ("composio", "github"))

    def test_a_bad_spelling_is_refused_not_guessed(self):
        for s in ("", "platform/telegram", "composio/", "composio/Bad Name",
                  "skill/notion", "composio/x/y"):
            self.assertRaises(ValueError, A.split, s)

    def test_every_toolkit_is_read_through_the_one_composio_server(self):
        self.assertEqual(A.server("composio/github"), "composio")
        self.assertEqual(A.server("composio/slack"), "composio")
        self.assertEqual(A.server("notion"), "notion")

    def test_stems_cannot_collide(self):
        """Composio's Notion and a dedicated Notion server are two sources."""
        self.assertNotEqual(A.stem("composio/notion"), A.stem("notion"))
        self.assertEqual(A.stem("composio/notion"), "composio-notion")
        self.assertEqual(A.stem("notion"), "notion")
        self.assertNotEqual(A.reads_path("composio/notion"), A.reads_path("notion"))


class ComposioClassifierTest(unittest.TestCase):
    """Composio's own annotations are the read/write signal; the content
    deny-list is still the backstop."""

    def _cands(self, rows):
        return [t["slug"] for t in rows
                if A.classify_composio(t["slug"], t["description"], t["tags"], t["required"])]

    def test_github_resolves_to_the_three_catalog_reads(self):
        self.assertEqual(self._cands(GITHUB_TOOLS), [
            "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER",
            "GITHUB_LIST_ORGANIZATIONS_FOR_THE_AUTHENTICATED_USER",
            "GITHUB_LIST_REPOSITORIES_STARRED_BY_THE_AUTHENTICATED_USER",
        ])

    def test_github_is_not_empty(self):
        """The whole point: an offer whose crawl returns nothing is worse
        than no offer. The MCP name classifier gives GitHub ZERO here,
        because every one of its catalog reads is spelled
        '…FOR_THE_AUTHENTICATED_USER' and 'user' is a content word."""
        self.assertTrue(self._cands(GITHUB_TOOLS))
        self.assertEqual([t["slug"] for t in GITHUB_TOOLS
                          if A.classify(A._unprefixed(t["slug"]), t["description"])], [])

    def test_gmail_keeps_structure_and_drops_the_mail(self):
        self.assertEqual(self._cands(GMAIL_TOOLS), ["GMAIL_LIST_LABELS", "GMAIL_LIST_DRAFTS"])

    def test_writes_are_denied_however_they_are_tagged(self):
        for t in GITHUB_TOOLS + GMAIL_TOOLS:
            if "readOnlyHint" not in t["tags"]:
                self.assertFalse(A.classify_composio(t["slug"], t["description"],
                                                     t["tags"], t["required"]),
                                 "%s must be denied" % t["slug"])

    def test_no_annotation_at_all_is_denied(self):
        self.assertFalse(A.classify_composio("ACME_LIST_PROJECTS", "Lists projects", [], []))

    def test_mcpignore_and_required_args_are_each_enough_to_deny(self):
        self.assertFalse(A.classify_composio("ACME_LIST_PROJECTS", "Lists projects",
                                             ["readOnlyHint", "mcpIgnore"], []))
        self.assertFalse(A.classify_composio("ACME_LIST_PROJECTS", "Lists projects",
                                             ["readOnlyHint"], ["project_id"]))
        self.assertTrue(A.classify_composio("ACME_LIST_PROJECTS", "Lists projects",
                                            ["readOnlyHint"], []))

    def test_the_toolkit_prefix_is_not_read_as_content(self):
        """A toolkit called `contacts` must not deny every tool it has."""
        self.assertTrue(A.classify_composio("CONTACTS_LIST_GROUPS", "Lists groups",
                                            ["readOnlyHint"], []))
        self.assertFalse(A.classify_composio("CONTACTS_LIST_CONTACTS", "Lists contacts",
                                             ["readOnlyHint"], []))

    def test_description_backstop_still_applies(self):
        self.assertFalse(A.classify_composio("ACME_LIST_THINGS",
                                             "Returns rows from the ledger.",
                                             ["readOnlyHint"], []))


class ComposioDiscoveryTest(unittest.TestCase):
    """Where a toolkit's tools come from, and that it is not a live call
    per run."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-autoread-composio-")
        os.environ["MOE_HOME"] = self.tmp
        os.environ["MOE_GATHER_DIR"] = os.path.join(self.tmp, "gather")
        os.environ["MOE_TODAY"] = "2026-09-20"
        os.makedirs(os.environ["MOE_GATHER_DIR"])
        self.fetches = []
        self._orig = A._fetch_composio_tools
        A._fetch_composio_tools = self._fetch

    def _fetch(self, slug):
        self.fetches.append(slug)
        return GITHUB_TOOLS if slug == "github" else GMAIL_TOOLS

    def tearDown(self):
        A._fetch_composio_tools = self._orig
        for k in ("MOE_HOME", "MOE_GATHER_DIR", "MOE_TODAY"):
            os.environ.pop(k, None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_schema_cache_is_not_where_a_toolkit_lives(self):
        """Measured: ~/.hermes/cache holds ONE server, `composio`, with
        twelve tools — none of them GitHub's 823. A prefix filter over it
        would find nothing, which is why the catalog route exists."""
        os.environ["HERMES_HOME"] = self.tmp
        os.makedirs(os.path.join(self.tmp, "cache"), exist_ok=True)
        with open(os.path.join(self.tmp, "cache", "mcp_schema_cache.json"), "w") as f:
            json.dump({"composio": {"tools": [
                {"name": "COMPOSIO_SEARCH_TOOLS", "description": "Find tools"},
                {"name": "GMAIL_FETCH_EMAILS", "description": "Fetch mail"}]}}, f)
        try:
            self.assertEqual(A._cache_tools("github"), [])
        finally:
            os.environ.pop("HERMES_HOME", None)

    def test_candidates_come_from_the_catalog(self):
        self.assertEqual([n for n, _ in A.candidates("composio/github")], [
            "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER",
            "GITHUB_LIST_ORGANIZATIONS_FOR_THE_AUTHENTICATED_USER",
            "GITHUB_LIST_REPOSITORIES_STARRED_BY_THE_AUTHENTICATED_USER",
        ])
        self.assertEqual(self.fetches, ["github"])

    def test_the_tool_list_is_cached_not_refetched(self):
        A.candidates("composio/github")
        A.candidates("composio/github")
        A.candidates("composio/github")
        self.assertEqual(self.fetches, ["github"])
        self.assertTrue(os.path.exists(A.tools_cache_path("github")))

    def test_a_failed_fetch_falls_back_to_what_is_cached(self):
        A.candidates("composio/github")
        A._fetch_composio_tools = lambda slug: None
        os.environ["MOE_TODAY"] = "2027-01-01"          # the cache is stale now
        self.assertTrue(A.candidates("composio/github"))

    def test_the_model_can_never_widen_past_the_composio_classifier(self):
        proposed = [{"tool": "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER", "args": {}},
                    {"tool": "GITHUB_DELETE_A_REPOSITORY", "args": {}},
                    {"tool": "GITHUB_ACTIVITY_LIST_STARGAZERS_FOR_REPO", "args": {}}]
        os.makedirs(os.path.join(self.tmp, "prompts"), exist_ok=True)
        shutil.copy(os.path.join(MOE_SRC, "prompts", "learn-gather-plan.md"),
                    os.path.join(self.tmp, "prompts", "learn-gather-plan.md"))
        reads = A.plan("composio/github", A.candidates("composio/github"),
                       chat=lambda *a, **k: json.dumps({"reads": proposed}),
                       extract=json.loads)
        self.assertEqual([r["tool"] for r in reads],
                         ["GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER"])

    def _plan_once(self, tool):
        os.makedirs(os.path.join(self.tmp, "prompts"), exist_ok=True)
        shutil.copy(os.path.join(MOE_SRC, "prompts", "learn-gather-plan.md"),
                    os.path.join(self.tmp, "prompts", "learn-gather-plan.md"))
        return A.resolve("composio/github",
                         chat=lambda *a, **k: json.dumps({"reads": [{"tool": tool, "args": {}}]}),
                         extract=json.loads)

    def test_the_saved_read_set_names_the_kind_and_the_server(self):
        self._plan_once("GITHUB_LIST_ORGANIZATIONS_FOR_THE_AUTHENTICATED_USER")
        with open(A.reads_path("composio/github")) as f:
            saved = json.load(f)
        self.assertEqual(saved["kind"], "composio")
        self.assertEqual(saved["server"], "composio")
        self.assertEqual(saved["connector"], "github")

    def test_a_toolkit_tool_is_dispatched_through_the_multiplexer(self):
        """MEASURED 2026-09-20 on this Mac's live Composio session: calling
        GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER by name is
        refused — "MCP error -32602: Tool GITHUB_… not found", because the
        session lists twelve tools and none of them is GitHub's. The same
        call through COMPOSIO_MULTI_EXECUTE_TOOL returned the owner's real
        repositories. Everything upstream of this — the offer, the row, the
        profile, the candidate set — is well-formed either way, so without
        this the whole feature is an offer that leads to an empty crawl."""
        r = A.dispatch("composio/github",
                       {"tool": "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER", "args": {}})
        self.assertEqual(r["tool"], "COMPOSIO_MULTI_EXECUTE_TOOL")
        self.assertEqual(r["args"], {"tools": [
            {"tool_slug": "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER",
             "arguments": {}}]})
        # The heading still says what was read, not what carried it.
        self.assertEqual(r["label"], "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER")
        # An MCP server of its own takes its tool by name, untouched.
        plain = {"tool": "list_projects", "args": {"limit": 5}}
        self.assertIs(A.dispatch("pulse", plain), plain)

    def test_the_crawl_calls_the_composio_server_through_the_multiplexer(self):
        calls = []

        class FakeMR(object):
            def read_connector(self, conn, reads, maxc, hermes_pair=None, task=None):
                calls.append((conn, reads[0]["tool"],
                              reads[0].get("args", {}).get("tools", [{}])[0].get("tool_slug")))
                return "## %s\n\nOK\n" % reads[0].get("label", reads[0]["tool"])
        self._plan_once("GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER")
        orig, A._mcp_read = A._mcp_read, lambda: FakeMR()
        try:
            out = A.crawl("composio/github")
        finally:
            A._mcp_read = orig
        self.assertEqual(calls, [("composio", "COMPOSIO_MULTI_EXECUTE_TOOL",
                                  "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER")])
        self.assertIn("OK", out)
        self.assertIn("GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER", out)


class SeedMemoryScrubTest(unittest.TestCase):
    """The write point: seed-memory id-scrubs every claim before Hermes sees it."""

    def test_scrub_ids_applied_at_the_door(self):
        sm = load(os.path.join(MOE_SRC, "learn", "seed-memory.py"), "moe_seed_memory")
        claims = sm.claims_from_digest({"source": "pulse", "claims": [
            {"file": "identity", "text": "note SSN: 123-45-6789 and MRN 00123 here",
             "confidence": "high"}]})
        self.assertNotIn("123-45-6789", claims[0]["text"])
        self.assertNotIn("00123", claims[0]["text"])


if __name__ == "__main__":
    unittest.main()

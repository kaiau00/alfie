"""Detached connectors: registered, callable, and queued (LEDGER-WIRE §14).

Slice 2½ dropped `runs_in=mac` connectors off the machine's catalogue, so the
model there could not see that the person had Notes. Slice 3 keeps them, and
calling one appends an `intent` record the Mac carries out.

What has to be right, and is checked here:

* a detached connector is REGISTERED on the machine, and its `check_fn` does
  not hide it again for the script it has no business having;
* calling it writes exactly ONE sealed `intent` — §14.2's clear fields
  `via` / `target` / `action`, and nothing the person wrote outside the seal;
* it returns the §14.5 deferred shape, never an error and never the away
  machine's "not connected" sentence;
* what the Mac published it can do (§14.4a) decides which of the three states
  a hand is in, and ONLY an explicit `needs-setup` or `absent` for that exact
  target and action withholds one: `ok` queues and says so; a document that is
  missing, unopenable, silent about this target or this action, or older than
  seven days all queue while saying they cannot see;
* `send` and `voice` stay withheld and are never queued (§14.4 rule 5);
* a `both` connector still runs its subprocess, and a Mac is untouched;
* and when the queue cannot be reached, it says so and writes nothing.

Nothing here sends anything, runs a real connector, or touches the person's
`~/.moe`, `~/.hermes` or ledger: `MOE_HOME` and `HERMES_HOME` are temp
directories for the length of each test, and the connectors are shell scripts
that echo.
"""

import importlib.util
import json
import os
import shutil
import tempfile
import time
import unittest

_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "moe_connectors_detached_under_test", os.path.join(_PKG, "__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plugin)

# The ledger library, found the way the plugin finds it and nowhere else: the
# plugin's own `_sibling` is what puts `moe-ledger` on sys.path. Asking for it
# once here is both how these tests get their imports and the check that the
# sibling trick works from this directory at all.
assert plugin._moeledger() is not None, "the moe-ledger plugin is not beside this one"

from moeledger import documents, intents, threadcrypto          # noqa: E402
from moeledger.records import (KIND_DOCUMENT, MEMORY_KEY_ID,        # noqa: E402
                               format_timestamp, ordered)
from moeledger.sync import LocalLedger           # noqa: E402
from moeledger.vault import Vault                # noqa: E402

OK = "#!/bin/sh\necho \"ok: two notes\"\n"
ECHOES = "#!/bin/sh\nverb=$1; shift\nIFS=,\necho \"verb=$verb args=$* stdin=$(cat)\"\n"

SESSION = "telegram:42"
THREAD = "9C1A0000-0000-4000-8000-00000000ABCD"

# The shipped catalogue in miniature: the four that run anywhere and three
# that only a Mac can run.
CATALOGUE = [
    ("gmail", "status pull", OK, "runs_in=both\n"),
    ("notes", "status pull create", OK,
     "runs_in=mac\ncreate_stdin=title* body\n"),
    ("calendar", "status pull crawl", OK, "runs_in=mac\ncost=expensive\n"),
    ("whatsapp", "status pull send voice", OK,
     "runs_in=mac\nsend_args=to* text*\nvoice_args=count\n"),
]


class Machine:
    """A machine (or a Mac) with connectors, a vault, and no real homes.

    Everything the plugin can read is inside two temp directories: `MOE_HOME`
    for the connectors, `HERMES_HOME` for the ledger vault the queue writes
    to. `session` and `thread` build exactly the state `moe-ledger` would have
    left behind — a session filed under its gateway key, naming a thread whose
    key is in the keyring — and nothing else.
    """

    def __init__(self, catalogue=CATALOGUE, runs_in="cloud", *, vault=True,
                 identity=True, thread=THREAD, key=True, session=SESSION):
        self.catalogue = catalogue
        self.runs_in = runs_in
        self.want_vault = vault
        self.want_identity = identity
        self.thread = thread
        self.want_key = key
        self.session = session
        self.key = None

    def __enter__(self):
        self.dir = tempfile.mkdtemp()
        self.moe_home = os.path.join(self.dir, "moe")
        self.hermes_home = os.path.join(self.dir, "hermes")
        conn = os.path.join(self.moe_home, "connectors")
        os.makedirs(conn)
        os.makedirs(self.hermes_home)
        for name, verbs, body, extra in self.catalogue:
            with open(os.path.join(conn, name + ".manifest"), "w") as handle:
                handle.write("name=%s\nlabel=%s\nverbs=%s\n%s"
                             % (name, name.title(), verbs, extra))
            if body is not None:
                path = os.path.join(conn, name + ".sh")
                with open(path, "w") as handle:
                    handle.write(body)
                os.chmod(path, 0o755)

        self.previous = {k: os.environ.get(k) for k in
                         ("MOE_HOME", "MOE_RUNS_IN", "HERMES_HOME", "HERMES_SESSION_KEY",
                          "HERMES_SESSION_ID")}
        os.environ["MOE_HOME"] = self.moe_home
        os.environ["HERMES_HOME"] = self.hermes_home
        os.environ.pop("HERMES_SESSION_ID", None)
        if self.runs_in is None:
            os.environ.pop("MOE_RUNS_IN", None)
        else:
            os.environ["MOE_RUNS_IN"] = self.runs_in
        if self.session:
            os.environ["HERMES_SESSION_KEY"] = self.session
        else:
            os.environ.pop("HERMES_SESSION_KEY", None)

        if self.want_vault:
            self.vault = Vault(os.path.join(self.hermes_home, "moe"))
            if self.want_identity:
                self.vault.identity(create=True, prefix="hermes")
            if self.thread:
                if self.want_key:
                    self.key = self.vault.mint_key(self.thread)
                self.vault.save_session(self.session or "unnamed",
                                        {"thread": self.thread, "shown": []})
        return self

    def __exit__(self, *exc):
        for name, value in self.previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        shutil.rmtree(self.dir, ignore_errors=True)

    # -- what the tests ask it ------------------------------------------------

    def tools(self):
        ctx = FakeContext()
        plugin.register(ctx)
        return ctx.tools

    def call(self, tool, **kwargs):
        return json.loads(self.tools()[tool]["handler"](kwargs))

    def records(self):
        return ordered(Vault(os.path.join(self.hermes_home, "moe")).read_ledger())

    def intents(self):
        return [r for r in self.records() if r.kind == intents.KIND_INTENT]

    # -- what the Mac would have published (§14.4a) ---------------------------

    def publish_capability(self, table, via="connector", seal_under=None,
                           text=None, days_ago=None):
        """Append the `capability/<via>` document the Mac's side writes.

        A `document` (§13.5) sealed under `moe:memory`, whose plaintext is
        §14.4a's `{"<target>": {"<action>": "ok"|"needs-setup"|"absent",
        "why": "…"}}`. `seal_under` seals it with some other key, which is how
        a document this machine cannot open is made; `text` puts arbitrary
        bytes inside the seal; `days_ago` dates the RECORD, which is what
        §14.4a's seven-day window is measured from.

        This plugin only ever READS these — writing one is the draining side's
        half of §14.4a — so the test writes it in the Mac's place.
        """
        vault = Vault(os.path.join(self.hermes_home, "moe"))
        memory = vault.key(MEMORY_KEY_ID) or vault.mint_key(MEMORY_KEY_ID)
        plain = text if text is not None else json.dumps(table)
        body = documents.document_body("capability/%s" % via, plain,
                                       seal_under or memory)
        identity = vault.identity(create=False)
        at = None if days_ago is None else format_timestamp(
            time.time() - days_ago * 24 * 3600)
        LocalLedger(vault, identity.device_id).append(KIND_DOCUMENT, body, at=at)
        return body


class FakeContext:
    def __init__(self):
        self.tools = {}

    def register_hook(self, name, callback):
        # The away send gate (moe-connectors registers it where MOE_RUNS_IN=cloud).
        self.__dict__.setdefault("hooks", []).append((name, callback))

    def register_tool(self, name, toolset, schema, handler, check_fn=None,
                      description="", emoji="", **kwargs):
        assert name not in self.tools, "registered %s twice" % name
        self.tools[name] = {"toolset": toolset, "schema": schema, "handler": handler,
                            "check_fn": check_fn, "description": description,
                            "emoji": emoji}


# ---------------------------------------------------------------------------

class RegisteredButDetached(unittest.TestCase):
    def test_a_mac_only_connector_is_a_tool_on_the_machine(self):
        with Machine() as m:
            tools = m.tools()
        self.assertIn("notes_pull", tools)
        self.assertIn("calendar_crawl", tools)

    def test_its_check_does_not_hide_it_for_the_script_it_does_not_have(self):
        """The fourth of CLOUD-PLAN §13's five changes. A detached
        connector's script is on the Mac by definition, so a check_fn that
        looked for it would undo the other four."""
        with Machine([("notes", "status pull", None, "runs_in=mac\n")]) as m:
            tools = m.tools()
            # Inside the temp home, where the script genuinely is not — a
            # check evaluated outside it would consult the real ~/.moe.
            self.assertIsNone(plugin.connector_script("notes"))
            self.assertTrue(tools["notes_pull"]["check_fn"]())

    def test_an_attached_connector_with_no_script_is_still_hidden(self):
        """The old rule survives where it still applies: a `both` connector
        whose script is missing here is broken, not detached."""
        with Machine([("gmail", "status pull", None, "runs_in=both\n")]) as m:
            tools = m.tools()
            self.assertFalse(tools["gmail_pull"]["check_fn"]())

    def test_the_description_names_the_hand(self):
        with Machine() as m:
            tools = m.tools()
        self.assertIn("your Mac", tools["notes_pull"]["description"])
        self.assertIn("queues", tools["notes_pull"]["description"])
        # Not a capability recitation, and not on the tools that run here.
        self.assertNotIn("your Mac", tools["gmail_pull"]["description"])

    def test_remind_me_on_the_machine_points_at_the_cronjob_tool(self):
        """2026-09-25: "remind me tomorrow morning" said to the machine with
        the Mac shut went to `reminders_create` — an Apple Reminder queued
        for a Mac that was off — because nothing in its description said a
        reminder at a time is a cronjob. Detached, it says so; on the Mac,
        where Apple Reminders is right there, it does not."""
        cat = CATALOGUE + [("reminders", "status pull create", OK,
                            "runs_in=mac\ncreate_stdin=title* notes due list\n")]
        with Machine(cat) as m:
            text = m.tools()["reminders_create"]["description"]
        self.assertIn("cronjob tool", text)
        self.assertIn("remind me", text)
        with Machine(cat, runs_in="mac") as m:
            here = m.tools().get("reminders_create", {}).get("description", "")
        self.assertNotIn("cronjob", here)
        # And only there: no other detached tool grows the clause.
        with Machine(cat) as m:
            self.assertNotIn("cronjob", m.tools()["notes_create"]["description"])

    def test_a_runtime_nothing_drains_is_not_offered_and_says_so(self):
        """Deferring to a place with no drain is queueing into a silence.
        `mac` is the only runtime a machine writes (§14.2), so anything else
        is dropped — loudly, in the log, never quietly."""
        catalogue = [("solaris", "status pull", OK, "runs_in=solaris\n")]
        with Machine(catalogue) as m:
            with self.assertLogs("moe-connectors", level="WARNING") as log:
                tools = m.tools()
        self.assertEqual(set(tools) - plugin.NOT_CONNECTOR_TOOLS, set())
        self.assertTrue(any("nothing drains" in line for line in log.output), log.output)

    def test_the_asked_sentence_is_published_only_where_it_is_read(self):
        with Machine() as m:
            tools = m.tools()
        detached = tools["notes_pull"]["schema"]["parameters"]["properties"]
        self.assertIn("asked", detached)
        self.assertNotIn("asked", tools["gmail_pull"]["schema"]["parameters"]["properties"])
        self.assertNotIn("asked", tools["notes_pull"]["schema"]["parameters"]["required"])


class CallingOneQueuesIt(unittest.TestCase):
    def test_exactly_one_sealed_intent_with_the_right_clear_fields(self):
        """§14.2's identity of the work is `via` / `target` / `action`, not a
        connector and a verb: what is queued is "work this runtime cannot do,
        carried out by one that can", and the connector is one executor of
        it. A record naming `connector`/`verb` is the older shape and no Mac
        drain matches on it."""
        with Machine() as m:
            out = m.call("notes_pull")
            records = m.intents()
        self.assertEqual(len(records), 1, records)
        body = records[0].body
        self.assertEqual(body["thread"], THREAD)
        self.assertEqual(body["runtime"], "mac")
        self.assertEqual(body["via"], "connector")
        self.assertEqual(body["target"], "notes")
        self.assertEqual(body["action"], "pull")
        self.assertNotIn("connector", body)
        self.assertNotIn("verb", body)
        self.assertEqual(body["enc"], threadcrypto.SCHEME)
        self.assertIn("expires", body)
        self.assertNotIn("text", body)
        self.assertFalse(records[0].is_plaintext)
        self.assertEqual(out["intent"], records[0].id)
        self.assertTrue(records[0].is_content_addressed)

    def test_the_deferred_shape_is_the_one_14_5_names(self):
        with Machine() as m:
            out = m.call("notes_pull")
        self.assertTrue(out["success"])
        self.assertTrue(out["deferred"])
        self.assertTrue(out["intent"])
        sentence = out["result"]
        # One sentence that names the hand and offers the two real options.
        self.assertIn("Mac", sentence)
        self.assertIn("queued", sentence)
        self.assertIn("already know", sentence)
        self.assertNotIn("not connected", sentence)

    def test_the_payload_opens_under_the_thread_key_and_not_without_it(self):
        with Machine() as m:
            m.call("calendar_crawl", days=3, asked="what's on this week")
            record = m.intents()[0]
            key = m.key
        self.assertIsNone(threadcrypto.open_sealed(record.body["text_enc"],
                                                   threadcrypto.mint_key()))
        parsed = intents.parse_intent(record, key)
        self.assertEqual(parsed.args, ["--since", "3"])
        self.assertEqual(parsed.asked, "what's on this week")
        # And nothing the person wrote is outside the seal.
        self.assertNotIn("this week", json.dumps(record.body))

    def test_a_stdin_verb_carries_its_stdin_inside_the_seal(self):
        with Machine() as m:
            m.call("notes_create", title="Shopping", body="milk\nbread")
            record = m.intents()[0]
            parsed = intents.parse_intent(record, m.key)
        self.assertEqual(parsed.action, "create")
        self.assertEqual(parsed.target, "notes")
        self.assertEqual(parsed.via, "connector")
        self.assertEqual(json.loads(parsed.stdin),
                         {"title": "Shopping", "body": "milk\nbread"})
        self.assertNotIn("milk", json.dumps(record.body))

    def test_a_missing_required_field_is_answered_here_and_queues_nothing(self):
        with Machine() as m:
            out = m.call("notes_create", body="no title")
            self.assertEqual(m.intents(), [])
        self.assertFalse(out["success"])
        self.assertIn("title", out["error"])

    def test_two_calls_are_two_intents_on_one_chain(self):
        with Machine() as m:
            first = m.call("notes_pull")
            second = m.call("calendar_pull")
            records = m.intents()
        self.assertEqual([r.id for r in records], [first["intent"], second["intent"]])
        self.assertEqual([r.seq for r in records], [1, 2])
        self.assertEqual(records[1].prev, records[0].id)

    def test_the_derived_status_sees_it_as_live_work_for_the_mac(self):
        with Machine() as m:
            m.call("notes_pull")
            out = intents.pending(m.records(), runtime="mac", keys=lambda t: m.key)
        self.assertEqual(len(out.live), 1)
        self.assertEqual(out.kinds, ["notes pull"])

    def test_the_machine_never_drains_what_it_queued(self):
        with Machine() as m:
            m.call("notes_pull")
            out = intents.pending(m.records(), runtime="cloud", keys=lambda t: m.key)
        self.assertEqual(out.live, [])


class EverySentenceOnThisPath(unittest.TestCase):
    """§14.5 and ONE-AGENT §4.4 over the whole set, not one at a time.

    Three rules, and every string the model can emit from here is held to all
    three: never claim something this machine does not know (the Mac's
    liveness above all — "if the Mac's liveness is unknown, say unknown"),
    never promise a queue for a hand that is absent, and never recite
    capabilities.
    """

    DEFERRING = ("DEFERRED_SENTENCE", "DEFERRED_UNSEEN_SENTENCE")
    ABSENT = ("NOT_SET_UP", "NOT_THERE")

    def sentences(self, names):
        return [(n, getattr(plugin, n)) for n in names]

    def test_none_of_them_says_the_mac_is_asleep(self):
        """This gateway has no liveness probe for the other device. "which is
        asleep" was a fact it did not have — and it read as an excuse for a
        delay that might not be one."""
        for name, text in self.sentences(self.DEFERRING + self.ABSENT
                                         + ("DETACHED_NOTE", "DETACHED_SEND_NOTE",
                                            "CANNOT_QUEUE", "NO_LIVE_MAC_SEND")):
            with self.subTest(name):
                self.assertNotIn("asleep", text)
                self.assertNotIn("wakes", text)

    def test_a_detached_send_never_says_it_queues(self):
        """gmail_send is the first shipped detached send. Its description is
        what the model reads when choosing, and a send is never queued."""
        self.assertNotIn("queues", plugin.DETACHED_SEND_NOTE)
        self.assertIn("never queued", plugin.DETACHED_SEND_NOTE)
        self.assertNotIn("I've queued", plugin.NO_LIVE_MAC_SEND)

    def test_an_absent_hand_offers_no_queue(self):
        for name, text in self.sentences(self.ABSENT):
            with self.subTest(name):
                self.assertNotIn("I've queued", text)
                self.assertNotIn("I'll tell you", text)
                self.assertNotIn("when your Mac", text)

    def test_a_deferral_offers_the_two_real_options(self):
        for name, text in self.sentences(self.DEFERRING):
            with self.subTest(name):
                self.assertIn("queued", text)
                self.assertIn("already know", text)
                # Not a capability recitation, not an apology.
                self.assertNotIn("sorry", text.lower())
                self.assertNotIn("cannot do", text)

    def test_only_the_one_with_no_evidence_hedges(self):
        self.assertIn("can't see", plugin.DEFERRED_UNSEEN_SENTENCE)
        self.assertNotIn("can't see", plugin.DEFERRED_SENTENCE)


class WhatTheMacSaysItCanDo(unittest.TestCase):
    """§14.4a. `$MOE_HOME` on the machine is a picture of the shipped
    catalogue, not of the person's Mac, so a `check_fn` of `lambda: True`
    offered `chrome_pull` to somebody who never turned Chrome on and said
    "I've queued it" — §4.4's lie with a delay on it, arriving five minutes
    later. The Mac publishes what it can actually do as a `document`; this
    reads it, and never writes one.
    """

    def setUp(self):
        # The derived view is module state keyed by vault root; a fresh temp
        # root invalidates it anyway, and this makes that explicit.
        plugin.forget_ledger()

    # -- ok: callable, queued, and said without a hedge -----------------------

    def test_ok_is_offered_and_queued(self):
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "ok", "create": "ok"}})
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
            queued = m.intents()
        self.assertTrue(out["deferred"])
        self.assertEqual(len(queued), 1)
        self.assertEqual(out["result"], plugin.DEFERRED_SENTENCE % "Notes")
        # It promises, because the Mac said it could.
        self.assertNotIn("can't see", out["result"])

    # -- needs-setup and absent: withheld, and NOTHING queued -----------------

    def test_needs_setup_is_withheld_and_queues_nothing(self):
        with Machine() as m:
            m.publish_capability(
                {"notes": {"pull": "needs-setup",
                           "why": "Moe has no access to Notes on this Mac"}})
            tools = m.tools()
            self.assertFalse(tools["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
            self.assertEqual(m.intents(), [])
        self.assertFalse(out["success"])
        self.assertTrue(out["absent"])
        self.assertNotIn("deferred", out)
        self.assertNotIn("intent", out)
        # Names the hand, gives the Mac's own reason, offers no queue.
        self.assertIn("Notes", out["error"])
        self.assertIn("no access to Notes", out["error"])
        self.assertIn("would only fail there", out["error"])
        self.assertIn("already know", out["error"])
        self.assertNotIn("I've queued", out["error"])
        self.assertNotIn("when your Mac", out["error"])

    def test_absent_says_it_cannot_and_does_not_send_them_to_settings(self):
        """`needs-setup` is something the person can fix and `absent` is not,
        so the sentence differs: telling somebody to go and set up a thing
        their Mac has not got is its own small dishonesty."""
        with Machine() as m:
            m.publish_capability({"calendar": {"pull": "absent", "why": "no Calendar app"}})
            out = m.call("calendar_pull")
            self.assertEqual(m.intents(), [])
        self.assertTrue(out["absent"])
        self.assertIn("can't get at your Calendar", out["error"])
        self.assertIn("no Calendar app", out["error"])
        self.assertNotIn("Set it up", out["error"])

    def test_a_target_the_document_never_mentions_is_unseen_not_absent(self):
        """§14.4a: an omission is *silence about that one thing*, and rule 8's
        "missing is not gone" binds a reader exactly as it binds the drain.
        A Mac running an older build publishes a document that predates a
        newly shipped connector; reading that as a denial would withdraw a
        hand the person has just been given, quietly, from the other side of
        the world."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "ok"}})
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            self.assertTrue(tools["calendar_pull"]["check_fn"]())
            out = m.call("calendar_pull")
            queued = m.intents()
        self.assertTrue(out["deferred"])
        self.assertEqual(len(queued), 1)
        self.assertEqual(out["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Calendar")

    def test_an_action_the_document_never_mentions_is_unseen_not_absent(self):
        """The same rule one level down: a document that speaks about `notes
        pull` has said nothing about `notes create`."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "ok"}})
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            self.assertTrue(tools["notes_create"]["check_fn"]())
            self.assertEqual(m.call("notes_pull")["result"],
                             plugin.DEFERRED_SENTENCE % "Notes")
            out = m.call("notes_create", title="Shopping", body="milk")
            queued = m.intents()
        self.assertTrue(out["deferred"])
        self.assertEqual(len(queued), 2)
        self.assertEqual(out["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")

    # -- and evidence goes stale (§14.4a) -------------------------------------

    def test_evidence_older_than_seven_days_is_not_evidence(self):
        """§4.4 forbids quoting a capability probe older than the heartbeat
        window and there is no heartbeat here, so a Mac shut for a fortnight
        stops being quoted as authority on what it can do today. Everything
        the document describes falls back to the hedge — including what it
        said was `ok`, and including what it said it could NOT do: stale is
        not evidence in either direction."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "ok", "create": "needs-setup"}},
                                 days_ago=8)
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            self.assertTrue(tools["notes_create"]["check_fn"]())
            pulled = m.call("notes_pull")
            created = m.call("notes_create", title="Shopping", body="milk")
            self.assertEqual(len(m.intents()), 2)
        self.assertEqual(pulled["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")
        self.assertEqual(created["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")

    def test_evidence_six_days_old_still_counts(self):
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "ok", "create": "needs-setup"}},
                                 days_ago=6)
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            self.assertFalse(tools["notes_create"]["check_fn"]())
            pulled = m.call("notes_pull")
            created = m.call("notes_create", title="Shopping", body="milk")
            self.assertEqual(len(m.intents()), 1)
        self.assertEqual(pulled["result"], plugin.DEFERRED_SENTENCE % "Notes")
        self.assertTrue(created["absent"])

    def test_a_clock_far_ahead_is_distrusted_the_same_way(self):
        """§14.2 distrusts an intent's `at` in BOTH directions because two
        computers' clocks are two clocks. A Mac 400 days fast would otherwise
        be quoted as an authority on today for over a year."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "needs-setup"}}, days_ago=-400)
            self.assertTrue(m.tools()["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
        self.assertEqual(out["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")

    def test_staleness_is_measured_when_it_is_asked_not_when_it_was_read(self):
        """The parse is cached until the ledger moves, and time is not
        something the ledger moving tells us about — so the window has to be
        checked at the question, not at the read."""
        self.assertFalse(plugin._stale(time.time() - 6 * 86400))
        self.assertTrue(plugin._stale(time.time() - 8 * 86400))
        self.assertTrue(plugin._stale(None))
        # Six days old, asked two days later.
        self.assertTrue(plugin._stale(time.time() - 6 * 86400,
                                      now=time.time() + 2 * 86400))

    def test_an_absent_hand_is_not_queued_even_called_straight_at_the_queue(self):
        """The invariant lives in the function that writes the record, not
        only in the two gates in front of it."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "absent"}})
            out = json.loads(plugin.queue_intent("connector", "notes", "pull", "Notes",
                                                 "mac", [], None))
            self.assertEqual(m.intents(), [])
        self.assertTrue(out["absent"])

    # -- no document: still detached, but no promise --------------------------

    def test_no_document_queues_while_saying_it_cannot_see(self):
        """The normal case until a Mac publishes one. Silence is not consent
        and it is not capability either — so it queues, and says so."""
        with Machine() as m:
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
            queued = m.intents()
        self.assertTrue(out["deferred"])
        self.assertEqual(len(queued), 1)
        self.assertEqual(out["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")
        self.assertIn("can't see", out["result"])
        self.assertIn("can't promise", out["result"])

    def test_a_document_that_will_not_open_is_no_document_not_absent(self):
        """A body this machine cannot read says nothing about the Mac.
        Reading it as "absent" would withhold a hand the person has."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "absent"}},
                                 seal_under=threadcrypto.mint_key())
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
            queued = m.intents()
        self.assertTrue(out["deferred"])
        self.assertEqual(len(queued), 1)
        self.assertEqual(out["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")

    def test_a_document_sealed_before_that_mac_joined_a_tenant_still_opens(self):
        """CLOUD-PLAN §15.1. A Mac that ran Moe free published its capability
        tables under the `moe:memory` key it minted for itself; joining a
        tenant retires that key and adopts the tenant's. Reading asks the
        vault for every key that may open a document, not only the current
        one — and it matters here more than almost anywhere, because the test
        above is what a single key would produce instead: unreadable is read
        as *unknown*, so a hand the person actually has becomes silence about
        it, and the machine queues work the Mac has already said it cannot do.
        """
        import base64

        old = threadcrypto.mint_key()
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "absent"}}, seal_under=old)
            path = Vault(os.path.join(m.hermes_home, "moe")).keyring_path
            held = json.loads(path.read_text("utf-8"))
            held["retired"] = {MEMORY_KEY_ID: [base64.b64encode(old).decode()]}
            path.write_text(json.dumps(held), "utf-8")
            plugin.forget_ledger()
            out = m.call("notes_pull")
            queued = m.intents()
        self.assertTrue(out["absent"], "the retired key is what makes the table readable")
        self.assertEqual(queued, [])

    def test_a_document_that_is_not_the_shape_14_4a_names_is_no_document(self):
        for plain in ("not json at all", '["notes"]', '"ok"'):
            with self.subTest(plain=plain), Machine() as m:
                plugin.forget_ledger()
                m.publish_capability(None, text=plain)
                self.assertTrue(m.tools()["notes_pull"]["check_fn"]())
                out = m.call("notes_pull")
                self.assertTrue(out["deferred"])
                self.assertEqual(len(m.intents()), 1)

    def test_a_state_word_this_build_does_not_know_is_no_evidence(self):
        """Not "the Mac says it cannot", so not absent — and not a promise
        either."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "probably-fine"}})
            self.assertTrue(m.tools()["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
        self.assertEqual(out["result"], plugin.DEFERRED_UNSEEN_SENTENCE % "Notes")

    def test_the_newest_document_wins(self):
        """§13.5: latest in ledger order, no merge. Turning Notes on for the
        first time must reach the machine without a restart."""
        with Machine() as m:
            m.publish_capability({"notes": {"pull": "needs-setup"}})
            self.assertFalse(m.tools()["notes_pull"]["check_fn"]())
            m.publish_capability({"notes": {"pull": "ok"}})
            self.assertTrue(m.tools()["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
        self.assertEqual(out["result"], plugin.DEFERRED_SENTENCE % "Notes")

    def test_a_per_action_object_is_read_too(self):
        with Machine() as m:
            m.publish_capability(
                {"notes": {"pull": {"state": "needs-setup", "why": "not enabled"}}})
            out = m.call("notes_pull")
            self.assertEqual(m.intents(), [])
        self.assertIn("not enabled", out["error"])

    # -- what it must never touch ---------------------------------------------

    def test_it_never_speaks_for_an_attached_connector(self):
        """Attached means "runs here", and what the Mac can do has no bearing
        on it: `gmail` runs its own script on the machine."""
        with Machine() as m:
            m.publish_capability({"gmail": {"pull": "absent"}, "notes": {"pull": "ok"}})
            tools = m.tools()
            self.assertTrue(tools["gmail_pull"]["check_fn"]())
            out = m.call("gmail_pull")
            self.assertEqual(m.intents(), [])
        self.assertTrue(out["success"])
        self.assertIn("two notes", out["result"])

    def test_a_mac_is_untouched_by_its_own_document(self):
        with Machine(runs_in=None) as m:
            m.publish_capability({"notes": {"pull": "absent"}})
            tools = m.tools()
            self.assertTrue(tools["notes_pull"]["check_fn"]())
            out = m.call("notes_pull")
            self.assertEqual(m.intents(), [])
        self.assertTrue(out["success"])
        self.assertIn("two notes", out["result"])

    def test_it_writes_no_capability_document_of_its_own(self):
        """The Mac's half, not this one's. Reading is all this plugin does."""
        with Machine() as m:
            m.tools()
            m.call("notes_pull")
            names = [r.body.get("name") for r in m.records() if r.kind == KIND_DOCUMENT]
        self.assertEqual(names, [])


class OneReadOfTheLedgerPerChange(unittest.TestCase):
    """L3. The detached path used to read the WHOLE ledger on every tool call
    just to work out the `after` an intent orders behind, which makes a
    detached call O(ledger) inside a turn — and §14.4a would have added a
    second full read per `check_fn`, fifty of them per listing."""

    def counted(self):
        """Every `read_ledger` this plugin makes, while the block runs."""
        calls = []
        original = Vault.read_ledger

        def counting(vault):
            calls.append(str(vault.root))
            return original(vault)

        Vault.read_ledger = counting
        self.addCleanup(setattr, Vault, "read_ledger", original)
        plugin.forget_ledger()
        return calls

    def stop_counting(self):
        self.doCleanups()

    def test_a_turn_of_calls_reads_the_ledger_once(self):
        with Machine() as m:
            calls = self.counted()
            first = m.call("notes_pull")
            second = m.call("calendar_pull")
            self.assertEqual(len(calls), 1, calls)
            self.stop_counting()
            records = m.intents()
        # …and the second intent still orders behind the first, which is what
        # the read was for.
        self.assertEqual([r.id for r in records], [first["intent"], second["intent"]])
        self.assertEqual(records[1].after, [records[0].id])

    def test_a_record_arriving_from_elsewhere_is_seen(self):
        """Cheap must not mean stale: a document (or a turn) appended by
        another writer changes the stamp, and the next call reads again."""
        with Machine() as m:
            calls = self.counted()
            m.call("notes_pull")
            self.assertEqual(len(calls), 1, calls)
            m.publish_capability({"notes": {"pull": "needs-setup"}})
            out = m.call("notes_pull")
            self.assertGreater(len(calls), 1)
            self.stop_counting()
        self.assertTrue(out["absent"])


class NothingQueuedMaySend(unittest.TestCase):
    """§14.4 rule 5. `send` and `voice` are withheld on the machine, and
    withheld is not deferred: a send is not a thing to queue."""

    def test_send_and_voice_are_not_tools_on_the_machine(self):
        with Machine() as m:
            tools = m.tools()
        self.assertNotIn("whatsapp_send", tools)
        self.assertNotIn("whatsapp_voice", tools)
        self.assertIn("whatsapp_pull", tools)

    def test_a_detached_connectors_send_is_withheld_not_queued(self):
        with Machine() as m:
            self.assertNotIn("whatsapp_send", m.tools())
            self.assertEqual(m.intents(), [])

    def test_a_mac_offers_them_as_it_always_did(self):
        with Machine(runs_in=None) as m:
            tools = m.tools()
        self.assertIn("whatsapp_send", tools)
        self.assertIn("whatsapp_voice", tools)


class OnAMacNothingChanges(unittest.TestCase):
    def test_a_mac_detaches_nothing(self):
        with Machine(runs_in=None):
            self.assertFalse([c for c in plugin.read_manifests() if c["detached"]])
        with Machine(runs_in="mac"):
            self.assertFalse([c for c in plugin.read_manifests() if c["detached"]])

    def test_a_mac_runs_the_script_and_writes_no_intent(self):
        with Machine(runs_in=None) as m:
            out = m.call("notes_pull")
            self.assertEqual(m.intents(), [])
        self.assertTrue(out["success"])
        self.assertNotIn("deferred", out)
        self.assertIn("two notes", out["result"])

    def test_a_both_connector_still_runs_its_subprocess_on_the_machine(self):
        with Machine() as m:
            out = m.call("gmail_pull")
            self.assertEqual(m.intents(), [])
        self.assertTrue(out["success"])
        self.assertNotIn("deferred", out)
        self.assertIn("two notes", out["result"])

    def test_arguments_still_reach_an_attached_connector(self):
        catalogue = [("gmail", "status pull crawl", ECHOES, "runs_in=both\n")]
        with Machine(catalogue) as m:
            out = m.call("gmail_crawl", days=14)
        self.assertIn("--since,14", out["result"])


class WhenItCannotQueue(unittest.TestCase):
    """§14.5's other half: an absent hand is different and must not be
    queued. "I'll do it when your Mac wakes" about a record nobody wrote is
    a lie with a delay on it."""

    def assert_honest(self, out):
        self.assertFalse(out["success"])
        self.assertNotIn("deferred", out)
        self.assertNotIn("intent", out)
        self.assertIn("could not queue", out["error"])
        self.assertIn("already know", out["error"])
        self.assertNotIn("when your Mac", out["error"])

    def test_no_thread_for_this_session_says_so_and_writes_nothing(self):
        with Machine(thread=None) as m:
            out = m.call("notes_pull")
            self.assertEqual(m.records(), [])
        self.assert_honest(out)
        self.assertIn("share yet", out["error"])

    def test_no_session_at_all_says_so_and_writes_nothing(self):
        with Machine(session=None) as m:
            out = m.call("notes_pull")
            self.assertEqual(m.records(), [])
        self.assert_honest(out)

    def test_no_key_for_the_thread_says_so_and_writes_nothing(self):
        with Machine(key=False) as m:
            out = m.call("notes_pull")
            self.assertEqual(m.records(), [])
        self.assert_honest(out)
        self.assertIn("key", out["error"])

    def test_an_unenrolled_machine_with_no_identity_says_so(self):
        with Machine(identity=False) as m:
            out = m.call("notes_pull")
            self.assertEqual(m.records(), [])
        self.assert_honest(out)
        self.assertIn("no ledger", out["error"])

    def test_no_ledger_library_beside_this_plugin_says_so(self):
        with Machine() as m:
            saved = plugin._moeledger
            try:
                plugin._moeledger = lambda: None
                out = m.call("notes_pull")
                self.assertEqual(m.records(), [])
            finally:
                plugin._moeledger = saved
        self.assert_honest(out)
        self.assertIn("no ledger", out["error"])


class TheAwaySentenceStaysAwayFromIt(unittest.TestCase):
    """The fifth of CLOUD-PLAN §13's changes: `away_text` must not rewrite a
    deferred result into "not connected on the away machine yet"."""

    def test_a_deferred_result_is_never_rewritten(self):
        with Machine() as m:
            out = m.call("notes_pull")
        self.assertNotIn(plugin.AWAY_NOT_CONNECTED % "Notes", json.dumps(out))
        self.assertNotIn("away machine", out["result"])

    def test_away_text_leaves_a_detached_connector_alone(self):
        sentence = plugin.DEFERRED_SENTENCE % "Notes"
        with Machine():
            self.assertEqual(
                plugin.away_text("notes", "Notes", "pull", sentence, False, True),
                sentence)
            # …and still does its job for a connector that ran here.
            self.assertEqual(
                plugin.away_text("gmail", "Gmail", "pull", "needs-setup: run connect.sh",
                                 True, False),
                plugin.AWAY_NOT_CONNECTED % "Gmail")


class NothingLeaksIntoTheRealHomes(unittest.TestCase):
    """A belt for the braces: every test above runs inside two temp
    directories, and this is the one that would notice if one did not."""

    def test_the_plugin_reads_its_homes_from_the_environment(self):
        with Machine() as m:
            self.assertEqual(plugin.moe_home(), m.moe_home)
            self.assertEqual(plugin.vault_root(), os.path.join(m.hermes_home, "moe"))
            self.assertEqual(plugin.session_key(), SESSION)
        self.assertNotIn(os.path.expanduser("~/.moe"), plugin.vault_root())


if __name__ == "__main__":
    unittest.main()


class TheTwoHalvesOfCapabilityMeet(unittest.TestCase):
    """§14.4a's writer and reader, joined.

    Every other test in this file hand-writes the table it wants the reader
    to see, which is right for testing the reader and proves nothing about
    the seam. These publish what `moeledger.capability` — the Mac's actual
    writer — really produces from real manifests and a real `config.yaml`,
    and then ask this plugin what it makes of it. A drift between the two
    would otherwise show up first on somebody's phone.
    """

    def _connector(self, directory, name, verbs, exit_code, says):
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, name + ".manifest"), "w") as handle:
            handle.write("name=%s\nverbs=%s\nruns_in=mac\n" % (name, verbs))
        script = os.path.join(directory, name + ".sh")
        with open(script, "w") as handle:
            handle.write("#!/bin/sh\necho '%s'\nexit %d\n" % (says, exit_code))
        os.chmod(script, 0o755)

    def test_what_the_mac_writes_is_what_this_machine_reads(self):
        from moeledger import capability

        with Machine() as m:
            mac = tempfile.mkdtemp(prefix="moe-mac-")
            try:
                connectors = os.path.join(mac, "connectors")
                # Set up, not set up, and cannot be — one of each, using the
                # names the machine's own catalogue knows, since a hand it has
                # no tool for is a different (and already covered) case.
                self._connector(connectors, "notes", "status pull create", 0, "ok: 4 notes")
                self._connector(connectors, "whatsapp", "status pull", 1,
                                "needs-setup: sign in to WhatsApp on your Mac")
                self._connector(connectors, "calendar", "status pull", 3,
                                "unavailable: no Calendar app")
                text = capability.tables(mac, mac, use_cache=False)[
                    capability.CAPABILITY_PREFIX + capability.VIA_CONNECTOR]
                m.publish_capability(None, text=text)

                # ok → queued.
                queued = m.call("notes_pull")
                self.assertTrue(queued.get("deferred"))
                self.assertEqual(len(m.intents()), 1)

                # absent → refused, never queued, and no "go and set it up".
                cannot = m.call("calendar_pull")
                self.assertTrue(cannot.get("absent"))
                self.assertIn("no Calendar app", cannot["error"])
                self.assertEqual(len(m.intents()), 1, "an absent hand queues nothing")

                # needs-setup → also not queued, but the sentence sends the
                # person somewhere real, because there is somewhere to go.
                setup = m.call("whatsapp_pull")
                self.assertTrue(setup.get("absent"))
                self.assertIn("sign in to WhatsApp on your Mac", setup["error"])
                self.assertEqual(len(m.intents()), 1)
            finally:
                shutil.rmtree(mac, ignore_errors=True)

    def test_the_mcp_table_reaches_the_machine_too(self):
        """The owner's actual complaint: they asked the machine about their
        Supabase and it said there was no connection and offered to make one.
        With the table published, `mcp/supabase` is a hand the machine knows
        the Mac has."""
        from moeledger import capability

        with Machine() as m:
            mac = tempfile.mkdtemp(prefix="moe-mac-mcp-")
            try:
                with open(os.path.join(mac, "config.yaml"), "w") as handle:
                    handle.write("mcp_servers:\n"
                                 "  supabase:\n    auth: oauth\n"
                                 "  cloudflare:\n    auth: oauth\n")
                os.makedirs(os.path.join(mac, "mcp-tokens"))
                with open(os.path.join(mac, "mcp-tokens", "supabase.json"), "w") as handle:
                    handle.write("{}")
                text = capability.tables(mac, mac, use_cache=False)[
                    capability.CAPABILITY_PREFIX + capability.VIA_MCP]
                m.publish_capability(None, via="mcp", text=text)

                state, _said, why = plugin.hand("mcp", "supabase", "call")
                self.assertEqual(state, plugin.HAND_DETACHED,
                                 "signed in on the Mac: the machine can queue for it")
                self.assertIn("connected on the Mac", why)

                # Signed out reads as absent — do not queue — but `said`
                # carries the Mac's own word, which is what makes the
                # difference between "set it up on your Mac" and "your Mac
                # hasn't got one". Both are honest; only one is actionable.
                state, said, why = plugin.hand("mcp", "cloudflare", "call")
                self.assertEqual(state, plugin.HAND_ABSENT)
                self.assertEqual(said, "needs-setup")
                self.assertIn("sign-in", why)

                # And one nobody has ever connected is *unseen* — the table
                # says nothing about it, and silence withdraws nothing.
                state, _said, _why = plugin.hand("mcp", "notion", "call")
                self.assertEqual(state, plugin.HAND_UNSEEN)
            finally:
                shutil.rmtree(mac, ignore_errors=True)

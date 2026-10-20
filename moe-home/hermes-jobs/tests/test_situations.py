#!/usr/bin/env python3
"""The situations engine (moe-home/lib/situations.py) and its job, with a
fake connector and a fake model — no Hermes, no network.

Run: python3 moe-home/hermes-jobs/tests/test_situations.py

The fake connector is a real executable answering `items --since <cursor>`
the way connectors/whatsapp-items.py does, so the engine is exercised through
the one verb every source will speak, and never through a source's name.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MOE_SRC = os.path.normpath(os.path.join(HERE, "..", ".."))
LIB = os.path.join(MOE_SRC, "lib", "situations.py")
JOB = os.path.join(MOE_SRC, "hermes-jobs", "moe-situations.py")
WA_ITEMS = os.path.join(MOE_SRC, "connectors", "whatsapp-items.py")

NOW = 1790280000.0


def load():
    spec = importlib.util.spec_from_file_location("situations_under_test", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def item(i, text, *, me=False, thread="acme", at=None, to_me=True, name="Acme", group=False):
    return {"id": "m%d" % i, "thread": thread, "thread_name": name, "at": at or NOW - 600 + i,
            "from": {"id": "me" if me else "acme", "name": "" if me else name, "me": me},
            "to_me": to_me, "group": group, "kind": "msg", "text": text}


DISPUTE = [
    item(1, "Your order is ready, 700 birds, arriving at 6am"),
    item(2, "Only 250 came and you were 2 hours late. We lost customers.", me=True),
    item(3, "I'll pay half, that's fair given what happened", me=True),
    item(4, "Not acceptable. Full payment of $4,200 by Friday or we stop supplying you."),
]

FOUND = {"situation": {
    "title": "Acme short delivery", "kind": "payment dispute",
    "owner_position": "pay half", "other_position": "wants $4,200 in full",
    "at_stake": "$4,200 and the supplier", "open_question": "how much to pay",
    "next_move": "owner", "deadline": "2026-09-25", "help": ["research", "draft", "shout"],
    "p_wanted": 0.8,
    "evidence": [{"id": "m4", "quote": "Full payment of $4,200 by Friday"},
                 {"id": "m2", "quote": "I invented this line"},
                 {"id": "m1", "quote": "Full payment of $4,200 by Friday"}]}}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-situations-")
        os.environ["MOE_HOME"] = self.tmp
        self.s = load()
        self.asked = []
        self.batches = []          # what the fake connector returns, one list per call
        self.adapter = os.path.join(self.tmp, "fake-items.py")
        with open(self.adapter, "w") as f:
            f.write(textwrap.dedent("""\
                #!/usr/bin/env python3
                import json, os, sys
                state = os.path.join(os.path.dirname(__file__), "fake-state.json")
                st = json.load(open(state))
                since = sys.argv[sys.argv.index("--since") + 1]
                open(os.path.join(os.path.dirname(__file__), "fake-asked.log"), "a").write(since + "\\n")
                batch = st["batches"].pop(0) if st["batches"] else []
                json.dump(st, open(state, "w"))
                if st.get("fail"):
                    sys.exit(3)
                for it in batch:
                    print(json.dumps(it))
                print(json.dumps({"cursor": str(int(since or 0) + len(batch))}))
                """))
        os.chmod(self.adapter, 0o755)
        self.set_batches([])

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_batches(self, batches, fail=False):
        with open(os.path.join(self.tmp, "fake-state.json"), "w") as f:
            json.dump({"batches": batches, "fail": fail}, f)

    def answering(self, payload):
        def call(messages):
            self.asked.append(messages)
            return payload if isinstance(payload, str) else json.dumps(payload)
        return call

    def tick(self, call, now=NOW, consent=lambda name: True, **kw):
        return self.s.tick(call=call, sources=[("fakechat", self.adapter)], consent=consent,
                           now=now, **kw)

    def monitor(self):
        with open(self.s.monitor_path()) as f:
            return [json.loads(line) for line in f]


class GateTest(Base):
    def test_signals_not_scenarios(self):
        ok, why = self.s.gate(DISPUTE, DISPUTE[3:], False, now=NOW)
        self.assertTrue(ok)
        self.assertIn("money", why)
        self.assertIn("tension or obligation", why)
        self.assertIn("reply pending on the owner", why)

    def test_what_passes_nothing(self):
        chat = [item(1, "haha yes see you tomorrow"), item(2, "👍", me=True)]
        self.assertFalse(self.s.gate(chat, chat[1:], False, now=NOW)[0])
        # A reply pending on its own is most of an inbox; it needs company.
        pending = [item(1, "how was your weekend")]
        self.assertFalse(self.s.gate(pending, pending, False, now=NOW)[0])

    def test_an_exchange_still_going_waits(self):
        live = [item(1, "Full payment of $4,200 by Friday", at=NOW - 30)]
        self.assertEqual(self.s.gate(live, live, False, now=NOW), (False, ["still talking"]))

    def test_automated_and_unaddressed(self):
        otp = [item(1, "Your verification code is 552211, it expires in 10 minutes")]
        self.assertEqual(self.s.gate(otp, otp, False, now=NOW)[1], ["automated"])
        group = [item(1, "Anyone owe money for the $40 pizza? Friday deadline", to_me=False, group=True)]
        self.assertEqual(self.s.gate(group, group, False, now=NOW)[1], ["not addressed to the owner"])


class SensorTest(Base):
    def test_every_situation_must_quote_the_thread(self):
        found, why = self.s.parse_sensor(json.dumps(FOUND), DISPUTE)
        self.assertEqual(why, "situation")
        self.assertEqual([e["id"] for e in found["evidence"]], ["m4"],
                         "the invented quote and the right words on the wrong message are dropped")
        self.assertEqual(found["help"], ["research", "draft"], "only the known kinds of help")
        bad = json.loads(json.dumps(FOUND))
        bad["situation"]["evidence"] = [{"id": "m4", "quote": "wire the money to account 1234"}]
        self.assertEqual(self.s.parse_sensor(json.dumps(bad), DISPUTE), (None, "no quote found in the thread"))

    def test_silence_and_nonsense(self):
        self.assertEqual(self.s.parse_sensor('{"situation": null}', DISPUTE), (None, "no situation"))
        self.assertEqual(self.s.parse_sensor("I think so", DISPUTE)[1], "unreadable answer")

    def test_the_prompt_names_no_scenario_and_carries_the_ids(self):
        msgs = self.s.sensor_messages(DISPUTE, owner_name="Izzy")
        system = msgs[0]["content"].lower()
        for scenario in ("supplier", "invoice", "flight", "whatsapp"):
            self.assertNotIn(scenario, system)
        self.assertIn("[m4]", msgs[1]["content"])
        self.assertIn("me (the owner)", msgs[1]["content"])


class TickTest(Base):
    def test_first_look_starts_from_now(self):
        self.set_batches([[]])
        self.tick(self.answering(FOUND))
        with open(os.path.join(self.tmp, "fake-asked.log")) as f:
            self.assertEqual(f.read().splitlines(), [""])
        self.assertEqual(json.load(open(self.s.cursors_path())), {"fakechat": "0"})
        self.assertEqual(self.asked, [])

    def test_a_situation_is_found_recorded_and_monitored_silently(self):
        self.set_batches([DISPUTE])
        summary = self.tick(self.answering(FOUND))
        self.assertEqual(summary["asked"], 1)
        self.assertEqual(summary["situations"], 1)
        sits = self.s.load_situations()
        (sid, rec), = sits.items()
        self.assertEqual(rec["title"], "Acme short delivery")
        self.assertEqual(rec["status"], "sensed")
        self.assertEqual(rec["next_move"], "owner")
        events = [e["event"] for e in self.monitor()]
        self.assertIn("situation", events)
        self.assertEqual(events[-1], "tick")
        self.assertEqual(json.load(open(self.s.cursors_path())), {"fakechat": "4"})
        # The monitor holds the situation's short fields, never the messages.
        blob = open(self.s.monitor_path()).read()
        self.assertNotIn("we stop supplying you", blob)

    def test_the_cursor_moves_so_nothing_is_read_twice(self):
        self.set_batches([DISPUTE, []])
        self.tick(self.answering(FOUND))
        self.tick(self.answering(FOUND), now=NOW + 300)
        with open(os.path.join(self.tmp, "fake-asked.log")) as f:
            self.assertEqual(f.read().splitlines(), ["", "4"])
        self.assertEqual(len(self.asked), 1, "one read, one question")

    def test_a_live_exchange_waits_for_the_pause_then_is_read_once(self):
        live = [dict(it, at=NOW - 10 + i) for i, it in enumerate(DISPUTE)]
        self.set_batches([live, []])
        self.tick(self.answering(FOUND))
        self.assertEqual(self.asked, [], "still talking")
        self.tick(self.answering(FOUND), now=NOW + 300)
        self.assertEqual(len(self.asked), 1)

    def test_nothing_is_read_from_a_source_the_person_did_not_allow(self):
        self.set_batches([DISPUTE])
        self.tick(self.answering(FOUND), consent=lambda name: False)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "fake-asked.log")))
        self.assertEqual(self.asked, [])

    def test_background_thinking_off_spends_nothing_and_keeps_no_backlog(self):
        self.set_batches([DISPUTE, []])
        self.tick(self.answering(FOUND), think=False)
        self.assertEqual(self.asked, [])
        self.tick(self.answering(FOUND), now=NOW + 300)
        self.assertEqual(self.asked, [], "switching it back on does not read the backlog")
        self.assertIn("skipped", [e["event"] for e in self.monitor()])

    def test_a_failed_read_moves_no_cursor_and_a_failed_question_is_asked_again(self):
        self.set_batches([DISPUTE], fail=True)
        self.tick(self.answering(FOUND))
        self.assertFalse(os.path.exists(self.s.cursors_path()) and
                         json.load(open(self.s.cursors_path())).get("fakechat"))
        self.assertIn("read-failed", [e["event"] for e in self.monitor()])
        self.set_batches([DISPUTE, []])

        def boom(messages):
            raise RuntimeError("lane down")
        self.tick(boom)
        self.tick(self.answering(FOUND), now=NOW + 300)
        self.assertEqual(len(self.asked), 1, "the thread waited and was asked once the lane was back")

    def test_a_thread_that_calms_down_is_resolved_not_deleted(self):
        self.set_batches([DISPUTE, [item(5, "Ok, half now and the rest when you deliver the balance. Deal.")]])
        self.tick(self.answering(FOUND))
        self.tick(self.answering('{"situation": null}'), now=NOW + 600)
        (rec,) = self.s.load_situations().values()
        self.assertEqual(rec["status"], "resolved")

    def test_the_same_thread_is_one_situation(self):
        self.set_batches([DISPUTE, [item(5, "Still waiting on the $4,200, final notice before Friday")]])
        self.tick(self.answering(FOUND))
        self.tick(self.answering(FOUND), now=NOW + 600)
        self.assertEqual(len(self.s.load_situations()), 1)
        (rec,) = self.s.load_situations().values()
        self.assertEqual(len(rec["history"]), 2)


class PruneTest(Base):
    def test_settled_situations_age_out_and_the_file_stays_bounded(self):
        day = 86400
        data = {"old_settled": {"status": "resolved", "updated_at": self.s._iso(NOW - 40 * day)},
                "old_open": {"status": "sensed", "updated_at": self.s._iso(NOW - 40 * day)},
                "new_settled": {"status": "resolved", "updated_at": self.s._iso(NOW - 2 * day)}}
        self.assertEqual(sorted(self.s.prune(data, NOW)), ["new_settled", "old_open"])
        many = {"s%d" % i: {"status": "sensed", "updated_at": self.s._iso(NOW - i)} for i in range(400)}
        kept = self.s.prune(many, NOW)
        self.assertEqual(len(kept), self.s.MAX_SITUATIONS)
        self.assertIn("s0", kept)
        self.assertNotIn("s399", kept)


class JobTest(Base):
    def test_the_job_never_prints_because_its_stdout_is_a_message(self):
        lib = os.path.join(self.tmp, "lib")
        os.makedirs(lib)
        for mod in ("situations.py", "cheap_model.py", "prepare.py", "promises.py", "travel.py"):
            shutil.copy(os.path.join(os.path.dirname(LIB), mod), os.path.join(lib, mod))
        os.makedirs(os.path.join(self.tmp, "connectors"))
        env = dict(os.environ, MOE_HOME=self.tmp, HERMES_AGENT_DIR="/nonexistent")
        p = subprocess.run([sys.executable, JOB], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, env=env, timeout=60)
        self.assertEqual(p.stdout, "")
        self.assertEqual(p.returncode, 0, p.stderr)


class WhatsAppItemsTest(unittest.TestCase):
    """The first adapter: the bridge's store, read-only, by rowid."""

    def setUp(self):
        import sqlite3
        self.tmp = tempfile.mkdtemp(prefix="moe-wa-items-")
        self.db = os.path.join(self.tmp, "messages.db")
        con = sqlite3.connect(self.db)
        con.executescript("""
            create table chats (jid text primary key, name text, last_message_time timestamp);
            create table messages (id text, chat_jid text, sender text, content text,
                timestamp timestamp, is_from_me boolean, media_type text, primary key (id, chat_jid));
            insert into chats values ('15550104477@s.whatsapp.net', '', null),
                                     ('1203@g.us', 'Family', null);
            insert into messages values ('A1', '15550104477@s.whatsapp.net', null, 'Full payment by Friday',
                                         '2026-09-24 20:00:00', 0, null);
            insert into messages values ('A2', '15550104477@s.whatsapp.net', null, 'I will pay half',
                                         '2026-09-24 20:01:00', 1, null);
            insert into messages values ('A3', '1203@g.us', '15551112222@s.whatsapp.net', 'dinner at 8?',
                                         '2026-09-24 20:02:00', 0, null);
            insert into messages values ('A4', '1203@g.us', null, '', '2026-09-24 20:03:00', 0, 'image');
            insert into messages values ('A5', '1203@g.us', null, 'no time on this one', null, 0, null);
        """)
        con.commit()
        con.close()
        os.environ["MOE_HOME"] = self.tmp
        with open(os.path.join(self.tmp, "contacts.json"), "w") as f:
            json.dump({"550104477": "Acme Foods"}, f)

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        os.environ.pop("MOE_ITEMS_BACKFILL_HOURS", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_items(self, since):
        p = subprocess.run([sys.executable, WA_ITEMS, self.db, "--since", since],
                           stdout=subprocess.PIPE, universal_newlines=True, check=True)
        return [json.loads(line) for line in p.stdout.splitlines()]

    def test_first_look_is_only_a_cursor(self):
        self.assertEqual(self.run_items(""), [{"cursor": "5"}])

    def test_items_since_a_cursor(self):
        out = self.run_items("0")
        items, cursor = out[:-1], out[-1]
        self.assertEqual(cursor, {"cursor": "5"}, "the empty image row and the untimed row are passed over")
        self.assertEqual([i["text"] for i in items], ["Full payment by Friday", "I will pay half", "dinner at 8?"])
        self.assertEqual(items[0]["thread_name"], "Acme Foods")
        self.assertTrue(items[0]["to_me"] and not items[0]["group"])
        self.assertTrue(items[1]["from"]["me"])
        self.assertTrue(items[2]["group"] and not items[2]["to_me"])
        self.assertEqual(self.run_items("5"), [{"cursor": "5"}])
        self.assertNotIn("no time on this one", [i["text"] for i in items])

    def test_items_are_what_the_engine_accepts(self):
        s = load()
        out = self.run_items("0")[:-1]
        self.assertTrue(all(s.normalise_item(i, "whatsapp") for i in out))


class FreshnessTest(Base):
    """2026-09-25 review: a backlog written again with new ids (Messages in
    iCloud switched on, an index rebuilt) is not news, and an item a reader
    returns twice (a calendar's overlap) is not asked about twice."""

    def test_old_items_never_reach_the_sensor(self):
        old = [dict(item(1, "Full payment of $4,200 by Friday, or I call my lawyer"),
                    at=NOW - 5 * 86400)]
        self.set_batches([old])
        summary = self.tick(self.answering({"situation": None}), now=NOW)
        self.assertEqual(summary["items"], 0)
        self.assertEqual(self.asked, [])
        self.assertIn("stale-skipped", [e["event"] for e in self.monitor()])

    def test_an_item_read_again_is_not_new_again(self):
        batch = DISPUTE
        self.set_batches([batch, batch])
        self.tick(self.answering({"situation": None}), now=NOW)
        n = len(self.asked)
        summary = self.tick(self.answering({"situation": None}), now=NOW + 600)
        self.assertEqual(summary["items"], 0)
        self.assertEqual(len(self.asked), n)


class PaceTest(Base):
    """2026-10-15: every tick asked a Telegram that was never signed in
    (~145 read-failed a day), and every tick paid ~10 s per Composio read
    that usually found nothing. A not-connected source is parked until its
    connection changes; a quiet Composio read waits longer, up to 15 min."""

    def setUp(self):
        super().setUp()
        self.unsigned = os.path.join(self.tmp, "unsigned-items.py")
        with open(self.unsigned, "w") as f:
            f.write(textwrap.dedent("""\
                #!/usr/bin/env python3
                import os, sys
                open(os.path.join(os.path.dirname(__file__), "unsigned-asked.log"), "a").write("x\\n")
                print("unavailable: Telegram is not signed in", file=sys.stderr)
                sys.exit(1)
                """))
        os.chmod(self.unsigned, 0o755)
        os.environ["MOE_CONNECTORS_DIR"] = os.path.join(self.tmp, "connectors")
        os.makedirs(os.environ["MOE_CONNECTORS_DIR"])

    def tearDown(self):
        os.environ.pop("MOE_CONNECTORS_DIR", None)
        super().tearDown()

    def asks(self, log):
        try:
            with open(os.path.join(self.tmp, log)) as f:
                return len(f.read().splitlines())
        except OSError:
            return 0

    def ptick(self, sources, now):
        return self.s.tick(call=self.answering({"situation": None}), sources=sources,
                           consent=lambda name: True, now=now, pace=True)

    def test_a_source_that_is_not_signed_in_is_parked_until_its_connection_changes(self):
        src = [("native/telegram", [self.unsigned])]
        for i in range(4):
            self.ptick(src, NOW + 300 * i)
        self.assertEqual(self.asks("unsigned-asked.log"), 1)
        failed = [e for e in self.monitor() if e["event"] == "read-failed"]
        self.assertEqual(len(failed), 1)                       # said once, not every tick
        # A sign-in lands a file in connectors/: asked again at once.
        with open(os.path.join(os.environ["MOE_CONNECTORS_DIR"], "telegram.session"), "w") as f:
            f.write("x")
        os.utime(os.environ["MOE_CONNECTORS_DIR"], (NOW + 5000, NOW + 5000))
        self.ptick(src, NOW + 1500)
        self.assertEqual(self.asks("unsigned-asked.log"), 2)
        # And without any change, again after half an hour, not never.
        self.ptick(src, NOW + 1500 + self.s.PARK_RECHECK_S + 1)
        self.assertEqual(self.asks("unsigned-asked.log"), 3)

    def test_a_quiet_composio_read_backs_off_to_fifteen_minutes(self):
        src = [("composio/github", [self.adapter])]
        t = NOW
        for _ in range(12):                                    # an hour of 5-minute ticks
            self.ptick(src, t)
            t += 300
        # 0, 5, 15, 30, 45 min… — not twelve reads.
        self.assertLessEqual(self.asks("fake-asked.log"), 6)
        self.assertGreaterEqual(self.asks("fake-asked.log"), 4)

    def test_a_composio_read_that_finds_something_is_back_to_every_tick(self):
        src = [("composio/github", [self.adapter])]
        self.set_batches([[item(1, "hello")], [], []])
        self.ptick(src, NOW)
        self.ptick(src, NOW + 300)
        self.assertEqual(self.asks("fake-asked.log"), 2)

    def test_native_sources_are_read_every_tick(self):
        src = [("native/whatsapp", [self.adapter])]
        for i in range(4):
            self.ptick(src, NOW + 300 * i)
        self.assertEqual(self.asks("fake-asked.log"), 4)


class SameMailTwoRoutesTest(Base):
    """#10.3: one email read by Apple Mail and by Composio Gmail is judged once."""

    def mail(self, i, source_style, subject="Invoice 4411", at=None, sender="Dana <dana@acme.io>"):
        frm = sender if source_style == "composio" else "dana@acme.io"
        return {"id": "%s-%d" % (source_style, i), "thread": "%s/t%d" % (source_style, i),
                "thread_name": subject, "at": at or NOW - 300, "kind": "mail" if source_style == "native" else "msg",
                "from": {"id": frm, "name": "Dana", "me": False}, "to_me": True, "group": False,
                "text": "Please pay the invoice by Friday, $4,200"}

    def test_the_second_route_is_kept_for_context_and_never_judged(self):
        self.set_batches([[self.mail(1, "native")], [self.mail(1, "composio", subject="Re: Invoice 4411")]])
        self.s.tick(
            call=self.answering({"situation": None}), now=NOW, consent=lambda n: True,
            sources=[("native/mail", self.adapter), ("composio/gmail", self.adapter)])
        events = [e for e in self.monitor() if e.get("event") == "same-mail-skipped"]
        self.assertEqual([(e["source"], e["count"]) for e in events], [("composio/gmail", 1)])
        self.assertTrue(os.path.exists(self.s.feed_path("composio/gmail")), "kept in its own feed")

    def test_one_route_never_skips_its_own_second_mail(self):
        a, b = self.mail(1, "native"), self.mail(2, "native", at=NOW - 200)
        self.assertEqual(self.s.other_route_had([dict(a, source="native/mail")], "native/mail", NOW), [])
        self.assertEqual(self.s.other_route_had([dict(b, source="native/mail")], "native/mail", NOW), [])

    def test_different_mail_or_far_apart_is_not_the_same(self):
        seen = self.s.other_route_had
        seen([dict(self.mail(1, "native"), source="native/mail")], "native/mail", NOW)
        other_subject = dict(self.mail(2, "composio", subject="Lunch?"), source="composio/gmail")
        later = dict(self.mail(3, "composio", at=NOW - 300 + 3600), source="composio/gmail")
        other_sender = dict(self.mail(4, "composio", sender="Sam <sam@acme.io>"), source="composio/gmail")
        self.assertEqual(seen([other_subject, later, other_sender], "composio/gmail", NOW), [])

    CODE = ("Your verification code\n\nHi Dana,\n\nYour verification code is {code}. It expires in 10 "
            "minutes. If you didn't request this code, you can safely ignore this email. Someone else might "
            "have typed your email address by mistake.\n\nThanks,\nThe Acme Accounts team")
    ALERT = ("Security alert\n\nA new sign-in on Mac\n\n{addr}\n\nWe noticed a new sign-in to your Google "
             "Account on a Mac device. If this was you, you don't need to do anything. If not, we'll help you "
             "secure your account. Check activity at https://myaccount.google.com/notifications?x=1")

    def test_two_accounts_with_the_same_alert_are_two_mails(self):
        """Realistic length (re-review: a 3-word fixture could not fail)."""
        for fill in ({"code": "482913"}, {"code": "118244"}), ({"addr": "dana@acme.io"}, {"addr": "dana.p@gmail.com"}):
            tmpl = self.CODE if "code" in fill[0] else self.ALERT
            self.tearDown(); self.setUp()
            first = dict(self.mail(1, "native"), source="native/gmail", text=tmpl.format(**fill[0]))
            other = dict(self.mail(2, "composio"), source="composio/gmail", text=tmpl.format(**fill[1]))
            self.s.other_route_had([first], "native/gmail", NOW)
            self.assertEqual(self.s.other_route_had([other], "composio/gmail", NOW), [], fill)

    def test_one_alert_read_by_two_readers_is_one_mail(self):
        body = self.CODE.format(code="482913")
        apple = dict(self.mail(1, "native"), source="native/mail", text=body)
        # Composio: subject then the text, with a tracking link, no sign-off.
        comp = dict(self.mail(2, "composio"), source="composio/gmail",
                    text="Your verification code — " + body.split("\n\n", 1)[1].rsplit("\n\nThanks", 1)[0]
                    + " https://t.acme.io/c/77123")
        snippet = dict(self.mail(3, "composio"), source="composio/outlook", text=body[:90])
        self.s.other_route_had([apple], "native/mail", NOW)
        self.assertEqual(len(self.s.other_route_had([comp], "composio/gmail", NOW)), 1)
        self.assertEqual(len(self.s.other_route_had([snippet], "composio/outlook", NOW)), 1)

    def test_a_copy_on_a_tracked_thread_is_let_through(self):
        self.s.other_route_had([dict(self.mail(1, "native"), source="native/mail")], "native/mail", NOW)
        copy = dict(self.mail(1, "composio"), source="composio/gmail")
        self.assertEqual(self.s.other_route_had([copy], "composio/gmail", NOW,
                                                keep=lambda it: it["thread"] == "composio/t1"), [])

    def test_a_newsletter_service_is_not_a_mailbox(self):
        self.assertIsNone(self.s.mail_key(dict(self.mail(1, "composio"), source="composio/mailchimp")))

    def test_chats_are_never_compared(self):
        chat = {"source": "native/whatsapp", "kind": "msg", "thread_name": "Invoice 4411", "at": NOW,
                "from": {"id": "1555@s.whatsapp.net", "me": False}}
        self.assertIsNone(self.s.mail_key(chat))

    def test_forgetting_a_route_forgets_what_it_saw(self):
        self.s.other_route_had([dict(self.mail(1, "composio"), source="composio/gmail")], "composio/gmail", NOW)
        self.s.forget_source("composio/gmail")
        with open(self.s.mail_seen_path()) as f:
            self.assertEqual(json.load(f), {})


if __name__ == "__main__":
    unittest.main()

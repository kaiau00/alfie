"""The Mac's native `items` readers (connectors/*-items.py): each gives the
situations engine the whole text of new messages since a cursor, and reads
nothing it does not recognise.

Falsifiers: read `text` alone (every attributedBody-only iMessage vanishes),
move the cursor to the store's top instead of the last row read (a burst
past LIMIT is skipped), read reactions as messages, or print items on the
first look (years of history arrive as new) — each turns a test red.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CONN = os.path.normpath(os.path.join(HERE, "..", "..", "connectors"))
APPLE = 978307200


def typedstream(text):
    """An archived NSAttributedString as Messages writes it: the class
    chain, `NSString`, the "\\x01\\x94\\x84\\x01+" header, the length, the UTF-8."""
    raw = text.encode("utf-8")
    n = len(raw)
    if n < 0x80:
        length = bytes([n])
    elif n < 0x10000:
        length = b"\x81" + n.to_bytes(2, "little")
    else:
        length = b"\x82" + n.to_bytes(4, "little")
    return (b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00"
            b"\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
            + length + raw + b"\x86\x84\x02iI\x01\x05\x92\x84\x84\x84\x0cNSDictionary\x00")


def chat_db(path, rows):
    con = sqlite3.connect(path)
    con.executescript("""
        create table handle (ROWID integer primary key, id text);
        create table chat (ROWID integer primary key, guid text, display_name text, style integer,
                           chat_identifier text);
        create table message (ROWID integer primary key, guid text, text text, attributedBody blob,
                              handle_id integer, date integer, is_from_me integer,
                              associated_message_type integer default 0, item_type integer default 0);
        create table chat_message_join (chat_id integer, message_id integer);
        insert into handle values (1, '+972541234567'), (2, 'dana@example.com');
        insert into chat values (1, 'iMessage;-;+972541234567', '', 45, '+972541234567'),
                                (2, 'iMessage;+;chat999', 'Family', 43, 'chat999');
    """)
    for r in rows:
        con.execute("insert into message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me,"
                    " associated_message_type, item_type) values (?,?,?,?,?,?,?,?,?)",
                    (r["rowid"], "G%d" % r["rowid"], r.get("text"), r.get("body"), r.get("handle", 1),
                     int((r.get("at", 1790000000) - APPLE) * 1e9), 1 if r.get("me") else 0,
                     r.get("assoc", 0), r.get("item_type", 0)))
        con.execute("insert into chat_message_join values (?, ?)", (r.get("chat", 1), r["rowid"]))
    con.commit()
    con.close()


def run(script, *args, env=None):
    p = subprocess.run([sys.executable, os.path.join(CONN, script)] + list(args),
                       capture_output=True, text=True, env=dict(os.environ, **(env or {})))
    lines = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    return p.returncode, lines, p.stderr


class IMessageItemsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = os.path.join(self.tmp, "chat.db")
        long = "Can you send the invoice by Friday? " * 10
        chat_db(self.db, [
            {"rowid": 1, "text": "old one"},
            {"rowid": 2, "text": None, "body": typedstream("Where is the deposit?")},
            {"rowid": 3, "text": None, "body": typedstream(long)},
            {"rowid": 4, "text": "Loved “Where is the deposit?”", "assoc": 2000},
            {"rowid": 5, "text": "Coming at 7", "me": True},
            {"rowid": 6, "text": "Dinner Friday?", "chat": 2, "handle": 2},
            {"rowid": 7, "text": "￼"},
        ])
        with open(os.path.join(self.tmp, "contacts.json"), "w") as f:
            json.dump({"541234567": "Dana Cohen"}, f)
        self.env = {"MOE_HOME": self.tmp}

    def test_first_look_only_sets_the_cursor(self):
        rc, lines, _ = run("imessage-items.py", self.db, "--since", "", env=self.env)
        self.assertEqual((rc, lines), (0, [{"cursor": "7"}]))

    def test_whole_text_from_attributed_body_and_no_reactions(self):
        rc, lines, err = run("imessage-items.py", self.db, "--since", "1", env=self.env)
        self.assertEqual(rc, 0, err)
        items, cursor = lines[:-1], lines[-1]
        self.assertEqual(cursor, {"cursor": "7"})
        texts = [it["text"] for it in items]
        self.assertEqual(texts[0], "Where is the deposit?")
        self.assertEqual(len(texts[1]), len(("Can you send the invoice by Friday? " * 10).strip()))
        self.assertNotIn("Loved", " ".join(texts))
        self.assertEqual(len(items), 4)          # 2, 3, 5, 6 — not 4 (reaction) or 7 (attachment)
        one = items[0]
        self.assertEqual(one["thread_name"], "Dana Cohen")
        self.assertTrue(one["to_me"] and not one["group"] and not one["from"]["me"])
        self.assertEqual(one["at"], 1790000000)
        mine = items[2]
        self.assertTrue(mine["from"]["me"])
        grp = items[3]
        self.assertTrue(grp["group"] and not grp["to_me"])
        self.assertEqual(grp["thread_name"], "Family")

    def test_an_unfamiliar_layout_reads_nothing(self):
        con = sqlite3.connect(self.db)
        con.execute("alter table message rename column attributedBody to body_v2")
        con.commit()
        con.close()
        rc, lines, err = run("imessage-items.py", self.db, "--since", "1", env=self.env)
        self.assertEqual((rc, lines), (1, []))
        self.assertIn("unfamiliar Messages layout", err)

    def test_long_bodies_decode(self):
        for n in (127, 128, 300, 70000):
            text = "x" * n
            import importlib.util
            spec = importlib.util.spec_from_file_location("imi", os.path.join(CONN, "imessage-items.py"))
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            self.assertEqual(m.body_text(typedstream(text)), text, n)


class FakeTelegram(object):
    """Telethon's shape: iter_dialogs pinned first then newest activity;
    iter_messages(min_id=…/offset_date=…, reverse=True) oldest first."""

    def __init__(self, dialogs, msgs):
        self.dialogs, self.msgs = dialogs, msgs

    def iter_dialogs(self, limit):
        order = [d for d in self.dialogs if getattr(d, "pinned", False)] + \
            sorted([d for d in self.dialogs if not getattr(d, "pinned", False)],
                   key=lambda d: d.date, reverse=True)
        return iter(order[:limit])

    def iter_messages(self, did, limit, reverse=True, min_id=None, offset_date=None):
        ms = sorted(self.msgs.get(did, []), key=lambda m: m.id)
        if min_id is not None:
            ms = [m for m in ms if m.id > min_id]
        if offset_date is not None:
            ms = [m for m in ms if m.date > offset_date]
        return iter(ms[:limit])


class TelegramItemsTest(unittest.TestCase):
    def load(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("tgc", os.path.join(CONN, "telegram.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m

    def t(self, x):
        from datetime import datetime, timezone
        return datetime.fromtimestamp(x, timezone.utc)

    def msg(self, i, at, text, sender=7, out=False, mentioned=False):
        from types import SimpleNamespace as NS
        return NS(id=i, date=self.t(at), message=text, text=text, sender_id=99 if out else sender,
                  sender=NS(first_name="Dana", last_name="Cohen", title=None), out=out, mentioned=mentioned)

    def test_whole_text_mentions_pinned_and_no_broadcasts(self):
        from types import SimpleNamespace as NS
        long = "Please confirm the delivery for Sunday, the driver needs the address. " * 8
        dialogs = [
            NS(id=5, name="Saved", date=self.t(100), is_group=False, is_channel=False, pinned=True),
            NS(id=1, name="Dana Cohen", date=self.t(1000), is_group=False, is_channel=False),
            NS(id=2, name="Building", date=self.t(990), is_group=True, is_channel=True),
            NS(id=3, name="News", date=self.t(980), is_group=False, is_channel=True),
            NS(id=4, name="Old", date=self.t(400), is_group=False, is_channel=False),
        ]
        msgs = {1: [self.msg(10, 300, "too old"), self.msg(11, 700, "ok", out=True), self.msg(12, 1000, long)],
                2: [self.msg(21, 980, "anyone home?", sender=8), self.msg(22, 990, "@izzy lift broken", sender=8,
                                                                          mentioned=True)],
                3: [self.msg(31, 980, "breaking")]}
        m = self.load()
        items, st = m.items_from(FakeTelegram(dialogs, msgs), {"t": 500}, 99, 2000)
        self.assertEqual([it["text"][:12] for it in items], ["ok", "anyone home?", "@izzy lift b", "Please confi"])
        self.assertEqual(len(items[-1]["text"]), len(long.strip()))
        self.assertTrue(items[0]["from"]["me"])
        self.assertEqual([it["to_me"] for it in items if it["group"]], [False, True])
        self.assertEqual(st["t"], 2000)
        self.assertEqual(st["d"], {"1": 12, "2": 22})

    def test_a_burst_finishes_over_the_next_looks_and_nothing_twice(self):
        from types import SimpleNamespace as NS
        dialogs = [NS(id=1, name="Dana", date=self.t(1100), is_group=False, is_channel=False)]
        msgs = {1: [self.msg(i, 1000 + i, "m%d" % i) for i in range(1, 81)]}
        m = self.load()
        fake = FakeTelegram(dialogs, msgs)
        a, st = m.items_from(fake, {"t": 900}, 99, 2000)
        self.assertEqual(len(a), 50)
        self.assertEqual(st["more"], ["1"])
        b, st = m.items_from(fake, st, 99, 3000)         # the chat has not moved since
        self.assertEqual(len(b), 30)
        self.assertEqual(st["more"], [])
        self.assertEqual({x["id"] for x in a} & {x["id"] for x in b}, set())
        c, st = m.items_from(fake, st, 99, 4000)
        self.assertEqual(c, [])

    def test_a_chat_with_more_waiting_is_kept_when_the_walk_stops_above_it(self):
        from types import SimpleNamespace as NS
        a = NS(id=1, name="A", date=self.t(1000), is_group=False, is_channel=False)
        c = NS(id=3, name="C", date=self.t(1001), is_group=False, is_channel=False)
        msgs = {1: [self.msg(i, 900 + i, "a%d" % i) for i in range(1, 61)], 3: [self.msg(500, 1001, "c")]}
        m = self.load()
        fake = FakeTelegram([a, c], msgs)
        got, st = m.items_from(fake, {"t": 800}, 99, 1001)
        self.assertEqual((len(got), st["more"]), (51, ["1"]))
        b = NS(id=2, name="B", date=self.t(1005), is_group=False, is_channel=False)
        fake.dialogs.append(b)
        msgs[2] = [self.msg(700, 1005, "b")]
        got, st = m.items_from(fake, st, 99, 1010)
        self.assertEqual(sorted(x["id"] for x in got),
                         sorted(["telegram/1/%d" % i for i in range(51, 61)] + ["telegram/2/700"]))
        self.assertEqual(st["more"], [])

    def test_a_message_in_the_same_second_as_the_last_look_is_read(self):
        from types import SimpleNamespace as NS
        d = NS(id=1, name="A", date=self.t(1001), is_group=False, is_channel=False)
        got, st = self.load().items_from(FakeTelegram([d], {1: [self.msg(5, 1001, "m5")]}),
                                         {"t": 1001.4}, 99, 1100)
        self.assertEqual([x["id"] for x in got], ["telegram/1/5"])

    def test_more_chats_moved_than_a_look_reads_are_all_read(self):
        """Third review: 50 chats moved, 40 read a look; the other 10 were
        passed over for good."""
        from types import SimpleNamespace as NS
        ds = [NS(id=i, name="c%d" % i, date=self.t(1000 + i), is_group=False, is_channel=False,
                 message=NS(id=i * 10)) for i in range(1, 51)]
        fake = FakeTelegram(ds, {i: [self.msg(i * 10, 1000 + i, "m")] for i in range(1, 51)})
        m, st, seen = self.load(), {"t": 900}, set()
        for k in range(4):
            got, st = m.items_from(fake, st, 99, 2000 + k * 300)
            seen |= {g["id"] for g in got}
        self.assertEqual(len(seen), 50)
        self.assertEqual(st["more"], [])

    def test_a_chat_with_more_waiting_below_a_quiet_chat_is_finished(self):
        from types import SimpleNamespace as NS
        a = NS(id=1, name="A", date=self.t(1000), is_group=False, is_channel=False)
        b = NS(id=2, name="B", date=self.t(1001), is_group=False, is_channel=False)
        fake = FakeTelegram([a, b], {1: [self.msg(i, 900 + i, "a") for i in range(1, 81)],
                                     2: [self.msg(500, 1001, "b")]})
        m, st, got_a = self.load(), {"t": 800}, 0
        for k in range(3):
            got, st = m.items_from(fake, st, 99, 1100 + k * 300)
            got_a += len([g for g in got if g["thread"] == "telegram/1"])
        self.assertEqual(got_a, 80)

    def test_first_look_sets_the_cursor_without_signing_in(self):
        rc, lines, _ = run("telegram.py", "items", "--since", "",
                           env={"MOE_HOME": tempfile.mkdtemp()})
        self.assertEqual(rc, 0)
        self.assertIn('"t"', lines[0]["cursor"])


class GmailItemsTest(unittest.TestCase):
    """parse_items on the bytes a UID FETCH returns."""

    def load(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gm", os.path.join(CONN, "gmail.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m

    def test_whole_body_threads_and_who(self):
        m = self.load()
        acct = {"email": "Izzy@Example.com", "label": "me"}
        hdr1 = (b"From: Dana Cohen <dana@acme.com>\r\nTo: izzy@example.com\r\n"
                b"Subject: Re: Invoice 4471\r\nDate: Tue, 23 Sep 2026 10:00:00 +0000\r\n"
                b"Content-Type: text/plain; charset=utf-8\r\n\r\n")
        body1 = (b"Hi Izzy,\r\n\r\nThe amount is wrong: we agreed $1,200 not $1,450.\r\n"
                 b"Can you fix it before Friday?\r\n\r\nOn Mon, Izzy wrote:\r\n> old\r\n")
        hdr2 = (b"From: Izzy <izzy@example.com>\r\nTo: a@x.com, b@y.com\r\n"
                b"Subject: Plans\r\nDate: Tue, 23 Sep 2026 11:00:00 +0000\r\n\r\n")
        msgs = [
            (b"7 (UID 501 X-GM-THRID 9001 BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE)] {%d}" % len(hdr1), hdr1),
            (b" BODY[TEXT]<0> {%d}" % len(body1), body1),
            b")",
            (b"8 (UID 502 X-GM-THRID 9002 BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE)] {%d}" % len(hdr2), hdr2),
            (b" BODY[TEXT]<0> {2}", b"ok"),
            b")",
        ]
        items = m.parse_items(msgs, acct)
        self.assertEqual([it["id"] for it in items], ["gmail/izzy@example.com/501", "gmail/izzy@example.com/502"])
        a, b = items
        self.assertEqual(a["thread"], "gmail/izzy@example.com/9001")
        self.assertEqual(a["thread_name"], "Invoice 4471")
        self.assertIn("we agreed $1,200 not $1,450", a["text"])
        self.assertTrue(a["text"].startswith("Re: Invoice 4471"))
        self.assertTrue(a["to_me"] and not a["from"]["me"] and a["from"]["name"] == "Dana Cohen")
        self.assertTrue(b["from"]["me"] and b["group"] and not b["to_me"])
        self.assertEqual(a["kind"], "mail")
        # The engine keeps only the new part of the reply.
        import importlib
        sys.path.insert(0, os.path.normpath(os.path.join(CONN, "..", "lib")))
        situations = importlib.import_module("situations")
        self.assertNotIn("old", situations.normalise_item(a, "native/gmail")["text"])

    def test_uid_after_the_literal_and_no_date_header(self):
        m = self.load()
        hdr = b"From: Dana <dana@acme.com>\r\nTo: izzy@example.com\r\nSubject: Rent\r\n\r\n"
        msgs = [(b'3 (INTERNALDATE "23-Sep-2026 10:00:00 +0000" BODY[HEADER.FIELDS (FROM)] {%d}' % len(hdr), hdr),
                (b" BODY[TEXT]<0> {11}", b"Pay by Fri."),
                b" UID 42 X-GM-THRID 7)"]
        items = m.parse_items(msgs, {"email": "izzy@example.com"})
        self.assertEqual([it["id"] for it in items], ["gmail/izzy@example.com/42"])
        self.assertEqual(items[0]["thread"], "gmail/izzy@example.com/7")
        self.assertEqual(items[0]["at"], 1790157600)

    def test_no_accounts_is_silent_with_a_cursor(self):
        rc, lines, _ = run("gmail.py", "items", "--since", "", env={"HOME": tempfile.mkdtemp()})
        self.assertEqual((rc, lines), (0, [{"cursor": "{}"}]))


class MailItemsTest(unittest.TestCase):
    """mail-items.py against a Mail index and .emlx files in Mail's layout."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        root = os.path.join(self.tmp, "Mail", "V10")
        os.makedirs(os.path.join(root, "MailData"))
        con = sqlite3.connect(os.path.join(root, "MailData", "Envelope Index"))
        con.executescript("""
            create table messages (ROWID integer primary key, sender integer, subject integer,
                                   summary integer, date_received integer, mailbox integer,
                                   conversation_id integer, deleted integer default 0);
            create table addresses (ROWID integer primary key, address text, comment text);
            create table subjects (ROWID integer primary key, subject text);
            create table summaries (ROWID integer primary key, summary text);
            create table mailboxes (ROWID integer primary key, url text);
            create table recipients (ROWID integer primary key, message integer, address integer,
                                     type integer, position integer);
            insert into mailboxes values (1, 'imap://ACC-1/INBOX'), (2, 'imap://ACC-1/Sent%20Messages'),
                                         (3, 'imap://ACC-1/Junk');
            insert into addresses values (1, 'dana@acme.com', 'Dana Cohen'), (2, 'izzy@example.com', 'Izzy'),
                                         (3, 'spam@x.com', 'Winner');
            insert into subjects values (1, 'Re: Invoice 4471'), (2, 'You won'), (3, 'Invoice 4471');
            insert into summaries values (1, 'short preview only');
            insert into messages values (10, 2, 3, null, 1790000000, 2, 77, 0);
            insert into messages values (11, 1, 1, 1, 1790000100, 1, 77, 0);
            insert into messages values (12, 3, 2, null, 1790000200, 3, 78, 0);
            insert into messages values (13, 1, 1, 1, 1790000300, 1, 77, 0);
            insert into recipients values (1, 11, 2, 0, 0), (2, 10, 1, 0, 0), (3, 13, 2, 0, 0);
        """)
        con.commit()
        con.close()
        msg = (b"From: Dana Cohen <dana@acme.com>\r\nTo: izzy@example.com\r\nSubject: Re: Invoice 4471\r\n"
               b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
               b"Hi Izzy,\r\nWe agreed $1,200, not $1,450. Please reissue by Friday.\r\n"
               b"\r\nOn Mon, Sep 22, 2026 at 9:00 AM Izzy <izzy@example.com> wrote:\r\n> the old one\r\n")
        d = os.path.join(root, "ACC-1", "INBOX.mbox", "STORE-UUID", "Data", "Messages")
        os.makedirs(d)
        with open(os.path.join(d, "11.emlx"), "wb") as f:
            f.write(b"%d\n" % len(msg) + msg + b"<?xml version=\"1.0\"?><plist/>")
        self.env = {"MOE_MAIL_DIR": os.path.join(self.tmp, "Mail")}

    def ident(self):
        return str(os.stat(os.path.join(self.tmp, "Mail", "V10", "MailData", "Envelope Index")).st_ino)

    def test_first_look_and_whole_bodies_inbox_and_sent_only(self):
        rc, lines, err = run("mail-items.py", "items", "--since", "", env=self.env)
        self.assertEqual((rc, lines), (0, [{"cursor": "%s:13" % self.ident()}]), err)
        rc, lines, err = run("mail-items.py", "items", "--since", "%s:9" % self.ident(), env=self.env)
        self.assertEqual(rc, 0, err)
        items, cursor = lines[:-1], lines[-1]
        self.assertEqual(cursor, {"cursor": "%s:13" % self.ident()})
        self.assertEqual([it["id"] for it in items], ["mail/10", "mail/11", "mail/13"])   # not Junk
        sent, dana, no_file = items
        self.assertTrue(sent["from"]["me"])
        self.assertIn("We agreed $1,200, not $1,450", dana["text"])
        self.assertTrue(dana["to_me"] and dana["from"]["name"] == "Dana Cohen")
        self.assertEqual(dana["thread"], "mail/77")
        self.assertEqual(dana["thread_name"], "Invoice 4471")
        self.assertIn("short preview only", no_file["text"])      # no .emlx: Mail's summary

    def test_an_unfamiliar_layout_reads_nothing(self):
        con = sqlite3.connect(os.path.join(self.tmp, "Mail", "V10", "MailData", "Envelope Index"))
        con.execute("alter table messages rename column conversation_id to thread_v2")
        con.commit()
        con.close()
        rc, lines, err = run("mail-items.py", "items", "--since", "%s:9" % self.ident(), env=self.env)
        self.assertEqual((rc, lines), (1, []))
        self.assertIn("unfamiliar Mail layout", err)

    def db(self):
        return sqlite3.connect(os.path.join(self.tmp, "Mail", "V10", "MailData", "Envelope Index"))

    def test_a_rebuilt_index_or_a_cursor_past_the_top_is_a_first_look(self):
        for cursor in ("999999:9", "%s:500" % self.ident()):
            rc, lines, _ = run("mail-items.py", "items", "--since", cursor, env=self.env)
            self.assertEqual((rc, lines), (0, [{"cursor": "%s:13" % self.ident()}]), cursor)

    def test_an_unknown_charset_is_read_not_fatal(self):
        d = os.path.join(self.tmp, "Mail", "V10", "ACC-1", "INBOX.mbox", "STORE-UUID", "Data", "Messages")
        msg = (b"From: Dana <dana@acme.com>\r\nContent-Type: text/plain; charset=unknown-8bit\r\n\r\n"
               b"Pay the 300 today please\r\n")
        with open(os.path.join(d, "11.emlx"), "wb") as f:
            f.write(b"%d\n" % len(msg) + msg)
        rc, lines, err = run("mail-items.py", "items", "--since", "%s:10" % self.ident(), env=self.env)
        self.assertEqual(rc, 0, err)
        self.assertIn("Pay the 300 today", lines[0]["text"])

    def test_folders_are_named_whole_and_localised_sent_is_sent(self):
        con = self.db()
        con.execute("update mailboxes set url = 'imap://ACC-1/Gesendet' where ROWID = 2")
        con.execute("insert into mailboxes values (4, 'imap://ACC-1/Presentations')")
        con.execute("insert into addresses values (4, 'boss@acme.com', 'Boss')")
        con.execute("insert into messages values (14, 4, 3, null, 1790000400, 4, 79, 0)")
        con.commit()
        con.close()
        rc, lines, err = run("mail-items.py", "items", "--since", "%s:9" % self.ident(), env=self.env)
        ids = [it["id"] for it in lines[:-1]]
        self.assertIn("mail/10", ids)                 # Gesendet is Sent
        self.assertNotIn("mail/14", ids)              # Presentations is neither
        self.assertTrue([it for it in lines[:-1] if it["id"] == "mail/10"][0]["from"]["me"])

    def test_a_new_message_not_downloaded_yet_holds_the_cursor(self):
        import time as _t
        con = self.db()
        con.execute("insert into messages values (15, 1, 1, 1, ?, 1, 77, 0)", (int(_t.time()) - 60,))
        con.commit()
        con.close()
        rc, lines, err = run("mail-items.py", "items", "--since", "%s:13" % self.ident(), env=self.env)
        self.assertEqual((rc, lines), (0, [{"cursor": "%s:13" % self.ident()}]), err)

    def test_a_quiet_inbox_is_connected_not_unreadable(self):
        # Every fixture message is years old: nothing in the last 24 h.
        rc, lines, err = run("mail-items.py", "pull", env=self.env)
        self.assertEqual((rc, lines), (0, []), err)

    def test_no_mail_set_up(self):
        rc, lines, err = run("mail-items.py", "items", "--since", "1",
                             env={"MOE_MAIL_DIR": os.path.join(self.tmp, "none")})
        self.assertEqual((rc, lines), (1, []))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""`imessage.sh items --since <cursor>`: new iMessages and SMS in Messages'
own store, as the situations engine's items (moe-home/lib/situations.py).

    imessage-items.py <chat.db> --since <cursor>
    imessage-items.py <chat.db> pull <hours>      (imessage.sh pull)
    imessage-items.py <chat.db> crawl <days>      (imessage.sh crawl)

The whole text of every message, not a preview. On recent macOS most
messages keep their text only in `attributedBody` (an archived
NSAttributedString) with `text` left empty; that is decoded here, or a
Messages database read with `text` alone would look almost silent.

The cursor is the message ROWID. An empty cursor is the first look: it
prints only the newest ROWID, so the engine starts from now rather than
reading years of history as if it had just arrived (MOE_ITEMS_BACKFILL_HOURS
reads that many hours back instead, for a measurement run). Reactions
("Loved …"), edits-in-place and group events are not messages and are
skipped. Read-only (`mode=ro`), with a busy timeout: Messages writes this
file all day.

**Fails closed on an unfamiliar layout**: if a column this reads is not
there (a macOS release that renamed one), it says so on stderr and exits 1,
so the engine logs an error and moves nothing — it never reads the wrong
column as text.
"""
import json
import os
import re
import sqlite3
import sys

LIMIT = 500
TEXT_CAP = 4000
#: Seconds between the Unix epoch and Apple's (2001-01-01).
APPLE_EPOCH = 978307200
NEEDED = {
    "message": {"ROWID", "guid", "text", "attributedBody", "handle_id", "date", "is_from_me",
                "associated_message_type", "item_type"},
    "handle": {"ROWID", "id"},
    "chat": {"ROWID", "guid", "display_name", "style"},
    "chat_message_join": {"chat_id", "message_id"},
}
#: What `pull` and `crawl` read (the reaction columns are used when present).
RECENT_NEEDS = {
    "message": {"ROWID", "text", "attributedBody", "handle_id", "date", "is_from_me"},
    "handle": {"ROWID", "id"},
    "chat": {"ROWID", "display_name"},
    "chat_message_join": {"chat_id", "message_id"},
}
#: chat.style for a group conversation (43); a one-to-one chat is 45.
GROUP_STYLE = 43


def names():
    try:
        with open(os.path.join(os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe"),
                               "contacts.json"), encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def handle_name(handle, table):
    """A phone number by its last nine digits (the contacts.json table the
    WhatsApp reader uses), an address as itself."""
    handle = handle or ""
    digits = re.sub(r"\D", "", handle)
    if "@" not in handle and len(digits) >= 7:
        return table.get(digits[-9:], "")
    return table.get(handle.lower(), "")


def body_text(blob):
    """The string inside an archived NSAttributedString (typedstream).

    After the class name (`NSString`, or `NSMutableString`) comes a short
    header ending in "+", then the length — one byte, or 0x81 and a 16-bit
    little-endian integer, or 0x82 and a 32-bit one (typedstream's integer
    tags) — then that many bytes of UTF-8. Anything else is "no text". """
    if not blob:
        return ""
    blob = bytes(blob)
    at = blob.find(b"NSString")
    if at < 0:
        return ""
    plus = blob.find(b"+", at + 8, at + 8 + 40)
    if plus < 0:
        return ""
    i = plus + 1
    if i >= len(blob):
        return ""
    lead = blob[i]
    if lead == 0x81:
        n, start = int.from_bytes(blob[i + 1:i + 3], "little"), i + 3
    elif lead == 0x82:
        n, start = int.from_bytes(blob[i + 1:i + 5], "little"), i + 5
    else:
        n, start = lead, i + 1
    if n <= 0 or start + n > len(blob):
        return ""
    return blob[start:start + n].decode("utf-8", "replace")


def unix_time(apple):
    """Messages stores nanoseconds since 2001 (seconds before High Sierra)."""
    if apple is None:
        return None
    apple = float(apple)
    if apple > 1e12:
        apple /= 1e9
    return apple + APPLE_EPOCH if apple > 0 else None


def layout_problem(con, needed=None):
    for table, cols in (needed or NEEDED).items():
        have = {r[1] for r in con.execute("pragma table_info(%s)" % table)}
        if not have:
            return "no %s table" % table
        missing = cols - have
        if missing:
            return "%s has no %s" % (table, ", ".join(sorted(missing)))
    return ""


def message_text(text, blob):
    """What a message says: `text`, or the string inside `attributedBody`
    when `text` is empty (most messages on recent macOS)."""
    return text if text else body_text(blob)


def recent(db, mode, window):
    """`imessage.sh pull` / `crawl`, the same lines they have always printed,
    with the text decoded as `items` does: until 2026-09-29 both read
    `m.text` alone and so never saw a message whose text lives only in
    attributedBody.

    pull  (window in hours): newest first, at most 60,
          "<when> | <me -> handle | handle -> me> | <first 220 chars>"
    crawl (window in days):  newest first, every one in the window,
          "<when> | <chat name or handle> | <me or handle> | <whole text>"
    """
    import signal
    import time
    # crawl is piped into `head -c` (newest_cap): when the cap is reached the
    # pipe closes, and this ends quietly as sqlite3 did (SIGPIPE, exit 141)
    # rather than with a traceback a caller could hand the model.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
        problem = layout_problem(con, RECENT_NEEDS)
        cols = {r[1] for r in con.execute("pragma table_info(message)")}
    except sqlite3.Error as e:
        print("unavailable: %s (Full Disk Access for Memoe?)" % e, file=sys.stderr)
        return 1
    if problem:
        print("unfamiliar Messages layout: %s" % problem, file=sys.stderr)
        return 1
    since = time.time() - window * (3600 if mode == "pull" else 86400) - APPLE_EPOCH
    # Reactions ("Loved …") and group events are not messages, where the
    # store says which rows those are.
    only_messages = " and m.associated_message_type = 0 and m.item_type = 0" \
        if {"associated_message_type", "item_type"} <= cols else ""
    # One line per message, even one that sits in two chats.
    rows = con.execute("""
        select m.date, m.is_from_me, h.id, m.text, m.attributedBody,
               (select c.display_name from chat_message_join j join chat c on c.ROWID = j.chat_id
                where j.message_id = m.ROWID order by c.ROWID limit 1)
        from message m
        left join handle h on h.ROWID = m.handle_id
        where (m.date > ? * 1000000000 or (m.date < 1000000000000 and m.date > ?))%s
        order by m.date desc""" % only_messages, (since, since))
    shown = 0
    for date, from_me, handle, text, blob, chat_name in rows:
        body = message_text(text, blob)
        if not body:
            continue
        at = unix_time(date)
        if at is None:
            continue
        when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(at))
        handle = handle or "?"
        if mode == "pull":
            who = ("me -> %s" if from_me else "%s -> me") % handle
            line = "%s | %s | %s" % (when, who, body[:220].replace("\n", " "))
        else:
            name = " ".join((chat_name or "").replace("\r", " ").split("\n")).strip() or handle
            line = "%s | %s | %s | %s" % (when, name, "me" if from_me else handle,
                                          body.replace("\n", " ").replace("\r", " "))
        sys.stdout.write(line + "\n")
        shown += 1
        if mode == "pull" and shown >= 60:
            break
    return 0


def main(argv):
    if len(argv) >= 4 and argv[2] in ("pull", "crawl"):
        try:
            window = int(argv[3])
        except ValueError:
            print("%s takes a whole number" % argv[2], file=sys.stderr)
            return 2
        return recent(argv[1], argv[2], window)
    if len(argv) < 2:
        print("usage: imessage-items.py <chat.db> --since <cursor>", file=sys.stderr)
        return 2
    db = argv[1]
    cursor = ""
    if "--since" in argv:
        i = argv.index("--since")
        cursor = argv[i + 1] if i + 1 < len(argv) else ""
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
        problem = layout_problem(con)
    except sqlite3.Error as e:
        print("unavailable: %s (Full Disk Access for Memoe?)" % e, file=sys.stderr)
        return 1
    if problem:
        print("unfamiliar Messages layout: %s" % problem, file=sys.stderr)
        return 1
    top = con.execute("select coalesce(max(ROWID), 0) from message").fetchone()[0]
    if cursor.strip().isdigit() and int(cursor) > top:
        cursor = ""       # a restored or rebuilt store: start from now, never skip
    if not cursor.strip().isdigit():
        hours = os.environ.get("MOE_ITEMS_BACKFILL_HOURS", "")
        if not hours.isdigit():
            print(json.dumps({"cursor": str(top)}))
            return 0
        import time
        since_apple = (time.time() - int(hours) * 3600 - APPLE_EPOCH) * 1e9
        start = con.execute("select coalesce(min(ROWID) - 1, ?) from message where date > ?",
                            (top, since_apple)).fetchone()[0]
    else:
        start = int(cursor)
    table = names()
    rows = con.execute("""
        select m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, h.id,
               c.guid, c.display_name, c.style, c.ROWID
        from message m
        left join handle h on h.ROWID = m.handle_id
        left join chat_message_join j on j.message_id = m.ROWID
        left join chat c on c.ROWID = j.chat_id
        where m.ROWID > ? and m.associated_message_type = 0 and m.item_type = 0
        order by m.ROWID limit ?""", (start, LIMIT)).fetchall()
    last = start
    for rowid, guid, text, body, date, from_me, handle, chat_guid, chat_name, style, chat_row in rows:
        last = max(last, rowid)
        text = (text or "").strip() or body_text(body).strip()
        # U+FFFC stands where an attachment was; alone it is not a message.
        text = text.replace("￼", "").strip()
        at = unix_time(date)
        if not text or at is None:
            continue
        group = style == GROUP_STYLE
        thread = chat_guid or ("handle:%s" % (handle or rowid))
        who_name = handle_name(handle, table)
        thread_name = (chat_name or "").strip() or (who_name if not group else "") or (handle or "")
        if from_me:
            who = {"id": "me", "name": "", "me": True}
        else:
            who = {"id": handle or "", "name": who_name, "me": False}
        print(json.dumps({
            "id": "imessage/%s" % (guid or rowid), "thread": thread, "thread_name": thread_name,
            "at": int(at), "from": who,
            # A one-to-one conversation is addressed to the owner; a group
            # only when it names them, which this store cannot say.
            "to_me": not group, "group": group, "kind": "msg",
            "text": text[:TEXT_CAP],
        }, ensure_ascii=False))
    # The cursor is the last row read, never the store's top, so a burst
    # larger than LIMIT is read over the next ticks rather than skipped.
    print(json.dumps({"cursor": str(last)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

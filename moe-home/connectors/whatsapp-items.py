#!/usr/bin/env python3
"""`whatsapp.sh items --since <cursor>`: new messages in the bridge's store,
as the situations engine's items (moe-home/lib/situations.py).

    whatsapp-items.py <messages.db> --since <cursor>

The cursor is the store's rowid. An empty cursor is the first look: it prints
only the cursor of the newest message, so the engine starts from now rather
than reading years of history as if it had just arrived
(MOE_ITEMS_BACKFILL_HOURS, set by hand for a measurement run, reads that many
hours back instead). One JSON object per line, then {"cursor": "<rowid>"}.

Read-only (`mode=ro`), with a busy timeout: the bridge writes this store all
day. Names come from ~/.moe/contacts.json, the same table name-numbers.py
uses, matched on the last nine digits.
"""
import json
import os
import re
import sqlite3
import sys

LIMIT = 500
TEXT_CAP = 2000


def names():
    try:
        with open(os.path.join(os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe"),
                               "contacts.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def number_name(jid, table):
    digits = re.sub(r"\D", "", (jid or "").split("@", 1)[0])
    return table.get(digits[-9:], "") if len(digits) >= 7 else ""


def main(argv):
    if len(argv) < 2:
        print("usage: whatsapp-items.py <db> --since <cursor>", file=sys.stderr)
        return 2
    db = argv[1]
    cursor = ""
    if "--since" in argv:
        i = argv.index("--since")
        cursor = argv[i + 1] if i + 1 < len(argv) else ""
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
    top = con.execute("select coalesce(max(rowid), 0) from messages").fetchone()[0]
    if not cursor.strip().isdigit():
        hours = os.environ.get("MOE_ITEMS_BACKFILL_HOURS", "")
        if not hours.isdigit():
            print(json.dumps({"cursor": str(top)}))
            return 0
        start = con.execute(
            "select coalesce(min(rowid) - 1, ?) from messages where timestamp > datetime('now', ?)",
            (top, "-%d hours" % int(hours))).fetchone()[0]
    else:
        start = int(cursor)
    table = names()
    rows = con.execute("""
        select m.rowid, m.id, m.chat_jid, m.sender, m.content, strftime('%s', m.timestamp),
               m.is_from_me, c.name
        from messages m left join chats c on c.jid = m.chat_jid
        where m.rowid > ? and m.content is not null and m.content != ''
        order by m.rowid limit ?""", (start, LIMIT)).fetchall()
    last = start
    for rowid, mid, chat, sender, content, at, from_me, chat_name in rows:
        last = rowid
        if not at:
            # No time on the row: it cannot be placed in a conversation, and
            # stamped 0 it would read as 1970. Passed over; the cursor moves on.
            continue
        group = (chat or "").endswith("@g.us")
        thread_name = (chat_name or "") or number_name(chat, table) or (chat or "").split("@", 1)[0]
        if from_me:
            who = {"id": "me", "name": "", "me": True}
        elif group:
            who = {"id": sender or "", "name": number_name(sender, table), "me": False}
        else:
            who = {"id": chat or "", "name": thread_name, "me": False}
        print(json.dumps({
            "id": "%s/%s" % (chat, mid), "thread": chat, "thread_name": thread_name,
            "at": int(at), "from": who,
            # A one-to-one chat is addressed to the owner; a group only
            # when it names them, which a store without mentions cannot say.
            "to_me": not group, "group": group, "kind": "msg",
            "text": (content or "")[:TEXT_CAP],
        }, ensure_ascii=False))
    # Rows past the limit are read next tick; the cursor is the last one read,
    # never the store's top, so a burst larger than LIMIT is not skipped.
    print(json.dumps({"cursor": str(last)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

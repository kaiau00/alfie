#!/usr/bin/env python3
"""Apple Mail on this Mac — every account set up in Mail.app — read from
Mail's own index and message files. Read-only. Needs Full Disk Access for
Memoe.app (the same as Messages).

    mail-items.py status
    mail-items.py pull                      the last day's mail, one line each
    mail-items.py items --since <cursor>    the situations engine's feed

`items` gives the WHOLE text of each new message (the engine trims quoted
replies and signatures), read from the message's `.emlx` file; Mail's own
summary stands in only when the file is not on disk (a message Mail has not
downloaded). Inbox and Sent only — Junk, Trash, Drafts and archive folders
are not conversations waiting on anyone — and Sent is how the owner's own
replies are known. The owner is whoever sends from the Sent mailboxes.

The cursor is the index's message ROWID. An empty cursor is the first look:
it prints only the newest ROWID, so the engine starts from now.

**Fails closed on an unfamiliar layout**: Apple does not document this
index. If a table or column this reads is missing (a macOS release that
changed it), it says so on stderr and exits 1, so the engine logs an error
and moves nothing — it never reads the wrong column as mail.
"""
import email as emaillib
import glob
import json
import os
import re
import sqlite3
import sys
import time
from email.header import decode_header as _dh
from email.utils import getaddresses

LIMIT = 100
TEXT_CAP = 4000
EMLX_READ_CAP = 400_000
NEEDED = {
    "messages": {"ROWID", "sender", "subject", "date_received", "mailbox", "conversation_id", "deleted"},
    "addresses": {"ROWID", "address", "comment"},
    "subjects": {"ROWID", "subject"},
    "mailboxes": {"ROWID", "url"},
    "recipients": {"message", "address", "type"},
}
_SKIP_BOX = re.compile(r"(junk|spam|trash|deleted|drafts|archive|outbox|notes)", re.I)
#: Sent folders by their whole name, in the languages Mail and the big
#: providers use; "Presentations" is not a Sent folder.
_SENT_NAMES = {
    "sent", "sent messages", "sent items", "sent mail", "[gmail]/sent mail", "gesendet",
    "gesendete objekte", "gesendete elemente", "enviados", "elementos enviados", "envoyés",
    "éléments envoyés", "messages envoyés", "inviati", "posta inviata", "verzonden",
    "verzonden items", "skickat", "skickade objekt", "sendt", "sendte elementer", "lähetetyt",
    "wysłane", "odeslané", "отправленные", "נשלח", "דואר יוצא", "פריטים שנשלחו", "送信済み",
    "已发送", "보낸편지함", "enviadas", "itens enviados",
}
_RE_PREFIX = re.compile(r"^\s*((re|fwd?|aw|wg|tr)\s*:\s*)+", re.I)


def mail_root():
    base = os.environ.get("MOE_MAIL_DIR") or os.path.expanduser("~/Library/Mail")
    versions = sorted(glob.glob(os.path.join(base, "V[0-9]*")),
                      key=lambda p: int(re.sub(r"\D", "", os.path.basename(p)) or 0))
    return versions[-1] if versions else ""


def index_path(root):
    return os.path.join(root, "MailData", "Envelope Index") if root else ""


def connect(path):
    return sqlite3.connect("file:%s?mode=ro" % path.replace(" ", "%20"), uri=True, timeout=3)


def layout_problem(con):
    for table, cols in NEEDED.items():
        have = {r[1] for r in con.execute("pragma table_info(%s)" % table)}
        if not have:
            return "no %s table" % table
        missing = cols - have
        if missing:
            return "%s has no %s" % (table, ", ".join(sorted(missing)))
    return ""


def box_kind(url):
    """"inbox", "sent", or "" for every mailbox that is not read."""
    name = (url or "").rstrip("/").rsplit("/", 1)[-1]
    from urllib.parse import unquote
    name = unquote(name)
    if name.strip().lower() in _SENT_NAMES:
        return "sent"
    if _SKIP_BOX.search(name):
        return ""
    return "inbox" if name.upper() == "INBOX" else ""


def emlx_path(root, url, rowid):
    """A message's file: <root>/<account>/<box>.mbox/…/Messages/<ROWID>.emlx
    (or .partial.emlx). Searched under the mailbox's own directory rather
    than computed, because the directory scheme under it has changed across
    releases."""
    from urllib.parse import unquote, urlparse
    u = urlparse(url or "")
    parts = [unquote(p) for p in (u.netloc + u.path).split("/") if p]
    if len(parts) < 2:
        return ""
    box = os.path.join(root, parts[0], *[p + ".mbox" for p in parts[1:]])
    # Mail's own scheme first: the digits of ROWID // 1000, reversed, as
    # directories under each store's Data (123456 → Data/3/2/1/Messages).
    digits = list(str(rowid // 1000)) if rowid >= 1000 else []
    sub = os.path.join("Data", *reversed(digits), "Messages") if digits else os.path.join("Data", "Messages")
    for name in ("%d.emlx" % rowid, "%d.partial.emlx" % rowid):
        hits = glob.glob(os.path.join(glob.escape(box), "*", sub, name))
        if hits:
            return hits[0]
    # An older layout kept the files directly under the mailbox. No recursive
    # search: on a large mailbox a hundred of them outlast the engine's time
    # for one read, and a timed-out read is repeated forever.
    hits = glob.glob(os.path.join(glob.escape(box), "Messages", "%d.emlx" % rowid))
    if hits:
        return hits[0]
    return ""


def emlx_text(path):
    """The text of an .emlx: a byte count on the first line, then the
    RFC 822 message, then Mail's plist."""
    try:
        with open(path, "rb") as f:
            data = f.read(EMLX_READ_CAP)
    except OSError:
        return ""
    nl = data.find(b"\n")
    try:
        n = int(data[:nl].strip())
        raw = data[nl + 1:nl + 1 + n]
    except ValueError:
        raw = data
    msg = emaillib.message_from_bytes(raw)
    parts = list(msg.walk()) if msg.is_multipart() else [msg]
    plain = [p for p in parts if p.get_content_type() == "text/plain"]
    html = [p for p in parts if p.get_content_type() == "text/html"]
    part = (plain or html or [None])[0]
    if part is None:
        return ""
    payload = part.get_payload(decode=True) or b""
    try:
        text = payload.decode(part.get_content_charset() or "utf-8", "replace")
    except LookupError:          # "unknown-8bit" and friends
        text = payload.decode("utf-8", "replace")
    if part.get_content_type() == "text/html":
        text = re.sub(r"(?is)<(script|style).*?</\1>", " ", text)
        text = re.sub(r"(?i)<br\s*/?>|</p>|</div>", "\n", text)
        text = re.sub(r"<[^>]{0,400}>", " ", text)
        import html as htmllib
        text = htmllib.unescape(text)
    lines = [" ".join(l.split()) for l in text.replace("\r\n", "\n").split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def decoded(value):
    try:
        return "".join(t.decode(e or "utf-8", "replace") if isinstance(t, bytes) else t
                       for t, e in _dh(value or "")).strip()
    except Exception:  # noqa: BLE001
        return value or ""


def my_addresses(con):
    """The owner's addresses: whoever sends from a Sent mailbox, and — for a
    Sent folder this does not recognise — the address most of the inbox is
    sent to (at least a third of recent inbox mail)."""
    rows = con.execute("""select distinct a.address, b.url from messages m
                          join addresses a on a.ROWID = m.sender
                          join mailboxes b on b.ROWID = m.mailbox""").fetchall()
    mine = {(a or "").lower() for a, url in rows if box_kind(url) == "sent" and a}
    recent = con.execute("""select m.ROWID, b.url from messages m join mailboxes b on b.ROWID = m.mailbox
                            order by m.ROWID desc limit 2000""").fetchall()
    inbox = [r for r, url in recent if box_kind(url) == "inbox"]
    if inbox:
        counts = {}
        for (addr,) in con.execute(
                """select a.address from recipients r join addresses a on a.ROWID = r.address
                   where r.type in (0, 1) and r.message in (%s)""" % ",".join("?" * len(inbox)), inbox):
            counts[(addr or "").lower()] = counts.get((addr or "").lower(), 0) + 1
        for addr, n in counts.items():
            if addr and n * 3 >= len(inbox):
                mine.add(addr)
    return mine


def items(con, root, since, mine_fn):
    has_summary = bool({r[1] for r in con.execute("pragma table_info(messages)")} & {"summary"}) and \
        bool(list(con.execute("pragma table_info(summaries)")))
    summary_sql = ", (select s.summary from summaries s where s.ROWID = m.summary)" if has_summary else ", null"
    rows = con.execute("""
        select m.ROWID, a.address, a.comment, sj.subject, m.date_received, b.url, m.conversation_id%s
        from messages m
        left join addresses a on a.ROWID = m.sender
        left join subjects sj on sj.ROWID = m.subject
        left join mailboxes b on b.ROWID = m.mailbox
        where m.ROWID > ? and coalesce(m.deleted, 0) = 0
        order by m.ROWID limit ?""" % summary_sql, (since, LIMIT)).fetchall()
    out, last = [], since
    mine = mine_fn() if rows else set()     # only worked out when there is mail to read
    for rowid, addr, comment, subject, received, url, conv, summary in rows:
        kind = box_kind(url)
        if not kind or not received:
            last = max(last, rowid)
            continue
        try:
            item, ready = one_item(con, root, rowid, addr, comment, subject, received, url, conv, summary, mine)
        except Exception as e:  # noqa: BLE001 — one bad message is skipped, not the feed
            print("mail: message %d skipped: %s" % (rowid, type(e).__name__), file=sys.stderr)
            last = max(last, rowid)
            continue
        if not ready:
            # Indexed but not downloaded yet, and new: stop here, so the next
            # look reads it whole rather than as a subject line.
            break
        last = max(last, rowid)
        out.append(item)
    return out, last


PENDING_BODY_S = 15 * 60


def one_item(con, root, rowid, addr, comment, subject, received, url, conv, summary, mine):
    """(item, ready). Not ready: a message under PENDING_BODY_S old whose
    file is not on disk yet."""
    kind = box_kind(url)
    rcpt = con.execute("""select a.address from recipients r join addresses a on a.ROWID = r.address
                          where r.message = ? and r.type in (0, 1)""", (rowid,)).fetchall()
    recipients = [(x or "").lower() for (x,) in rcpt]
    subject = decoded(subject) or "(no subject)"
    path = emlx_path(root, url, rowid)
    if not path and time.time() - received < PENDING_BODY_S:
        return None, False
    body = emlx_text(path) if path else ""
    body = body or " ".join((summary or "").split())
    from_me = (addr or "").lower() in mine or kind == "sent"
    topic = _RE_PREFIX.sub("", subject).strip()
    return ({
        "id": "mail/%d" % rowid,
        "thread": "mail/%s" % (conv if conv else topic.lower()),
        "thread_name": topic[:120],
        "at": int(received),
        "from": {"id": "me" if from_me else (addr or "").lower(),
                 "name": "" if from_me else decoded(comment), "me": from_me},
        "to_me": bool(mine & set(recipients)),
        "group": len(set(recipients) - mine) > 1,
        "kind": "mail",
        "text": (subject if not body else "%s\n\n%s" % (subject, body))[:TEXT_CAP],
    }, True)


def open_index():
    base = os.environ.get("MOE_MAIL_DIR") or os.path.expanduser("~/Library/Mail")
    try:
        os.listdir(base)
    except PermissionError:
        print("needs-setup: grant Full Disk Access to Memoe.app in System Settings › Privacy & Security",
              file=sys.stderr)
        return None, None
    except OSError:
        pass
    root = mail_root()
    path = index_path(root)
    if not path or not os.path.exists(path):
        print("unavailable: no Mail data on this Mac (is Mail.app set up?)", file=sys.stderr)
        return None, None
    try:
        con = connect(path)
        problem = layout_problem(con)
    except sqlite3.Error as e:
        print("needs-setup: grant Full Disk Access to Memoe.app (%s)" % e, file=sys.stderr)
        return None, None
    if problem:
        print("unfamiliar Mail layout: %s" % problem, file=sys.stderr)
        return None, None
    return con, root


def main(argv):
    verb = argv[1] if len(argv) > 1 else "status"
    if verb == "status":
        con, _ = open_index()
        if con is None:
            return 1
        print("ok: reading Mail on this Mac")
        return 0
    if verb == "pull":
        con, root = open_index()
        if con is None:
            return 1
        rows = con.execute("""
            select m.ROWID, a.address, a.comment, sj.subject, m.date_received, b.url
            from messages m left join addresses a on a.ROWID = m.sender
            left join subjects sj on sj.ROWID = m.subject left join mailboxes b on b.ROWID = m.mailbox
            where m.date_received > ? and coalesce(m.deleted, 0) = 0
            order by m.date_received desc limit 40""", (time.time() - 86400,)).fetchall()
        shown = 0
        for _r, addr, comment, subject, received, url in rows:
            if box_kind(url) != "inbox":
                continue
            when = time.strftime("%d %b %H:%M", time.localtime(received))
            print("- %s | %s | %s" % (when, (decoded(comment) or addr or "?")[:60], decoded(subject)[:90]))
            shown += 1
        # A quiet inbox is an answer, not a failure: exit 0 with nothing
        # printed is sync.sh's "connected, nothing new". Exiting 1 here read
        # as "could not be read" and marked Mail disconnected every day the
        # inbox had no mail in 24 h (905 false alarms on the owner's Mac).
        return 0
    if verb == "items":
        cursor = ""
        if "--since" in argv:
            i = argv.index("--since")
            cursor = argv[i + 1] if i + 1 < len(argv) else ""
        con, root = open_index()
        if con is None:
            return 1
        # The cursor names the index it counts in ("<inode>:<rowid>"): a
        # rebuilt index or a new V* directory starts its ROWIDs again, and a
        # cursor from the old one would skip every new message until the new
        # ROWIDs caught up. A different index is a first look.
        ident = str(os.stat(index_path(root)).st_ino)
        top = con.execute("select coalesce(max(ROWID), 0) from messages").fetchone()[0]
        held, _, row = cursor.partition(":")
        if held != ident or not row.isdigit() or int(row) > top:
            print(json.dumps({"cursor": "%s:%d" % (ident, top)}))
            return 0
        got, last = items(con, root, int(row), lambda: my_addresses(con))
        for it in got:
            print(json.dumps(it, ensure_ascii=False))
        print(json.dumps({"cursor": "%s:%d" % (ident, last)}))
        return 0
    print("usage: mail.sh [status|pull|items --since CURSOR]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

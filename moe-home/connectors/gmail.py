#!/usr/bin/env python3
"""Gmail over IMAP and SMTP — as many accounts as you like (personal, work…).

Why IMAP/SMTP and not the Gmail API: the API route means creating a Google
Cloud project, an OAuth client, and consent screens, and while that app sits
in "Testing" Google expires the refresh token every 7 days — you would be
re-authorising your own assistant every week forever. An app password is one
paste, never expires, and is revocable from the same page. (CONNECTORS.md
records why the OAuth connector was built and then dropped.)

Passwords live in the macOS Keychain, never in a file, and never on argv.
Reading is read-only: mailboxes are opened with readonly=True.

  gmail.py status
  gmail.py pull
  gmail.py crawl [--since DAYS] [--max-bytes N]
  gmail.py send            ← the message arrives as JSON on stdin
  gmail.py accounts        label<TAB>address, one per connected mailbox

`send` cannot send anything without a human clicking Send in a real macOS
dialog: it calls tools/confirm.sh itself, for every caller, before it opens
a socket. See "Sending" below and connectors/gmail-send-patterns.md.

crawl is the learn-me pass (learn.sh): headers plus the first ~1,500 bytes of
each message's text, INBOX and Sent Mail, batched 50 to a round trip and
partial-fetched (BODY.PEEK[TEXT]<0.N>) so the mailbox never sends whole
attachments. That keeps 90 days to a few dozen round trips even on a busy
account. Sent Mail is read because how the user writes is half the point.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta

MOE = os.path.expanduser("~/.moe")
ACCOUNTS_FILE = os.path.join(MOE, "connectors", "gmail-accounts.json")
KEYCHAIN_SERVICE = "moe-gmail"
SINCE_HOURS = int(os.environ.get("MOE_SINCE_HOURS", "24"))
MAX_PER_ACCOUNT = 15

# Outgoing mail. 465 is implicit TLS: the socket is encrypted before a single
# byte of SMTP is spoken. 587 + STARTTLS begins in the clear and can be
# stripped by anything on the path, so it is not offered here.
SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 465
SEND_TIMEOUT = 30
# The dialog waits for a person. Long enough to read a message and think;
# short enough that a forgotten dialog does not pin a process forever.
CONFIRM_TIMEOUT = 600


def load_accounts():
    try:
        with open(ACCOUNTS_FILE) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []
    out = []
    for a in data:
        if not isinstance(a, dict):
            continue
        addr = a.get("email")
        if not isinstance(addr, str) or not addr:
            continue
        # A hand-edited or corrupted file must read as "no mailbox", never as
        # a traceback in the middle of a sync.
        try:
            port = int(a.get("smtp_port", SMTP_PORT))
        except (TypeError, ValueError):
            port = SMTP_PORT
        out.append({"label": a.get("label") if isinstance(a.get("label"), str) else addr.split("@")[0],
                    "email": addr,
                    "host": a.get("host") if isinstance(a.get("host"), str) else "imap.gmail.com",
                    # Outgoing is a separate host from incoming. Read from
                    # the same file as `host` so an account that is Gmail
                    # by app password but not by hostname still works.
                    "smtp_host": a.get("smtp_host") if isinstance(a.get("smtp_host"), str) else SMTP_HOST,
                    "smtp_port": port})
    return out


def keychain_password(email):
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
             "-a", email, "-w"],
            capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except (subprocess.SubprocessError, OSError):
        return None


def decode_header(raw):
    from email.header import decode_header as dh
    try:
        parts = dh(raw or "")
    except Exception:
        return raw or ""
    out = []
    for text, enc in parts:
        if isinstance(text, bytes):
            try:
                out.append(text.decode(enc or "utf-8", errors="replace"))
            except LookupError:
                out.append(text.decode("utf-8", errors="replace"))
        else:
            out.append(text)
    return "".join(out).replace("\n", " ").strip()


def fetch(account):
    """Return (lines, error). Never raises."""
    import imaplib
    import email as emaillib

    pw = keychain_password(account["email"])
    if not pw:
        return [], "no app password in Keychain"

    lines = []
    conn = None
    try:
        conn = imaplib.IMAP4_SSL(account["host"], timeout=25)
        conn.login(account["email"], pw)
        conn.select("INBOX", readonly=True)

        # IMAP SINCE is date-granular, so this is "since that whole day
        # began" — up to 24h wider than SINCE_HOURS suggests. The caller's
        # heading says "recent" rather than an exact window for that reason.
        since = (datetime.now() - timedelta(hours=SINCE_HOURS)).strftime("%d-%b-%Y")
        typ, data = conn.search(None, f'(SINCE {since})')
        if typ != "OK":
            return [], "search failed"

        ids = data[0].split()[-MAX_PER_ACCOUNT:]
        if not ids:
            return [], None

        # One round trip for all of them.
        # FLAGS *before* the BODY literal. imaplib splits a response at the
        # literal: anything after it lands in a separate, non-tuple element
        # that the loop below skips — so with FLAGS last, "\\Seen" is never
        # found and every single message reports as unread.
        typ, msgs = conn.fetch(b",".join(ids),
                               "(FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        if typ != "OK":
            return [], "fetch failed"

        for item in msgs:
            if not isinstance(item, tuple) or len(item) < 2:
                continue
            meta = item[0].decode("utf-8", "replace") if isinstance(item[0], bytes) else str(item[0])
            unread = "\\Seen" not in meta
            hdr = emaillib.message_from_bytes(item[1])
            sender = decode_header(hdr.get("From"))
            subject = decode_header(hdr.get("Subject")) or "(no subject)"
            when = decode_header(hdr.get("Date"))[:22]
            flag = "UNREAD" if unread else "read"
            lines.append(f"{when} | {flag} | {sender[:60]} | {subject[:90]}")

        lines.reverse()
        return lines, None

    except Exception as e:  # imaplib raises a zoo of things; none should kill sync
        return [], f"{type(e).__name__}: {e}"
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
            try:
                conn.logout()
            except Exception:
                pass


def crawl_args(argv):
    """[--since DAYS] [--max-bytes N] → (days, max_bytes); exits 2 on junk."""
    days, max_bytes = 90, int(os.environ.get("MOE_CRAWL_MAX_BYTES", "400000"))
    i = 0
    while i < len(argv):
        opt, val = argv[i], argv[i + 1] if i + 1 < len(argv) else ""
        if opt not in ("--since", "--max-bytes") or not val.isdigit():
            print("crawl: usage: crawl [--since DAYS] [--max-bytes N]", file=sys.stderr)
            sys.exit(2)
        if opt == "--since":
            days = int(val)
        else:
            max_bytes = int(val)
        i += 2
    return days, max_bytes


# imaplib sends mailbox names verbatim, so a name with a space must carry
# its own quotes or the server reads `EXAMINE [Gmail]/Sent Mail` as two
# arguments and answers BAD — and Sent Mail, the half that shows how the
# user writes, silently never gets crawled.
CRAWL_FOLDERS = ("INBOX", '"[Gmail]/Sent Mail"')
CRAWL_BATCH = 50
CRAWL_BODY_BYTES = 1500
# Content-Type and -Transfer-Encoding ride along with the four headers we
# show, so a single-part base64 or quoted-printable body (common: Apple
# Mail, most phones) can be decoded instead of digested as gibberish.
CRAWL_HEADERS = "FROM TO SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING"
# A FETCH response for message N opens with "N (" in the meta of its first
# literal; the meta of every later literal of the same message starts with
# a space instead. That number, not the order of arrival, is what pairs a
# header with its text.
SEQ_RE = re.compile(rb"^\s*(\d+)\s*\(")


def _decoded_payload(part):
    """One MIME part → text, tolerant of a body cut mid-encoding by the
    partial fetch (base64 is trimmed to whole quads, qp just stops)."""
    import base64
    import quopri
    cte = str(part.get("Content-Transfer-Encoding", "")).strip().lower()
    raw = part.get_payload(decode=False)
    if not isinstance(raw, str):
        return ""
    data = raw.encode("utf-8", "surrogateescape")
    if cte == "base64":
        clean = re.sub(rb"[^A-Za-z0-9+/]", b"", data)
        try:
            data = base64.b64decode(clean[:len(clean) // 4 * 4])
        except (ValueError, TypeError):
            pass
    elif cte == "quoted-printable":
        data = quopri.decodestring(data)
    charset = part.get_content_charset() or "utf-8"
    try:
        return data.decode(charset, "replace")
    except LookupError:
        return data.decode("utf-8", "replace")


def body_text(header_bytes, text_bytes, keep_lines=False):
    """Prose from a header block plus the first bytes of BODY[TEXT]. The
    two are glued back into one message so the email module can walk the
    MIME parts; text/plain wins, text/html is tag-stripped as a fallback."""
    import email as emaillib
    msg = emaillib.message_from_bytes(header_bytes.rstrip(b"\r\n") + b"\r\n\r\n" + text_bytes)
    parts = list(msg.walk()) if msg.is_multipart() else [msg]
    plain = [p for p in parts if p.get_content_type() == "text/plain"]
    html = [p for p in parts if p.get_content_type() == "text/html"]
    if plain:
        text = _decoded_payload(plain[0])
    elif html:
        text = re.sub(r"<[^>]{0,200}>", " ", _decoded_payload(html[0]))
    elif not msg.is_multipart():
        text = _decoded_payload(msg)
    else:
        text = ""
    if keep_lines:
        # Line starts are what tell a reply from the message it quotes.
        lines = [" ".join(l.split()) for l in text.replace("\r\n", "\n").split("\n")]
        return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    return " ".join(text.split())


def parse_fetch(msgs):
    """imaplib's FETCH list → [(seq, header bytes, text bytes or None)] in
    arrival order. Parts are keyed on the sequence number that opens each
    message's response, so a message the server answered without a TEXT
    literal (an empty body comes back as "" rather than a literal) still
    keeps its own header instead of being paired with the next one's."""
    order, found = [], {}
    cur = None
    for item in msgs:
        if not isinstance(item, tuple) or len(item) < 2:
            continue
        meta = item[0] if isinstance(item[0], bytes) else str(item[0]).encode("utf-8", "replace")
        m = SEQ_RE.match(meta)
        if m:
            cur = m.group(1)
            if cur not in found:
                found[cur] = [None, None]
                order.append(cur)
        if cur is None:
            continue
        if b"HEADER.FIELDS" in meta:
            found[cur][0] = item[1]
        elif b"BODY[TEXT]" in meta or b"TEXT]" in meta:
            found[cur][1] = item[1]
    return [(seq, found[seq][0], found[seq][1]) for seq in order if found[seq][0] is not None]


def crawl_folder(conn, folder, since_days, budget, already_yielded=False):
    """Yield one block per message, oldest first, until the byte budget is spent."""
    import email as emaillib

    typ, _ = conn.select(folder, readonly=True)
    if typ != "OK":
        return
    since = (datetime.now() - timedelta(days=since_days)).strftime("%d-%b-%Y")
    typ, data = conn.search(None, f'(SINCE {since})')
    if typ != "OK" or not data or not data[0]:
        return
    ids = data[0].split()
    spent = 0
    # At least one message always comes back. A budget smaller than the
    # first message used to yield nothing at all, and `cmd_crawl` reads
    # "nothing yielded" as a failure — so `crawl --max-bytes 2000` reported
    # an error while printing headings. A budget is a stopping rule, not a
    # reason to answer nothing.
    yielded = already_yielded
    for start in range(0, len(ids), CRAWL_BATCH):
        batch = ids[start:start + CRAWL_BATCH]
        typ, msgs = conn.fetch(
            b",".join(batch),
            "(BODY.PEEK[HEADER.FIELDS (%s)] BODY.PEEK[TEXT]<0.%d>)" % (CRAWL_HEADERS, CRAWL_BODY_BYTES))
        if typ != "OK":
            return
        for _seq, header_bytes, text_bytes in parse_fetch(msgs):
            hdr = emaillib.message_from_bytes(header_bytes)
            body = body_text(header_bytes, text_bytes) if text_bytes else ""
            block = "### %s | %s | from %s | to %s\n%s\n\n" % (
                decode_header(hdr.get("Date"))[:31], decode_header(hdr.get("Subject")) or "(no subject)",
                decode_header(hdr.get("From"))[:80], decode_header(hdr.get("To"))[:80], body[:CRAWL_BODY_BYTES])
            spent += len(block.encode("utf-8"))
            if spent > budget and yielded:
                return
            yielded = True
            yield block


def cmd_crawl(argv):
    import imaplib
    days, max_bytes = crawl_args(argv)
    accounts = load_accounts()
    if not accounts:
        return 1
    # Split the budget evenly so one busy account cannot crowd the other out.
    per_account = max(1, max_bytes // len(accounts))
    wrote, errors = False, 0
    out = sys.stdout
    for a in accounts:
        pw = keychain_password(a["email"])
        if not pw:
            errors += 1
            continue
        conn = None
        try:
            conn = imaplib.IMAP4_SSL(a["host"], timeout=60)
            conn.login(a["email"], pw)
            out.write("## mailbox: %s\n\n" % a["label"])
            for folder in CRAWL_FOLDERS:
                # `spent` is carried across folders and accounts, so the "at
                # least one block" rule below costs one block in total rather
                # than one per folder per account — which with two mailboxes
                # and two folders was four blocks, about 7 KB, whatever budget
                # was asked for.
                for block in crawl_folder(conn, folder, days,
                                          max(1, per_account // len(CRAWL_FOLDERS)),
                                          already_yielded=wrote):
                    out.write(block)
                    wrote = True
        except Exception as e:
            print("[%s] crawl failed: %s: %s" % (a["label"], type(e).__name__, e), file=sys.stderr)
            errors += 1
        finally:
            if conn is not None:
                try:
                    conn.logout()
                except Exception:
                    pass
    if wrote:
        return 0
    return 3 if errors and errors == len(accounts) else 1


def probe(account):
    """Actually log in. Returns None on success, else a reason."""
    import imaplib
    pw = keychain_password(account["email"])
    if not pw:
        return "no app password saved"
    conn = None
    try:
        conn = imaplib.IMAP4_SSL(account["host"], timeout=12)
        conn.login(account["email"], pw)
        return None
    except Exception as e:
        text = str(e)
        if "AUTHENTICATIONFAILED" in text or "Invalid credentials" in text:
            return "Google turned down the app password. Make a new one and connect Gmail again"
        # The exception's class name is a fact about Python, not about the
        # user's mailbox, and it is the last line the app shows them.
        return "Moe could not reach Google just now. Check this Mac is online, then try again"
    finally:
        if conn is not None:
            try:
                conn.logout()
            except Exception:
                pass


def cmd_status():
    accounts = load_accounts()
    if not accounts:
        # "<sentence> — run <command>": the app cuts everything from " — run "
        # (ConnectionsCatalog.humanDetail), so the terminal keeps the command
        # and the screen keeps a sentence.
        print("needs-setup: no mailbox added yet — run ~/.moe/scripts/connect-gmail.sh")
        return 1

    # Actually connect. Checking only that a keychain entry exists is how this
    # reported "ok" for an account whose app password had been revoked — the
    # worst kind of wrong, because the brief then tells Moe it checked your mail
    # and found nothing.
    problems = []
    for a in accounts:
        why = probe(a)
        if why:
            problems.append(f"{a['label']}: {why}")
    if problems:
        print("needs-setup: " + "; ".join(problems))
        return 1

    # The ADDRESS, not the label. "personal" and "work" are names this Mac
    # made up; the only thing that tells a person which Google account they
    # are looking at is the address itself. Asked for by name after a screen
    # said "personal" and left him none the wiser.
    print(f"ok: {len(accounts)} mailbox(es) — "
          f"{', '.join(a.get('email') or a['label'] for a in accounts)}")
    return 0


def cmd_accounts():
    """One `label<TAB>address` per connected mailbox. The Connections screen
    reads this to ask WHICH mailbox to disconnect when there is more than
    one — parsing that out of a sentence meant for a person would break the
    first time the sentence was reworded."""
    accounts = load_accounts()
    for a in accounts:
        print("%s\t%s" % (a["label"], a["email"]))
    return 0 if accounts else 1


def cmd_pull():
    accounts = load_accounts()
    if not accounts:
        return 1
    any_output = False
    errors = 0
    for a in accounts:
        lines, err = fetch(a)
        if err:
            print(f"[{a['label']}] unavailable: {err}", file=sys.stderr)
            errors += 1
            continue
        if lines:
            any_output = True
            print(f"**{a['label']}** ({a['email']})")
            for ln in lines:
                print(f"- {ln}")
            print()
    if any_output:
        return 0
    # Exit 3 = configured but unreachable. Without this a revoked app password
    # or a DNS blip looks identical to an empty inbox, and the brief tells Moe
    # it checked your mail and found nothing.
    if errors and errors == len(accounts):
        return 3
    return 1


# ── items: the situations engine's feed ───────────────────────────────────
# `gmail.py items --since <cursor>`: new mail since a per-account UID, whole
# body (quoted replies and signatures are trimmed by the engine), as the
# engine's items (moe-home/lib/situations.py). On Gmail it reads All Mail
# filtered to Inbox and Sent outside Promotions, Social, Updates and Forums —
# Gmail's own sorting is a free "bulk" signal — so the owner's replies count
# too (a thread they answered is addressed to them). The cursor is a JSON
# object {address: last UID}; an account not in it is a first look, which
# only records where the mailbox is now.

ITEMS_LIMIT = 100
ITEMS_BODY_BYTES = 64000
ITEMS_TEXT_CAP = 4000
ITEMS_HEADERS = "FROM TO CC SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING"
ITEMS_GMAIL_FILTER = ('"(in:inbox OR in:sent) -category:promotions -category:social '
                      '-category:updates -category:forums"')
_RE_PREFIX = re.compile(r"^\s*((re|fwd?|aw|wg|tr)\s*:\s*)+", re.I)


def _addrs(value):
    from email.utils import getaddresses
    return [a.lower() for _n, a in getaddresses([value or ""]) if a]


def parse_items(msgs, account):
    """UID FETCH responses → items. Pure, so it is tested on bytes."""
    import email as emaillib
    from email.utils import parseaddr, parsedate_to_datetime
    me = account["email"].lower()
    rows, cur = {}, None
    for part in msgs:
        if isinstance(part, bytes) and SEQ_RE.match(part):
            # A message answered with no literal at all opens its own entry.
            cur = SEQ_RE.match(part).group(1)
            rows.setdefault(cur, {"uid": None, "thr": None, "hdr": None, "text": None, "internal": None})
        if isinstance(part, bytes) and cur is not None:
            # What a server sends after the last literal (" UID 42 X-GM-THRID 7)")
            # belongs to the message just read.
            u = re.search(rb"UID (\d+)", part)
            t = re.search(rb"X-GM-THRID (\d+)", part)
            d = re.search(rb'INTERNALDATE "([^"]+)"', part)
            if u:
                rows[cur]["uid"] = int(u.group(1))
            if t:
                rows[cur]["thr"] = t.group(1).decode()
            if d:
                rows[cur]["internal"] = d.group(0)
            continue
        if not isinstance(part, tuple) or len(part) < 2:
            continue
        meta = part[0] if isinstance(part[0], bytes) else str(part[0]).encode()
        m = SEQ_RE.match(meta)
        if m:
            cur = m.group(1)
            rows.setdefault(cur, {"uid": None, "thr": None, "hdr": None, "text": None, "internal": None})
        if cur is None:
            continue
        u = re.search(rb"UID (\d+)", meta)
        t = re.search(rb"X-GM-THRID (\d+)", meta)
        if u:
            rows[cur]["uid"] = int(u.group(1))
        if t:
            rows[cur]["thr"] = t.group(1).decode()
        d = re.search(rb'INTERNALDATE "([^"]+)"', meta)
        if d:
            rows[cur]["internal"] = d.group(0)
        if b"HEADER.FIELDS" in meta:
            rows[cur]["hdr"] = part[1]
        elif b"TEXT]" in meta:
            rows[cur]["text"] = part[1]
    out = []
    for r in rows.values():
        if r["uid"] is None or r["hdr"] is None:
            continue
        hdr = emaillib.message_from_bytes(r["hdr"])
        try:
            at = parsedate_to_datetime(hdr.get("Date")).timestamp()
        except (TypeError, ValueError, IndexError):
            at = None
        if at is None and r["internal"]:
            import imaplib
            import time as _time
            tt = imaplib.Internaldate2tuple(r["internal"])
            at = _time.mktime(tt) if tt else None
        if at is None:
            print("gmail: message %d has no date; skipped" % r["uid"], file=sys.stderr)
            continue
        subject = decode_header(hdr.get("Subject")) or "(no subject)"
        body = body_text(r["hdr"], r["text"] or b"", keep_lines=True)
        name, addr = parseaddr(decode_header(hdr.get("From")))
        recipients = _addrs(hdr.get("To")) + _addrs(hdr.get("Cc"))
        from_me = addr.lower() == me
        topic = _RE_PREFIX.sub("", subject).strip().lower()
        text = subject if not body else "%s\n\n%s" % (subject, body)
        out.append({
            "id": "gmail/%s/%d" % (me, r["uid"]),
            "thread": "gmail/%s/%s" % (me, r["thr"] or topic),
            "thread_name": _RE_PREFIX.sub("", subject).strip()[:120],
            "at": int(at),
            "from": {"id": "me" if from_me else addr.lower(), "name": "" if from_me else name,
                     "me": from_me},
            "to_me": me in recipients,
            "group": len(set(recipients) - {me}) > 1,
            "kind": "mail",
            "text": text[:ITEMS_TEXT_CAP],
        })
    out.sort(key=lambda it: it["at"])
    return out


def items_for(account, held):
    """(items, new cursor {"uid", "v"}) for one mailbox. ``held`` is the
    old cursor or None. Raises on a failed read, so the caller keeps the old
    cursor. A changed UIDVALIDITY (the server renumbered the mailbox) is a
    first look: old UIDs mean nothing any more."""
    import imaplib
    pw = keychain_password(account["email"])
    if not pw:
        raise RuntimeError("no app password in Keychain")
    conn = imaplib.IMAP4_SSL(account["host"], timeout=30)
    try:
        conn.login(account["email"], pw)
        box, gmail = '"[Gmail]/All Mail"', True
        if conn.select(box, readonly=True)[0] != "OK":
            box, gmail = "INBOX", False
            if conn.select(box, readonly=True)[0] != "OK":
                raise RuntimeError("cannot open the mailbox")
        # UIDNEXT and UIDVALIDITY as SELECT reported them (RFC 3501 advises
        # against STATUS on the selected mailbox).
        nxt = (conn.untagged_responses.get("UIDNEXT") or [None])[-1]
        validity = (conn.untagged_responses.get("UIDVALIDITY") or [b""])[-1]
        validity = validity.decode() if isinstance(validity, bytes) else str(validity or "")
        if not nxt:
            raise RuntimeError("no UIDNEXT")
        top = int(nxt) - 1
        last_uid = held.get("uid") if isinstance(held, dict) else None
        if last_uid is None or (held.get("v") and held.get("v") != validity) or last_uid > top:
            return [], {"uid": top, "v": validity}
        if last_uid == top:
            return [], {"uid": top, "v": validity}
        span = "%d:%d" % (last_uid + 1, top)
        crit = ("X-GM-RAW", ITEMS_GMAIL_FILTER, "UID", span) if gmail else ("UID", span)
        typ, data = conn.uid("SEARCH", None, *crit)
        if typ != "OK":
            raise RuntimeError("search failed")
        uids = sorted(int(x) for x in (data[0] or b"").split() if last_uid < int(x) <= top)
        new_last = top
        if len(uids) > ITEMS_LIMIT:
            uids = uids[:ITEMS_LIMIT]
            new_last = uids[-1]          # the rest next tick, never skipped
        if not uids:
            return [], {"uid": new_last, "v": validity}
        what = "(UID INTERNALDATE %sBODY.PEEK[HEADER.FIELDS (%s)] BODY.PEEK[TEXT]<0.%d>)" % (
            "X-GM-THRID " if gmail else "", ITEMS_HEADERS, ITEMS_BODY_BYTES)
        typ, msgs = conn.uid("FETCH", ",".join(str(u) for u in uids), what)
        if typ != "OK":
            raise RuntimeError("fetch failed")
        return parse_items(msgs, account), {"uid": new_last, "v": validity}
    finally:
        try:
            conn.logout()
        except Exception:  # noqa: BLE001
            pass


def cmd_items(argv):
    cursor = ""
    if "--since" in argv:
        i = argv.index("--since")
        cursor = argv[i + 1] if i + 1 < len(argv) else ""
    try:
        state = json.loads(cursor) if cursor.strip() else {}
        state = state if isinstance(state, dict) else {}
    except ValueError:
        state = {}
    accounts = load_accounts()
    new_state, items, failed = {}, [], []
    for a in accounts:
        key = a["email"].lower()
        last = state.get(key)
        if isinstance(last, int) or str(last).isdigit():
            last = {"uid": int(last), "v": ""}       # a cursor from before UIDVALIDITY was kept
        try:
            got, new_last = items_for(a, last if isinstance(last, dict) else None)
        except Exception as e:  # noqa: BLE001 — one mailbox down is not all of them
            failed.append("%s: %s: %s" % (a["label"], type(e).__name__, e))
            if key in state:
                new_state[key] = state[key]
            continue
        items.extend(got)
        new_state[key] = new_last
    if failed and len(failed) == len(accounts):
        print("unavailable: " + "; ".join(failed), file=sys.stderr)
        return 1
    for f in failed:
        print("unavailable: " + f, file=sys.stderr)
    for it in sorted(items, key=lambda it: it["at"]):
        print(json.dumps(it, ensure_ascii=False))
    print(json.dumps({"cursor": json.dumps(new_state, sort_keys=True)}))
    return 0


# ── Sending ───────────────────────────────────────────────────────────────
# The whole message arrives as one JSON object on stdin:
#
#   {"account": "you@example.com", "to": ["a@example.com"], "cc": [],
#    "subject": "…", "body": "…", "in_reply_to": "<msgid@example.com>"}
#
# on stdin and never on argv, so no part of a private message and no
# recipient list is visible in `ps` to every other process on the Mac.
#
# THE GATE. Before a socket is opened, this runs tools/confirm.sh — the same
# macOS dialog whatsapp.sh puts in front of its own `send` — and refuses on
# any answer but Send. It is deliberately NOT a flag in the JSON: the model
# writes that JSON, and text Moe reads in your mail can talk a model into
# writing anything, `"confirmed": true` included. A dialog the OS draws and a
# human clicks is the one thing an injected instruction cannot produce.
#
# The path to confirm.sh is derived from this file's own location, never from
# an environment variable, so there is no switch anywhere that points the
# gate at /bin/true. A missing or unrunnable dialog means no send.

# Bare addresses only, and only out of the printable ASCII an address is
# actually made of. A display name ("Ada <ada@example.com>") is refused,
# because what the dialog shows the human must be exactly what the envelope
# gets — and a name is a place to hide a second address.
#
# The allow-list matters as much as the shape. The old rule was "anything
# that is not whitespace or a delimiter", which let through:
#   * NUL and the other control characters. subprocess cannot put a NUL on
#     the dialog's argv at all, so `a\0b@example.com` did not get a dialog
#     — it got a Python traceback;
#   * the bidi controls (U+202E RIGHT-TO-LEFT OVERRIDE and friends), which
#     make macOS draw one address on screen while another goes in the
#     envelope. A gate whose display can be steered is not a gate.
ADDR_RE = re.compile(r"^[A-Za-z0-9!#$%&*+/=?^_{|}~.-]+"
                     r"@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$")
# RFC 5321's limit. Also the thing that stops one 5,000-character address
# from filling the dialog and pushing the message out of sight.
MAX_ADDRESS = 254
# Unknown keys are an error, not something to ignore: a silently dropped
# "bcc" would be a recipient the human approving the dialog never saw.
SEND_KEYS = {"account", "to", "cc", "subject", "body", "in_reply_to"}
MAX_RECIPIENTS = 25
# Everything the dialog has to render before the message starts. Past these
# the send is refused rather than shown in part: a recipient the human
# cannot see is exactly what this whole path exists to prevent.
MAX_TO_LINE = 900
MAX_SUBJECT = 300
MAX_IN_REPLY_TO = 400
# Control characters (CR and LF included), DEL, the Unicode line and
# paragraph separators, and the bidi overrides and isolates. None of them
# belong in a header, and every one of them makes the dialog show something
# other than what is sent.
BAD_TEXT_RE = re.compile("[\\x00-\\x08\\x0b-\\x1f\\x7f"
                         "\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069]")


def confirm_script():
    """…/connectors/gmail.py → …/tools/confirm.sh, from this file's path.

    Not $MOE_HOME, not $HOME: a gate whose location an environment variable
    can move is not a gate. Installed (~/.moe/connectors) and in the repo
    (moe-home/connectors) both resolve to the confirm.sh beside them.

    realpath, not abspath: abspath leaves symlinks alone, so a symlink to
    this file dropped in a directory with a friendlier tools/confirm.sh
    beside it ran the friendlier one. Resolving the link first means the
    gate is the one beside the real file, wherever the link lives. (A
    straight copy of this file still finds the confirm.sh next to the copy —
    nothing in a script can prevent that, and anyone who can put a copy
    there can read the app password out of the Keychain anyway.)
    """
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.normpath(os.path.join(here, os.pardir, "tools", "confirm.sh"))


#: confirm.sh's exit when the card withdrew rather than being answered
#: (Sources/MoeDesign/ConfirmLifecycle.swift). Nobody cancelled anything.
WITHDRAWN = 7
WITHDRAWN_TEXT = ("not sent — the confirmation expired or was withdrawn before anyone "
                  "answered, so nothing was sent.")
#: How far under CONFIRM_TIMEOUT the card gives up, so its own "expired"
#: note lands before this process would kill it.
CARD_DEADLINE_MARGIN = 15


def card_env(timeout):
    """The environment for confirm.sh, with the card's deadline under THIS
    call's own timeout. The plugin hands down a deadline from its timeout
    (900 s); this one kills confirm.sh at CONFIRM_TIMEOUT, which is shorter —
    so without this the card was killed out from under itself and said "the
    task that asked stopped" when the truth was "nobody answered in time".
    The earlier of the two wins; a card never waits past the smallest timeout
    in its chain."""
    import time
    env = dict(os.environ)
    ours = int(time.time() + max(timeout - CARD_DEADLINE_MARGIN, 5))
    theirs = env.get("MOE_CONFIRM_DEADLINE", "")
    env["MOE_CONFIRM_DEADLINE"] = str(min(ours, int(theirs)) if theirs.isdigit() else ours)
    return env


PROVENANCE_ENV = "MOE_CONFIRM_PROVENANCE"


def _with_provenance(provenance, base):
    """The card's environment (card_env) plus who named the recipient, for the
    dialog to say. Display only: it moves nothing and skips nothing."""
    child = dict(base)
    child[PROVENANCE_ENV] = provenance or ""
    return child


def recipient_check(raw, body, resolved=()):
    """(ok, refusal, provenance) from tools/recipients.py beside confirm.sh.

    Sends only against the send gate's one-time ticket for exactly these
    recipients and these words — minted in memory by the moe-connectors
    plugin that started this connector, redeemed once over its socket — and
    never to the owner's own address through a contact tool unasked (see
    recipients.py, "tickets").
    Found from this file's real path, like the dialog; a check that cannot run
    is a refusal, like a dialog that cannot open."""
    tools = os.path.dirname(confirm_script())
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("moe_recipients", os.path.join(tools, "recipients.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        raws = raw if isinstance(raw, (list, tuple)) else [raw]
        v = mod.connector_check([r for r in raws if r], body, [r for r in resolved if r])
    except Exception:  # noqa: BLE001 — any failure here refuses
        return False, "not sent — Moe could not check who this is going to, so nothing was sent.", ""
    if v.get("verdict") == "refuse":
        return False, v.get("message") or "not sent", ""
    prov = v.get("provenance")
    import json as _json
    return True, "", _json.dumps(prov, ensure_ascii=True) if isinstance(prov, dict) else ""


def confirm(from_addr, to_line, subject, body, in_reply_to="", provenance=""):
    """(approved, edits). Approved only if a human clicked Send. Anything
    else — cancelled, no dialog, a crash, a timeout — is False, because a
    gate that opens when it is confused is not a gate.

    `edits` is what they rewrote before clicking: ``{"body": …}`` and/or
    ``{"subject": …}``, empty when the message goes as it was shown. Exit 5
    from confirm.sh carries them on stdout; a 5 with nothing usable on
    stdout is not an approval of anything.

    `from_addr` is in the dialog because with a personal and a work mailbox
    connected the model picks which one sends, and "which of my addresses is
    this going out as" is part of what a person is approving."""
    script = confirm_script()
    if not os.path.isfile(script) or not os.access(script, os.X_OK):
        return False, {}
    shown = "From: %s\nSubject: %s\n\n%s" % (from_addr, subject or "(no subject)", body)
    if in_reply_to:
        # The one field of the request that reached the wire and never the
        # dialog. It decides which existing conversation an approved message
        # lands inside, which is part of what somebody is approving.
        shown = "In-Reply-To: %s\n%s" % (in_reply_to, shown)
    try:
        r = subprocess.run([script, "Gmail", to_line, shown],
                           capture_output=True, text=True, timeout=CONFIRM_TIMEOUT,
                           env=_with_provenance(provenance, card_env(CONFIRM_TIMEOUT)))
    except subprocess.TimeoutExpired:
        # Nobody answered in time: an expiry, not a cancel.
        return False, None
    except (subprocess.SubprocessError, OSError):
        return False, {}
    if r.returncode == 0:
        return True, {}
    if r.returncode == 5:
        edits = edits_from(r.stdout)
        return bool(edits), edits
    if r.returncode == WITHDRAWN:
        # The card withdrew: whoever asked stopped, or nobody answered in
        # time. `None`, not `{}`, so the caller does not say "you cancelled".
        return False, None
    return False, {}


def edits_from(stdout):
    """The fields a person rewrote in the dialog, out of confirm.sh's stdout
    on exit 5: NUL-separated ``key=value`` records, ``body`` and ``subject``
    only. Anything else on stdout is ignored."""
    out = {}
    for rec in (stdout or "").split("\0"):
        key, sep, value = rec.partition("=")
        if sep and key in ("body", "subject"):
            out[key] = value
    return out


def _addresses(value, field):
    """A JSON to/cc field → a list of bare addresses. Raises ValueError with
    a sentence a person can act on."""
    if value is None:
        return []
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        raise ValueError("'%s' should be a list of email addresses." % field)
    out = []
    for item in value:
        if not isinstance(item, str):
            raise ValueError("'%s' should be a list of email addresses." % field)
        addr = item.strip()
        if not addr:
            continue
        if len(addr) > MAX_ADDRESS or not ADDR_RE.match(addr):
            # Never echo the whole value: it is attacker-controlled text.
            raise ValueError("'%s' contains something that is not a plain email address." % field)
        # The same address twice would be counted twice in "sent to N
        # recipients" and read as two people in the dialog.
        if addr not in out:
            out.append(addr)
    return out


def _one_line(value, field, limit):
    """A header value: one line of ordinary text, no longer than `limit`.

    A newline in a header is how an extra Bcc: gets smuggled onto a message
    the human approved. The rest of the characters barred here are the ones
    that let a header show a person one thing and send another: NUL (which
    cannot even be put on the dialog's argv — it used to end in a
    traceback), the other control characters, and the bidi overrides. The
    length limit is there so a 100,000-character subject cannot push the
    message itself out of the dialog.
    """
    if value is None:
        return ""
    if not isinstance(value, str):
        raise ValueError("'%s' should be text." % field)
    if "\r" in value or "\n" in value:
        raise ValueError("'%s' must be a single line." % field)
    if BAD_TEXT_RE.search(value):
        raise ValueError("'%s' contains a character that cannot be shown in the confirmation. Use ordinary text." % field)
    if len(value) > limit:
        raise ValueError("'%s' is too long — keep it under %d characters." % (field, limit))
    return value


def parse_send_request(raw):
    """stdin text → (account name, to, cc, subject, body, in_reply_to).
    Raises ValueError with one plain sentence."""
    try:
        req = json.loads(raw)
    except ValueError:
        raise ValueError("send expects one JSON object on stdin.")
    if not isinstance(req, dict):
        raise ValueError("send expects one JSON object on stdin.")
    unknown = sorted(k for k in req if k not in SEND_KEYS)
    if unknown:
        raise ValueError("send does not understand: %s." % ", ".join(unknown)[:80])

    to = _addresses(req.get("to"), "to")
    cc = _addresses(req.get("cc"), "cc")
    if not to:
        raise ValueError("send needs at least one address in 'to'.")
    if len(to) + len(cc) > MAX_RECIPIENTS:
        raise ValueError("that is more than %d recipients — send it in smaller batches." % MAX_RECIPIENTS)

    subject = _one_line(req.get("subject"), "subject", MAX_SUBJECT)
    in_reply_to = _one_line(req.get("in_reply_to"), "in_reply_to", MAX_IN_REPLY_TO).strip()
    if in_reply_to and (" " in in_reply_to or "<" not in in_reply_to):
        raise ValueError("'in_reply_to' should be one message id, in angle brackets.")
    body = req.get("body") or ""
    if not isinstance(body, str):
        raise ValueError("'body' should be text.")
    # Newlines and tabs are the point of a body; the rest of the control
    # characters are not. A NUL in here reached subprocess and came back as
    # a traceback instead of a dialog, and a bidi override in here shows the
    # human one message and sends another.
    if BAD_TEXT_RE.search(body.replace("\r", "").replace("\n", "").replace("\t", "")):
        raise ValueError("'body' contains a character that cannot be shown in the confirmation. Use ordinary text.")

    account = req.get("account")
    if account is not None and not isinstance(account, str):
        raise ValueError("'account' should be the address or label of a connected mailbox.")
    return (account or "").strip(), to, cc, subject, body, in_reply_to


def pick_account(accounts, wanted):
    """Match on address or label, case-insensitively. With one mailbox and
    nothing asked for, that mailbox. Raises ValueError otherwise — guessing
    which mailbox a message goes out from would be the wrong 'From' on
    somebody's work mail."""
    if wanted:
        for a in accounts:
            if wanted.lower() in (a["email"].lower(), a["label"].lower()):
                return a
        raise ValueError("No connected mailbox matches that account. Connected: %s."
                         % ", ".join(a["label"] for a in accounts))
    if len(accounts) == 1:
        return accounts[0]
    raise ValueError("Say which mailbox to send from: %s."
                     % ", ".join(a["label"] for a in accounts))


def build_message(account, to, cc, subject, body, in_reply_to):
    """An RFC 5322 message: UTF-8 where it needs to be, with a Date and a
    Message-ID of our own (Gmail adds one otherwise, but a reply needs ours
    to thread reliably)."""
    from email.message import EmailMessage
    from email.utils import formatdate, make_msgid

    msg = EmailMessage()
    msg["From"] = account["email"]
    msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=account["email"].rsplit("@", 1)[-1])
    if in_reply_to:
        # Both headers: In-Reply-To is what Gmail threads on, References is
        # what everything else threads on.
        msg["In-Reply-To"] = in_reply_to
        msg["References"] = in_reply_to
    # set_content picks the charset and transfer encoding: plain ASCII stays
    # readable on the wire, anything else becomes UTF-8 quoted-printable.
    msg.set_content(body)
    return msg


def smtp_send(account, password, msg, recipients):
    """One message out over implicit TLS with verified certificates.

    Returns the refused-recipients dict smtplib hands back: ``{}`` when every
    recipient was accepted, ``{addr: (code, msg)}`` for a partial refusal.
    """
    import smtplib
    import ssl

    # create_default_context(): certificate chain verified against the system
    # roots, hostname checked. Neither is ever relaxed here — a TLS session
    # nobody verified is a plaintext session with extra steps, and the app
    # password goes down it.
    context = ssl.create_default_context()
    with smtplib.SMTP_SSL(account["smtp_host"], account["smtp_port"],
                          context=context, timeout=SEND_TIMEOUT) as server:
        server.login(account["email"], password)
        # The return value is not decoration. smtplib raises
        # SMTPRecipientsRefused only when EVERY recipient is refused; when
        # some are refused it returns them as a dict and says nothing. Two
        # addresses, one of them a typo, used to print "✓ sent to 2
        # recipients" — the person believes a message reached someone it
        # never reached, which is worse than an error.
        return server.send_message(msg, from_addr=account["email"], to_addrs=recipients) or {}


def cmd_send(argv):
    if argv:
        print("send takes no arguments — the message is one JSON object on stdin.")
        return 2

    accounts = load_accounts()
    if not accounts:
        print("No mailbox is connected. Add one in Settings › Connections.")
        return 1

    try:
        wanted, to, cc, subject, body, in_reply_to = parse_send_request(sys.stdin.read())
        account = pick_account(accounts, wanted)
    except ValueError as e:
        print(str(e))
        return 1

    password = keychain_password(account["email"])
    if not password:
        print("No app password saved for %s — reconnect it in Settings › Connections." % account["label"])
        return 1

    recipients = to + cc
    # Exactly what will go out, to exactly whom, in front of a human.
    to_line = ", ".join(to) + ((" (cc " + ", ".join(cc) + ")") if cc else "")
    # A dialog that cannot show the whole recipient list is worse than no
    # dialog: the person clicks Send on the addresses they can see while the
    # ones below the fold go out too. Refuse instead of showing part of it.
    if len(to_line) > MAX_TO_LINE:
        print("that is too many addresses to show you before sending — send it in smaller batches.")
        return 1
    # The server is named in the dialog when it is not Google's. `smtp_host`
    # comes out of gmail-accounts.json, which is a file: point it elsewhere
    # and the approved message — and the mailbox password that logs in to
    # send it — go to that host instead, while the dialog said only "Gmail,
    # to bob@example.com". Any host has a valid certificate for its own name,
    # so TLS verification does not help here; saying where it is going does.
    where = account["email"]
    if account.get("smtp_host") and account["smtp_host"] != SMTP_HOST:
        where = "%s  (sending through %s:%s — NOT Gmail)" % (
            account["email"], account["smtp_host"], account.get("smtp_port", ""))
    # Mail to yourself is the owner's door, not a contact's; and everybody
    # on it must have been named by somebody (tools/recipients.py).
    allowed, refusal, provenance = recipient_check(recipients, body)
    if not allowed:
        print(refusal)
        return 1
    approved, edits = confirm(where, to_line, subject, body, in_reply_to, provenance)
    if not approved:
        print(WITHDRAWN_TEXT if edits is None else "not sent — you cancelled")
        return 1
    # What they typed goes out, and it is checked the way the request was:
    # the dialog refuses steering characters itself, and this is the second
    # look the rest of the fields already get.
    if edits:
        try:
            if "subject" in edits:
                subject = _one_line(edits["subject"], "subject", MAX_SUBJECT)
            if "body" in edits:
                body = edits["body"]
                if BAD_TEXT_RE.search(body.replace("\r", "").replace("\n", "").replace("\t", "")):
                    raise ValueError("the rewritten message contains a character that cannot be sent.")
        except ValueError as e:
            print("not sent — %s" % e)
            return 1

    try:
        refused = smtp_send(account, password,
                            build_message(account, to, cc, subject, body, in_reply_to), recipients)
    except Exception as e:  # noqa: BLE001 — smtplib/ssl raise a zoo; none may print a traceback
        # Never the password, never a stack trace: this text can end up in a
        # log, a notification, or read aloud. Matched on the class name
        # rather than by importing smtplib again — an import inside an
        # exception handler can raise its own exception, and then the
        # traceback this whole block exists to prevent is what the user gets.
        kind = type(e).__name__
        if kind == "SMTPAuthenticationError":
            print("Gmail rejected the app password for %s. Create a new one and reconnect it." % account["label"])
        elif kind == "SMTPRecipientsRefused":
            print("Gmail would not accept those recipients — check the addresses.")
        else:
            print("Couldn't send the message (%s). Nothing was sent." % kind)
        return 1

    n = len(recipients)
    if refused:
        # Partly sent is its own outcome, and the only honest way to say it
        # is to name who did not get it. Non-zero: a caller that checks the
        # exit code must not read this as a clean send.
        names = ", ".join(sorted(refused))[:200]
        got = n - len(refused)
        print("sent to %d of %d — %s did not accept: %s"
              % (got, n, "this address" if len(refused) == 1 else "these addresses", names))
        return 1
    print("✓ sent to %d recipient%s" % (n, "" if n == 1 else "s"))
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "crawl":
        sys.exit(cmd_crawl(sys.argv[2:]))
    if cmd == "send":
        sys.exit(cmd_send(sys.argv[2:]))
    if cmd == "items":
        sys.exit(cmd_items(sys.argv[2:]))
    if cmd == "accounts-file":
        # Where the mailboxes actually live. Exists so nothing else has to
        # rebuild this path from an environment variable that a second app
        # with its own home will point somewhere else.
        print(ACCOUNTS_FILE)
        sys.exit(0)
    if cmd == "accounts":
        sys.exit(cmd_accounts())
    sys.exit(cmd_status() if cmd == "status" else cmd_pull() if cmd == "pull" else 2)

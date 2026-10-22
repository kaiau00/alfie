#!/usr/bin/env python3
"""Your personal Telegram chats (not the bot — your own account).

Telegram Desktop keeps its local store encrypted, so reading your real chats
means talking MTProto as your user account. That needs Telethon and a one-time
phone login: run ~/.moe/scripts/connect-telegram.sh.

The session file it creates is the equivalent of a logged-in device. Keep it.
"""
import os
import re
import sys

MOE = os.path.expanduser("~/.moe")
VENV_PY = os.path.join(MOE, "venv", "bin", "python3")
SESSION = os.path.join(MOE, "connectors", "telegram.session")
SINCE_HOURS = int(os.environ.get("MOE_SINCE_HOURS", "24"))
MAX_CHATS = 15
MAX_PER_CHAT = 6


def have_session():
    """Is there a session file, and is there anything in it?

    A 0-byte `telegram.session` is not a sign-in — it is the wreckage of a
    run that died between `sqlite3.connect()` (which creates the file) and
    the schema (which is what makes it a session). One was left on the
    owner's Mac on 2026-09-07 by connect-telegram.sh's error path, and
    `os.path.exists` alone read it as connected: `status` stopped saying
    "you have not signed in to Telegram yet" and started reporting a
    different, wrong problem, so the row on screen never named the thing to
    do. Size is the cheap half of the question; is_user_authorized() is the
    expensive half and pull/crawl/send still ask it.
    """
    try:
        return os.path.getsize(SESSION) > 0
    except OSError:
        return False


def reexec_in_venv():
    """Telethon lives in Alfie' venv, not in system python."""
    if os.path.exists(VENV_PY) and os.path.realpath(sys.executable) != os.path.realpath(VENV_PY):
        os.execv(VENV_PY, [VENV_PY, os.path.abspath(__file__)] + sys.argv[1:])


def have_telethon():
    try:
        import telethon  # noqa: F401
        return True
    except ImportError:
        return False


def cmd_status():
    # A session file is not a sign-in. Telethon writes it on connect(),
    # before it knows whether the account is authorised, so a failed attempt
    # leaves one behind — and this used to read that as "ok: reading your
    # Telegram chats" while nothing was signed in at all. The application
    # pair is written only by a run that got as far as trying, and removed
    # again when Telegram rejects it, so requiring both is the cheap check.
    # (The authoritative one is is_user_authorized(), which costs a network
    # round trip every ten minutes; pull and crawl report it when they run.)
    if not have_session():
        # Everything after " — run " is cut before the app shows this
        # (ConnectionsCatalog.humanDetail), so both audiences get their half.
        print("needs-setup: you have not signed in to Telegram yet — run ~/.moe/scripts/connect-telegram.sh")
        return 1
    if not have_telethon():
        print("needs-setup: a piece Alfie needs to read Telegram is missing — run ~/.moe/scripts/connect-telegram.sh")
        return 1
    api_id, api_hash = telegram_creds()
    if not api_id or not api_hash:
        print("needs-setup: your Telegram sign-in did not finish — run ~/.moe/scripts/connect-telegram.sh")
        return 1
    print("ok: reading your Telegram chats")
    return 0


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


def telegram_creds():
    api_id = os.environ.get("TELEGRAM_API_ID")
    api_hash = os.environ.get("TELEGRAM_API_HASH")
    if not api_id or not api_hash:
        cfg = os.path.join(MOE, "connectors", "telegram.json")
        try:
            import json
            with open(cfg) as f:
                d = json.load(f)
            api_id, api_hash = d.get("api_id"), d.get("api_hash")
        except Exception:
            return None, None
    return api_id, api_hash


def connected_client():
    """A signed-in Telethon client, or None — never a login prompt.

    `with TelegramClient(...)` calls __aenter__ → start(), whose default
    phone argument is `input('Please enter your phone (or bot token): ')`.
    On a session Telegram has since terminated that meant `pull` and `crawl`
    blocked a background sync on a prompt nobody could see — and, worse,
    Telethon had already asked Telegram to text the user a login code before
    the block. A read verb must never begin a sign-in.

    connect() opens the socket without authorising; is_user_authorized() is
    the question actually being asked.
    """
    api_id, api_hash = telegram_creds()
    if not api_id or not api_hash:
        return None
    from telethon.sync import TelegramClient
    client = TelegramClient(SESSION.replace(".session", ""), int(api_id), api_hash)
    try:
        client.connect()
        if not client.is_user_authorized():
            client.disconnect()
            return None
    except Exception:  # noqa: BLE001 — telethon raises a zoo; none of it is a prompt
        try:
            client.disconnect()
        except Exception:  # noqa: BLE001
            pass
        return None
    return client


def cmd_crawl(argv):
    """The learn-me pass: whole messages, every recent chat, byte-capped."""
    days, max_bytes = crawl_args(argv)
    if not have_session() or not have_telethon():
        return 1
    api_id, api_hash = telegram_creds()
    if not api_id or not api_hash:
        return 1

    from datetime import datetime, timedelta, timezone
    from telethon.sync import TelegramClient

    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    spent, printed = 0, False
    try:
        client = connected_client()
        if client is None:
            print("unavailable: your Telegram sign-in has expired — reconnect it in Settings › Connections.",
                  file=sys.stderr)
            return 1
        with client:
            me = client.get_me()
            my_id = me.id if me else None
            # Dialogs come newest-activity first; stop at the first one that
            # went quiet before the window, since every one after it did too.
            for dialog in client.iter_dialogs():
                if dialog.date and dialog.date < cutoff:
                    break
                lines = []
                for m in client.iter_messages(dialog.id, offset_date=cutoff, reverse=True):
                    if not m.text:
                        continue
                    who = "me" if (my_id and m.sender_id == my_id) else (
                        getattr(m.sender, "first_name", None) or dialog.name or "them")
                    lines.append("%s | %s: %s" % (m.date.astimezone().strftime("%Y-%m-%d %H:%M"), who,
                                                 " ".join(m.text.split())))
                if not lines:
                    continue
                block = "## chat: %s\n%s\n\n" % (dialog.name, "\n".join(lines))
                spent += len(block.encode("utf-8"))
                # A budget is a stopping rule, not a reason to answer nothing:
                # a budget smaller than the first chat printed nothing and
                # returned 1, which the caller reads as a failed connector.
                # At least one block always comes out.
                if spent > max_bytes and printed:
                    return 0
                sys.stdout.write(block)
                printed = True
    except Exception as e:
        print("unavailable: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 3 if printed is False else 0
    return 0 if printed else 1


ITEMS_MAX_DIALOGS = 40
ITEMS_MAX_PER_DIALOG = 50
ITEMS_TEXT_CAP = 4000


def _item(dialog, m, my_id, group):
    text = (getattr(m, "message", None) or m.text or "").strip()
    if not text or not m.date:
        return None
    me = bool(my_id and m.sender_id == my_id) or bool(getattr(m, "out", False))
    sender = getattr(m, "sender", None)
    name = " ".join(x for x in (getattr(sender, "first_name", None),
                                getattr(sender, "last_name", None)) if x) \
        or getattr(sender, "title", None) or (dialog.name if not group else "")
    return {
        "id": "telegram/%s/%s" % (dialog.id, m.id), "thread": "telegram/%s" % dialog.id,
        "thread_name": dialog.name or "", "at": int(m.date.timestamp()),
        "from": {"id": "me" if me else str(m.sender_id or ""), "name": "" if me else (name or ""),
                 "me": me},
        "to_me": (not group) or bool(getattr(m, "mentioned", False)),
        "group": group, "kind": "msg", "text": text[:ITEMS_TEXT_CAP],
    }


ITEMS_KEEP_CHATS = 400
#: Dialogs listed per look: no cap. Listing is cheap (a page of 100 a
#: request) and stops at the first quiet chat, normally a few chats in;
#: reading is what ITEMS_MAX_DIALOGS limits. A cap here left the chats below
#: it unlisted for good whenever more than that many moved (the walk never
#: completed, so `t` never moved either).
ITEMS_MAX_RAW_DIALOGS = None


#: How far before the last look the walk counts a chat as moved: the Mac's
#: clock and Telegram's disagree by seconds, and a chat already read is
#: protected by its message id, so a margin costs nothing but a look.
ITEMS_CLOCK_MARGIN_S = 120


def _read_chat(client, dialog, key, last, since_of, t, my_id, group, out):
    """Read one chat after its last id (or, never read, after the time it
    was queued from). True when more is waiting in it."""
    import math
    from datetime import datetime, timezone
    if key in last:
        batch = client.iter_messages(dialog.id, min_id=last[key], reverse=True,
                                     limit=ITEMS_MAX_PER_DIALOG + 1)
    else:
        since = since_of.get(key, t)
        batch = client.iter_messages(
            dialog.id, offset_date=datetime.fromtimestamp(math.floor(since) - ITEMS_CLOCK_MARGIN_S,
                                                          timezone.utc),
            reverse=True, limit=ITEMS_MAX_PER_DIALOG + 1)
    n = 0
    for m in batch:
        if n == ITEMS_MAX_PER_DIALOG:
            return True
        n += 1
        last[key] = max(last.get(key, 0), int(m.id))
        it = _item(dialog, m, my_id, group)
        if it:
            out.append(it)
    return False


def items_from(client, state, my_id, now):
    """(items, new state). The state is {"t": unix time of the last complete
    look, "d": {chat id: last message id read}, "r": {chat id: when last
    read}, "more": [chats still to read], "q": {never-read queued chat: the
    time it was queued from}, "m": {queued chat: [name, is group]}}.

    A chat has news when its newest message id is past the last one read
    there (or, never read before, when it moved after `t`). A message id only
    grows within a chat, so each chat is read after its own last id, oldest
    first, at most ITEMS_MAX_PER_DIALOG a look; at most ITEMS_MAX_DIALOGS
    chats are read a look, and every other chat with news goes into "more",
    to be read next look — found again in the walk, or read directly by id
    when the walk no longer reaches it. The walk (newest activity first;
    pinned chats first whatever their date; broadcast channels are not
    conversations) stops at the first chat with no news dated before `t`
    (less a clock margin); `t` moves to now only after such a complete walk,
    so a chat is never passed over because a look ran out of room."""
    import math
    from datetime import datetime, timezone
    from types import SimpleNamespace
    t = float(state.get("t") or now)
    last = {str(k): int(v) for k, v in (state.get("d") or {}).items() if str(v).isdigit()}
    read_at = {str(k): float(v) for k, v in (state.get("r") or {}).items()}
    more = {str(x) for x in state.get("more") or []}
    since_of = {str(k): float(v) for k, v in (state.get("q") or {}).items()}
    meta = {str(k): v for k, v in (state.get("m") or {}).items() if isinstance(v, list) and len(v) == 2}
    cutoff = datetime.fromtimestamp(math.floor(t) - ITEMS_CLOCK_MARGIN_S, timezone.utc)
    out, queued, visited = [], set(), set()
    read_chats, complete, raw = 0, False, 0

    def queue(key, name, group):
        queued.add(key)
        meta[key] = [name or "", bool(group)]
        if key not in last:
            since_of.setdefault(key, t)

    # Chats already waiting are read first, directly by id, so a look full
    # of fresh chats never starves them.
    read_now = set()
    for key in sorted(more, key=lambda k: since_of.get(k, read_at.get(k, 0.0))):
        if key not in meta or read_chats == ITEMS_MAX_DIALOGS:
            continue
        name, group = meta[key]
        read_chats += 1
        read_now.add(key)
        read_at[key] = now
        try:
            if _read_chat(client, SimpleNamespace(id=int(key), name=name), key, last, since_of, t,
                          my_id, group, out):
                queue(key, name, group)
        except Exception:  # noqa: BLE001 — left, deleted or no longer readable: dropped
            continue
    for dialog in client.iter_dialogs(limit=ITEMS_MAX_RAW_DIALOGS):
        raw += 1
        key = str(dialog.id)
        if getattr(dialog, "is_channel", False) and not getattr(dialog, "is_group", False):
            continue
        visited.add(key)
        if key in read_now:
            continue
        group = bool(getattr(dialog, "is_group", False))
        top = getattr(getattr(dialog, "message", None), "id", None)
        if key in last and top is not None:
            news = int(top) > last[key]
        else:
            news = bool(dialog.date and dialog.date > cutoff)
        if not news and (key not in more or key in read_now):
            if getattr(dialog, "pinned", False) or (dialog.date and dialog.date > cutoff):
                continue
            complete = True
            break
        if read_chats == ITEMS_MAX_DIALOGS:
            queue(key, dialog.name, group)
            continue
        read_chats += 1
        read_at[key] = now
        if _read_chat(client, dialog, key, last, since_of, t, my_id, group, out):
            queue(key, dialog.name, group)
    if not complete and (ITEMS_MAX_RAW_DIALOGS is None or raw < ITEMS_MAX_RAW_DIALOGS):
        complete = True              # the list ended: every chat was seen
    # A waiting chat neither read nor reached this look stays waiting.
    for key in more - read_now - visited:
        queued.add(key)
    still = queued
    if len(last) > ITEMS_KEEP_CHATS:
        # A chat with more waiting is never forgotten; the rest by when they
        # were last read (message ids are not comparable across chats).
        rest = sorted((k for k in last if k not in still), key=lambda k: read_at.get(k, 0.0))
        drop = set(rest[:max(0, len(last) - ITEMS_KEEP_CHATS)])
        last = {k: v for k, v in last.items() if k not in drop}
    read_at = {k: v for k, v in read_at.items() if k in last}
    out.sort(key=lambda it: it["at"])
    return out, {"t": now if complete else t, "d": last, "r": read_at, "more": sorted(still),
                 "q": {k: v for k, v in since_of.items() if k in still and k not in last},
                 "m": {k: v for k, v in meta.items() if k in still}}


def cmd_items(argv):
    """`items --since <state>`: the situations engine's feed. An empty or
    unreadable cursor is the first look and only records the time."""
    import json
    import time
    cursor = ""
    if "--since" in argv:
        i = argv.index("--since")
        cursor = argv[i + 1] if i + 1 < len(argv) else ""
    now = time.time()
    try:
        state = json.loads(cursor)
        if not isinstance(state, dict) or "t" not in state:
            raise ValueError
    except ValueError:
        print(json.dumps({"cursor": json.dumps({"t": now, "d": {}, "more": []})}))
        return 0
    if not have_session() or not have_telethon():
        print("unavailable: Telegram is not signed in", file=sys.stderr)
        return 1
    client = connected_client()
    if client is None:
        print("unavailable: your Telegram sign-in has expired", file=sys.stderr)
        return 1
    try:
        with client:
            me = client.get_me()
            # The look starts now: a message arriving while it runs moves its
            # chat past this time and is read next look.
            items, new_state = items_from(client, state, me.id if me else None, now)
    except Exception as e:  # noqa: BLE001 — never move the cursor on a failed read
        print("unavailable: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1
    for it in items:
        print(json.dumps(it, ensure_ascii=False))
    print(json.dumps({"cursor": json.dumps(new_state, sort_keys=True)}))
    return 0


def cmd_pull():
    if not have_session() or not have_telethon():
        return 1

    from datetime import datetime, timedelta, timezone
    from telethon.sync import TelegramClient

    api_id = os.environ.get("TELEGRAM_API_ID")
    api_hash = os.environ.get("TELEGRAM_API_HASH")
    if not api_id or not api_hash:
        cfg = os.path.join(MOE, "connectors", "telegram.json")
        try:
            import json
            with open(cfg) as f:
                d = json.load(f)
            api_id, api_hash = d.get("api_id"), d.get("api_hash")
        except Exception:
            return 1
    if not api_id or not api_hash:
        return 1

    cutoff = datetime.now(timezone.utc) - timedelta(hours=SINCE_HOURS)
    printed = False
    try:
        client = connected_client()
        if client is None:
            print("unavailable: your Telegram sign-in has expired — reconnect it in Settings › Connections.",
                  file=sys.stderr)
            return 1
        with client:
            me = client.get_me()
            my_id = me.id if me else None
            for dialog in client.iter_dialogs(limit=MAX_CHATS):
                lines = []
                for m in client.iter_messages(dialog.id, limit=MAX_PER_CHAT):
                    if not m.date or m.date < cutoff or not m.text:
                        continue
                    who = "me" if (my_id and m.sender_id == my_id) else (
                        getattr(m.sender, "first_name", None) or dialog.name or "them")
                    stamp = m.date.astimezone().strftime("%d %b %H:%M")
                    # One message, one line: a body with a newline could otherwise
                    # print a line of its own that reads as a sender.
                    lines.append(f"- {stamp} | {who}: {' '.join(m.text[:200].split())}")
                if lines:
                    printed = True
                    print(f"**{dialog.name}**")
                    print("\n".join(reversed(lines)))
                    print()
    except Exception as e:
        print(f"unavailable: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0 if printed else 1


# ---------------------------------------------------------------------------
# Sending
#
# The session file is a full delegated login, so Telethon can send as you.
# That makes this the most dangerous verb in the connector, and it is built
# to the same shape as `gmail.py send` (connectors/gmail-send-patterns.md):
#
#   * The message is ONE JSON OBJECT ON STDIN, never argv. A private message
#     and the person it is going to have no business in `ps`.
#   * The connector confirms for EVERY caller, before it opens a socket. The
#     approval is not a field in the request — text Moe reads in your own
#     chats can talk a model into writing anything, `"confirmed": true`
#     included — so an unknown key is an error, not something ignored.
#   * confirm.sh is found from this file's real path, never $MOE_HOME. A
#     gate an environment variable can move is not a gate.
#   * It FAILS CLOSED. No dialog, a crash, a timeout, an unresolvable
#     recipient: all refusals.
#   * ONE recipient per call, on purpose. Bulk messaging from a user account
#     is what gets accounts banned, and it is not a thing Moe should make
#     easy (Telegram's API ToS §1.4; Telethon's own FAQ on established
#     accounts and anti-spam).
#
# The recipient is resolved to a real name BEFORE the dialog, so a person
# approves "Dan Whitfield (@danw)" rather than a number they cannot check.
# ---------------------------------------------------------------------------

SEND_KEYS = {"to", "text"}
MAX_TEXT = 4096          # Telegram's own limit for one message
MAX_TO = 200

# Control characters, DEL, the Unicode line/paragraph separators and the bidi
# overrides and isolates: every one of them can make the dialog show a person
# something other than what is sent. Newline and tab are the point of a
# message body and are allowed through.
BAD_TEXT_RE = re.compile("[\\x00-\\x08\\x0b-\\x1f\\x7f"
                          "\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069]")
CONFIRM_TIMEOUT = 600


def confirm_script():
    """…/connectors/telegram.py → …/tools/confirm.sh, from this file's path.

    realpath first, so a symlink to this file dropped beside a friendlier
    tools/confirm.sh runs the gate next to the *real* file.
    """
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.normpath(os.path.join(here, os.pardir, "tools", "confirm.sh"))


#: confirm.sh's exit when the card withdrew rather than being answered.
WITHDRAWN = 7
WITHDRAWN_TEXT = ("not sent — the confirmation expired or was withdrawn before anyone "
                  "answered, so nothing was sent.")
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
        return False, "not sent — Alfie could not check who this is going to, so nothing was sent.", ""
    if v.get("verdict") == "refuse":
        return False, v.get("message") or "not sent", ""
    prov = v.get("provenance")
    import json as _json
    return True, "", _json.dumps(prov, ensure_ascii=True) if isinstance(prov, dict) else ""


def confirm(to_line, text, provenance=""):
    """(approved, text). Approved only if a human clicked Send; `text` is
    the message to send — what they rewrote in the dialog when they did
    (confirm.sh exit 5, the new words on stdout), else what was shown."""
    import subprocess
    script = confirm_script()
    if not os.path.isfile(script) or not os.access(script, os.X_OK):
        return False, text
    try:
        r = subprocess.run([script, "Telegram", to_line, text],
                           capture_output=True, text=True, timeout=CONFIRM_TIMEOUT,
                           env=_with_provenance(provenance, card_env(CONFIRM_TIMEOUT)))
    except subprocess.TimeoutExpired:
        # Nobody answered in time: an expiry, not a cancel.
        return False, None
    except (subprocess.SubprocessError, OSError):
        return False, text
    if r.returncode == 0:
        return True, text
    if r.returncode == 5:
        for rec in (r.stdout or "").split("\0"):
            key, sep, value = rec.partition("=")
            if sep and key == "body" and value.strip():
                return True, value
    if r.returncode == WITHDRAWN:
        # The card withdrew (confirm.sh exit 7). `None` so the caller does
        # not say "you cancelled": nobody did.
        return False, None
    return False, text


def parse_send_request(raw):
    """stdin text → (to, text). Raises ValueError with one plain sentence."""
    import json
    try:
        req = json.loads(raw)
    except ValueError:
        raise ValueError("send expects one JSON object on stdin.")
    if not isinstance(req, dict):
        raise ValueError("send expects one JSON object on stdin.")
    unknown = sorted(k for k in req if k not in SEND_KEYS)
    if unknown:
        raise ValueError("send does not understand: %s." % ", ".join(unknown)[:80])

    to = req.get("to")
    if not isinstance(to, str) or not to.strip():
        raise ValueError("send needs 'to' — a @username, a phone number, or a chat id.")
    to = to.strip()
    if len(to) > MAX_TO or BAD_TEXT_RE.search(to) or "\n" in to:
        raise ValueError("'to' should be one @username, phone number or chat id.")

    text = req.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("send needs 'text' — the message to send.")
    if len(text) > MAX_TEXT:
        raise ValueError("that message is longer than Telegram allows (%d characters)." % MAX_TEXT)
    if BAD_TEXT_RE.search(text.replace("\r", "").replace("\n", "").replace("\t", "")):
        raise ValueError("'text' contains a character that cannot be shown in the confirmation. Use ordinary text.")
    return to, text


def describe(entity, fallback):
    """The name a person would recognise, plus the handle when there is one."""
    name = " ".join(x for x in [getattr(entity, "first_name", None),
                                getattr(entity, "last_name", None)] if x).strip()
    name = name or getattr(entity, "title", None) or ""
    handle = getattr(entity, "username", None)
    if name and handle:
        return "%s (@%s)" % (name, handle)
    if name:
        return name
    if handle:
        return "@%s" % handle
    return fallback


def offer_check(text):
    """(to, body) when the app handed this over and it is fresh, else
    (None, why) — tools/recipients.py `offer`, the check WhatsApp's
    send-offer uses, beside confirm.sh."""
    import subprocess
    tools = os.path.dirname(confirm_script())
    try:
        p = subprocess.run(["/usr/bin/python3", os.path.join(tools, "recipients.py"), "offer",
                            "--ppid", str(os.getppid())], input=text, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None, "not sent — that offer could not be checked."
    lines = (p.stdout or "").split("\n", 2)
    if p.returncode != 0 or lines[0] != "ok" or len(lines) < 3:
        return None, (lines[1] if len(lines) > 1 and lines[1] else "not sent — that offer could not be checked.")
    return (lines[1], lines[2]), ""


def cmd_send_offer(stdin_text):
    """The app's "Use draft": checked here, in this same process (the venv
    re-exec keeps the pid, so the parent the check asks about is still the
    app), then sent to exactly that chat with the dialog. There is no second
    entry point that skips the check."""
    got, why = offer_check(stdin_text)
    if not got:
        print(why)
        return 1
    to, body = got
    # The feed names a chat "telegram/<id>" (item_of); the send wants the id.
    m = re.match(r"^(?:telegram/)?(-?\d+)$", to)
    if not m:
        print("not sent — that is not a Telegram chat Alfie can reply to.")
        return 1
    return cmd_send([], offer=(m.group(1), body))


def cmd_send(argv, offer=None):
    if argv:
        print("send takes no arguments — the message is one JSON object on stdin.")
        return 2
    if not have_session():
        print("Alfie is not signed in to your own Telegram, so it cannot read or write "
              "your chats. Connect My own Telegram in Settings › Connections — that "
              "is separate from the Alfie you message on Telegram.")
        return 1
    if not have_telethon():
        print("A piece Alfie needs to reach Telegram is missing — reconnect it in Settings › Connections.")
        return 1
    try:
        to, text = offer if offer else parse_send_request(sys.stdin.read())
    except ValueError as e:
        print(str(e))
        return 1

    api_id, api_hash = telegram_creds()
    if not api_id or not api_hash:
        print("Alfie is not signed in to your own Telegram, so it cannot read or write "
              "your chats. Connect My own Telegram in Settings › Connections — that "
              "is separate from the Alfie you message on Telegram.")
        return 1

    from telethon.sync import TelegramClient
    client = TelegramClient(SESSION, int(api_id), api_hash)
    try:
        client.connect()
        if not client.is_user_authorized():
            print("Your Telegram sign-in has expired. Reconnect it in Settings › Connections.")
            return 1
        # Resolved first: the dialog has to name who this really goes to.
        # An unresolvable recipient is a refusal — never a send to an id
        # nobody could check.
        try:
            # An offer names the chat by its own id (the engine's thread).
            entity = client.get_entity(int(to) if offer and str(to).lstrip("-").isdigit() else to)
        except Exception as e:  # noqa: BLE001 — telethon raises a zoo
            print("Couldn't find anyone on Telegram matching that (%s). Nothing was sent." % type(e).__name__)
            return 1
        who = describe(entity, to)
        # Your own account resolves as "me": a contact tool never messages the
        # owner. And whoever it is, somebody must have named them.
        resolved = ["me"] if getattr(entity, "is_self", False) else [str(getattr(entity, "id", "") or "")]
        if offer:
            # The app vouched for this chat and these words (checked above,
            # by the parent process's signature and the offer's age): no send
            # ticket to redeem. The dialog below still shows it all.
            allowed, refusal, provenance = True, "", ""
        else:
            allowed, refusal, provenance = recipient_check(to, text, resolved)
        if not allowed:
            print(refusal)
            return 1
        approved, text = confirm(who, text, provenance)
        if not approved:
            print(WITHDRAWN_TEXT if text is None else "not sent — you cancelled")
            return 1
        # Rewritten in the dialog: the same two checks the request passed.
        if len(text) > MAX_TEXT:
            print("not sent — that message is longer than Telegram allows (%d characters)." % MAX_TEXT)
            return 1
        if BAD_TEXT_RE.search(text.replace("\r", "").replace("\n", "").replace("\t", "")):
            print("not sent — the rewritten message contains a character that cannot be sent.")
            return 1
        try:
            client.send_message(entity, text)
        except Exception as e:  # noqa: BLE001
            print("Telegram would not send that (%s). Nothing was sent." % type(e).__name__)
            return 1
    finally:
        try:
            client.disconnect()
        except Exception:  # noqa: BLE001 — a failed disconnect must not mask the result
            pass
    print("\u2713 sent to %s" % who)
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "pull":
        reexec_in_venv()
        sys.exit(cmd_pull())
    if cmd == "crawl":
        reexec_in_venv()
        sys.exit(cmd_crawl(sys.argv[2:]))
    if cmd == "items":
        reexec_in_venv()
        sys.exit(cmd_items(sys.argv[2:]))
    if cmd == "send":
        reexec_in_venv()
        sys.exit(cmd_send(sys.argv[2:]))
    if cmd == "send-offer":
        # The Memoe app's "Use draft" (SituationOffer.directSend). execv keeps
        # this pid and its parent, so the check in the venv still asks about
        # the process that started this one: the app, or not.
        reexec_in_venv()
        sys.exit(cmd_send_offer(sys.stdin.read()))
    reexec_in_venv()
    sys.exit(cmd_status() if cmd == "status" else 2)

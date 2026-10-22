#!/usr/bin/env python3
"""Use draft, sent from the Alfie app through the Mac's own apps: Messages
and Mail (status #10.2; the owner, 2026-09-29: "everything").

    offer_send.py imessage     one JSON object on stdin, from the app:
    offer_send.py mail          {"to": <the conversation's own id>, "body": …, "at": …}

Started by `imessage.sh send-offer` / `mail.sh send-offer` with `exec`, so
this process is the one the app started and its parent is the app:
- tools/recipients.py `offer` checks exactly that (the parent's signature)
  and that the offer is minutes old — the check WhatsApp, Telegram and every
  Composio service use; a call from a model's shell is refused;
- the reply goes to the conversation's own id (a Messages chat's guid; the
  newest message someone else wrote in a Mail conversation, from what the
  engine read), never a name looked up again;
- the confirmation card (tools/confirm.sh) shows who and what and takes a
  rewrite; nothing goes without its Send;
- the words reach AppleScript as `argv`, never inside the script's source,
  so no text can become a command.

Prints one line: "✓ sent to …" or "not sent — …". Exit 0 only on a send.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
CONFIRM_TIMEOUT = 600
WITHDRAWN = 7
MAX_TEXT = 8000
# osascript ran out of time while the app was sending: it may have gone, and
# a second tap would send it twice. "not sent" leads so the app shows it.
UNSURE = ("not sent — %s took too long to answer, so it may have gone after all; "
          "look in the conversation before sending it again.")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def tools_dir():
    return os.path.normpath(os.path.join(HERE, os.pardir, "tools"))


def offer_check(text):
    try:
        p = subprocess.run(["/usr/bin/python3", os.path.join(tools_dir(), "recipients.py"), "offer",
                            "--ppid", str(os.getppid())], input=text, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None, "not sent — that offer could not be checked."
    lines = (p.stdout or "").split("\n", 2)
    if p.returncode != 0 or lines[0] != "ok" or len(lines) < 3:
        return None, (lines[1] if len(lines) > 1 and lines[1] else "not sent — that offer could not be checked.")
    return (lines[1], lines[2]), ""


def confirm(service, who, text):
    """(approved, text): the person's click and any rewrite; (False, None)
    when the card expired."""
    script = os.path.join(tools_dir(), "confirm.sh")
    if not (os.path.isfile(script) and os.access(script, os.X_OK)):
        return False, text
    env = dict(os.environ, MOE_CONFIRM_DEADLINE=str(int(time.time() + CONFIRM_TIMEOUT - 15)))
    try:
        r = subprocess.run([script, service, who, text], capture_output=True, text=True,
                           timeout=CONFIRM_TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
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
        return False, None
    return False, text


def osascript(script, *args):
    """Run AppleScript with the values as argv — never spliced into it."""
    p = subprocess.run(["/usr/bin/osascript", "-", *args], input=script, capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        err = (p.stderr or "").strip()
        if "-1743" in err or "not allowed" in err.lower() or "not authorized" in err.lower():
            raise PermissionError(err[:200])
        raise RuntimeError(err[:200] or "no reason given")
    return (p.stdout or "").strip()


# ── Messages ───────────────────────────────────────────────────────────────

MESSAGES_SEND = '''
on run argv
  set chatGuid to item 1 of argv
  set theText to item 2 of argv
  tell application "Messages"
    send theText to chat id chatGuid
  end tell
  return "ok"
end run
'''


def chat_name(thread):
    """(name, members): the chat's name as the engine read it ("Family", or
    the person) and the people who wrote in it, so a group is recognisable
    on the card even when it has no name."""
    name, members = "", []
    try:
        with open(os.path.join(moe_home(), "feed", "native_imessage.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    it = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(it, dict) or it.get("thread") != thread:
                    continue
                if it.get("thread_name"):
                    name = str(it["thread_name"])[:80]
                frm = it.get("from") if isinstance(it.get("from"), dict) else {}
                who = str(frm.get("name") or frm.get("id") or "")[:40]
                if who and not frm.get("me") and who not in members:
                    members.append(who)
    except OSError:
        pass
    return name, members


def imessage_target(thread):
    """(chat guid, who) — a Messages chat's own guid ("iMessage;-;+1555…",
    "SMS;-;…", "iMessage;+;chat…"); anything else is not a chat Messages can
    be told to send to."""
    if not re.match(r"^(iMessage|SMS|RCS|any);[-+];\S+$", thread or ""):
        return None, ""
    return thread, thread.split(";", 2)[2]


def send_imessage(thread, body, *, confirm_fn=confirm, run=osascript):
    guid, who = imessage_target(thread)
    if not guid:
        return 1, "not sent — that is not a Messages conversation Alfie can reply to."
    name, members = chat_name(guid)
    if ";+;" in guid:
        if name:
            who = "the group \u201c%s\u201d" % name
        elif members:
            who = "the group with %s" % ", ".join(members[:5]) + (" and others" if len(members) > 5 else "")
        else:
            who = "a group chat Alfie has no names for"
    elif name and name != who:
        who = "%s (%s)" % (name, who)
    ok, text = confirm_fn("Messages", who, body)
    if not ok:
        return 1, ("not sent — the confirmation expired before anyone answered." if text is None
                   else "not sent — you cancelled")
    if len(text) > MAX_TEXT:
        return 1, "not sent — that message is too long."
    try:
        run(MESSAGES_SEND, guid, text)
    except subprocess.TimeoutExpired:
        return 1, UNSURE % "Messages"
    except PermissionError:
        return 1, "not sent — allow Alfie to control Messages (System Settings › Privacy & Security › Automation)."
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        return 1, "not sent — Messages would not send it (%s)." % str(e)[:120]
    return 0, "✓ sent to %s" % who


# ── Mail ───────────────────────────────────────────────────────────────────

MAIL_REPLY = '''
on run argv
  set mid to (item 1 of argv) as integer
  set theText to item 2 of argv
  set expected to item 3 of argv
  tell application "Mail"
    set hits to (every message of inbox whose id is mid)
    if (count of hits) is 0 then error "the message is no longer in the inbox"
    set r to reply (item 1 of hits) opening window false
    -- A reply goes to the message's Reply-To, which can name someone other
    -- than the sender the card showed (a list, a forged header): refuse it.
    set rcpts to to recipients of r
    if (count of rcpts) is not 1 then
      close r saving no
      error "MOE_ELSEWHERE the reply would go to more than one address"
    end if
    set actual to address of item 1 of rcpts
    ignoring case
      if actual is not expected then
        close r saving no
        error "MOE_ELSEWHERE the reply would go to " & actual & ", not the sender"
      end if
    end ignoring
    set content of r to theText
    if not (send r) then error "Mail did not send it"
  end tell
  return "ok"
end run
'''


def mail_target(thread):
    """(Mail's own id for the newest message someone else wrote in that
    conversation, their address) — from what the engine read of it."""
    path = os.path.join(moe_home(), "feed", "native_mail.jsonl")
    best = None
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    it = json.loads(line)
                except ValueError:
                    continue
                frm = it.get("from") if isinstance(it.get("from"), dict) else {}
                if it.get("thread") != thread or frm.get("me") or "@" not in str(frm.get("id") or ""):
                    continue
                m = re.match(r"^mail/(\d+)$", str(it.get("id") or ""))
                if m and (best is None or float(it.get("at") or 0) >= best[2]):
                    best = (int(m.group(1)), str(frm.get("id") or ""), float(it.get("at") or 0))
    except OSError:
        return None, ""
    return (best[0], best[1]) if best else (None, "")


def send_mail(thread, body, *, confirm_fn=confirm, run=osascript, target_fn=mail_target):
    if not re.match(r"^mail/\d+$", thread or ""):
        # Named by its subject: anyone's later mail with that subject would
        # be taken for this conversation.
        return 1, "not sent — Alfie cannot tell that mail conversation apart from others with the same subject."
    mid, who = target_fn(thread)
    if mid is None:
        return 1, "not sent — Alfie does not have that mail conversation to reply to."
    ok, text = confirm_fn("Mail", who, body)
    if not ok:
        return 1, ("not sent — the confirmation expired before anyone answered." if text is None
                   else "not sent — you cancelled")
    if len(text) > MAX_TEXT:
        return 1, "not sent — that message is too long."
    try:
        run(MAIL_REPLY, str(mid), text, who)
    except PermissionError:
        return 1, "not sent — allow Alfie to control Mail (System Settings › Privacy & Security › Automation)."
    except subprocess.TimeoutExpired:
        return 1, UNSURE % "Mail"
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        why = str(e)
        if "MOE_ELSEWHERE" in why:
            return 1, "not sent — %s." % why.split("MOE_ELSEWHERE", 1)[1].strip().rstrip(".")[:160]
        return 1, "not sent — Mail would not send it (%s)." % why[:120]
    return 0, "✓ sent to %s" % who


def main(argv):
    kind = argv[1] if len(argv) > 1 else ""
    if kind not in ("imessage", "mail"):
        print("usage: offer_send.py imessage|mail < offer.json", file=sys.stderr)
        return 2
    got, why = offer_check(sys.stdin.read())
    if not got:
        print(why)
        return 1
    thread, body = got
    rc, line = (send_imessage if kind == "imessage" else send_mail)(thread, body)
    print(line)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

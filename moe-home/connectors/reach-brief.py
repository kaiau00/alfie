#!/usr/bin/env python3
"""The brief's two sentences about reaching the owner. Called by sync.sh.

    reach-brief.py section        the "## Reaching them" section
    reach-brief.py line "<line>"  one "Not connected" line, relabelled when it
                                  is about a chat app; nothing otherwise

**The incident.** The owner said "message me on Telegram". The brief's "Not
connected" section said `telegram — needs-setup: you have not signed in to
Telegram yet`, which is the *personal-account reader* (connectors/telegram.py,
Telethon) — while Memoe's own bot on his phone, which the cloud holds, was
working and invisible. The brain read "Telegram not connected", had no way to
reach him, and a job it wrote messaged a contact instead.

So, the same shape as sync.sh's Composio correction, and for the same reason
(a specific sentence beats a general list): a chat app the cloud carries is
named CONNECTED, first, with the tool that reaches him; the personal-account
reader's status stays, second, labelled as what it is — optional, for reading
his own chats. And a standing section says which channels reach him right
now, so nothing has to be inferred.

"Connected through Memoe" needs the CLOUD's word that the owner's own chat
is confirmed there (``$MOE_HOME/cloud/owner-reach.json``, from
``channels.py owner-status``), not only that it holds the bot. What the cloud
holds is ``$MOE_HOME/cloud/channel-holder.json``'s ``holder: edge`` rows — written by channel-holder.py after it asked the
provider where it actually sends, never assumed. Stdlib only; any unreadable
file is "nothing known", which keeps the old sentence.
"""
import json
import os
import sys

MOE = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")

#: The chat apps whose local connector reads the owner's PERSONAL account
#: (Telethon, the linked WhatsApp device). Not being signed in there is not
#: "cannot reach him".
PERSONAL = ("telegram", "whatsapp")
TOOL = "reach_owner"


def _json(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def held():
    """Chat apps Memoe's cloud carries for them, sorted."""
    rows = _json(os.path.join(MOE, "cloud", "channel-holder.json")).get("channels")
    if not isinstance(rows, dict):
        return []
    return sorted(str(name) for name, row in rows.items()
                  if isinstance(row, dict) and row.get("holder") == "edge")


def reaches():
    """Chat apps the CLOUD says reach the owner — their own chat confirmed and
    still let in — as `channels.py owner-status` last wrote it. Holding a
    channel is not enough: the bot can be connected while Moe does not know
    which chat is theirs."""
    rows = _json(os.path.join(MOE, "cloud", "owner-reach.json")).get("channels")
    return sorted(str(c) for c in rows or [] if isinstance(c, str)) if isinstance(rows, list) else []


def ticked():
    raw = _json(os.path.join(MOE, "config.json")).get("reminderChannels")
    if not isinstance(raw, list):
        return []
    return [str(x).strip().lower() for x in raw if isinstance(x, str) and x.strip()]


def section():
    carried = reaches()
    waiting = [c for c in held() if c not in carried]
    forwards = [c for c in ticked() if c not in carried]
    out = ["## Reaching them", ""]
    if carried:
        out.append("- Connected through Memoe (Moe's own bot, their own chat): %s."
                   % ", ".join(carried))
    if waiting:
        out.append("- Memoe's bot is connected on %s, but their own chat there is not "
                   "confirmed, so Moe cannot message them on it. Connections › Telegram › "
                   "Confirm it's you is where they confirm it, when Memoe knows which chat "
                   "is theirs; until then messages stay on the Mac." % ", ".join(waiting))
    if forwards:
        out.append("- Forwarded from this Mac (they ticked these): %s." % ", ".join(forwards))
    if not carried and not forwards and not waiting:
        out.append("- No chat app reaches them yet; a message waits in their inbox on the Mac.")
    out += ["",
            "To tell them something outside this reply — or when they say \"message me\", "
            "\"text me\", \"on Telegram\" — use %s: it knows whether they are at the Mac "
            "and which of their channels are live. Never use a contact-send tool "
            "(WhatsApp, Telegram, email, SMS) to reach them, and never write a job "
            "that does. Say which channel it used." % TOOL, ""]
    return "\n".join(out)


def line(text):
    """The relabelled bullet(s) for one "Not connected" entry, or ""."""
    name = text.split(" ", 1)[0].strip().lower()
    rest = text.split(" — ", 1)[1] if " — " in text else text[len(name):].strip()
    if name in reaches():
        return ("- %s: CONNECTED through Memoe — their own chat with Moe's bot. Reach them "
                "there with %s.\n  (Only reading their personal %s account is not set up, "
                "which is optional: %s)" % (name, TOOL, name, rest))
    if name in held():
        return ("- %s: Memoe's bot is connected for talking to Moe, but their own chat "
                "there is not confirmed, so Moe cannot message them on it yet (ask them to "
                "open Connections › Telegram › Confirm it's you).\n  (Only "
                "reading their personal %s account is not set up, which is optional: %s)"
                % (name, name, rest))
    if name in PERSONAL:
        return ("- %s (their personal account — optional, only for reading their own chats): %s"
                % (name, rest))
    return ""


def main(argv):
    if argv[:1] == ["section"]:
        print(section())
        return 0
    if argv[:1] == ["line"] and len(argv) > 1:
        said = line(argv[1])
        if said:
            print(said)
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

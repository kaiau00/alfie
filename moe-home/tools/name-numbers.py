#!/usr/bin/env python3
"""Replace bare phone numbers with contact names in piped '|' separated rows.

WhatsApp labels one-to-one chats with the number; your Contacts knows the name.
Matching is on the last nine digits so +1 (555) 010-4477, 5550104477 and
15550104477 all resolve to the same person.
"""
import json, os, re, sys

try:
    NAMES = json.load(open(os.path.expanduser("~/.moe/contacts.json")))
except Exception:
    NAMES = {}

def resolve(field: str) -> str:
    raw = field.strip()
    # Leave anything that looks like an address alone: the JID is what you send
    # to, and rewriting it to a friendly name makes the row unusable.
    if "@" in raw:
        return raw
    digits = re.sub(r"\D", "", raw)
    if len(digits) < 7:
        return raw
    name = NAMES.get(digits[-9:])
    if not name:
        return raw
    # Keep the number visible: it's what you need to actually send.
    return f"{name} ({digits})"

# A reader that stops early (a byte cap, `head`) is a clean stop, not a
# failure: until 2026-10-07 this raised BrokenPipeError when one did, and a
# capped WhatsApp crawl under `set -o pipefail` exited 120 with its answer
# already written (ticket #21).
try:
    for line in sys.stdin:
        parts = line.rstrip("\n").split("|")
        print("|".join(resolve(p) if re.search(r"\d{7,}", p) else p for p in parts))
    sys.stdout.flush()
except BrokenPipeError:
    # Point stdout at /dev/null so the interpreter's own flush at exit does
    # not raise the same error again on the way out.
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    sys.exit(0)

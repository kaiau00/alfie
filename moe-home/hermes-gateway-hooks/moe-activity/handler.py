"""One line per finished turn, so Moe can see the work it did not start.

Moe drives Hermes over the OpenAI-compatible api_server: one HTTP request in,
one response out. Nothing pushes back. So a turn that begins anywhere else —
a Telegram message, say — happens completely outside Moe's knowledge: it
never appears in the app, never reaches the ledger, and the first the user
hears of it is the reply on their phone.

Inbound turns only. `agent:end` is emitted from the gateway's inbound-message
pipeline and nowhere else — a cron job's delivery never fires it, so scheduled
work is NOT recorded here. `hermes cron runs` is where that lives.

`hooks.outbound` is Hermes's documented answer and would work, but it POSTs
over HTTP and so needs a listener, a port and a shared secret inside Memoe.app —
a Swift change and a new network surface for what is, in the end, an append.
This is the same information through a mechanism that already runs inside the
gateway: a drop-in gateway hook (gateway/hooks.py), in-process, whose errors
are caught and can never block a turn.

WHAT IS NOT WRITTEN, deliberately: the message and the response. Moe's own
confirm-send hook says it in as many words — "the log is for 'why was I asked'
and 'what got blocked', and a log of message bodies is a liability" — and this
file would be a far better prize than that one, since it would hold both sides
of every conversation on every platform. The session id is recorded instead:
anyone who needs the content can ask Hermes's own store for that session, which
already holds it under the user's own permissions.
"""

import json
import os
import time

# `.get(k, default)` returns "" for a variable that is SET AND EMPTY, and
# expanduser("") is "" — so MOE_HOME= would have put this file at the relative
# path logs/activity.jsonl, inside whatever the gateway's cwd happens to be.
# `or` is the idiom the rest of this repo uses for exactly that reason.
_PATH = os.path.join(os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe"),
                     "logs", "activity.jsonl")
# A day of chat is a few hundred lines; a runaway loop is not. Trimmed from the
# front so the newest is always what a reader sees last.
_MAX_LINES = 5000


#: What the gateway truncates message/response to before a hook sees them.
_TRUNCATED_AT = 500


def _size(value):
    """`"120"`, or `"500+"` when the gateway had already cut it short."""
    n = len(str(value or ""))
    return "%d+" % n if n >= _TRUNCATED_AT else str(n)


def _trim(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
        if len(lines) <= _MAX_LINES:
            return
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines[-_MAX_LINES:])
    except OSError:
        pass


async def handle(event_type, context):
    if event_type != "agent:end":
        return
    ctx = context or {}
    platform = str(ctx.get("platform") or "")
    # api_server IS Moe. It already knows about its own turns, and writing them
    # here would bury the ones it does not know about.
    if platform in ("", "api_server"):
        return
    row = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "platform": platform,
        "chat_type": str(ctx.get("chat_type") or ""),
        "chat_id": str(ctx.get("chat_id") or ""),
        "session_id": str(ctx.get("session_id") or ""),
        "model": str(ctx.get("model") or ""),
        "provider": str(ctx.get("provider") or ""),
        # Sizes, not text — and CLAMPED, not exact. The gateway truncates
        # both fields to 500 characters before a hook ever sees them
        # (gateway/run.py, documented in gateway/hooks.py), so anything
        # longer arrives as exactly 500. Recording that as a length would be
        # a quiet lie on every substantial turn; the suffix says what it is.
        "in_chars": _size(ctx.get("message")),
        "out_chars": _size(ctx.get("response")),
    }
    try:
        os.makedirs(os.path.dirname(_PATH), exist_ok=True)
        # 0600: chat ids are personal data even without the words.
        fd = os.open(_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        _trim(_PATH)
    except OSError:
        # gateway/hooks.py catches and logs anything raised here, but a hook
        # that cannot write should still not be the loudest thing in the log.
        pass

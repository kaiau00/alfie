#!/usr/bin/env python3
"""Alfie's own records as the situations engine's items: the meetings Alfie
took notes in, and what the person said to Alfie in chat. Not connections —
nothing here reaches outside this Mac — so they are read the way any
source is (`items --since <cursor>`, moe-home/lib/situations.py), under the
names `moe/meetings` and `moe/chats`.

    moe_items.py meetings --since <cursor>
    moe_items.py chats --since <cursor>

**meetings** — every finished, summarised meeting (`$MOE_HOME/meetings/
<folder>/meeting.json`): its summary, decisions, action items and to-dos as
one item, kind "meeting", written by the owner (it is their record of the
meeting). A meeting summarised again is read again. Cursor: the newest
`meeting.json` modification time read.

**chats** — the person's own words to Alfie (Hermes's `state.db`, user turns
of the person's conversations, never scheduled jobs or helpers), with Alfie's
notes and pasted context taken out the way the loop sweep does
(moe-screen/sweep.py `persons_text`). Only turns that speak of a commitment
are emitted ("I told Dan I'd send it Friday", "she promised to pay"):
everything else said to Alfie is already Alfie's to act on in the conversation
itself. Kind "moe-chat". Cursor: the message id.

An empty cursor is the first look: only the cursor, so the engine starts
from now (MOE_ITEMS_BACKFILL_HOURS reads back that far, for a measurement
run). Read-only. Stdlib only.
"""
from __future__ import annotations

import glob
import importlib.util
import json
import os
import re
import sqlite3
import sys
import time
import types
from typing import Any, Dict, List, Optional, Tuple

TEXT_CAP = 4000
LIMIT = 200
#: Hermes session sources that are the person talking (not cron, not a
#: helper): the Mac app's api_server and any chat app a gateway serves.
NOT_THE_PERSON = ("cron", "subagent", "delegate", "batch", "tool")
#: Turns the app types for the person (SituationOffer.sendRequest): the
#: words in them are a draft Moe wrote, not a promise the person made
#: (re-review 2026-09-29 #3).
OWN_REQUESTS = ("Send the reply between the ", "Send the message between the ")
#: A commitment, either side's, in how people report one to an assistant.
COMMITMENT = re.compile(
    r"(?:\b(?:promis\w*|i'?ll|i will|we'?ll|we will|i'm going to|i said i'?d|i told \w+ i'?d|"
    r"(?:he|she|they|\w+) (?:said|says|promised) (?:he|she|they)'?d|owe[sd]?|committed|"
    r"agreed to|supposed to|by (?:mon|tue|wed|thu|fri|sat|sun)\w*|by tomorrow|by next)\b|"
    r"הבטח|אמרתי ש|אמר ש|אמרה ש|התחייב|אשלח|אחזור|עד מחר|עד יום)", re.I)


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home() -> str:
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _first_look(now: float) -> Optional[float]:
    """The backfill start for a measurement run, or None: cursor only."""
    hours = os.environ.get("MOE_ITEMS_BACKFILL_HOURS", "")
    return now - int(hours) * 3600 if hours.isdigit() else None


# ── meetings ───────────────────────────────────────────────────────────────


def meeting_text(rec: Dict[str, Any]) -> str:
    notes = rec.get("notes") if isinstance(rec.get("notes"), dict) else {}
    lines = []
    if notes.get("summary"):
        lines.append(str(notes["summary"]).strip())
    for label, key in (("Decision", "decisions"), ("To do", "todos"), ("Open question", "open_questions")):
        for v in notes.get(key) or []:
            if isinstance(v, str) and v.strip():
                lines.append("%s: %s" % (label, v.strip()))
    for a in notes.get("action_items") or []:
        if not isinstance(a, dict) or not str(a.get("what") or "").strip():
            continue
        who = str(a.get("who") or "").strip()
        when = str(a.get("when") or "").strip()
        lines.append("Action item: %s%s%s" % ((who + " will ") if who else "", str(a["what"]).strip(),
                                                (" (by %s)" % when) if when else ""))
    return "\n".join(lines)


def _started(rec: Dict[str, Any], fallback: float) -> float:
    from datetime import datetime, timezone
    try:
        return datetime.strptime(str(rec.get("startedAt") or ""), "%Y-%m-%dT%H:%M:%SZ") \
            .replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return fallback


def meetings(since: str, now: Optional[float] = None) -> Tuple[List[Dict[str, Any]], str]:
    now = time.time() if now is None else now
    if not since:
        start = _first_look(now)
        if start is None:
            return [], str(int(now))
        since = str(int(start))
    try:
        cursor = float(since)
    except ValueError:
        cursor = now
    found = []
    for path in glob.glob(os.path.join(moe_home(), "meetings", "*", "meeting.json")):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if mtime <= cursor:
            continue
        try:
            with open(path, encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(rec, dict) or not rec.get("summarised") or rec.get("incomplete"):
            continue
        text = meeting_text(rec)
        if not text:
            continue
        folder = os.path.basename(os.path.dirname(path))
        title = str(((rec.get("notes") or {}).get("title")) or "Meeting").strip()
        # Dated when it happened, and one item per meeting: its record is
        # rewritten later (the audio janitor, a re-summary) and must not come
        # back as a meeting held today (re-review 2026-09-29 #2).
        found.append((mtime, {
            "id": folder, "thread": "meeting:" + folder,
            "thread_name": ("Meeting: " + title)[:120], "at": _started(rec, mtime),
            "from": {"id": "me", "name": "", "me": True}, "to_me": True, "group": False,
            "kind": "meeting", "text": text[:TEXT_CAP]}))
    found.sort(key=lambda t: t[0])
    found = found[:LIMIT]
    new_cursor = str(found[-1][0]) if found else str(cursor)
    return [it for _, it in found], new_cursor


# ── chats with Moe ─────────────────────────────────────────────────────────


def _persons_text():
    """moe-screen's `persons_text`, loaded as a package member so its own
    relative import (deliver) resolves; beside Hermes when installed, in the
    repo otherwise."""
    for d in (os.path.join(hermes_home(), "plugins", "moe-screen"),
              os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hermes-plugins", "moe-screen")):
        path = os.path.join(d, "sweep.py")
        if not os.path.isfile(path):
            continue
        pkg_name = "moe_screen_for_items"
        if pkg_name not in sys.modules:
            pkg = types.ModuleType(pkg_name)
            pkg.__path__ = [d]
            sys.modules[pkg_name] = pkg
        spec = importlib.util.spec_from_file_location(pkg_name + ".sweep", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[pkg_name + ".sweep"] = mod
        spec.loader.exec_module(mod)
        return mod.persons_text
    raise RuntimeError("moe-screen's sweep.py is not installed")


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        try:
            parts = json.loads(content)
        except ValueError:
            return content
        if isinstance(parts, list):
            return "\n".join(str(p.get("text") or "") for p in parts
                             if isinstance(p, dict) and p.get("type") in (None, "text"))
        return content
    return str(content or "")


def chats(since: str, now: Optional[float] = None, db: Optional[str] = None,
          persons_text=None) -> Tuple[List[Dict[str, Any]], str]:
    now = time.time() if now is None else now
    db = db or os.path.join(hermes_home(), "state.db")
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=10)
    try:
        cols = {r[1] for r in con.execute("PRAGMA table_info(messages)")}
        scols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
        if not {"id", "session_id", "role", "content", "timestamp"} <= cols or not {"id", "source"} <= scols:
            raise RuntimeError("unfamiliar Hermes session layout")
        if not since:
            start = _first_look(now)
            if start is None:
                top = con.execute("SELECT COALESCE(MAX(id), 0) FROM messages").fetchone()[0]
                return [], str(int(top))
            row = con.execute("SELECT COALESCE(MIN(id), 1) - 1 FROM messages WHERE timestamp >= ?",
                              (start,)).fetchone()
            since = str(int(row[0] or 0))
        if not since.isdigit():
            # A cursor this never wrote: start from now, never from the top.
            top = con.execute("SELECT COALESCE(MAX(id), 0) FROM messages").fetchone()[0]
            return [], str(int(top))
        cursor = int(since)
        rows = con.execute(
            "SELECT m.id, m.session_id, m.content, m.timestamp, s.source, m.role FROM messages m "
            "JOIN sessions s ON s.id = m.session_id WHERE m.id > ? ORDER BY m.id LIMIT ?",
            (cursor, LIMIT * 5)).fetchall()
    finally:
        con.close()
    persons_text = persons_text or _persons_text()
    out = []
    last = cursor
    for mid, sid, content, ts, source, role in rows:
        last = max(last, int(mid))
        if role != "user" or str(source or "").lower() in NOT_THE_PERSON:
            continue
        try:
            text = persons_text(_content_text(content))
        except Exception:  # noqa: BLE001 — one odd turn is not the read
            continue
        if text.startswith("# What is going on right now"):
            # The brief as builds before <brief> fencing sent it: the
            # person's words are after its `---`, the reminder after them.
            parts = re.split(r"\n-{3,}[ \t]*\n", text, maxsplit=1)
            text = re.split(r"\n#{1,6} Before you answer\b", parts[1])[0].strip() if len(parts) == 2 else ""
        if "<transcript>" in text:
            continue                    # a meeting handed to the brain: moe/meetings reads those
        if "========" in text or text.startswith(OWN_REQUESTS):
            continue                    # Moe's own "Use draft" request, its draft fenced inside
        if not text or not COMMITMENT.search(text):
            continue
        out.append({"id": "chat:%d" % mid, "thread": "chat:%s" % sid, "thread_name": "Your chat with Alfie",
                    "at": float(ts), "from": {"id": "me", "name": "", "me": True}, "to_me": True,
                    "group": False, "kind": "moe-chat", "text": text[:TEXT_CAP]})
    # A user turn is written when it is sent, never later: a message id read
    # is read for good.
    return out, str(last)


def main(argv: List[str]) -> int:
    kind = argv[1] if len(argv) > 1 else ""
    if kind not in ("meetings", "chats") or "--since" not in argv:
        print("usage: moe_items.py meetings|chats --since CURSOR", file=sys.stderr)
        return 2
    i = argv.index("--since") + 1
    since = argv[i] if i < len(argv) else ""
    try:
        found, cursor = (meetings if kind == "meetings" else chats)(since)
    except (OSError, sqlite3.Error, RuntimeError) as e:
        print("%s: %s" % (kind, e), file=sys.stderr)
        return 1
    for it in found:
        print(json.dumps(it, ensure_ascii=False))
    print(json.dumps({"cursor": cursor}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

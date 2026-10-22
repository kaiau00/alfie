#!/usr/bin/env python3
"""What already happened, out of the stores Hermes keeps it in.

Two panes read this one script, because they read two halves of one
question and neither half has a `--json` anywhere in the CLI.

    history.py activity [--days 7] [--log-lines 40]
    history.py search --query TEXT [--limit 40]   (sessions on stdin)

**Activity** is `~/.moe/logs/activity.jsonl` — one line per turn that
happened somewhere other than Alfie's own channel — plus Hermes's cron run
ledger and its failure incidents, out of `cron/executions.db`.

**Search** is Hermes's FTS5 index over every message it has ever stored,
and it is deliberately crippled: it searches ONLY the sessions given to it
on stdin, and refuses to run at all when none are. See below.

Four things this file exists to get right.

**The activity log records no message bodies, and this does not add any.**
The hook that writes it says why in as many words: it would hold both
sides of every conversation on every platform and would be a far better
prize than anything else in `~/.moe`. What comes back here is what is on
the line — when, where, which model, how many characters — and the
session id, which is how the words are reached under the person's own
permissions rather than through a log.

**`in_chars` is a STRING and sometimes ends in `+`.** The gateway
truncates a message to 500 characters before a hook sees it, so the hook
writes `"500+"` rather than a length that would be a quiet lie on every
substantial turn. Older lines on this Mac (2026-09-01) carry plain
integers from the version before that. Both shapes are still in the file;
both are normalised to a string here, and the `+` is kept.

**Cron runs are rolled up per job per day.** Measured on this Mac:
`moe-calendar-heads-up` runs every two minutes, so a week is 5,000 rows of
"ran, fine". A timeline made of those is not a timeline. One row per job
per day carries the count, the failures and the last time, and a job that
ran once that day reads as the single event it was.

**The search is a guard, not a filter.** Hermes's index holds 7,497
messages on this Mac across 763 sessions: cron prompts, subagent turns,
CLI sessions, and the conversations a person deleted — Hermes keeps its
copy of a deleted thread on purpose (`CLOUD-PLAN` §9). Only 117 of the
657 api_server sessions are Alfie app threads at all. So this does not
search and let the caller sort: the caller sends the sessions the ledger
vouches for, on stdin, one per line, and nothing else is ever read. A
`search` with no sessions is refused rather than run wide — that way the
words of a deleted conversation never leave Hermes's store, whatever the
pane above does.

One JSON object on stdout, always: `{"ok": true, …}` or
`{"ok": false, "error": "…"}`, exit 0 for both. A non-zero exit with no
JSON means this crashed, which is a different thing.

Read-only throughout: every database is opened `mode=ro` and, where
Hermes holds a write lock, `immutable=1`, exactly as `job-activity.py`
does. Nothing here writes anything.

Python 3.9, stdlib only — no PyYAML, so it runs under /usr/bin/python3 as
well as the Hermes venv.
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import time

DEFAULT_DAYS = 7
DEFAULT_LOG_LINES = 40
DEFAULT_LIMIT = 40
#: Hits read out of the index at most, whatever the caller asks for. A
#: search is a keystroke away and this is a settings pane, not a corpus
#: tool.
MAX_LIMIT = 200
#: Sessions accepted on stdin. Generous — this Mac has 117 — and finite,
#: because the list becomes an IN clause.
MAX_SESSIONS = 5000

#: Moe's own upkeep, the same five names `reminders.py` reserves. Kept here
#: rather than imported because that module needs PyYAML at import and this
#: one deliberately does not.
#:
#: MATCHED CASE-INSENSITIVELY, and that is not tidiness. Hermes resolves a
#: job reference case-insensitively, so `MOE-PROACTIVE` and `moe-proactive`
#: are one job to it and were two to a `frozenset` lookup — which is how
#: `reminders.py` came to accept a name that made Moe's own upkeep job
#: permanently unaddressable. This file only LABELS a history row, so the
#: same slip here is a wrong label rather than a hijack; it is folded anyway,
#: because two copies of one rule disagreeing is how the next person finds
#: out the rule was never one rule.
UPKEEP = frozenset((
    "moe-learn-deep",
    "moe-proactive",
    "moe-watch-pulse",
    "moe-drain-intents",
    "moe-calendar-heads-up",
    "moe-situations",
))
UPKEEP_PREFIX = "moe-watch-"


def is_upkeep(name):
    """Is this one of Alfie's own jobs? Case-insensitively, per the note above."""
    folded = (name or "").strip().casefold()
    return bool(folded in UPKEEP or folded.startswith(UPKEEP_PREFIX))

#: Every key each answer carries, whether or not it has anything to say.
#:
#: A contract with Swift rather than tidiness. Swift's synthesised
#: `Decodable` does NOT fall back to a property's default for a missing
#: key — it throws `keyNotFound` and the WHOLE answer decodes to nothing.
#: One absent `error` on a success turned a working Reminders pane into
#: "Moe couldn't reach the part of itself that keeps the clock" on
#: 2026-09-04. The Swift side reads every key with `decodeIfPresent` too;
#: this is the second of two halves, because the failure is silent in
#: exactly the direction that matters.
SHAPES = {
    "activity": {"ok": False, "error": "", "days": DEFAULT_DAYS, "elsewhere": [],
                 "runs": [], "incidents": [], "log": {}},
    "search": {"ok": False, "error": "", "query": "", "hits": [],
               "sessions": 0, "capped": False},
}


def answer(kind, fields):
    """One answer, with every key its shape promises."""
    out = dict(SHAPES[kind])
    out.update(fields)
    return out


def die(message, kind):
    json.dump(answer(kind, {"ok": False, "error": str(message)}), sys.stdout)
    sys.stdout.write("\n")
    return 0


def hermes_home():
    # `.get(k, default)` returns "" for a variable that is set and empty,
    # and expanduser("") is "" — so HERMES_HOME= would point every path
    # below at the current directory. `or` is the idiom this repo uses.
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def read_only(path):
    """A read-only connection, or None.

    `immutable` is the fallback and it is not optional: Hermes's databases
    are WAL and it closes after each write, so between writes there is no
    -shm file and a plain `mode=ro` connection fails at query time rather
    than at connect time. `immutable=1` can read a value a moment stale,
    which for a screen that shows what already happened is the right
    trade against not opening at all. Lifted from `job-activity.py`,
    which found this the hard way.
    """
    if not os.path.isfile(path):
        return None
    for uri in ("file:%s?mode=ro" % path, "file:%s?mode=ro&immutable=1" % path):
        try:
            c = sqlite3.connect(uri, uri=True, timeout=1)
            c.execute("select 1 from sqlite_master limit 1")
            return c
        except sqlite3.Error:
            continue
    return None


#: `+0000`, not `+00:00` — the offset shape `time.strftime("%z")` writes.
_BARE_OFFSET = re.compile(r"([+-])(\d{2})(\d{2})$")


def seconds(v):
    """Hermes writes timestamps as epoch floats in some tables and ISO
    strings in others, and both turn up in `executions` depending on when
    the row was written.

    The colon in the offset is not a nicety. `activity.jsonl` is written
    with `time.strftime("%Y-%m-%dT%H:%M:%S%z")`, which produces `-0400`,
    and `datetime.fromisoformat` did not accept that until Python 3.11.
    This script runs under /usr/bin/python3 as well as the Hermes venv,
    and on this Mac those are 3.9 and 3.11 — so without the colon every
    line of the activity log parsed as epoch 0 under one interpreter and
    fell out of the window, and the pane drew an empty timeline on a Mac
    with a week of turns in it. Measured, not guessed: it did exactly
    that on the first run.
    """
    if isinstance(v, (int, float)):
        return float(v)
    try:
        s = str(v).strip().replace("Z", "+00:00")
        if "T" in s:
            from datetime import datetime
            return datetime.fromisoformat(_BARE_OFFSET.sub(r"\1\2:\3", s)).timestamp()
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def iso(epoch):
    """Local time with an offset, the shape Swift's ISO8601 reader takes."""
    if not epoch:
        return ""
    t = time.localtime(epoch)
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", t)


# ---------------------------------------------------------------------------
# Activity
# ---------------------------------------------------------------------------


def chars(value):
    """A count as the hook wrote it: `"29"`, or `"500+"` where the gateway
    had already cut the text short before the hook could see it.

    Both shapes are in the live file. Lines written before 2026-09-01 hold
    a bare integer; everything since holds a string, sometimes suffixed.
    Anything else is dropped rather than guessed at — a wrong number here
    reads as a fact about a conversation.
    """
    if isinstance(value, bool):
        return ""
    if isinstance(value, int):
        return str(value)
    text = str(value or "").strip()
    return text if re.fullmatch(r"\d+\+?", text) else ""


def elsewhere(since):
    """Turns that happened somewhere other than Alfie's own channel.

    The file is the `moe-activity` gateway hook's, capped at 5,000 lines
    and trimmed from the front, so this reads it whole. A line that will
    not parse is skipped in silence: a hook that wrote a bad line once
    must not cost the person the rest of their history.
    """
    path = os.path.join(moe_home(), "logs", "activity.jsonl")
    if not os.path.isfile(path):
        return []
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                at = str(row.get("at") or "")
                if seconds(at) < since:
                    continue
                out.append({
                    "at": at,
                    "platform": str(row.get("platform") or ""),
                    "chat_type": str(row.get("chat_type") or ""),
                    "chat_id": str(row.get("chat_id") or ""),
                    "session": str(row.get("session_id") or ""),
                    "model": str(row.get("model") or ""),
                    "provider": str(row.get("provider") or ""),
                    "in_chars": chars(row.get("in_chars")),
                    "out_chars": chars(row.get("out_chars")),
                })
    except OSError:
        return []
    out.sort(key=lambda r: r["at"], reverse=True)
    return out


def job_names():
    """job id → the name it was created under. {} when unreadable."""
    path = os.path.join(hermes_home(), "cron", "jobs.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    raw = data.get("jobs", data) if isinstance(data, dict) else data
    items = raw if isinstance(raw, list) else \
        list(raw.values()) if isinstance(raw, dict) else []
    return {str(j.get("id") or ""): str(j.get("name") or "")
            for j in items if isinstance(j, dict)}


def runs(since, names):
    """Cron runs, one row per job per day.

    Not one row per run. `moe-calendar-heads-up` fires every two minutes,
    which is about 5,000 rows a week from one job — and a timeline made of
    those says nothing at all. The count, the failures and the last time
    are what a person is actually asking, and a job that ran once that day
    still reads as the one event it was.

    Failures are counted here but never rolled away: `incidents` below is
    the per-failure record, and it is never grouped.
    """
    c = read_only(os.path.join(hermes_home(), "cron", "executions.db"))
    if c is None:
        return []
    try:
        rows = list(c.execute(
            "select job_id, status, coalesce(finished_at, started_at, claimed_at) "
            "from executions"))
    except sqlite3.Error:
        return []
    buckets = {}
    for job_id, status, at in rows:
        epoch = seconds(at)
        if epoch < since:
            continue
        day = time.strftime("%Y-%m-%d", time.localtime(epoch))
        key = (str(job_id or ""), day)
        b = buckets.get(key)
        if b is None:
            name = names.get(str(job_id or ""), "")
            b = buckets[key] = {
                "job": str(job_id or ""), "name": name, "day": day,
                "runs": 0, "failures": 0, "first_at": "", "last_at": "",
                "upkeep": is_upkeep(name),
                "_first": epoch, "_last": epoch,
            }
        b["runs"] += 1
        if str(status or "").lower() in ("failed", "error"):
            b["failures"] += 1
        b["_first"] = min(b["_first"], epoch)
        b["_last"] = max(b["_last"], epoch)
    out = []
    for b in buckets.values():
        b["first_at"] = iso(b.pop("_first"))
        b["last_at"] = iso(b.pop("_last"))
        out.append(b)
    out.sort(key=lambda r: r["last_at"], reverse=True)
    return out


def incidents(since, names):
    """Every cron failure Hermes minted, one row each and never grouped.

    A failure is the thing on this screen a person can act on, so it keeps
    its own row however many times the same job succeeded around it.
    `state` is Hermes's own — detected, alerted, acked, closed — and is
    passed through rather than reduced to a boolean here.
    """
    c = read_only(os.path.join(hermes_home(), "cron", "executions.db"))
    if c is None:
        return []
    try:
        rows = list(c.execute(
            "select id, job_id, state, failure_type, first_seen_at, "
            "       last_seen_at, error, output_file, closed_at "
            "from cron_incidents"))
    except sqlite3.Error:
        return []
    out = []
    for (ident, job_id, state, kind, first, last, error, output, closed) in rows:
        if seconds(last) < since:
            continue
        name = names.get(str(job_id or ""), "")
        out.append({
            "id": str(ident or ""),
            "job": str(job_id or ""),
            "name": name,
            "state": str(state or ""),
            "type": str(kind or ""),
            "first_at": iso(seconds(first)),
            "last_at": iso(seconds(last)),
            # Hermes stores a whole stderr dump here on a script failure.
            # One line is what a row can hold; the output file is named so
            # the rest is findable.
            "error": " ".join(str(error or "").split())[:400],
            "output": str(output or ""),
            "closed": bool(closed),
            "upkeep": is_upkeep(name),
        })
    out.sort(key=lambda r: r["last_at"], reverse=True)
    return out


def log_tail(lines):
    """The end of the gateway log, and what it is honestly not.

    Three things are true of this file and all three are said in `note`
    rather than implied by drawing it as a health check:

    * It is NOT complete. `Plugin discovery complete` is logged by
      `hermes_cli.plugins`, which this file's component filter excludes —
      it lands in `agent.log` — and `Loaded hook '<name>'` is a bare
      `print()` that reaches no file at all. A health check built on the
      first of those cried wolf on a healthy machine.
    * It is NOT this account's whole life. Alfie Away runs on a Fly volume
      and its logs stay there; nothing on this Mac can read them.
    * It is NOT redacted. Measured 2026-09-04: `agent.log` carries 223
      lines with `msg='…'` in them and `gateway.log` ten, which is the
      text of turns. That is why this is behind a disclosure and why the
      activity log above is a different thing entirely.
    """
    path = os.path.join(hermes_home(), "logs", "gateway.log")
    note = ("Hermes's own log for this Mac. It is not a complete record — some "
            "of what Hermes does is written to other files, and some is printed "
            "where nothing keeps it — and it is not filtered, so it can contain "
            "the text of turns. Alfie Away keeps its logs on its own machine; "
            "none of them are here.")
    if not os.path.isfile(path):
        return {"path": path, "lines": [], "missing": True, "note": note}
    keep = []
    try:
        # Read the tail rather than the file: gateway.log is 1.8 MB on this
        # Mac and rotates at 5 MB, and forty lines never needs the rest.
        size = os.path.getsize(path)
        window = min(size, max(lines, 1) * 400 + 8192)
        with open(path, "rb") as f:
            f.seek(size - window)
            raw = f.read().decode("utf-8", "replace")
        keep = raw.splitlines()
        if window < size and keep:
            # The first line of a window that started mid-file is half a
            # line. Half a log line looks like a truncated message.
            keep = keep[1:]
        keep = keep[-max(lines, 1):]
    except OSError:
        return {"path": path, "lines": [], "missing": True, "note": note}
    return {"path": path, "lines": keep, "missing": False, "note": note}


def do_activity(days, log_lines):
    since = time.time() - max(days, 1) * 86400
    names = job_names()
    return answer("activity", {
        "ok": True,
        "days": days,
        "elsewhere": elsewhere(since),
        "runs": runs(since, names),
        "incidents": incidents(since, names),
        "log": log_tail(log_lines),
    })


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------


def fts_query(text):
    """A person's words as an FTS5 expression that cannot be a syntax error.

    Everything a person types is a phrase, quoted: `NEAR`, `AND`, `OR`,
    `*`, `-` and `"` all mean something to FTS5, and an unbalanced one of
    them raises `fts5: syntax error` rather than finding nothing — which
    would reach the pane as "Alfie could not search" for the crime of typing
    an apostrophe. Tokens are ANDed, which is what a person means by
    typing two words.

    Returns "" when there is nothing left to search for; the caller
    refuses rather than matching everything.
    """
    tokens = re.findall(r"[^\W_]+", text, re.UNICODE)
    return " ".join('"%s"' % t for t in tokens)


def do_search(query, sessions, limit):
    if not sessions:
        # THE line this half exists for. Without a session list there is
        # nothing separating a person's conversations from cron prompts,
        # subagent turns and the threads they deleted — Hermes keeps its
        # copy of those on purpose. Refusing is the only answer that
        # cannot leak one.
        return answer("search", {"error": "Alfie had nothing to search in.",
                                 "query": query})
    match = fts_query(query)
    if not match:
        return answer("search", {"error": "Type something to look for.",
                                 "query": query})
    c = read_only(os.path.join(hermes_home(), "state.db"))
    if c is None:
        return answer("search", {
            "error": "Alfie couldn't open the index of what has been said.",
            "query": query})
    capped = len(sessions) > MAX_SESSIONS
    allowed = sessions[:MAX_SESSIONS]
    limit = max(1, min(limit, MAX_LIMIT))
    holes = ",".join("?" * len(allowed))
    try:
        rows = list(c.execute(
            "select m.session_id, m.role, m.timestamp, "
            "       snippet(messages_fts, 0, '‹', '›', '…', 14) "
            "from messages_fts f "
            "join messages m on m.id = f.rowid "
            "where messages_fts match ? "
            "  and m.session_id in (%s) "
            "  and m.role in ('user', 'assistant') "
            "order by m.timestamp desc limit ?" % holes,
            [match] + allowed + [limit]))
    except sqlite3.Error as e:
        # An FTS error is Hermes's, not the person's, and saying which
        # is what stops "search is broken" being the only report.
        return answer("search", {"error": "The index refused that: %s" % e,
                                 "query": query})
    hits = [{
        "session": str(r[0] or ""),
        "role": str(r[1] or ""),
        "at": iso(seconds(r[2])),
        "snippet": " ".join(str(r[3] or "").split()),
    } for r in rows]
    return answer("search", {"ok": True, "query": query, "hits": hits,
                             "sessions": len(allowed), "capped": capped})


def read_sessions():
    """The sessions the caller vouches for, one per line on stdin.

    On stdin rather than argv because the list is as long as a person's
    history and argv is not. Blank lines and anything that is not a
    session id are dropped here rather than reaching an IN clause.
    """
    if sys.stdin is None or sys.stdin.isatty():
        return []
    out = []
    seen = set()
    for line in sys.stdin.read().splitlines():
        line = line.strip()
        if not line or line in seen or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", line):
            continue
        seen.add(line)
        out.append(line)
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("activity", "search"))
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS)
    ap.add_argument("--log-lines", type=int, default=DEFAULT_LOG_LINES)
    ap.add_argument("--query", default="")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    args = ap.parse_args(argv)
    # A refusal has to be shaped like the answer that was asked for, or
    # the pane cannot read it at all. See SHAPES.
    kind = args.action

    try:
        if args.action == "activity":
            out = do_activity(args.days, args.log_lines)
        else:
            out = do_search(args.query, read_sessions(), args.limit)
    except Exception as e:
        return die("%s: %s" % (type(e).__name__, e), kind)
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

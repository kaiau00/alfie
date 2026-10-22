#!/usr/bin/env python3
"""What Alfie has spent, out of the one table Hermes keeps it in.

Settings › Usage reads this. `hermes insights` computes the same numbers and
prints them in a box-drawing table with no `--json` anywhere in the
subcommand, and it takes several seconds because it renders a month of
activity charts nobody asked for. This asks the same table the same
questions.

    token-usage.py usage [--days 30] [--tools 12]

**The source is `~/.hermes/state.db`, table `sessions`.** Every column read
here is one `agent/insights.py` reads: `input_tokens`, `output_tokens`,
`cache_read_tokens`, `cache_write_tokens`, `estimated_cost_usd`,
`actual_cost_usd`, `cost_status`, `cost_source`, `billing_provider`,
`model`, `source`, `api_call_count`, `started_at`. Nothing is derived that
Hermes does not already store.

Four things measured on this Mac on 2026-09-04, each of which changes what
an honest pane can say.

**"Total tokens" is not what you and Alfie wrote.** Thirty days here: 2.08M
input, 1.06M output — and 193M of cache read and cache write. `hermes
insights` adds all four and prints "Total tokens: 216,847,032", which reads
as a bill and is mostly the same system prompt being re-read. The two are
kept apart here and never summed into one number.

**Most of it costs nothing per token, and that is recorded, not guessed.**
706 of 774 sessions carry `cost_status = "included"` with
`cost_source = "claude-code-subscription"`: the Claude plan already paid for
them. 32 carry `"estimated"` against `deepseek` and are the only real money
— $0.56 — and 36 carry no status at all and have **zero tokens**, which is a
session that never took a turn rather than a cost nobody knows.

**§4.4's own worry has been fixed since it was written.** It says the
auxiliary lanes are all `auto`, so title generation records `$0.00` against
an "unknown" billing route. Measured now: those lanes are named
(`deepseek-v4-pro`, `deepseek-v4-flash`), their provider is `deepseek`,
their status is `estimated` and they carry the only dollars on this Mac.
The §6 config audit closed it. What is left unknown is 36 empty sessions.

**Cost per TOOL cannot be computed, and is not.** §4.4 asks for "which
tools cost most". Hermes attributes tokens to a session and never to a tool
call: there is no per-tool token column anywhere in `state.db`. What can be
counted is how often each tool ran, and that is what comes back — under a
key that says `calls`, so nothing downstream can mistake it for money. Two
sources are counted and merged exactly as `insights._get_tool_usage` merges
them: `messages.tool_name` on tool-role rows (which the gateway sets) and
the `tool_calls` JSON on assistant rows (which is where CLI turns land).
Counting only the first gives 27 `terminal` calls where there were 279.

**The rate-limit warning is looked for and usually absent.** At ≥90% of an
Anthropic window the engine emits "heads up — N% of your {window} limit
used"; `HermesBrain` recognises it and puts it in the transcript. Whether it
has ever *fired* is a fact about this Mac, and the only record of it is
`Log.write("status: …")` in `~/.moe/logs/moe.log`. On this Mac: never, in
the whole log. The pane says that, rather than drawing a gauge over a number
nothing has ever produced.

One JSON object on stdout, always: `{"ok": true, …}` or
`{"ok": false, "error": "…"}`, exit 0 for both. A non-zero exit with no JSON
means this crashed, which is a different thing.

Read-only throughout: the database is opened `mode=ro` and, where Hermes
holds a write lock, `immutable=1` — the ladder `job-activity.py` found the
hard way and `history.py` repeats. Nothing here writes anything.

Python 3.9, stdlib only — no PyYAML, nothing imported out of Hermes — so it
runs under /usr/bin/python3 as well as the Hermes venv, and a Mac whose
Hermes install is broken can still be told what it spent before it broke.
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import time

DEFAULT_DAYS = 30
DEFAULT_TOOLS = 12
#: Tools listed at most. A settings pane is not a profiler.
MAX_TOOLS = 60
#: Days charted at most, so a --days 3650 cannot return a thousand rows.
MAX_DAYS = 365

#: Every key each answer carries, whether or not it has anything to say.
#:
#: A contract with Swift rather than tidiness. Swift's synthesised
#: `Decodable` does NOT fall back to a property's default for a missing key
#: — it throws `keyNotFound` and the WHOLE answer decodes to nothing. One
#: absent `error` on a success turned a working Reminders pane into "Moe
#: couldn't reach the part of itself that keeps the clock" on 2026-09-04,
#: after the work had already been done. The Swift side reads every key with
#: `decodeIfPresent` as well; this is the second of two halves, because the
#: failure is silent in exactly the direction that matters.
SHAPES = {
    "usage": {"ok": False, "error": "", "days": DEFAULT_DAYS, "db": "",
              "missing": True, "totals": {}, "money": {}, "daily": [],
              "models": [], "sources": [], "tools": [], "tools_total": 0,
              "warning": {}},
}

TOTALS = {"sessions": 0, "messages": 0, "tool_calls": 0, "api_calls": 0,
          "written": 0, "read_back": 0, "input": 0, "output": 0,
          "cache_read": 0, "cache_write": 0, "reasoning": 0}

#: Providers are split by BUCKET, not pooled.
#:
#: Found by rendering the pane: one `providers` list put `deepseek` — the
#: only thing on this Mac that charges money — into the sentence under
#: "covered by a plan you already pay for". A list that spans two buckets
#: can only be read as belonging to whichever one it is printed beneath.
MONEY = {"metered_usd": 0.0, "metered": 0, "included": 0, "unknown": 0,
         "unknown_tokens": 0, "actual_usd": 0.0,
         "plan_providers": [], "metered_providers": []}

DAY = {"day": "", "sessions": 0, "input": 0, "output": 0,
       "cache_read": 0, "cache_write": 0, "usd": 0.0}

MODEL = {"model": "", "sessions": 0, "input": 0, "output": 0,
         "cache_read": 0, "cache_write": 0, "usd": 0.0, "status": "",
         "provider": ""}

SOURCE = {"source": "", "sessions": 0, "messages": 0, "input": 0,
          "output": 0, "cache_read": 0, "usd": 0.0}

TOOL = {"tool": "", "calls": 0}

WARNING = {"seen": False, "at": "", "text": "", "log": "", "checked": False}


def answer(kind, fields):
    out = dict(SHAPES[kind])
    out.update(fields)
    return out


def filled(template, fields):
    """One row with every key its shape promises. Same contract as `answer`,
    one level down — a row missing a key takes the whole answer with it just
    as surely as a top-level one does."""
    out = dict(template)
    out.update(fields)
    return out


def emit(obj):
    json.dump(obj, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def hermes_home():
    # `.get(k, default)` returns "" for a variable that is SET and empty, and
    # expanduser("") is "" — so HERMES_HOME= would point every path below at
    # the current directory. `or` is the idiom this repo uses.
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def read_only(path):
    """A read-only connection, or None.

    `immutable` is the fallback and it is not optional: Hermes's databases
    are WAL and it closes after each write, so between writes there is no
    -shm file and a plain `mode=ro` connection fails at query time rather
    than at connect time. `immutable=1` can read a value a moment stale,
    which for a screen showing what has already been spent is the right
    trade against not opening at all. Lifted from `job-activity.py`, which
    found this the hard way, by way of `history.py`.
    """
    if not os.path.isfile(path):
        return None
    for uri in ("file:%s?mode=ro" % path, "file:%s?mode=ro&immutable=1" % path):
        try:
            c = sqlite3.connect(uri, uri=True, timeout=2)
            c.execute("select 1 from sqlite_master limit 1")
            c.row_factory = sqlite3.Row
            return c
        except sqlite3.Error:
            continue
    return None


#: `+0000`, not `+00:00` — the offset shape `time.strftime("%z")` writes and
#: the one `datetime.fromisoformat` could not read before Python 3.11.
_BARE_OFFSET = re.compile(r"([+-])(\d{2})(\d{2})$")


def seconds(v):
    """Hermes writes timestamps as epoch floats in some tables and ISO
    strings in others. `sessions.started_at` is an epoch float today; both
    are read, because a column that has changed shape once can do it again
    and the cost of being wrong is a whole window falling out of range.
    """
    if isinstance(v, bool):
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        s = str(v or "").strip().replace("Z", "+00:00")
        if "T" in s:
            from datetime import datetime
            return datetime.fromisoformat(_BARE_OFFSET.sub(r"\1\2:\3", s)).timestamp()
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def num(v):
    """A count, whatever SQLite handed back. NULL is 0 — every token column
    in this table is nullable and a session that never took a turn has NULL
    rather than zero in all of them."""
    if isinstance(v, bool) or v is None:
        return 0
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def money(v):
    if v is None or isinstance(v, bool):
        return 0.0
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


#: The columns this reads. Named one by one rather than `select *`: a
#: `select *` binds to column ORDER, and this table has gained columns twice
#: in the life of this repo.
COLUMNS = ("id, source, model, started_at, message_count, tool_call_count, "
           "input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, "
           "reasoning_tokens, billing_provider, billing_mode, "
           "estimated_cost_usd, actual_cost_usd, cost_status, cost_source, "
           "api_call_count")


def gather(conn, since):
    """Every session in the window, rolled up four ways at once.

    One pass over the rows rather than four `group by` queries, because the
    four groupings have to agree with each other: a total that came from a
    different query than its own breakdown is a total that can be off by
    one and never say so.
    """
    totals = dict(TOTALS)
    cash = dict(MONEY)
    by_day, by_model, by_source = {}, {}, {}
    plan_providers, metered_providers = set(), set()

    try:
        rows = conn.execute(
            "select %s from sessions where started_at >= ?" % COLUMNS, (since,))
    except sqlite3.Error as e:
        raise RuntimeError("the usage table refused that: %s" % e)

    for r in rows:
        at = seconds(r["started_at"])
        inp, out = num(r["input_tokens"]), num(r["output_tokens"])
        cr, cw = num(r["cache_read_tokens"]), num(r["cache_write_tokens"])
        usd = money(r["estimated_cost_usd"])
        status = str(r["cost_status"] or "")
        provider = str(r["billing_provider"] or "")
        model = str(r["model"] or "")

        totals["sessions"] += 1
        totals["messages"] += num(r["message_count"])
        totals["tool_calls"] += num(r["tool_call_count"])
        totals["api_calls"] += num(r["api_call_count"])
        totals["input"] += inp
        totals["output"] += out
        totals["cache_read"] += cr
        totals["cache_write"] += cw
        totals["reasoning"] += num(r["reasoning_tokens"])

        # The two numbers that must never be added together. "Written" is
        # what you and Moe actually said; "read back" is the same context
        # arriving again on every turn, which is 98% of the tokens on this
        # Mac and none of the conversation.
        totals["written"] += inp + out
        totals["read_back"] += cr + cw

        if status == "included":
            cash["included"] += 1
            if provider:
                plan_providers.add(provider)
        elif status:
            cash["metered"] += 1
            cash["metered_usd"] += usd
            if provider:
                metered_providers.add(provider)
        else:
            cash["unknown"] += 1
            cash["unknown_tokens"] += inp + out + cr + cw
        cash["actual_usd"] += money(r["actual_cost_usd"])

        day = time.strftime("%Y-%m-%d", time.localtime(at)) if at else ""
        d = by_day.setdefault(day, filled(DAY, {"day": day}))
        d["sessions"] += 1
        d["input"] += inp
        d["output"] += out
        d["cache_read"] += cr
        d["cache_write"] += cw
        d["usd"] += usd

        m = by_model.setdefault(model, filled(MODEL, {"model": model}))
        m["sessions"] += 1
        m["input"] += inp
        m["output"] += out
        m["cache_read"] += cr
        m["cache_write"] += cw
        m["usd"] += usd
        # The status a model is SEEN under, not one derived from its name.
        # `sonnet` is included here and metered on a Mac paying per token,
        # and a pane that decided from the name would be wrong on one of
        # them without ever saying which.
        if status and not m["status"]:
            m["status"] = status
        elif status and m["status"] != status:
            m["status"] = "mixed"
        if provider and not m["provider"]:
            m["provider"] = provider

        src = str(r["source"] or "")
        s = by_source.setdefault(src, filled(SOURCE, {"source": src}))
        s["sessions"] += 1
        s["messages"] += num(r["message_count"])
        s["input"] += inp
        s["output"] += out
        s["cache_read"] += cr
        s["usd"] += usd

    cash["metered_usd"] = round(cash["metered_usd"], 6)
    cash["actual_usd"] = round(cash["actual_usd"], 6)
    cash["plan_providers"] = sorted(plan_providers)
    cash["metered_providers"] = sorted(metered_providers)
    for bucket in (by_day, by_model, by_source):
        for row in bucket.values():
            row["usd"] = round(row["usd"], 6)
    daily = sorted((d for d in by_day.values() if d["day"]),
                   key=lambda d: d["day"])
    models = sorted(by_model.values(),
                    key=lambda m: (m["input"] + m["output"]), reverse=True)
    sources = sorted(by_source.values(), key=lambda s: s["sessions"], reverse=True)
    return totals, cash, daily, models, sources


def tools(conn, since, limit):
    """How often each tool ran. Two sources, merged, exactly as
    `insights._get_tool_usage` merges them.

    `messages.tool_name` is set by the gateway on tool-role rows; the
    `tool_calls` JSON on assistant rows is where a CLI turn's calls land and
    the gateway never fills the column. Measured on this Mac: the column
    alone reports 27 `terminal` calls where the pair reports 279. Counting
    one source would be a number that is quietly a tenth of the truth.

    Never a cost. Hermes attributes tokens to a session and to nothing
    smaller, so there is no per-tool money to report and none is invented.
    """
    counts = {}
    try:
        for r in conn.execute(
                "select m.tool_name as name, count(*) as n from messages m "
                "join sessions s on s.id = m.session_id "
                "where s.started_at >= ? and m.role = 'tool' "
                "  and m.tool_name is not null group by m.tool_name", (since,)):
            name = str(r["name"] or "")
            if name:
                counts[name] = counts.get(name, 0) + num(r["n"])
    except sqlite3.Error:
        pass
    try:
        for r in conn.execute(
                "select m.tool_calls as calls from messages m "
                "join sessions s on s.id = m.session_id "
                "where s.started_at >= ? and m.role = 'assistant' "
                "  and m.tool_calls is not null", (since,)):
            try:
                parsed = json.loads(r["calls"])
            except (ValueError, TypeError):
                continue
            if not isinstance(parsed, list):
                continue
            for call in parsed:
                if not isinstance(call, dict):
                    continue
                # Two shapes in the wild: OpenAI's nested `function.name`
                # and Hermes's flat `name`.
                fn = call.get("function")
                name = ""
                if isinstance(fn, dict):
                    name = str(fn.get("name") or "")
                if not name:
                    name = str(call.get("name") or "")
                if name:
                    counts[name] = counts.get(name, 0) + 1
    except sqlite3.Error:
        pass
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return ([filled(TOOL, {"tool": t, "calls": n}) for t, n in ranked[:limit]],
            len(ranked))


def last_warning():
    """The last time Alfie told you it was near a limit, if it ever has.

    `HermesBrain` logs every engine status as `status: …` and shows exactly
    one of them — the one containing "limit used", which is the phrase
    `agent/transports/claude_code_session.py:_on_rate_limit` emits at ≥90%
    of an Anthropic window. `moe.log` is therefore the only record on this
    Mac that the warning ever fired.

    `checked` is the honest half: false means the log could not be read at
    all, and `seen` false then means nothing. A pane that drew "you have
    never been near a limit" over a log it could not open would be making
    that up.
    """
    path = os.path.join(moe_home(), "logs", "moe.log")
    out = filled(WARNING, {"log": path})
    if not os.path.isfile(path):
        return out
    try:
        size = os.path.getsize(path)
        # The whole file where it is small, the last 2 MB where it is not.
        # A warning older than the last 2 MB of log is older than the window
        # any of this reports on.
        window = min(size, 2 * 1024 * 1024)
        with open(path, "rb") as f:
            f.seek(size - window)
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return out
    # moe.log rotates at 5 MiB into moe.log.1 (Log.rotate in Config.swift);
    # just after a rotation the rest of the last 2 MB is in the old file.
    short = 2 * 1024 * 1024 - window
    if short > 0:
        try:
            with open(path + ".1", "rb") as f:
                f.seek(max(0, os.path.getsize(path + ".1") - short))
                text = f.read().decode("utf-8", "replace") + text
        except OSError:
            pass
    out["checked"] = True
    for line in reversed(text.splitlines()):
        if "limit used" not in line.lower():
            continue
        out["seen"] = True
        out["text"] = " ".join(line.split())[:300]
        stamp = re.match(r"\[([^\]]+)\]", line)
        out["at"] = stamp.group(1) if stamp else ""
        break
    return out


def do_usage(days, tool_limit):
    days = max(1, min(days, MAX_DAYS))
    tool_limit = max(1, min(tool_limit, MAX_TOOLS))
    since = time.time() - days * 86400
    path = os.path.join(hermes_home(), "state.db")
    warning = last_warning()
    conn = read_only(path)
    if conn is None:
        # Not an error. A Mac where Hermes has not started yet has spent
        # nothing, and "Moe could not look" and "nothing has been spent"
        # must not draw the same. `missing` is what separates them.
        return answer("usage", {
            "ok": True, "days": days, "db": path, "missing": True,
            "totals": dict(TOTALS), "money": dict(MONEY),
            "warning": warning})
    totals, cash, daily, models, sources = gather(conn, since)
    listed, distinct = tools(conn, since, tool_limit)
    return answer("usage", {
        "ok": True, "days": days, "db": path, "missing": False,
        "totals": totals, "money": cash, "daily": daily, "models": models,
        "sources": sources, "tools": listed, "tools_total": distinct,
        "warning": warning})


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("usage",))
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS)
    ap.add_argument("--tools", type=int, default=DEFAULT_TOOLS)
    args = ap.parse_args(argv)
    try:
        out = do_usage(args.days, args.tools)
    except Exception as e:
        # A refusal has to be shaped like the answer that was asked for, or
        # the pane cannot read it at all. See SHAPES.
        return emit(answer("usage", {"error": "%s: %s" % (type(e).__name__, e),
                                     "days": args.days,
                                     "totals": dict(TOTALS),
                                     "money": dict(MONEY),
                                     "warning": dict(WARNING)}))
    return emit(out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

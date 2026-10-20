#!/usr/bin/env python3
"""What each background job has been doing, and what it has cost.

One answer for two screens: Settings › Background's activity view and the
Reminders pane another session is building. Neither should be querying
Hermes's databases itself — the shapes here took a morning to find, the
cost story has two very different halves, and a number that implies a bill
when there is none is worse than no number.

    job-activity.py            every job Moe installed, as JSON
    job-activity.py <job>      one job, by name or id
    job-activity.py --days 30  a different window (default 7)

Per job:

    name, id, enabled, schedule, last_run, next_run, last_status
    outcome      ok | failed | quiet | never          (see below)
    runs, failures, quiet_runs      within the window
    error                           the last one, if it failed
    cost: {tokens_in, tokens_out, calls, amount, basis, label, models}

`outcome` is the word a person needs and no single field holds. A
monitor-mode job whose source has not changed does not run at all: Hermes
records it as a silent success, and a row saying "ok" the way a job that
did work says "ok" is misleading, while a row saying nothing reads as
broken. `quiet` means "looked, nothing had changed, nothing was spent" —
which is most ticks of a healthy watch and is the answer to "why does this
say it last ran an hour ago".

The two cost halves, both measured on this Mac rather than assumed:

    basis "included"   a subscription (Claude, ChatGPT). Hermes records
                       cost 0 and cost_status "included". There IS no
                       dollar figure; tokens and calls are the honest
                       numbers, and `label` says so.
    basis "estimated"  an API key (DeepSeek, Gemini…). Hermes prices the
                       tokens from a published-rates snapshot — its own
                       cost_source is "official_docs_snapshot" — and never
                       fetches the real invoice. `amount` is that estimate
                       and `label` says estimated, never "spent".
    basis "none"       nothing charged to a model at all. The ten-minute
                       sync is scripts and connectors; it costs battery.

Usage is attributed by session id: Hermes names a cron run's session
`cron_<job_id>_<date>`, so a job's spend is a prefix match with no new
plumbing. What that CANNOT see is a job that shells out to something which
talks to the gateway itself — the daily learn pass distils through the
api_server, so its tokens land under that and not under the job. Rather
than guess, such a job reports `basis: "elsewhere"` and says where.

Read-only throughout: every database is opened `mode=ro` and, where
Hermes holds a write lock, `immutable=1`. Nothing here writes, and a
missing or busy database is an empty answer, never an error — a settings
screen that cannot draw because a lock was held is a worse bug than a
blank cost column.

Python 3.9, stdlib only.
"""

import json
import os
import re
import sqlite3
import sys
import time

DEFAULT_DAYS = 7
#: Jobs Moe installs. Anything else in Hermes's cron is someone else's and
#: is reported the same way — this is only the order they are listed in.
MOE_PREFIX = "moe-"
#: A cron run's session, from cron/scheduler.py: cron_<job_id>_<YYYYMMDD>.
_CRON_SESSION = "cron_%s_"
#: What the daily learn pass spends its tokens through, since it does not
#: spend them as itself. Named so the answer can say where to look.
ELSEWHERE = {"moe-learn-deep": "the distil calls it makes through the gateway"}


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def read_only(path):
    """A read-only connection, or None. `immutable` is the fallback: the
    live databases are WAL and Hermes closes after each write, so between
    writes there is no -shm and a plain mode=ro connection fails at query
    time. immutable can read a value a moment stale, which for a settings
    screen is the right trade against not opening at all."""
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


def jobs():
    """Every job Hermes has, from its own store. [] when unreadable."""
    path = os.path.join(hermes_home(), "cron", "jobs.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    raw = data.get("jobs", data) if isinstance(data, dict) else data
    out = raw if isinstance(raw, list) else list(raw.values()) if isinstance(raw, dict) else []
    return [j for j in out if isinstance(j, dict)]


def runs(job_id, since):
    """(runs, failures, last_status, last_error, last_finished) in the window."""
    c = read_only(os.path.join(hermes_home(), "cron", "executions.db"))
    if c is None:
        return 0, 0, "", "", None
    try:
        rows = list(c.execute(
            "select status, error, finished_at, started_at from executions "
            "where job_id = ? order by coalesce(finished_at, started_at, claimed_at) desc",
            (job_id,)))
    except sqlite3.Error:
        return 0, 0, "", "", None
    n = fails = 0
    last_status = last_error = ""
    last_at = None
    for status, error, finished, started in rows:
        at = finished or started
        if last_status == "":
            last_status, last_error, last_at = (status or ""), (error or ""), at
        if at is None or _seconds(at) < since:
            continue
        n += 1
        if (status or "").lower() in ("failed", "error"):
            fails += 1
    return n, fails, last_status, last_error, last_at


def _seconds(v):
    """Hermes writes timestamps as epoch floats in some tables and ISO
    strings in others; both appear in executions depending on version."""
    if isinstance(v, (int, float)):
        return float(v)
    try:
        s = str(v).strip().replace("Z", "+00:00")
        if "T" in s:
            from datetime import datetime
            return datetime.fromisoformat(s).timestamp()
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def spend(job_id, since):
    """What this job's own runs cost. See the module note on the halves."""
    empty = {"tokens_in": 0, "tokens_out": 0, "calls": 0, "amount": 0.0,
             "basis": "none", "label": "Nothing is charged for this.", "models": []}
    c = read_only(os.path.join(hermes_home(), "state.db"))
    if c is None:
        return empty
    try:
        rows = list(c.execute(
            "select u.model, u.billing_mode, u.cost_status, sum(u.api_call_count), "
            "       sum(u.input_tokens), sum(u.output_tokens), sum(u.estimated_cost_usd) "
            "from session_model_usage u "
            "where u.session_id like ? and coalesce(u.last_seen, 0) >= ? "
            "group by u.model, u.billing_mode, u.cost_status",
            (_CRON_SESSION % job_id + "%", since)))
    except sqlite3.Error:
        return empty
    if not rows:
        return empty
    tin = tout = calls = 0
    amount = 0.0
    included = estimated = False
    models = []
    for model, mode, status, n_calls, inp, out, est in rows:
        tin += int(inp or 0)
        tout += int(out or 0)
        calls += int(n_calls or 0)
        amount += float(est or 0)
        if model and model not in models:
            models.append(model)
        if (status or "").lower() == "included" or (mode or "").lower() == "subscription":
            included = True
        elif float(est or 0) > 0 or (status or "").lower() == "estimated":
            estimated = True
    if estimated:
        basis, label = "estimated", "Estimated from published rates, not a bill."
    elif included:
        basis, label = "included", "Included in your plan — no separate charge."
    else:
        basis, label = "unpriced", "No price recorded for this model."
    return {"tokens_in": tin, "tokens_out": tout, "calls": calls,
            "amount": round(amount, 4), "basis": basis, "label": label, "models": models}


def outcome(job, n_runs, fails, last_status, monitor):
    """The one word a person needs. See the module note."""
    if not job.get("enabled", True):
        return "paused"
    s = (last_status or "").lower()
    if s in ("failed", "error"):
        return "failed"
    if n_runs == 0:
        return "never" if not last_status else "quiet"
    # A monitor job records a silent success on a tick where its source had
    # not changed. Hermes does not distinguish those from real work, so the
    # honest word for a monitor job that succeeded is "quiet": it looked.
    if monitor and s in ("completed", "ok", "success"):
        return "quiet"
    if s in ("completed", "ok", "success"):
        return "ok"
    # Hermes records "unknown" for a run it lost track of — the gateway went
    # down mid-run, most often because an install restarted it. It is not a
    # failure and not a success; "interrupted" is what happened, and it is a
    # word a person can act on (or ignore) rather than one that reads as a
    # fault in the job.
    if s in ("unknown", "", "interrupted"):
        return "interrupted" if s else "never"
    return s


def describe(job, days):
    since = time.time() - days * 86400
    jid = str(job.get("id") or "")
    name = str(job.get("name") or "")
    n, fails, last_status, last_error, last_at = runs(jid, since)
    monitor = bool((job.get("monitor_script") or job.get("monitor_url") or "").strip())
    cost = spend(jid, since)
    if name in ELSEWHERE and cost["basis"] == "none":
        cost = dict(cost, basis="elsewhere",
                    label="Its thinking is spent through %s, so it is not counted here."
                          % ELSEWHERE[name])
    sched = job.get("schedule")
    return {
        "name": name,
        "id": jid,
        "enabled": bool(job.get("enabled", True)),
        "schedule": (sched or {}).get("display") if isinstance(sched, dict) else sched,
        "monitor": monitor,
        "last_run": job.get("last_run_at") or last_at,
        "next_run": job.get("next_run_at"),
        "last_status": last_status,
        "outcome": outcome(job, n, fails, last_status, monitor),
        "runs": n,
        "failures": fails,
        "failure_streak": job.get("failure_streak") or 0,
        "error": last_error if (last_status or "").lower() in ("failed", "error") else "",
        "window_days": days,
        "cost": cost,
    }


def main(argv):
    days = DEFAULT_DAYS
    wanted = ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--days" and i + 1 < len(argv):
            try:
                days = max(1, min(365, int(argv[i + 1])))
            except ValueError:
                print("usage: job-activity.py [<job>] [--days N]", file=sys.stderr)
                return 2
            i += 2
            continue
        if a.startswith("-"):
            print("usage: job-activity.py [<job>] [--days N]", file=sys.stderr)
            return 2
        wanted = a
        i += 1
    all_jobs = jobs()
    if wanted:
        all_jobs = [j for j in all_jobs
                    if str(j.get("name") or "") == wanted or str(j.get("id") or "") == wanted]
        if not all_jobs:
            print("no such job: %s" % wanted, file=sys.stderr)
            return 1
    else:
        # Moe's own first, then everyone else's, each alphabetically.
        all_jobs.sort(key=lambda j: (not str(j.get("name") or "").startswith(MOE_PREFIX),
                                     str(j.get("name") or "")))
    out = [describe(j, days) for j in all_jobs]
    json.dump(out if not wanted else out[0], sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

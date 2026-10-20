""""I ran it" — the Mac's half of one runner per occurrence (docs/LOOPS.md §4).

The Mac never asks the edge before it fires: it is the presence, and "Mac
first" is the rule. What it owes the machine is the record that it DID fire,
so a machine that wakes a minute later and asks `POST /v1/cron/claim` for
the same occurrence is told `ran` rather than `won`. Without this, a
reminder due at the exact minute the Mac falls asleep can arrive twice.

This file computes the occurrence the way `moe-claim.py` does on the machine
— the interval bucket, the last cron match, the one-off's own instant — and
queues one line in ``~/.moe/cloud/ran-queue.json``. It cannot POST itself:
the device credential lives in the app's keychain, not on disk, so the app
drains the queue (`CloudSync`, `RanQueue.swift`) on its next sync with the
same transport it pushes the ledger through. The queue is a spool: fifty
lines at most, and a line older than a day is not worth reporting.

Called from the `moe` delivery adapter after a successful delivery, for a
job that travels (`moeledger.cronjobs.is_portable` — a person's own prompt
job) and no other. Never raises.

Python 3.9; stdlib, and croniter when Hermes has it (Hermes requires it for
cron-expression jobs, so it is there for exactly the jobs that need it).
"""

import json
import logging
import math
import os
import re
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

QUEUE_DIRNAME = "cloud"
QUEUE_FILENAME = "ran-queue.json"
#: What the app pulled from the edge on wake ("loops follow the person" S2,
#: docs/LOOPS.md §4): every occurrence another device claimed or ran since
#: the Mac last looked, written by `RanSeen.swift`. `deliver.py` drops an
#: occurrence found here, so a 09:00 reminder the machine fired is not said
#: again by a Mac waking at 09:10.
SEEN_FILENAME = "ran-seen.json"
QUEUE_KEEP = 50
_MOE_OWN = "moe-"
_ID = re.compile(r"^[0-9a-f]{6,32}$")
#: The edge, for a runtime that holds its credential on disk (the machine).
RAN_PATH = "/v1/cron/ran"
RAN_TIMEOUT = 15.0


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def queue_path():
    return os.path.join(moe_home(), QUEUE_DIRNAME, QUEUE_FILENAME)


def seen_path():
    return os.path.join(moe_home(), QUEUE_DIRNAME, SEEN_FILENAME)


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def machine_credential():
    """`(edge_url, bearer)` where this runtime holds its device credential on
    disk — the away machine's `$HERMES_HOME/moe/credential.json` and
    `edge.json`, the way `moe-claim.py` finds them — else `("", "")`. On a
    Mac the credential is in the app's keychain and this is empty, which is
    what routes a Mac's "ran" through the queue the app drains."""
    vault = os.path.join(hermes_home(), "moe")
    try:
        with open(os.path.join(vault, "credential.json"), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return "", ""
    bearer = doc.get("token") if isinstance(doc, dict) else None
    bearer = bearer.strip() if isinstance(bearer, str) else ""
    url = (os.environ.get("MOE_EDGE_URL") or "").strip()
    if not url:
        try:
            with open(os.path.join(vault, "edge.json"), encoding="utf-8") as f:
                edge = json.load(f)
            url = str(edge.get("url") or "").strip() if isinstance(edge, dict) else ""
        except (OSError, ValueError):
            url = ""
    return (url.rstrip("/"), bearer) if url and bearer else ("", "")


def post_ran(url, bearer, job_name, iso, status="ok", timeout=RAN_TIMEOUT):
    """`POST /v1/cron/ran` on the credential. True when the edge recorded it.
    `urllib`, stdlib only, like every other call this plugin makes."""
    import urllib.error
    import urllib.request

    body = json.dumps({"job": str(job_name)[:120], "occurrence": iso,
                       "status": str(status)[:40]}).encode("utf-8")
    request = urllib.request.Request(
        url + RAN_PATH, data=body, method="POST",
        headers={"Authorization": "Bearer " + bearer, "Content-Type": "application/json",
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            doc = json.loads(answer.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as e:
        logger.warning("ran: the edge did not take %s @ %s: %s", job_name, iso, type(e).__name__)
        return False
    return bool(isinstance(doc, dict) and doc.get("recorded"))




def is_portable(job):
    """The same rule as ``moeledger.cronjobs.is_portable``, repeated here
    because this plugin is stdlib-only by contract and must not import the
    ledger. A change to one is a change to both; a test holds them equal."""
    if not isinstance(job, dict):
        return False
    name = str(job.get("name") or "")
    if not name or name.startswith(_MOE_OWN) or name.startswith("moe-claim-"):
        return False
    if job.get("no_agent") or job.get("script") or job.get("monitor_script") or job.get("monitor_url"):
        return False
    if not isinstance(job.get("prompt"), str) or not job["prompt"].strip():
        return False
    return _ID.match(str(job.get("id") or "")) is not None


#: Moe's own background jobs that the away machine ALSO runs, each behind a
#: claim (the boot script's `install_claimed_job`). They never travel —
#: each side installs its own — but they are one runner per occurrence all
#: the same: the Mac's run of the 12:30 proactive pass is the 12:30 pass,
#: and a machine that claims it afterwards must be told `ran`. Until
#: 2026-09-30 the Mac reported only travelling jobs, so the machine ran the
#: same pass six minutes after the Mac and the owner heard it twice.
MACHINE_COVERED = frozenset(("moe-proactive", "moe-situations", "moe-loop-check", "moe-calendar-heads-up"))


def is_reported(job):
    """A job whose runs the edge must hear about: one that travels, or one of
    Moe's own the machine covers."""
    return is_portable(job) or (isinstance(job, dict) and str(job.get("name") or "") in MACHINE_COVERED)


def _parse_every_minutes(sched):
    minutes = sched.get("minutes") if isinstance(sched, dict) else None
    return minutes if isinstance(minutes, int) and minutes > 0 else None


def local_zone(now=None):
    """The zone Hermes fires a cron EXPRESSION in on this Mac: the one the
    app writes to tz.json while it is fresh, else the OS's.

    A cron expression names a wall-clock time; `0 8 * * 1-5` is eight in the
    morning where the person is. Both sides used to evaluate it in UTC, so a
    briefing that fired at 08:00 New York was reported as the 08:00Z
    occurrence — the same wrong key on both sides, which agreed with itself
    until the one case it did not: a machine whose timezone document had not
    been applied yet fires at 08:00Z, wins THAT key, and the Mac fires again
    four hours later. Found in the owner's `ran` queue on 2026-09-11
    (`"occurrence": "2026-09-11T08:00:00+00:00"` for a job that ran at
    08:00 EDT). Same rule in moe-claim.py, from Hermes's `timezone`."""
    now = now or datetime.now(timezone.utc)
    try:
        with open(os.path.join(moe_home(), "tz.json"), encoding="utf-8") as f:
            data = json.load(f)
        iana = str(data.get("iana") or "")
        at = data.get("at")
        if iana and isinstance(at, (int, float)) and 0 <= now.timestamp() - at <= 86400:
            from zoneinfo import ZoneInfo
            return ZoneInfo(iana)
    except Exception:  # noqa: BLE001 — a missing or odd file means "the OS's"
        pass
    return datetime.now().astimezone().tzinfo


def occurrence(job, now=None):
    """The instant both sides call this firing, as an aware UTC datetime,
    from the schedule dict Hermes stores; None for a shape this cannot read."""
    now = now or datetime.now(timezone.utc)
    sched = job.get("schedule") if isinstance(job, dict) else None
    if not isinstance(sched, dict):
        return None
    kind = sched.get("kind")
    if kind == "interval":
        minutes = _parse_every_minutes(sched)
        if not minutes:
            return None
        every = minutes * 60
        return datetime.fromtimestamp(math.floor(now.timestamp() / every) * every, tz=timezone.utc)
    if kind == "cron":
        expr = str(sched.get("expr") or "").strip()
        if not expr:
            return None
        zone = local_zone(now)
        try:
            from croniter import croniter
            prev = croniter(expr, now.astimezone(zone)).get_prev(datetime)
        except Exception as e:  # noqa: BLE001
            logger.info("ran: cannot read cron expression %r: %s", expr, e)
            return None
        if prev.tzinfo is None:
            prev = prev.replace(tzinfo=zone)
        return prev.astimezone(timezone.utc)
    if kind == "once":
        text = str(sched.get("run_at") or "").strip()
        try:
            when = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
        return when if when.tzinfo is not None else when.replace(tzinfo=timezone.utc)
    return None


def _read():
    try:
        with open(queue_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    rows = data.get("ran") if isinstance(data, dict) else None
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def _write(rows):
    path = queue_path()
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"ran": rows[-QUEUE_KEEP:]}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError as e:
        logger.warning("ran: could not write %s: %s", path, e)
        try:
            os.unlink(tmp)
        except OSError:
            pass


def note_ran(job, now=None, status="ok"):
    """Queue "I ran it" for this job's current occurrence. Returns the
    occurrence's ISO instant, or "" when nothing was queued. Never raises."""
    try:
        if not is_reported(job):
            return ""
        when = occurrence(job, now)
        if when is None:
            return ""
        iso = when.isoformat()
        url, bearer = machine_credential()
        if url and bearer:
            # The machine: its credential is on disk and nothing drains a
            # queue here, so it tells the edge itself (S2). When the edge
            # cannot be told, the line is queued and logged like the Mac's —
            # nothing drains it here, but the claim row the monitor script
            # wrote already names this device for the occurrence.
            if post_ran(url, bearer, job.get("name"), iso, status):
                logger.info("ran: told the edge %s @ %s", job.get("name"), iso)
                return iso
        rows = _read()
        key = (str(job.get("name")), iso)
        if any((r.get("job"), r.get("occurrence")) == key for r in rows):
            return iso
        rows.append({"job": str(job.get("name"))[:120], "occurrence": iso,
                     "at": (now or datetime.now(timezone.utc)).isoformat(), "status": str(status)[:40]})
        _write(rows)
        logger.info("ran: queued %s @ %s for the edge", job.get("name"), iso)
        return iso
    except Exception as e:  # noqa: BLE001
        logger.warning("ran: not queued: %s: %s", type(e).__name__, e)
        return ""

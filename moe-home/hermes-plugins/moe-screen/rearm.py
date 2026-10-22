"""A reminder cut by a restart is armed again, once, if its moment has not passed.

The owner's decision (2026-09-15): **interrupted reminders must be re-armed.**
Someone asked to be reminded; a gateway restart is not an answer.

── WHAT HAPPENS TODAY, MEASURED ────────────────────────────────────────────

Against the pinned Hermes at ``~/.hermes/hermes-agent``:

* ``cron/scheduler.py:3727`` — ``tick()`` calls ``advance_next_runs([...])``
  for the whole due set **before any job runs**.
* ``cron/jobs.py:2506`` — that writes ``job["next_run_at"] =
  compute_next_run(schedule, now)``: the NEXT occurrence. Its sibling's
  docstring (``cron/jobs.py:2532``) says the intent outright — *"at-most-once
  for recurring jobs — one missed run beats a crash-loop burst."*
* So when the run is then cut, the occurrence has already been stepped over.
  Nothing re-visits it. Measured in a scratch home: a daily 09:00 reminder
  forced due, pre-advanced, its owner process killed — ``get_due_jobs()``
  returns nothing and ``last_run_at`` is still ``None``. The occurrence is
  gone, silently.
* A **one-shot** ("remind me at 3pm") is worse: ``claim_dispatch`` has already
  incremented ``repeat.completed``, so the interrupt's ``mark_job_run(False)``
  reaches ``_advance_after_run`` → ``completed >= times`` →
  ``_complete_job_record`` (``cron/jobs.py:1463``), which sets
  ``enabled=False, state="completed", next_run_at=None``. The reminder is not
  merely skipped, it is **retired**.

The away machine's boot script already names this hole from the other end, and this
module is the reason that comment could be rewritten.

── DOES HERMES ALREADY HAVE A MISSED-RUN NOTION? PARTLY, AND IT IS INERT ───

It has two, and neither covers this:

* ``cron/scheduler_provider.py:243`` ``fire_overdue_jobs`` — a real misfire
  backstop with a ``cron.misfire_grace_minutes`` window. Its **third line** is
  ``if isinstance(provider, InProcessCronScheduler): return 0``, commented
  *"No-op for the built-in (its tick loop self-heals)"*. Alfie's Hermes sets no
  ``cron.provider`` (``~/.hermes/config.yaml`` has ``cron:`` with only
  ``model`` and ``wrap_response``), so ``resolve_cron_scheduler()`` returns the
  built-in and this backstop never runs here. And the claim it rests on —
  that the tick loop self-heals — is exactly what is false for a **cut**
  occurrence: the job is not overdue, because the tick moved it on.
* ``cron/executions.py:264`` ``recover_interrupted_executions`` — this one DOES
  run under the built-in (``cron/scheduler.py:3015``), and it is precise:
  it marks an attempt ``unknown`` once its owner process is **proved** gone.
  But its one-line docstring is the whole point: *"Mark provably abandoned
  attempts unknown **without scheduling retries**."* It is an audit ledger,
  not a queue. ``cron/executions.py:2`` says so again: *"it is not a retry
  queue."*

So Hermes **detects** the interrupted run exactly and durably, and then
deliberately does nothing about it. We do not build a second detector beside
it — we read its verdict. That is what this module does.

── WHAT COUNTS AS "INTERRUPTED", AND WHAT DOES NOT ─────────────────────────

Four things get called an interruption and they do not want the same answer:

1. **Gateway restart / machine stop / SIGKILL / power loss** — the run was
   dispatched and never reached a durable terminal state. The attempt row is
   left ``claimed``/``running`` owned by a pid that is gone, and Hermes's own
   recovery turns it into ``unknown``. *This is the one this module re-arms*,
   and reading Hermes's ledger is what makes it cover the ungraceful cases
   too: a SIGKILL sends no notice and runs no shutdown hook, but the row is
   already on disk.
2. **A turn that ran and failed** — the agent raised, ``mark_job_run(False,
   error=…)`` landed, the attempt finished ``failed``. Not interrupted: it
   ran, Hermes recorded it, and Settings › Background says "needs a look".
   Re-running it re-runs a failure. **Not re-armed.**
3. **A turn that ran but never delivered** — ``mark_job_run`` landed with a
   ``delivery_error``; ``last_status`` is ``delivery_failed``. The result
   exists. Re-running the agent does *different* work and can act twice (it
   reads mail, sends things). Hermes's own delivery retry owns this.
   **Not re-armed.**
4. **A machinery job's missed tick** — ``moe-proactive``, ``moe-loop-check``,
   a monitor. Nobody asked to be reminded; the next tick is in five minutes.
   Re-arming these is how a restart storm becomes a run storm.
   **Not re-armed** — ``ran.is_portable`` is the filter, and it is the same
   predicate the cloud already uses for "a person's own reminder".

Only (1), and only for a job (4) admits.

── WHAT RE-ARMING MUST NOT DO ──────────────────────────────────────────────

Written before the code, because most of these are the failure:

* **It must not say a reminder whose moment has passed.** "Your 9am standup"
  arriving at 3pm is a bug wearing a fix's clothes. Hence ``REARM_WITHIN_S``.
* **It must not move the schedule.** Tomorrow's 09:00 stays 09:00. (Measured:
  writing the cut occurrence back into ``next_run_at`` makes the due scan fire
  it once and re-anchor to the next real slot.)
* **It must not fire the same occurrence twice.** Terminal ledger rows are
  retained (``MAX_TERMINAL_EXECUTIONS = 1000``), so without a record of what
  we re-armed, every restart inside the window would re-arm the same row
  again. ``rearmed.json`` is that record, keyed by **execution id** — not by
  job, so a job interrupted twice is re-armed twice, which is right.
* **It must not resurrect a backlog.** A Mac shut overnight comes back to a
  ledger full of ``unknown`` rows. The window is what stops all of them
  firing at once, and it is the reason the window is tight rather than
  generous.
* **It must never raise.** It runs at gateway start, on the delivery
  adapter's ``connect()``. A reminder store we cannot read is a reason to log
  and carry on, never a reason for the ``moe`` platform to fail to connect.

── THE WINDOW ──────────────────────────────────────────────────────────────

``REARM_WITHIN_S`` is 15 minutes, and it is **not a new number**. The repo has
already answered this exact question once, on the other side of the same
feature: the edge's ``CRON_CLAIM_TTL_S = 15 * 60`` — the
visibility timeout on ``POST /v1/cron/claim``, i.e. how long an occurrence
that nobody has reported ``ran`` for is still considered worth firing by
somebody else (``docs/LOOPS.md`` §4: *"a stale claim (15 min, no ``ran``) is
taken over"*). "Is this occurrence still worth firing?" is the same question
here, so it gets the same answer, and the constant below says which one it is
copying.

The two other bounds in reach were both considered and both rejected:
``ONESHOT_GRACE_SECONDS = 120`` (``cron/jobs.py:96``) is Hermes's "a one-shot
this late will never fire" — too tight, since a gateway restart plus an Alfie
relaunch routinely exceeds two minutes, and a bound that expires during the
very outage it exists for is no bound at all. ``recover_interrupted_turns``'s
one hour (``gateway/session_lifecycle.py:150``) is about resuming a
*conversation*, where an hour-old half-answer is still worth finishing — a
reminder is not, because a reminder is a claim about *now*.

15 minutes covers every gateway restart on this Mac (seconds) and does not
cover a lunch break, a lid close, or an overnight sleep. That is the line.
"""

import json
import logging
import os
import re
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

#: How late an occurrence may be and still be worth saying. See the module
#: docstring: this is the edge's `CRON_CLAIM_TTL_S`, the window
#: the edge already uses for "nobody ran this occurrence yet, so somebody
#: still should". One number, two sides of one feature.
REARM_WITHIN_S = 15 * 60

#: Where we record what we have already re-armed, so a second restart inside
#: the window does not say it twice. `~/.moe/cron/rearmed.json`, 0600,
#: atomic, capped — the same shape as `ran.py`'s queue.
STATE_DIRNAME = "cron"
STATE_FILENAME = "rearmed.json"
STATE_KEEP = 200

#: Hermes's verdict for "dispatched, and provably never reached a durable
#: terminal state" (cron/executions.py `recover_interrupted_executions`).
#: `completed` and `failed` are runs that HAPPENED; neither is re-armed.
INTERRUPTED_STATUS = "unknown"

_ISO_Z = re.compile(r"Z$")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def state_path():
    return os.path.join(moe_home(), STATE_DIRNAME, STATE_FILENAME)


def hermes_zone():
    """The zone Hermes evaluates a cron expression in, or None for server-local.

    ``hermes_time.get_timezone()`` — the same profile zone ``_hermes_now()``
    carries, which is what the due scan compares a stored offset against.
    """
    try:
        from hermes_time import get_timezone
        return get_timezone()
    except Exception:  # noqa: BLE001
        return None


def in_hermes_zone(when):
    """*when*, the same instant, wearing Hermes's own UTC offset.

    **Not cosmetic.** The executions ledger canonicalises ``scheduled_instant``
    to UTC, and writing that UTC form straight back into a cron job's
    ``next_run_at`` gets the occurrence thrown away: ``cron/jobs.py``
    ``_repair_timezone_shifted_cron`` fires when the stored offset differs from
    now's AND the stored *wall clock* reads as future, which "18:55+00:00" does
    at 14:57-04:00 — so it "preserves local wall-clock intent" by recomputing
    forward, and skips the tick. Measured: the re-arm wrote 18:55+00:00 and
    Hermes logged *"next_run_at offset changed (0:00:00 -> -1 day, 20:00:00).
    Recomputing cron run to preserve local wall-clock intent"* and moved it to
    15:00-04:00. Converted to -04:00 first, the very same instant fires.

    This is the wrong-offset-key family ``ran.local_zone`` already documents
    from the cloud side, met again from the store side.
    """
    zone = hermes_zone()
    if zone is not None:
        return when.astimezone(zone)
    try:
        from hermes_time import now as hermes_now
        return when.astimezone(hermes_now().tzinfo)
    except Exception:  # noqa: BLE001
        return when.astimezone()


def _parse(iso):
    """An aware datetime from one of Hermes's ISO stamps, or None."""
    if not isinstance(iso, str) or not iso.strip():
        return None
    try:
        when = datetime.fromisoformat(_ISO_Z.sub("+00:00", iso.strip()))
    except ValueError:
        return None
    return when if when.tzinfo is not None else when.replace(tzinfo=timezone.utc)


def _read_state():
    try:
        with open(state_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    rows = data.get("rearmed") if isinstance(data, dict) else None
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def _write_state(rows):
    path = state_path()
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"rearmed": rows[-STATE_KEEP:]}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError as e:
        logger.warning("rearm: could not write %s: %s", path, e)
        try:
            os.unlink(tmp)
        except OSError:
            pass


def interrupted_attempts():
    """Hermes's own ``unknown`` attempts: ``(execution_id, job_id, occurrence)``.

    ``recover_interrupted_executions()`` is called first — it is Hermes's
    function, it is idempotent, and it is what turns a dead owner's
    ``claimed``/``running`` row into ``unknown``. Calling it here rather than
    waiting for the scheduler removes the ordering question between the
    gateway connecting its adapters and the ticker starting.
    """
    from cron.executions import _transaction, recover_interrupted_executions

    try:
        recover_interrupted_executions()
    except Exception as e:  # noqa: BLE001 — a recovery that fails is not ours to fix
        logger.warning("rearm: recovery pass failed: %s: %s", type(e).__name__, e)
    with _transaction() as conn:
        rows = conn.execute(
            "SELECT id, job_id, scheduled_instant FROM executions WHERE status=?",
            (INTERRUPTED_STATUS,),
        ).fetchall()
    return [(r["id"], r["job_id"], r["scheduled_instant"]) for r in rows]


def occurrence_completed(job_id, instant):
    """True when some attempt at this job's *instant* finished ``completed``.

    **Why not ``job["last_run_at"]``**, which is the obvious check and is
    wrong: the gateway's own interrupt path calls ``mark_job_run(job, False)``
    (``gateway/run_shutdown.py`` ``_mark_cron_interrupted``), and
    ``mark_job_run`` writes ``last_run_at`` whatever the outcome. So a run that
    was killed before it produced anything still stamps a ``last_run_at`` at or
    after its occurrence, and a guard reading that field skips exactly the case
    this module exists for. Measured: the one-shot test went green on the
    "already ran" branch, having delivered nothing.

    The attempt ledger does distinguish them — ``completed`` is written only by
    ``finish_execution(success=True)`` — and Hermes both keeps an index for
    this exact question (``idx_executions_occurrence ON executions(job_id,
    scheduled_instant) WHERE status='completed'``) and exposes the query as
    ``cron.occurrences.completed_occurrence``, whose one-line docstring is the
    rule we want: *"Unknown/failed/pruned attempts cannot prove completion:
    keep them eligible."* So this calls Hermes's rather than repeating the SQL
    — which is also how it gets the ``scheduled_instant`` canonicalisation for
    free, and a hand-rolled copy would have compared an un-normalized string.
    """
    from cron.occurrences import completed_occurrence

    return completed_occurrence({"id": str(job_id)}, instant)


def _rearm_job(job, occurrence, now):
    """Put *job* back so the next tick fires *occurrence*. True when changed.

    Two shapes, because Hermes treats them differently and this was measured
    rather than assumed:

    * **cron / interval** — write the occurrence itself back into
      ``next_run_at``. For a cron job this MUST be the original instant and
      nothing else: the due scan classifies an off-lattice ``next_run_at`` as
      a hand-edited expression and *re-anchors it without firing*
      (``cron/jobs.py`` ``_reanchor_stale_cron``, ``STALE_CRON_EXPR_EDIT``).
      Measured: a daily 09:00 job back-dated to 14:33 is silently moved to
      tomorrow 09:00 and never fires; back-dated to a real 09:00 slot it
      fires once, carries that instant as ``_scheduled_instant``, and
      ``mark_job_run`` re-anchors to tomorrow 09:00 on completion. Writing
      "now" here would have looked right and done nothing.
    * **once** — a one-shot has no lattice, and it has usually been retired
      outright (``_complete_job_record``). So un-retire it and make it due
      **now**: ``_retire_expired_oneshot`` drops any one-shot more than
      ``ONESHOT_GRACE_SECONDS`` (120 s) past ``next_run_at``, so writing the
      original instant back would hand it straight to the reaper. Its
      ``repeat.completed`` is reset because ``claim_dispatch`` had already
      counted the dispatch that never produced anything.
    """
    schedule = job.get("schedule") or {}
    kind = str(schedule.get("kind") or "")
    if kind in ("cron", "interval"):
        job["next_run_at"] = in_hermes_zone(occurrence).isoformat()
        if job.get("state") not in ("paused",):
            job["state"] = "scheduled"
        return True
    if kind == "once":
        job.update(enabled=True, state="scheduled", paused_at=None, paused_reason=None)
        job["next_run_at"] = in_hermes_zone(now).isoformat()
        repeat = job.get("repeat")
        if isinstance(repeat, dict):
            repeat["completed"] = 0
        return True
    return False


def rearm_interrupted(now=None):
    """Arm every reminder occurrence a restart cut, inside the window. Never raises.

    Returns the list of ``(job name, occurrence ISO)`` re-armed, which is what
    the log line and the tests read.
    """
    try:
        return _rearm_interrupted(now)
    except Exception as e:  # noqa: BLE001 — see the docstring: this runs at connect()
        logger.warning("rearm: nothing re-armed: %s: %s", type(e).__name__, e)
        return []


def _rearm_interrupted(now=None):
    from cron import jobs as J

    from . import ran as _ran

    now = now or datetime.now(timezone.utc)
    attempts = interrupted_attempts()
    if not attempts:
        return []

    seen = _read_state()
    handled = {r.get("execution") for r in seen}
    fresh = []
    done = []

    for execution_id, job_id, instant in attempts:
        if execution_id in handled:
            continue
        occurrence = _parse(instant)
        if occurrence is None:
            # No occurrence bound to the attempt: we cannot say WHICH firing
            # was lost, so we cannot put it back without guessing. Guessing
            # here is a reminder at the wrong time.
            continue
        late = (now - occurrence).total_seconds()
        if late < 0 or late > REARM_WITHIN_S:
            # Past its moment (or, defensively, in the future). Marked
            # handled so a restart loop does not re-read it every time.
            fresh.append({"execution": execution_id, "at": now.isoformat(),
                          "job": "", "occurrence": occurrence.isoformat(),
                          "outcome": "too late"})
            continue
        job = J.get_job(str(job_id))
        if job is None:
            continue
        if not _ran.is_portable(job):
            # Machinery: moe-*, a script, a monitor, a no_agent job. Nobody
            # asked to be reminded. See the module docstring, case 4.
            continue
        if occurrence_completed(job_id, instant):
            # A later attempt at this same occurrence finished. The person
            # heard it; the `unknown` row is a retry that succeeded.
            continue
        name = str(job.get("name") or "")
        with J._jobs_lock():
            stored = J.load_jobs()
            target = next((j for j in stored if j.get("id") == job_id), None)
            if target is None or not _rearm_job(target, occurrence, now):
                continue
            J.save_jobs(stored)
        logger.info("rearm: '%s' was cut at %s (%.0fs ago) — armed again",
                    name, occurrence.isoformat(), late)
        done.append((name, occurrence.isoformat()))
        fresh.append({"execution": execution_id, "at": now.isoformat(),
                      "job": name[:120], "occurrence": occurrence.isoformat(),
                      "outcome": "rearmed"})

    if fresh:
        _write_state(seen + fresh)
    return done

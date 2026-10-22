"""A reminder a restart cut is armed again — against the real Hermes cron store.

Not a source-text suite. Every test here builds a real ``jobs.json`` and a real
``cron/executions.db`` in a scratch ``HERMES_HOME``, interrupts a run the way a
killed gateway does (a durable attempt row whose owner pid is gone), runs
``rearm_interrupted()``, and then asks **Hermes's own** ``get_due_jobs()``
whether the occurrence will fire. That last step is the point: a reminder that
is "re-armed" but that the due scan declines to dispatch is not re-armed, and
asserting on ``next_run_at`` alone would have called it green. It very nearly
did — writing "now" into a cron job's ``next_run_at`` looks correct, stores
correctly, and is silently thrown away by ``_reanchor_stale_cron``
(``test_a_cut_reminder_off_its_lattice_would_never_fire`` pins that, so the
next person to "simplify" this back does not have to rediscover it).
"""

from __future__ import annotations

import datetime
import importlib.util
import json
import os
import sqlite3
import sys
import types

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))

pytest.importorskip("cron.jobs", reason="needs the pinned Hermes on PYTHONPATH")


def load_rearm():
    """`rearm.py` inside a synthetic package, so its `from . import ran` works.
    The same shape as `test_pushes.py`'s loader."""
    pkg = sys.modules.get("moe_screen_rearm_pkg")
    if pkg is None:
        pkg = types.ModuleType("moe_screen_rearm_pkg")
        pkg.__path__ = [PLUGIN]
        sys.modules["moe_screen_rearm_pkg"] = pkg
    for name in ("ran", "rearm"):
        full = "moe_screen_rearm_pkg." + name
        if full in sys.modules:
            continue
        spec = importlib.util.spec_from_file_location(full, os.path.join(PLUGIN, name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[full] = mod
        spec.loader.exec_module(mod)
    return sys.modules["moe_screen_rearm_pkg.rearm"]


@pytest.fixture()
def home(tmp_path, monkeypatch):
    """A scratch Hermes home and Alfie home. Hermes re-resolves its cron store
    from HERMES_HOME per call (`cron/jobs.py` `_current_cron_store`, precedence
    3), so this is real isolation, not a mock."""
    hermes = tmp_path / "hermes"
    moe = tmp_path / "moe"
    hermes.mkdir()
    moe.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(hermes))
    monkeypatch.setenv("HERMES_CONFIG_DIR", str(hermes))
    monkeypatch.setenv("MOE_HOME", str(moe))
    return types.SimpleNamespace(hermes=hermes, moe=moe)


# ── the machinery a killed gateway leaves behind ────────────────────────────

def now():
    from hermes_time import now as hnow
    return hnow()


def set_next_run(job_id, when):
    from cron import jobs as J
    with J._jobs_lock():
        stored = J.load_jobs()
        for j in stored:
            if j["id"] == job_id:
                j["next_run_at"] = when
        J.save_jobs(stored)


def interrupt(job_id, occurrence, home):
    """What a SIGKILLed gateway leaves: a claimed attempt whose owner is gone.
    Returns the execution id."""
    from cron import executions as E
    ex = E.create_execution(job_id, source="builtin", scheduled_instant=occurrence)
    db = os.path.join(str(home.hermes), "cron", "executions.db")
    con = sqlite3.connect(db)
    con.execute(
        "UPDATE executions SET pid=?, process_id=?, process_started_at=NULL WHERE id=?",
        (999999, "a-process-that-is-gone", ex["id"]))
    con.commit()
    con.close()
    return ex["id"]


def due_ids():
    from cron import jobs as J
    return {j["id"] for j in J.get_due_jobs()}


def a_reminder(name="standup", schedule="0 9 * * *", **kw):
    from cron import jobs as J
    return J.create_job(prompt="remind me about the standup", schedule=schedule,
                        name=name, deliver="moe", **kw)


def cut_a_recurring_reminder(home, minutes_ago=2, schedule="* * * * *", name="standup"):
    """A daily/minutely reminder whose run the gateway killed. Returns
    (job_id, occurrence ISO, execution id), with the store in exactly the
    state the measurement in `rearm.py`'s docstring describes."""
    from cron import jobs as J
    rec = a_reminder(name=name, schedule=schedule)
    jid = rec["id"]
    slot = (now() - datetime.timedelta(minutes=minutes_ago)).replace(second=0, microsecond=0)
    set_next_run(jid, slot.isoformat())
    # the tick pre-advances past the occurrence, before anything runs
    J.advance_next_runs([jid])
    ex = interrupt(jid, slot.isoformat(), home)
    return jid, slot.isoformat(), ex


# ── the hole itself, so the fix has something to be a fix OF ────────────────

def test_without_re_arming_the_cut_occurrence_is_simply_gone(home):
    from cron import jobs as J
    jid, occurrence, _ = cut_a_recurring_reminder(home)
    assert jid not in due_ids(), "the cut occurrence should be lost — that is the bug"
    assert J.get_job(jid)["last_run_at"] is None


# ── the fix ─────────────────────────────────────────────────────────────────

def test_a_cut_recurring_reminder_is_due_again(home):
    rearm = load_rearm()
    jid, occurrence, _ = cut_a_recurring_reminder(home)
    assert jid not in due_ids()

    armed = rearm.rearm_interrupted()

    assert [name for name, _ in armed] == ["standup"]
    # ONE due scan: it dispatches and re-anchors as it goes, so asking twice
    # is asking a different question the second time.
    from cron import jobs as J
    due = {j["id"]: j for j in J.get_due_jobs()}
    assert jid in due, "Hermes's own due scan must dispatch the cut occurrence"
    assert due[jid]["_scheduled_instant"], "it must fire AS the occurrence that was cut"


def test_a_cut_one_shot_reminder_is_un_retired_and_due_again(home):
    """"Remind me at 3pm" is the common shape, and it is the one a restart
    destroys outright: `_complete_job_record` sets enabled=False,
    state=completed, next_run_at=None."""
    from cron import jobs as J
    rearm = load_rearm()
    rec = a_reminder(name="dentist", schedule="in 1 hour", repeat=1)
    jid = rec["id"]
    slot = now() - datetime.timedelta(minutes=2)
    set_next_run(jid, slot.isoformat())
    ex = interrupt(jid, slot.isoformat(), home)
    J.claim_dispatch(jid)
    J.mark_job_run(jid, False, error="Gateway shutdown killed the run")

    retired = J.get_job(jid)
    assert retired["state"] == "completed" and retired["enabled"] is False, \
        "the one-shot should have been retired — that is the bug being fixed"
    assert jid not in due_ids()

    armed = rearm.rearm_interrupted()

    assert [name for name, _ in armed] == ["dentist"]
    back = J.get_job(jid)
    assert back["enabled"] is True and back["state"] == "scheduled"
    assert back["repeat"]["completed"] == 0
    assert jid in due_ids(), "the un-retired one-shot must actually be dispatched"


def test_the_next_occurrence_is_not_moved(home):
    """Re-arming yesterday's 09:00 must not disturb tomorrow's 09:00."""
    from cron import jobs as J
    rearm = load_rearm()
    rec = a_reminder(name="daily", schedule="0 9 * * *")
    jid = rec["id"]
    untouched = J.get_job(jid)["next_run_at"]
    slot = now().replace(minute=0, second=0, microsecond=0) - datetime.timedelta(minutes=0)
    # the most recent real 09:00 lattice point
    slot = now().replace(hour=9, minute=0, second=0, microsecond=0)
    if slot > now():
        slot -= datetime.timedelta(days=1)
    set_next_run(jid, slot.isoformat())
    J.advance_next_runs([jid])
    interrupt(jid, slot.isoformat(), home)

    rearm.rearm_interrupted(now=slot + datetime.timedelta(minutes=5))

    assert jid in due_ids()
    # the due scan re-anchors as it dispatches; the schedule is still 09:00
    assert J.get_job(jid)["next_run_at"][11:19] == untouched[11:19] == "09:00:00"


# ── what it must NOT do ─────────────────────────────────────────────────────

def test_a_reminder_past_the_window_is_left_alone(home):
    """One minute the other side of REARM_WITHIN_S and it stays lost — a
    reminder is a claim about now."""
    rearm = load_rearm()
    jid, _, _ = cut_a_recurring_reminder(
        home, minutes_ago=rearm.REARM_WITHIN_S // 60 + 1)

    assert rearm.rearm_interrupted() == []
    assert jid not in due_ids()


def test_the_window_is_the_edge_s_own_claim_timeout(home):
    """One number, not a new one: the edge's own `CRON_CLAIM_TTL_S`."""
    rearm = load_rearm()
    assert rearm.REARM_WITHIN_S == 15 * 60


def test_machinery_is_not_re_armed(home):
    """`moe-proactive` missing a tick is not a person missing a reminder, and
    a restart storm must not become a run storm."""
    from cron import jobs as J
    rearm = load_rearm()
    rec = J.create_job(prompt="look around", schedule="* * * * *",
                       name="moe-proactive", deliver="moe")
    jid = rec["id"]
    slot = (now() - datetime.timedelta(minutes=2)).replace(second=0, microsecond=0)
    set_next_run(jid, slot.isoformat())
    J.advance_next_runs([jid])
    interrupt(jid, slot.isoformat(), home)

    assert rearm.rearm_interrupted() == []
    assert jid not in due_ids()


def test_a_run_that_finished_is_not_re_armed(home):
    """A turn that ran and failed is not an interrupted turn: it ran, Hermes
    recorded it, and re-running it re-runs the failure."""
    from cron import executions as E
    from cron import jobs as J
    rearm = load_rearm()
    rec = a_reminder(name="ran-and-failed", schedule="* * * * *")
    jid = rec["id"]
    slot = (now() - datetime.timedelta(minutes=2)).replace(second=0, microsecond=0)
    set_next_run(jid, slot.isoformat())
    J.advance_next_runs([jid])
    ex = E.create_execution(jid, source="builtin", scheduled_instant=slot.isoformat())
    E.finish_execution(ex["id"], success=False, error="the agent raised")

    assert rearm.rearm_interrupted() == []
    assert jid not in due_ids()


def test_an_occurrence_already_run_to_completion_is_not_said_twice(home):
    """A later attempt at the SAME occurrence finished: the person heard it,
    and the stranded `unknown` row is a retry that succeeded."""
    from cron import executions as E
    rearm = load_rearm()
    jid, occurrence, _ = cut_a_recurring_reminder(home, name="already-said")
    done = E.create_execution(jid, source="builtin", scheduled_instant=occurrence)
    E.finish_execution(done["id"], success=True)

    assert rearm.rearm_interrupted() == []
    assert jid not in due_ids()


def test_last_run_at_alone_would_have_skipped_the_very_case_this_fixes(home):
    """`mark_job_run` stamps `last_run_at` even for a run the gateway KILLED
    (`_mark_cron_interrupted` calls it with success=False), so "last_run_at >=
    occurrence" means "something was marked", not "the person heard it". This
    pins the fact that made the obvious guard wrong; if it ever goes red,
    `occurrence_completed` can be reconsidered."""
    from cron import jobs as J
    rec = a_reminder(name="killed", schedule="in 1 hour", repeat=1)
    jid = rec["id"]
    slot = now() - datetime.timedelta(minutes=2)
    set_next_run(jid, slot.isoformat())
    J.claim_dispatch(jid)
    J.mark_job_run(jid, False, error="Gateway shutdown killed the run")

    stamped = J.get_job(jid)["last_run_at"]
    assert stamped is not None, "an interrupted run still stamps last_run_at"
    assert datetime.datetime.fromisoformat(stamped) >= slot


def test_it_is_not_re_armed_twice(home):
    """Terminal ledger rows are retained, so a second restart inside the
    window would otherwise re-arm the same occurrence again."""
    rearm = load_rearm()
    jid, _, _ = cut_a_recurring_reminder(home)

    assert len(rearm.rearm_interrupted()) == 1
    assert rearm.rearm_interrupted() == [], "the second gateway start must say nothing"


def test_an_attempt_with_no_occurrence_is_not_guessed_at(home):
    """Without a bound occurrence we cannot say WHICH firing was lost, and a
    guess is a reminder at the wrong time."""
    from cron import jobs as J
    rearm = load_rearm()
    rec = a_reminder(name="unbound", schedule="* * * * *")
    jid = rec["id"]
    J.advance_next_runs([jid])
    interrupt(jid, None, home)

    assert rearm.rearm_interrupted() == []


def test_a_cut_reminder_off_its_lattice_would_never_fire(home):
    """Why `_rearm_job` writes the occurrence and not "now", pinned against
    Hermes rather than against our own belief: a cron job whose next_run_at is
    not a legal occurrence of its expression is re-anchored WITHOUT firing
    (`_reanchor_stale_cron`, STALE_CRON_EXPR_EDIT). If this ever goes green
    with an off-lattice value, the shortcut became safe and `_rearm_job` can
    be simplified. Until then it has not."""
    from cron import jobs as J
    rec = a_reminder(name="off-lattice", schedule="0 9 * * *")
    jid = rec["id"]
    off = (now() - datetime.timedelta(minutes=3)).replace(second=0, microsecond=0)
    assert off.hour != 9 or off.minute != 0, "pick a clock where 09:00 is not 3 min ago"
    set_next_run(jid, off.isoformat())

    assert jid not in due_ids(), "an off-lattice next_run_at is thrown away, not fired"


def test_it_never_raises_when_the_store_is_unreadable(home):
    """It runs on the delivery adapter's connect(). A cron store we cannot
    read is a log line, never a platform that fails to come up."""
    rearm = load_rearm()
    cron_dir = home.hermes / "cron"
    cron_dir.mkdir(exist_ok=True)
    (cron_dir / "executions.db").write_text("this is not a database")

    assert rearm.rearm_interrupted() == []


def test_the_record_of_what_was_armed_is_readable(home):
    """`rearmed.json` is what stops the double-say; if it is not written, it
    cannot."""
    rearm = load_rearm()
    cut_a_recurring_reminder(home)
    rearm.rearm_interrupted()

    with open(rearm.state_path(), encoding="utf-8") as f:
        rows = json.load(f)["rearmed"]
    assert [r["outcome"] for r in rows] == ["rearmed"]
    assert rows[0]["job"] == "standup"
    assert oct(os.stat(rearm.state_path()).st_mode)[-3:] == "600"

#!/usr/bin/env python3
"""Everything Settings › Reminders needs from Hermes's cron, in one place.

The pane shows what is on a clock and lets a person put something new
there. Neither half can be done from Swift alone: the schedule store, the
blueprint catalogue and the brain pin all live inside Hermes, and two of
the three have shapes that have already moved once.

Five things this file exists to get right, each of which has cost real
work here before:

**A job is created through `register_job`, never `create_job`.**
`configure-hermes.py` owns that function and it pins the job to the brain
in use now (`pin_job_brain`). Hermes refuses to run an UNPINNED job whose
global inference config has changed since the job was created — "skipped
to prevent unintended spend" — so a job created any other way stops dead
the next time the person changes their brain in Settings, with one line in
a log nobody opens. That happened on this Mac and killed every background
job. So this imports configure-hermes.py rather than reimplementing it:
one definition of what a Moe job is, in the file that already reconciles
every job on every launch. `moe-blueprints`' own `blueprint_create` calls
`create_job` directly and is NOT that path — this is deliberately not a
wrapper around the plugin tool.

**A blueprint's default is never an answer.** `custom-reminder.what`
defaults to "take a break and stretch". `blueprints` strips `default` from
every field before it leaves this process, so no default can reach the
form and be pre-filled, and `create` refuses a blank answer to any slot
that is not optional. Both halves are needed: the plugin found that a
model shown a default echoes it back, and a form shown one is tapped
through. A third half, added after a review: the blank check SKIPS
optional slots, so that rule held only because no slot in Hermes's
catalogue is optional today. `do_create` now checks the prompt it is
about to store for a default the person did not type, which does not
depend on an upstream flag staying put.

**Nothing here reports a schedule for a job that cannot fire.** Hermes
already answers that — `is_job_runnable` and `effective_job_state`, plus
the ticker heartbeat — so the answer is asked for rather than re-derived
from `enabled` and `next_run_at`, which is how a paused job comes to read
as scheduled. **The brain is part of that answer**, and was missing until
2026-09-04: Hermes refuses an unpinned job whose brain has moved at
DISPATCH, leaving `state`, `runnable` and `next_run_at` untouched, so a
job that would be skipped for ever read "Next tomorrow at 8:00 am". Every
job this pane did not create can be in that state; on this Mac,
`moe-social-drafts` is one brain change from it. `describe` carries the
pin, the snapshot, and Hermes's own verdict on the pair (`drift_helpers`).

**A create that fails leaves nothing behind.** `register_job` can succeed
into the store and still produce no pin, and it can raise after writing.
Both used to leave the job there: enabled, on the clock, and — with no
snapshot of a brain either — outside the very guard that stops drifted
jobs, so it followed whatever brain Moe was moved to and spent on it. See
`abandon`; it is taken back, and the refusal says so.

**Read-mostly.** `list` and `blueprints` write nothing. The four verbs
that do write go through Hermes's own `cron.jobs` functions.

    reminders.py list
    reminders.py blueprints
    reminders.py create --key KEY --values JSON [--name=NAME]
    reminders.py pause|resume|remove|run JOB_ID

`--name=NAME`, with the equals sign, and the same at the call site. A
person may legitimately call a reminder `-daily`, and `--name -daily`
makes argparse exit 2 with an empty stdout — which is not a refusal the
pane can read, so it says "Moe couldn't reach the part of itself that
keeps the clock" about a name there was nothing wrong with.

One JSON object on stdout, always: `{"ok": true, …}` or
`{"ok": false, "error": "…"}`, and exit 0 for both — a refusal is an
answer with words in it, and the caller shows them. A non-zero exit with
no JSON means this crashed, which is a different thing and the pane says
so differently.

Needs the Hermes venv's interpreter: configure-hermes.py imports PyYAML at
module scope and refuses, loudly, to be imported by anything else.
"""

import argparse
import importlib.util
import json
import os
import sys

#: Moe's own upkeep, which the pane shows and does not let anyone edit.
#:
#: Named literally rather than matched on the `moe-` prefix, because that
#: prefix is not a reliable signal: `moe-blueprints`' own tool names a job
#: it creates `moe-<key>` when the caller gives no name, so a reminder the
#: person asked Moe for in conversation is called `moe-custom-reminder` and
#: is very much theirs to change. Seven, not three — `moe-drain-intents` and
#: `moe-calendar-heads-up` were added later and were missing from the first
#: two lists that tried to write this down; `moe-loop-check` and
#: `moe-channel-holder` (configure-hermes.py JOB_SPECS) were missing from
#: the third, and sat under "Yours" with raw names and a Remove button
#: until 2026-09-16. The list to keep this in step with is JOB_SPECS.
#:
#: Spelled in one case and compared in another (see `reserved_name`),
#: because **Hermes's own name lookup is case-insensitive and this used not
#: to be.** `cron.jobs.resolve_job_ref` lowercases both sides, so a
#: reminder called `MOE-PROACTIVE` — one shift key away, and accepted here
#: until 2026-09-04 — makes `resolve_job_ref("moe-proactive")` raise
#: `AmbiguousJobReference` from then on. That breaks every Hermes path
#: that reaches Moe's own job by name (`hermes cron pause|resume|remove|
#: runs moe-proactive`, and the web server) permanently, and on a Mac where
#: the real job has not been installed yet the impostor simply resolves AS
#: it. Measured both ways before the fix.
UPKEEP = frozenset((
    "moe-learn-deep",
    "moe-proactive",
    "moe-watch-pulse",
    "moe-drain-intents",
    "moe-calendar-heads-up",
    "moe-loop-check",
    "moe-channel-holder",
    "moe-situations",
    "moe-memory-tidy",
    "moe-weekly-digest",
))

#: The one open-ended part of it: `configure-hermes.py` installs one watch
#: job per recipe in ~/.moe/watch/, so the set of watch jobs is whatever
#: the person has connected. `moe-watch-pulse` is in UPKEEP above because
#: the plan names it; this is what covers the sixth one nobody has yet.
UPKEEP_PREFIX = "moe-watch-"


def reserved_name(name):
    """Whether Moe may be asked to CREATE a reminder under this name.

    Case-insensitive, because `resolve_job_ref` is (see UPKEEP). The whole
    `moe-watch-` family is reserved outright here even though only some of
    it exists on any given Mac: reserving a name Moe might later want costs
    the person one rename, and letting them take it costs them every Hermes
    command that names that job.
    """
    folded = str(name or "").strip().casefold()
    return (folded in {n.casefold() for n in UPKEEP}
            or folded.startswith(UPKEEP_PREFIX.casefold()))


def is_upkeep(job):
    """Whether this job RECORD is Moe's own upkeep — shown, never edited.

    Not the same question as `reserved_name`, and deliberately narrower.
    The seven literal names are Moe's whatever they contain. A
    `moe-watch-…` name is only Moe's when the record actually runs one of
    the watch shims `configure-hermes.py` writes (`monitor_script:
    moe-watch-<connection>.py`) — a well-formed identifier that resolves to
    nothing is more dangerous than an absent one, so this resolves rather
    than pattern-matching.

    That difference is the whole point: a reminder called
    `moe-watch-prices`, which Moe itself will make from a conversation when
    the caller gives no name, was refused pause, run AND remove from this
    pane with the words "it is switched off in Settings › Running in the
    background" — where it is not, because it is not upkeep. It was
    unremovable from anywhere the person could see. Now the prefix is still
    refused as a NEW name, and an existing job under it is theirs unless it
    is running Moe's own shim.
    """
    name = str(job.get("name") or "").casefold()
    if name in {n.casefold() for n in UPKEEP}:
        return True
    if not name.startswith(UPKEEP_PREFIX.casefold()):
        return False
    script = str(job.get("monitor_script") or job.get("script") or "").casefold()
    return script.startswith(UPKEEP_PREFIX.casefold())

#: What a job created from this pane may deliver to, beyond the platforms
#: the machine has enabled. `origin` is excluded on purpose: a job created
#: from a Moe conversation records an origin of `api_server`, whose adapter
#: cannot send, so a job delivering there runs and reaches nobody. `local`
#: writes a file nobody reads. `moe` is this Mac's screen plus the chats
#: ticked in Settings › Background, and is the default.
DEFAULT_DELIVER = "moe"


#: Every key each answer carries, whether or not it has anything to say.
#:
#: This is a contract with Swift, not tidiness. Swift's synthesised
#: `Decodable` does NOT fall back to a property's default value when a key
#: is missing — it throws `keyNotFound` and the WHOLE answer fails to
#: decode. So a successful `create` that simply had no `error` to report
#: came back to the pane as "Moe couldn't reach the part of itself that
#: keeps the clock", after having created the job. Measured, not reasoned
#: about: `struct S { var error = "" }` against `{"ok": true}` throws.
#:
#: The Swift side decodes every one of these with `decodeIfPresent` as
#: well, so neither end alone can bring it down. Two halves, because this
#: failure is silent in exactly the direction that matters — it turns a
#: success into an error message.
SHAPES = {
    "list": {"ok": False, "error": "", "jobs": [], "ticker": {"alive": None, "age": None}},
    "blueprints": {"ok": False, "error": "", "blueprints": [], "deliver": []},
    "job": {"ok": False, "error": "", "id": "", "name": "", "missing": []},
}


def answer(kind, fields):
    """One answer, with every key its shape promises."""
    out = dict(SHAPES[kind])
    out.update(fields)
    return out


def die(message, kind="job"):
    json.dump(answer(kind, {"ok": False, "error": str(message)}), sys.stdout)
    sys.stdout.write("\n")
    return 0


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def configure_hermes():
    """configure-hermes.py as a module, from wherever this file is.

    Installed, this sits in ~/.moe/hermes/ beside it; in a checkout, in
    moe-home/hermes/. Either way it is the sibling, so there is no path to
    keep in step. MOE_CONFIGURE_HERMES overrides that path.

    Nothing in this tree sets it, and this used to claim the tests did —
    "which run against a copy rather than the live one". They do not, and
    should not: `scripts/test-reminders-pane.sh` runs THIS file against the
    real configure-hermes.py beside it and a scratch HERMES_HOME, so what
    it proves is what ships. A suite testing a copy proves the copy.
    """
    path = os.environ.get("MOE_CONFIGURE_HERMES") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "configure-hermes.py")
    if not os.path.isfile(path):
        raise RuntimeError("configure-hermes.py is not beside %s — a Moe job cannot be "
                           "pinned to your brain without it, so nothing was created."
                           % os.path.basename(os.path.abspath(__file__)))
    spec = importlib.util.spec_from_file_location("moe_configure_hermes", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def on_path():
    """Put the hermes-agent checkout on sys.path, as every other caller of
    `cron.*` in this repo does. Returns the directory, for register_job."""
    cfg = configure_hermes()
    agent = cfg.hermes_agent_dir(hermes_home())
    if not agent:
        raise RuntimeError("Moe's thinking part isn't installed here yet, so there is "
                           "nothing to schedule against.")
    if agent not in sys.path:
        sys.path.insert(0, agent)
    return cfg, agent


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------


def ticker():
    """Whether a due job would actually fire, in Hermes's own terms.

    Three answers, and the third one matters: `None` is "cannot tell",
    which is not "dead". A missing heartbeat file is an older build or a
    scheduler that has never run, and calling that stopped would tell a
    person their reminders are broken on the evidence of a file that was
    never written.
    """
    try:
        from cron.jobs import get_ticker_heartbeat_age, TICKER_INTERVAL_SECONDS
    except Exception:
        return {"alive": None, "age": None}
    try:
        # Hermes's own threshold, so this and `hermes cron status` cannot
        # drift apart. The fallback is that function's own definition,
        # derived from the shared interval rather than a literal 200s.
        try:
            from hermes_cli.cron import _ticker_stale_after_seconds
            stale_after = _ticker_stale_after_seconds()
        except Exception:
            stale_after = TICKER_INTERVAL_SECONDS * 3 + 20
        age = get_ticker_heartbeat_age()
    except Exception:
        return {"alive": None, "age": None}
    if age is None:
        return {"alive": None, "age": None}
    return {"alive": bool(age <= stale_after), "age": round(float(age), 1)}


def drift_helpers(cfg):
    """Two questions about one job's brain, answered with Hermes's own code.

    `drifted(job)` is the list of axes — `provider`, `model` — on which the
    scheduler's fail-closed guard would refuse to dispatch this job **right
    now**: unpinned, snapshotted at creation, and resolving today to
    something else. Such a job is skipped on every tick, for good, and
    `Job.when()` used to say "Next tomorrow at 8:00 am" about it.

    `unguarded(job)` is the opposite hole and the worse one. An axis that
    is unpinned AND has no snapshot is invisible to that guard, so nothing
    stops it: the job follows whatever brain Moe is moved to, and spends on
    it. That is the state `do_create` used to leave behind on a failure.

    Since upstream 0469740ab3 (merged in the October 2026 catch-up) there
    are no snapshots and nothing can drift: see the comment in the body.

    Both are asked of Hermes (`cron_model_drift_axes`,
    `cron_model_drift_guard_enabled`, `_cron_fleet_default_covers_axis`)
    rather than re-derived here, so this and the scheduler cannot come to
    different answers — and the fleet-default case is why: with `cron.model`
    set, the model axis never follows the global default at all, so a job
    unpinned on it is neither drifted nor unguarded and saying either would
    be a false alarm on this very Mac.

    "Current" is `pin_job_brain(config, {})` — the same function that does
    the pinning, so the comparison is against what `create` would write
    rather than a second, drifting reading of config.yaml.

    When Hermes cannot be asked, both answer "nothing wrong". Reporting a
    job as dead on the evidence of a failed import is exactly the false
    negative the ticker docstring above refuses to make.
    """
    nothing = ((lambda job: []), (lambda job: False))
    try:
        conf, _ = cfg.load_yaml_file(os.path.join(hermes_home(), "config.yaml"))
    except Exception:
        conf = {}
    if not isinstance(conf, dict):
        conf = {}
    try:
        now = cfg.pin_job_brain(conf, {})
        import hermes_cli.config as hermes_config
    except Exception:
        return nothing
    # Upstream 0469740ab3 (2026-09-16) removed creation snapshots outright:
    # an unpinned job runs on whatever the main model is WHEN IT FIRES
    # (per-job pin > cron.model / cron.model_provider > model.default), a
    # legacy record that still carries *_snapshot keys follows the main
    # model too, and `pinned: true` is the only way to hold a job on one
    # brain — it writes an ordinary per-job pin, which is what
    # `pin_job_brain` already writes. `cron_model_drift_axes` went with the
    # snapshot. On that Hermes no job can be on a brain other than the one
    # it was asked to be on, so "drifted" is empty by definition, not as a
    # fallback. The fork pinned before that merge (39563b2a7b) still has
    # the function and still runs an unpinned job on its snapshot, so it is
    # asked there. The two cases are told apart by the attribute, never by
    # an exception: a broken import must not read as the new semantics.
    cron_model_drift_axes = getattr(hermes_config, "cron_model_drift_axes", None)
    if cron_model_drift_axes is None:
        return nothing

    def drifted(job):
        try:
            return [str(a) for a in cron_model_drift_axes(
                job, current_provider=now.get("provider") or "",
                current_model=now.get("model") or "", config=conf)]
        except Exception:
            return []

    def unguarded(job):
        # Hermes 0.21 (upstream 7e4d02fef5, 2026-09-09) no longer refuses an
        # unpinned job at dispatch: a job with no pin runs on its creation
        # snapshot, and one with no snapshot either on the global brain. So
        # there is no job Hermes "would refuse for its brain" any more, and the
        # pane's row for that state is never drawn. Kept as a field so the
        # pane's data shape is unchanged; always False.
        return False

    return drifted, unguarded


def describe(job, helpers):
    """One job as the pane needs it — and only the parts `job-activity.py`
    does not already give it.

    That script owns last run, next run, outcome and cost, and the pane
    reads both and joins them on `id`. What is here is what it has no
    reason to know: where the job delivers, what it was asked to do, and
    whether it can fire at all.
    """
    effective_state, runnable, terminal, drifted, unguarded = helpers
    name = str(job.get("name") or "")
    schedule = job.get("schedule")
    return {
        "id": str(job.get("id") or ""),
        "name": name,
        "deliver": str(job.get("deliver") or ""),
        "prompt": str(job.get("prompt") or ""),
        "script": str(job.get("script") or job.get("monitor_script") or ""),
        # Hermes's word, not one derived here. `enabled` alone says paused
        # for a job that has simply finished its run count, and a job whose
        # `state` still reads "paused" after being re-enabled is scheduled.
        "state": effective_state(job),
        # `is_job_runnable` answers "may the scheduler fire this", which
        # is about the enabled flag and the pause markers — a one-shot
        # that has already run keeps `enabled: true` and comes back True
        # from it. Terminal is folded in here so that one field means one
        # thing to the pane: this job can still happen.
        "runnable": bool(runnable(job) and not terminal(job)),
        "terminal": bool(terminal(job)),
        "schedule": (schedule or {}).get("display") if isinstance(schedule, dict)
                    else (schedule or ""),
        "next_run": job.get("next_run_at"),
        "repeat": (job.get("repeat") or {}).get("times"),
        "completed": (job.get("repeat") or {}).get("completed") or 0,
        # The brain, and whether it still adds up. Without these four the
        # pane's headline rule was FALSE for every job it did not create
        # itself: `state`, `runnable` and `next_run_at` all say a drifted
        # job is fine, because the guard that stops it lives at DISPATCH
        # and leaves no mark on the record. On this Mac that made
        # `moe-social-drafts` read "Next Monday at 8:00 am" while being one
        # brain change away from never running again.
        "provider": str(job.get("provider") or ""),
        "model": str(job.get("model") or ""),
        "provider_snapshot": str(job.get("provider_snapshot") or ""),
        "model_snapshot": str(job.get("model_snapshot") or ""),
        # …and Hermes's own verdict on those four, so the pane does not
        # have to reason about them. See drift_helpers.
        "drifted": drifted(job),
        "unguarded": bool(unguarded(job)),
        "upkeep": is_upkeep(job),
        # Made before jobs recorded who asked for them, and messages someone:
        # the Jobs card asks the person once (do_keep).
        "keep": keep_question(job),
    }


def do_list():
    cfg, _ = on_path()
    from cron.jobs import (list_jobs, effective_job_state, is_job_runnable,
                           is_terminal_job)
    drifted, unguarded = drift_helpers(cfg)
    helpers = (effective_job_state, is_job_runnable, is_terminal_job,
               drifted, unguarded)
    listed = stamp_unnamed_legacy(list_jobs(include_disabled=True))
    jobs = [describe(j, helpers) for j in listed]
    return answer("list", {"ok": True, "jobs": jobs, "ticker": ticker()})


def stamp_unnamed_legacy(jobs):
    """A job made before jobs recorded who asked for them, whose prompt asks
    it to message nobody, has nothing to keep: stamp `grounding_words: []`, so
    it is an ordinary strict job and no send of it is ever amber. Only ever
    makes a job stricter, so it needs no proof of who is asking."""
    out = []
    try:
        asks_for = _recipients().job_asks_for
    except Exception as e:  # noqa: BLE001 — never stamp on a reading that failed
        print("reminders: not stamping old jobs — tools/recipients.py could not be loaded (%s: %s)"
              % (type(e).__name__, e), file=sys.stderr)
        return list(jobs)
    for job in jobs:
        if "grounding_words" in job:
            out.append(job)
            continue
        try:
            asked = asks_for(str(job.get("prompt") or ""))
        except Exception as e:  # noqa: BLE001
            print("reminders: not stamping job %s — could not read whom it messages (%s)"
                  % (job.get("id"), type(e).__name__), file=sys.stderr)
            out.append(job)
            continue
        if not asked:
            try:
                from cron.jobs import set_job_grounding
                job = set_job_grounding(job["id"], []) or dict(job, grounding_words=[])
            except Exception:
                pass
        out.append(job)
    return out


def allowed_deliver():
    """`moe`, plus the bare name of each platform this machine has enabled.

    Read from Hermes's own config rather than from `hermes send --list`,
    which is what Settings › Background asks about forwarding: the two can
    disagree, and the one that decides whether a CRON delivery lands is
    this one. A bare platform name resolves through that platform's home
    channel — the person's own phone — and cannot name a chat, which is
    what keeps a job from being pointed somewhere the person never saw.
    """
    names = [DEFAULT_DELIVER]
    try:
        from hermes_cli.config import load_config
        platforms = load_config().get("platforms") or {}
    except Exception:
        return names
    for name, entry in sorted(platforms.items()):
        if isinstance(entry, dict) and entry.get("enabled") and name not in ("api_server", "moe"):
            names.append(str(name))
    return names


def do_blueprints():
    on_path()
    from cron.blueprint_catalog import CATALOG, blueprint_catalog_entry
    items = CATALOG.values() if hasattr(CATALOG, "values") else CATALOG
    deliver = allowed_deliver()
    out = []
    for b in items:
        entry = blueprint_catalog_entry(b)
        fields = []
        for f in entry.get("fields") or []:
            # `default` is dropped HERE, not in the pane. A default that
            # reaches the form is a default that gets tapped through, and
            # `custom-reminder.what` defaults to "take a break and
            # stretch" — a reminder nobody asked for, at a time nobody
            # chose. Options stay: those are real constraints, and a
            # person who invents an enum value gets a worse error than one
            # who picks from the list.
            field = {k: v for k, v in f.items() if k != "default"}
            if field.get("name") == "deliver":
                # The catalogue offers `discord` and `email` on every Mac,
                # connected or not, and cron then refuses them. Offering a
                # choice that fails is worse than offering fewer. Its help
                # goes with them: it explains `origin` and `local`, which
                # are the two this pane deliberately does not offer.
                field["options"] = deliver
                field["help"] = ("Moe means this Mac, spoken and on screen, plus the chats "
                                 "you ticked under Running in the background.")
            fields.append(field)
        out.append({
            "key": entry.get("key"),
            "title": entry.get("title"),
            "description": entry.get("description"),
            "category": entry.get("category"),
            # `scheduleHuman` is deliberately not passed on. It reads
            # "daily at 08:00" — the catalogue's own defaults rendered as
            # prose, which is a default reaching the form by the back door
            # and being read as the answer already chosen.
            "fields": fields,
        })
    return answer("blueprints", {"ok": True, "blueprints": out, "deliver": deliver})


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------


def abandon(name, list_jobs, remove_job):
    """Take back a half-made job, and say in the answer that it is gone.

    The duplicate check in `do_create` has already established that nothing
    was on the clock under this name, so anything there now was written by
    the call that then failed, and it is ours to remove.

    Leaving it — which is what this file did until 2026-09-04 — is worse
    than the failure it was reporting. The record is enabled, has a
    `next_run_at`, and has neither a provider, a model, nor a SNAPSHOT of
    either. `cron/scheduler.py`'s fail-closed drift guard skips an unpinned
    job only when it has a snapshot to compare against; with none, the
    guard never engages, so the job is not stopped — it quietly follows
    whatever brain Moe is moved to and spends on it, for as long as it
    exists. Meanwhile the pane drew the row as "Next at 6:30 pm" and a
    second press of Create answered "There is already a reminder called…",
    which is a different refusal about a job the person was told was never
    made. All four of those were reproduced before this was written.
    """
    stuck = []
    try:
        left = [j for j in list_jobs(include_disabled=True)
                if j.get("name") == name]
    except Exception:
        # Cannot even look. Say nothing rather than promise a clean store.
        return ""
    for j in left:
        try:
            if not remove_job(j.get("id")):
                stuck.append(str(j.get("id") or "?"))
        except Exception:
            stuck.append(str(j.get("id") or "?"))
    if stuck:
        return (" A half-made reminder is still on the clock (%s) and Moe could not take "
                "it back — remove it here before trying again." % ", ".join(stuck))
    return " Nothing was left on the clock."


def do_create(key, values, name):
    cfg, agent = on_path()
    from cron.blueprint_catalog import get_blueprint, fill_blueprint
    from cron.jobs import ensure_dirs, list_jobs, remove_job

    blueprint = get_blueprint(key)
    if blueprint is None:
        return answer("job", {"error": "There is no reminder template called %r." % key})

    # Every slot that is not optional must carry an answer the person
    # typed. The catalogue's defaults never left this process (see
    # do_blueprints), so a blank here is a blank on the form.
    missing = [s.name for s in blueprint.slots
               if not getattr(s, "optional", False)
               and not str(values.get(s.name) or "").strip()]
    if missing:
        return answer("job", {"error": "Still to answer: %s." % ", ".join(missing),
                              "missing": missing})

    deliver = str(values.get("deliver") or "").strip()
    if deliver and deliver not in allowed_deliver():
        return answer("job", {"error":
                              "Moe can't deliver a reminder to %s from here." % deliver})

    try:
        spec = fill_blueprint(blueprint, values)
    except Exception as e:
        # Hermes's own fill errors are already sentences a person can act
        # on — "invalid time '6pm' — use HH:MM (24h)" — so they are passed
        # through as they are. Anything else is a fault rather than an
        # answer and keeps its type, which is what a bug report needs.
        if type(e).__name__ == "BlueprintFillError":
            return answer("job", {"error": str(e)})
        return answer("job", {"error": "%s: %s" % (type(e).__name__, e)})

    # "A default is never an answer", enforced on what came OUT rather than
    # on a flag upstream.
    #
    # The `missing` check above skips any slot marked `optional`, and
    # `fill_blueprint` does `values.get(s.name, s.default)` — so the rule
    # this file's header states holds today only because no slot in
    # Hermes's catalogue is optional. Flipping one flag there (measured:
    # `custom-reminder.what`) makes a form nobody filled in store "Remind
    # the user: take a break and stretch", with `ok: true`, at a time
    # nobody chose. That flag is not ours and `hermes update` moves it.
    #
    # So the falsifier is here and does not depend on it: if a slot the
    # person left blank has a catalogue default, and that default is in the
    # prompt about to be written, the default IS the answer. Refuse.
    echoed = []
    for s in blueprint.slots:
        default = str(getattr(s, "default", "") or "").strip()
        if (default and not str(values.get(s.name) or "").strip()
                and default in str(spec.get("prompt") or "")):
            echoed.append(s.name)
    if echoed:
        return answer("job", {"error": "Still to answer: %s." % ", ".join(echoed),
                              "missing": echoed})

    # FORCED, not setdefault: `fill_blueprint` always writes the
    # blueprint's own title, so two reminders from one template would
    # collide on it — and `register_job` keys on the name, so the second
    # would quietly update the first instead of being a second reminder.
    spec["name"] = str(name or "").strip() or str(spec.get("name") or key)
    if str(spec.get("deliver") or "").strip().lower() in ("", "origin"):
        spec["deliver"] = DEFAULT_DELIVER

    # Moe's upkeep names are reserved, and this is not tidiness. Jobs are
    # keyed by NAME everywhere — `register_job` updates the job it finds
    # under one rather than making a second — so a reminder called
    # `moe-proactive` created before configure-hermes has installed the
    # real one would quietly BECOME the real one on the next launch, taking
    # its schedule and its script. The duplicate check below catches this
    # on a Mac where the upkeep job already exists; this catches the Mac
    # where it does not yet.
    if reserved_name(spec["name"]):
        return answer("job", {"error":
                              "%s is a name Moe uses for its own upkeep. Give this reminder "
                              "another one." % spec["name"]})

    ensure_dirs()
    # Case-insensitively, for the same reason the reserved names are: a
    # second job whose name differs only in case makes Hermes's own
    # `resolve_job_ref` ambiguous for BOTH of them from then on, so every
    # `hermes cron … <name>` against either one raises instead of running.
    folded = spec["name"].casefold()
    if [j for j in list_jobs(include_disabled=True)
            if str(j.get("name") or "").casefold() == folded]:
        return answer("job", {"error":
                              "There is already a reminder called %r. Give this one a "
                              "different name." % spec["name"]})

    report = cfg.Report()
    # THE line this file exists for. register_job pins the job to the brain
    # in use now before it creates anything; create_job does not.
    #
    # It writes through a child process, so it can fail AFTER the store has
    # the job — and `main`'s blanket `except` would then report the crash
    # and leave that job behind, live, unpinned and unmentioned. Same
    # cleanup as the unpinned case below, for the same reason.
    try:
        cfg.register_job(hermes_home(), agent, spec, "", report)
    except Exception as e:
        return answer("job", {"error": "That reminder wasn't created (%s: %s).%s"
                              % (type(e).__name__, e,
                                 abandon(spec["name"], list_jobs, remove_job))})

    # The job, not the verdict. register_job returns False for "already
    # registered" as well as for a refusal, and reports the refusal into a
    # list rather than raising — so asking it whether it worked is asking
    # the wrong thing. Ask the store.
    made = [j for j in list_jobs(include_disabled=True) if j.get("name") == spec["name"]]
    if not made:
        why = "; ".join(report.notes) or "Hermes did not say why."
        return answer("job", {"error": "That reminder wasn't created. %s" % why})
    job = made[0]
    # And the pin, for the same reason: a job in the store with no provider
    # and no model is the exact failure this path exists to prevent, and it
    # looks identical to a working one until the brain changes.
    #
    # Taken back rather than reported and left. See `abandon`: an unpinned,
    # UNSNAPSHOTTED job is not merely stopped, it is outside the guard that
    # stops drifted ones, so it runs on whatever brain comes next. "Remove
    # it and try again", which is what this used to say, asked the person
    # to clean up a live spend hole through a pane that had just told them
    # nothing was made.
    if not (job.get("provider") or job.get("model")):
        return answer("job", {"error":
                              "That reminder wasn't created: Moe couldn't tie it to a brain, "
                              "and an untied one would follow whatever brain you move to and "
                              "spend on it. Choose a brain under Settings › Brain, then try "
                              "again.%s" % abandon(spec["name"], list_jobs, remove_job)})
    # Who asked: the answers the person typed into this form, recorded as their
    # words — only when the app itself started this script (see `app_parent`).
    if app_parent():
        typed = "; ".join(str(v).strip() for v in values.values() if str(v or "").strip())
        if typed:
            from cron.jobs import set_job_grounding
            set_job_grounding(job.get("id"), person_words(typed))
    return answer("job", {"ok": True, "id": job.get("id"), "name": spec["name"],
                          "schedule": spec.get("schedule"), "deliver": spec.get("deliver"),
                          "provider": job.get("provider"), "model": job.get("model")})


def guard_upkeep(job):
    """Moe's own upkeep is read-only, wherever the request came from.

    The pane draws no buttons on those rows, but a pane is not a guard: it
    is the same subprocess with the same arguments, and the only place this
    can actually be refused is here.

    Takes the record rather than the id, because `is_upkeep` resolves the
    watch family against the shim the record runs rather than trusting its
    name — see there.
    """
    if is_upkeep(job):
        return answer("job", {"error":
                              "%s is part of how Moe keeps itself up to date. It is switched "
                              "off in Settings › Running in the background, not here."
                              % str(job.get("name") or "")})
    return None


def guard_dispatch(job, drifted):
    """"Run now" must not look like it worked when it cannot.

    `trigger_job` only stamps `manual_run_at`; the fail-closed drift guard
    runs later, at dispatch, and skips the job with one line in a log. So
    the button returned `ok: true`, the row did not change, and nothing
    ever happened — the silence being the whole complaint. Refused here,
    before the stamp, so the person is told rather than left watching.
    """
    axes = drifted(job)
    if not axes:
        return None
    was = ", ".join("%s %s" % (a, str(job.get("%s_snapshot" % a) or "?")) for a in axes)
    return answer("job", {"error":
                          "Moe won't run this: it was set up for a different brain (%s) and "
                          "is not tied to one, so Hermes skips it rather than spend on the "
                          "brain you are on now. Remove it and make it again." % was})


def _recipients():
    """Moe's tools/recipients.py, beside this payload."""
    import importlib.util
    here = os.path.dirname(os.path.realpath(__file__))
    path = os.path.join(here, os.pardir, "tools", "recipients.py")
    spec = importlib.util.spec_from_file_location("moe_recipients_pane", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def app_parent():
    """This script was started by the signed Memoe app itself (its parent
    process), not by a shell a model is typing into."""
    try:
        return bool(_recipients().parent_is_the_app(os.getppid()))
    except Exception:
        return False


def person_words(text):
    return [{"text": str(text), "origin": "person", "sender": {"kind": "local"}}]


def keep_question(job):
    """"This job messages Dan — keep?" for a job made before jobs recorded who
    asked for them, that messages somebody; else None."""
    if "grounding_words" in job:
        return None
    try:
        # The same reading the send gate is soft about (recipients.py
        # legacy_soft_for): the card asks about exactly who amber covers.
        asked = _recipients().job_asks_for(str(job.get("prompt") or ""))
    except Exception:
        return None
    if not asked:
        return None
    return {"asks_for": asked, "question": "This job messages %s — keep?" % ", ".join(asked)}


def do_keep(job_id, answer_text):
    """The person's answer on the Jobs card, recorded as who asked for the job.
    Refused unless the Memoe app started this script: a model's shell never is
    its child. Residual risk, stated: any same-uid process could import
    cron.jobs and call set_job_grounding itself; the send gate refuses a
    model's tool call that names it."""
    if not app_parent():
        return answer("job", {"error": "Only the Memoe app can record who asked for a job."})
    cfg, _ = on_path()
    from cron.jobs import get_job, set_job_grounding
    job = get_job(job_id)
    if job is None:
        return answer("job", {"error": "There is no reminder with that id."})
    text = (answer_text or "").strip()
    if not text:
        return answer("job", {"error": "Nothing was said to keep."})
    set_job_grounding(job_id, person_words(text))
    return answer("job", {"ok": True, "id": job_id, "name": str(job.get("name") or "")})


def do_verb(verb, job_id):
    cfg, _ = on_path()
    from cron.jobs import get_job
    job = get_job(job_id)
    if job is None:
        return answer("job", {"error": "There is no reminder with that id."})
    refusal = guard_upkeep(job)
    if refusal:
        return refusal
    drifted, _unguarded = drift_helpers(cfg)
    if verb == "run":
        refusal = guard_dispatch(job, drifted)
        if refusal:
            return refusal
    from cron.jobs import pause_job, resume_job, remove_job, trigger_job
    if verb == "pause":
        pause_job(job_id)
    elif verb == "resume":
        resume_job(job_id)
    elif verb == "run":
        trigger_job(job_id)
    elif verb == "remove":
        if not remove_job(job_id):
            return answer("job", {"error": "That reminder could not be removed."})
        return answer("job", {"ok": True, "id": job_id, "removed": True})

    # The store again, never the return value: `pause_job` answers with the
    # record it wrote, which is true of a pause that did nothing as well.
    job = get_job(job_id)
    if job is None:
        return answer("job", {"error": "That reminder is no longer there."})
    from cron.jobs import is_job_runnable, effective_job_state
    if verb == "pause" and is_job_runnable(job):
        return answer("job", {"error": "That reminder is still running on its clock."})
    if verb == "resume" and not is_job_runnable(job):
        return answer("job", {"error": "That reminder did not start again."})
    return answer("job", {"ok": True, "id": job_id, "state": effective_job_state(job),
                          "runnable": is_job_runnable(job)})


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("list", "blueprints", "create",
                                       "pause", "resume", "remove", "run", "keep"))
    ap.add_argument("--answer", default="")
    ap.add_argument("job_id", nargs="?", default="")
    ap.add_argument("--key", default="")
    ap.add_argument("--values", default="{}")
    ap.add_argument("--name", default="")
    args = ap.parse_args(argv)
    # A refusal has to be shaped like the answer that was asked for, or the
    # pane cannot read it — see SHAPES.
    kind = args.action if args.action in ("list", "blueprints") else "job"

    try:
        if args.action == "list":
            out = do_list()
        elif args.action == "blueprints":
            out = do_blueprints()
        elif args.action == "create":
            try:
                values = json.loads(args.values)
            except ValueError:
                return die("Moe could not read the answers on that form.", kind)
            if not isinstance(values, dict):
                return die("Moe could not read the answers on that form.", kind)
            out = do_create(args.key, values, args.name)
        elif args.action == "keep":
            if not args.job_id:
                return die("Which reminder?", kind)
            out = do_keep(args.job_id, args.answer)
        else:
            if not args.job_id:
                return die("Which reminder?", kind)
            out = do_verb(args.action, args.job_id)
    except Exception as e:
        return die("%s: %s" % (type(e).__name__, e), kind)
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

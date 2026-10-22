#!/usr/bin/env python3
"""What the daily learning pass did last time, and why — the one record
that makes "Alfie hasn't learned about you" a sentence instead of a silence.

    last_pass.py record <outcome> "<reason>" [--read a,b] [--skipped "a(why),b(why)"]
    last_pass.py show                 the record as JSON; exit 1 when there is none
    last_pass.py explain              one sentence for a person: why the list
                                      of what Alfie knows is empty, or what the
                                      pass last did — from this record and the
                                      recorded consent, nothing live

The record is $MOE_HOME/logs/learn-last.json:

    {"at": "2026-09-14T13:53:17-04:00", "outcome": "not-asked",
     "reason": "…", "read": [], "skipped": []}

and every `record` also appends one line to $MOE_HOME/logs/learn.log, the
log learn.sh keeps, so a developer reading the log sees the days the pass
did nothing beside the days it ran.

Why this exists. moe-learn-deep.sh runs once a day as a Hermes no-agent
cron job: empty stdout is a silent tick, and it prints nothing unless a
pass failed, because its stdout is delivered to the person. So every
reason it had for doing nothing — the switch never turned on, Background
thinking off, no source allowed — was a run Hermes recorded as `ok`,
`silent (empty output)`, and nothing on the Mac said why. Measured
2026-09-14: three such days after an erase, no `memory/profile/`, no
`logs/learn.log`, and the person's away machine answering "who am I" with
nothing, while every gate had answered correctly. The gates were right; the
silence was the bug.

Outcomes, in the order the wrapper and learn.sh reach them:

    paused      Background thinking is off (config.json backgroundThinking)
                or the plan is nearly used up (lib/headroom.py) — the reason says which
    not-asked   the background-learning consent has never been answered
    off         it was answered no (Settings › Background, or the sheet)
    no-gate     learn/consent.sh is missing, so nothing may be read
    ran         learn.sh completed; `read` names the sources merged and
                `skipped` the ones it passed over, each with its reason
    failed      learn.sh exited non-zero, or a source could not be
                distilled or merged

Python 3.9, stdlib only, like the rest of learn/.
"""

import json
import os
import re
import sys
from datetime import date, datetime

OUTCOMES = ("paused", "not-asked", "off", "no-gate", "ran", "failed")
FILE_NAME = "learn-last.json"

# learn.sh's skip tokens (`name(reason)`), said to a person.
SKIP_WORDS = {
    "no consent": "not switched on",
    "not connected": "not connected",
    "not due": "up to date",
    "empty": "had nothing new",
    "profile": "nothing to learn from",
    "profile unreadable": "couldn't be read",
    "not installed": "couldn't be read",
    "distil failed": "failed",
    "merge failed": "failed",
}


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def logs_dir():
    return os.path.join(moe_home(), "logs")


def record_path():
    return os.path.join(logs_dir(), FILE_NAME)


def profile_dir():
    return os.environ.get("MOE_PROFILE_DIR") or os.path.join(moe_home(), "memory", "profile")


def now_iso():
    return os.environ.get("MOE_NOW") or datetime.now().astimezone().replace(microsecond=0).isoformat()


def split_list(text):
    """learn.sh's lists, as it keeps them: space-separated tokens, a skip
    token carrying its reason in brackets — "fixture(no consent) second(not
    due)" → ["fixture(no consent)", "second(not due)"]. Commas separate
    too. The bracketed part may hold spaces; nothing else may."""
    return re.findall(r"[^\s,()]+(?:\([^)]*\))?", text or "")


def load():
    try:
        with open(record_path(), encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) and d.get("outcome") in OUTCOMES else None


def plan_paused(rec):
    """The record is the headroom gate's pause (not the switch's)."""
    return bool(rec) and rec.get("outcome") == "paused" and PLAN_NEARLY_USED in (rec.get("reason") or "")


#: Daily runs in a row paused for plan headroom before the owner is told,
#: once. A pass that waits a day is the gate working; one that has waited
#: three is a person whose memory has quietly stopped growing (2026-10-13/14:
#: two days running on the owner's Mac, with nothing anywhere saying so).
PAUSED_TELL_RUNS = 3


def record(outcome, reason, read=(), skipped=()):
    if outcome not in OUTCOMES:
        raise ValueError("unknown outcome: %s" % outcome)
    reason = " ".join((reason or "").split())
    os.makedirs(logs_dir(), exist_ok=True)
    prev = load()
    rec = {"at": now_iso(), "outcome": outcome, "reason": reason,
           "read": list(read), "skipped": list(skipped)}
    tell = ""
    if plan_paused(rec):
        # The streak rides on the record: how many runs in a row, since
        # when, and whether the owner has been told. Any other outcome
        # (a run, the switch) ends it.
        going = plan_paused(prev)
        rec["plan_paused_runs"] = (int(prev.get("plan_paused_runs") or 1) + 1) if going else 1
        rec["plan_paused_since"] = (prev.get("plan_paused_since") or prev.get("at")) if going else rec["at"]
        told = bool(prev.get("plan_paused_told")) if going else False
        if rec["plan_paused_runs"] >= PAUSED_TELL_RUNS and not told:
            tell = ("the daily pass has waited %d runs in a row for plan headroom (since %s) — "
                    "nothing new learned since; told once, on the Memory page and in Settings › Background"
                    % (rec["plan_paused_runs"], rec["plan_paused_since"]))
            told = True
        rec["plan_paused_told"] = told
    path = record_path()
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    # The same log learn.sh writes, in its line shape, so the days the pass
    # did nothing sit beside the days it ran.
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(os.path.join(logs_dir(), "learn.log"), "a", encoding="utf-8") as f:
        f.write("[%s] moe-learn-deep: %s — %s\n" % (stamp, outcome, reason))
        if tell:
            f.write("[%s] moe-learn-deep: %s\n" % (stamp, tell))
    return rec


def consent_state(name="background-learning"):
    """granted | refused | unset, the way learn/consent.sh state answers,
    read from the same file — no script is run."""
    try:
        with open(os.path.join(profile_dir(), "consent.json"), encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return "unset"
    entry = d.get(name) if isinstance(d, dict) else None
    if not isinstance(entry, dict) or "granted" not in entry:
        return "unset"
    return "granted" if entry.get("granted") is True else "refused"


def skipped_words(tokens):
    """["gmail(no consent)", "chrome(not connected)"] →
    "gmail: not switched on; chrome: not connected". Sources are grouped
    by reason, in the order the reasons first appear."""
    groups, order = {}, []
    for tok in tokens:
        name, _, why = tok.partition("(")
        why = SKIP_WORDS.get(why.rstrip(")"), why.rstrip(")") or "skipped")
        name = name.strip().split(":")[-1] or name.strip()
        if why not in groups:
            groups[why] = []
            order.append(why)
        groups[why].append(name)
    return "; ".join("%s: %s" % (", ".join(groups[w]), w) for w in order)


def day_words(iso):
    """"2026-09-14T13:53:17-04:00" → "14 Sep"; today → "today"."""
    try:
        d = datetime.fromisoformat(iso).date()
    except (TypeError, ValueError):
        return "recently"
    today = os.environ.get("MOE_TODAY")
    today = date.fromisoformat(today) if today else date.today()
    if d == today:
        return "today"
    if (today - d).days == 1:
        return "yesterday"
    return "%d %s" % (d.day, d.strftime("%b"))


SWITCH = "Turn it on in Settings › Background, along with what it may read."
SOURCES = "Switch on what it may read in Settings › Background."
PASS = "The daily pass that reads back over what you've allowed"
# moe-learn-deep.sh's reason when lib/headroom.py says no; matched, not parsed.
PLAN_NEARLY_USED = "plan is nearly used up"


def explain(rec=None, state=None):
    """One sentence for a person, from the record and the recorded consent.
    Never a live probe: this is read on a settings screen and on the Memory
    page, and both must open at once."""
    state = state or consent_state()
    if state == "unset":
        return "%s has never been switched on, so it hasn't looked yet. %s" % (PASS, SWITCH)
    if state == "refused":
        return "%s is switched off. %s" % (PASS, SWITCH)
    rec = rec if rec is not None else load()
    if rec is None:
        return "%s is on and hasn't run yet. It runs once a day." % PASS
    when = day_words(rec.get("at"))
    outcome = rec.get("outcome")
    if plan_paused(rec) and int(rec.get("plan_paused_runs") or 1) >= PAUSED_TELL_RUNS:
        # Several days running: the quiet note. Here, where the person looks
        # at what Moe knows — never a card on the island (docs/INBOX-QUIET.md).
        return ("%s has waited every day since %s because your plan was nearly used up, so Alfie "
                "hasn't learned anything new about you since. It tries again on its next daily run."
                % (PASS, day_words(rec.get("plan_paused_since"))))
    if outcome == "paused" and PLAN_NEARLY_USED in (rec.get("reason") or ""):
        # The headroom gate, not the switch: it waits and tries again on its
        # next daily run, so say that rather than send the person to a
        # switch that is already on.
        return "%s waited %s because your plan was nearly used up. It tries again on its next daily run." % (PASS, when)
    if outcome == "paused":
        return "%s is on, but “Let Alfie think on its own” is off, so it doesn't run." % PASS
    if outcome in ("not-asked", "off"):
        # The switch has been turned on since that run: nothing to explain
        # but the wait.
        return "%s is on and hasn't run since you switched it on. It runs once a day." % PASS
    if outcome == "no-gate":
        return "%s couldn't run %s: Alfie can't find the file it records your answers in. Run the installer again." % (PASS, when)
    if outcome == "failed":
        return "%s ran %s and didn't finish. Settings › Background has the details." % (PASS, when)
    read, skipped = rec.get("read") or [], rec.get("skipped") or []
    if read:
        return "%s ran %s and read %s, and hasn't found anything to note down yet." % (PASS, when, ", ".join(read))
    why = skipped_words(skipped)
    if why:
        return "%s ran %s but read nothing — %s. %s" % (PASS, when, why, SOURCES)
    return "%s ran %s but found nothing it may read. %s" % (PASS, when, SOURCES)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else ""
    if cmd == "record":
        if len(argv) < 3:
            print("usage: last_pass.py record <outcome> \"<reason>\" [--read a,b] [--skipped a(why),b(why)]",
                  file=sys.stderr)
            return 2
        outcome, reason, read, skipped = argv[1], argv[2], [], []
        rest = argv[3:]
        while rest:
            flag = rest.pop(0)
            value = rest.pop(0) if rest else ""
            if flag == "--read":
                read = split_list(value)
            elif flag == "--skipped":
                skipped = split_list(value)
            else:
                print("last_pass.py: unknown flag %s" % flag, file=sys.stderr)
                return 2
        try:
            record(outcome, reason, read, skipped)
        except ValueError as e:
            print("last_pass.py: %s" % e, file=sys.stderr)
            return 2
        return 0
    if cmd == "show":
        rec = load()
        if rec is None:
            return 1
        print(json.dumps(rec, sort_keys=True))
        return 0
    if cmd == "explain":
        print(explain())
        return 0
    print("usage: last_pass.py record|show|explain", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

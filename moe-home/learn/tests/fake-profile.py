#!/usr/bin/env python3
"""A stand-in for learn/profile.py's scheduling half, for the shell tests.

Answers `get`, `due` and `stamp` the way PROFILES-SPEC.md says the real one
does, from a table the test writes rather than from profiles.json, the
schema cache and consent.json — so a test can say "this source has nothing
to learn" or "this one seeds 400 days" in one line and know exactly what
learn.sh and sync.sh were told. Anything else (`list --json`, `correct`,
`delete`: the memory screen's calls) is handed to the real profile.py, which
the test keeps beside this file as profile.real.py.

  $MOE_HOME/.fake-profiles.json   {"native/fixture": {"seed_days": 400}, …}
                                  keys are kind/name; values override the
                                  built-ins below, per source
  $MOE_PROFILE_DIR/stamps/        the stamps, in the real layout
  $MOE_HOME/.fake-stamp-args      the argv of the last `stamp` call, so a
                                  test can see the --today learn.sh passed

Built-ins are the spec's: natives sync/seed with a 365-day window and a
daily update; Hermes connections nothing at all. Python 3.9, stdlib only.
"""
import json
import os
import sys
from datetime import date, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
MOE = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
PROFILE_DIR = os.environ.get("MOE_PROFILE_DIR") or os.path.join(MOE, "memory", "profile")
BUILTIN = {
    "native": {"sync": True, "seed": True, "seed_days": 365, "update": "daily", "dated": True, "watch": False},
    "mcp": {"sync": False, "seed": False, "seed_days": 365, "update": "never", "dated": False, "watch": True},
    "platform": {"sync": False, "seed": False, "seed_days": 365, "update": "never", "dated": False, "watch": False},
    "skill": {"sync": False, "seed": False, "seed_days": 365, "update": "never", "dated": False, "watch": False},
}
CADENCE = {"daily": 1, "weekly": 7, "monthly": 30}


def today():
    t = os.environ.get("MOE_TODAY")
    return date.fromisoformat(t) if t else date.today()


def split_today(argv):
    """`--today YYYY-MM-DD` out of a verb's arguments, the way the real one
    takes it; the rest come back in order. None means today()."""
    rest, day = [], None
    i = 0
    while i < len(argv):
        if argv[i] == "--today" and i + 1 < len(argv):
            day = date.fromisoformat(argv[i + 1])
            i += 2
        elif argv[i].startswith("--today="):
            day = date.fromisoformat(argv[i][8:])
            i += 1
        else:
            rest.append(argv[i])
            i += 1
    return rest, day


def normalise(source):
    if source.startswith("hermes:"):
        kind, _, name = source[len("hermes:"):].partition(":")
        return kind, name
    if "/" in source:
        kind, _, name = source.partition("/")
        return kind, name
    return "native", source


def resolve(source):
    kind, name = normalise(source)
    prof = dict(BUILTIN.get(kind, BUILTIN["mcp"]))
    try:
        table = json.load(open(os.path.join(MOE, ".fake-profiles.json"), encoding="utf-8"))
    except (OSError, ValueError):
        table = {}
    over = table.get("%s/%s" % (kind, name)) or {}
    prof.update(over)
    prof["source"] = "%s/%s" % (kind, name)
    prof["origin"] = "user" if over else "default"
    prof["why"] = "fake profile for the tests"
    return kind, name, prof


def stamp_path(kind, name):
    return os.path.join(PROFILE_DIR, "stamps", "%s_%s.json" % (kind, name))


def read_stamp(kind, name):
    try:
        return json.load(open(stamp_path(kind, name), encoding="utf-8"))
    except (OSError, ValueError):
        return None


def cmd_get(source):
    _, _, prof = resolve(source)
    print(json.dumps(prof, sort_keys=True))
    return 0


def cmd_due(source, day=None):
    day = day or today()
    kind, name, prof = resolve(source)
    stamp = read_stamp(kind, name)
    if stamp is None:
        print("seed" if prof["seed"] else "no")
        return 0
    every = CADENCE.get(prof["update"])
    if every is None:
        print("no")
        return 0
    updated = date.fromisoformat(stamp.get("updated") or stamp.get("seeded"))
    gap = (day - updated).days
    if gap < every:
        print("no")
        return 0
    n = gap + 1 if prof["dated"] else prof["seed_days"]
    print("update %d" % min(n, prof["seed_days"]))
    return 0


def cmd_stamp(source, what, day=None):
    kind, name, _ = resolve(source)
    stamp = read_stamp(kind, name) or {}
    key = {"seed": "seeded", "update": "updated"}[what]
    stamp[key] = (day or today()).isoformat()
    path = stamp_path(kind, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(stamp, f, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "get":
        return cmd_get(argv[1])
    rest, day = split_today(argv)
    if argv and argv[0] == "stamp":
        with open(os.path.join(MOE, ".fake-stamp-args"), "w", encoding="utf-8") as f:
            f.write(" ".join(argv))
    if len(rest) >= 2 and rest[0] == "due":
        return cmd_due(rest[1], day)
    if len(rest) >= 3 and rest[0] == "stamp" and rest[2] in ("seed", "update"):
        return cmd_stamp(rest[1], rest[2], day)
    real = os.path.join(HERE, "profile.real.py")
    if os.path.isfile(real):
        os.execv(sys.executable, [sys.executable, real] + argv)
    print("fake-profile: no such command: %s" % " ".join(argv), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

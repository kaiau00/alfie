#!/usr/bin/env python3
"""The headroom gate (docs/LOOPS.md §3): may discretionary background work
spend the person's plan right now?

    headroom.py check     exit 0 when there is headroom (or no way to tell),
                          exit 3 when a window is past its bar. Prints nothing.

Two callers share this one gate, so they cannot disagree about when a plan
is "nearly used up":

  * hermes-jobs/moe-brief-monitor.sh — the 30-minute proactive pass. It
    imports this file and prints the stable word `deferred`.
  * hermes-jobs/moe-learn-deep.sh — the daily learn pass, whose distil step
    runs on the person's MAIN brain, one call per ~12 000-character chunk:
    the largest background bill Moe can run up (docs/DEFAULTS.md row 23,
    finding B). It runs `check` and records `paused`.

Exit 3, not 1, for "no headroom": a python that crashes exits 1, and a gate
that cannot run must read as "no idea", which is "go" — not as a shut gate.

A subscription brain has windows — Claude's five-hour and seven-day,
ChatGPT's session and weekly — and past HEADROOM_PAUSE_AT of any short one,
or HEADROOM_PAUSE_LONG_AT of a long one, discretionary work on the person's
own plan does not run, so their own conversation comes first.

Where the gauge comes from depends on the brain. Claude Code reports its
windows on every turn and the fork's transport writes them to
$HERMES_HOME/rate-limit.json. Codex reports nothing per turn, so this asks
Hermes's own usage helper (the one behind `/usage`) at most once per
HEADROOM_ASK_SECONDS and writes the same file in the same shape. An API key
has no windows at all — the person pays per token, and the Background
thinking switch is their gate. A stale, absent or unreadable gauge is "no
idea", which is "go": a gate that cannot read its gauge must not become a
gate that is always shut.

Python 3.9, stdlib only: it runs under whatever python3 is on PATH.
"""

import json
import os
import subprocess
import sys
import time

HEADROOM_PAUSE_AT = 0.5
# The long window is judged on its own, higher bar. On the owner's Mac on
# 2026-09-11 the five-hour window had reset to 17% and the seven-day one
# stood at 57% — every Claude session on the Mac shares it — and one
# threshold for both would have silenced every follow-up for a day and a
# half. A weekly window at half is normal use; at four fifths it is worth
# protecting what is left of the week.
HEADROOM_PAUSE_LONG_AT = 0.8
LONG_WINDOWS = ("seven_day", "weekly")
HEADROOM_FRESH_SECONDS = 6 * 3600
HEADROOM_ASK_SECONDS = 15 * 60
# Brains whose windows Hermes's usage helper can read for us. Claude Code
# is not here: its transport writes the file itself, every turn.
ASKABLE = {"openai-codex": "openai-codex"}
# `check`'s exit code when a window is past its bar.
NO_HEADROOM_EXIT = 3


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def rate_limit_file():
    return os.path.join(hermes_home(), "rate-limit.json")


def brain_provider():
    """`model.provider` from Hermes's config, or "" — a line scan, because
    this runs under whatever python3 is on PATH and PyYAML is not promised."""
    try:
        with open(os.path.join(hermes_home(), "config.yaml"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    in_model = False
    for line in lines:
        if not line.startswith(" ") and line.strip():
            in_model = line.split(":")[0].strip() == "model"
            continue
        if in_model:
            key, _, value = line.strip().partition(":")
            if key == "provider":
                return value.strip().strip("'\"")
    return ""


def pressure(windows):
    """How close the fullest window is to ITS bar: 1.0 means at the bar, so
    the gate reads `>= 1`. A short window is measured against
    HEADROOM_PAUSE_AT, a long one against HEADROOM_PAUSE_LONG_AT. None when
    no window carries a number."""
    worst = None
    if isinstance(windows, dict):
        for name, w in windows.items():
            u = w.get("utilization") if isinstance(w, dict) else None
            if not isinstance(u, (int, float)):
                continue
            bar = HEADROOM_PAUSE_LONG_AT if str(name) in LONG_WINDOWS else HEADROOM_PAUSE_AT
            p = float(u) / bar
            if worst is None or p > worst:
                worst = p
    return worst


def read_gauge():
    """The file as (age in seconds, pressure or None), or None."""
    try:
        with open(rate_limit_file(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    at = data.get("at")
    if not isinstance(at, (int, float)):
        return None
    return time.time() - at, pressure(data.get("windows"))


def ask_hermes(provider):
    """Fetch the windows through Hermes's usage helper, in Hermes's own
    Python, and write them as the transport would. Returns the worst
    utilisation or None; never raises, never takes longer than its timeout."""
    root = os.path.join(hermes_home(), "hermes-agent")
    python = os.path.join(root, ".venv", "bin", "python")
    if not os.access(python, os.X_OK):
        return None
    code = (
        "import json,sys\n"
        "from agent.account_usage import fetch_account_usage\n"
        "s = fetch_account_usage(sys.argv[1])\n"
        "out = {}\n"
        "for w in (s.windows if s else ()):\n"
        "    if w.used_percent is None: continue\n"
        "    out[w.label.lower()] = {'utilization': max(0.0, min(1.0, float(w.used_percent) / 100.0)),\n"
        "                            'resets_at': w.reset_at.isoformat() if w.reset_at else None}\n"
        "print(json.dumps(out))\n"
    )
    try:
        done = subprocess.run([python, "-c", code, provider], cwd=root, capture_output=True,
                              text=True, timeout=20)
        windows = json.loads(done.stdout or "{}")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if not isinstance(windows, dict):
        return None
    snapshot = {"at": time.time(), "provider": provider, "windows": windows}
    target = rate_limit_file()
    tmp = target + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snapshot, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)
    except OSError:
        pass
    return pressure(windows)


def headroom_used():
    """Pressure on the fullest window (1.0 = at its bar), or None when unknown."""
    gauge = read_gauge()
    provider = ASKABLE.get(brain_provider())
    if provider and (gauge is None or gauge[0] > HEADROOM_ASK_SECONDS):
        asked = ask_hermes(provider)
        if asked is not None:
            return asked
    if gauge is None:
        return None
    age, worst = gauge
    if not (0 <= age <= HEADROOM_FRESH_SECONDS):
        return None
    return worst


def no_headroom():
    """True only when a fresh gauge says a window is at or past its bar."""
    used = headroom_used()
    return used is not None and used >= 1.0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] != ["check"]:
        print("usage: headroom.py check", file=sys.stderr)
        return 2
    return NO_HEADROOM_EXIT if no_headroom() else 0


if __name__ == "__main__":
    sys.exit(main())

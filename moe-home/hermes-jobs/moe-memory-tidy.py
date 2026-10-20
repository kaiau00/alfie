#!/usr/bin/env python3
"""The nightly tidy of Hermes's memory, one hourly look (docs/PROACTIVE-MEMORY.md
§3.1/§3.4; the work is claimstore/tidy.py).

Runs the tidy when the last one is at least 20 hours old and the Mac has been
idle for 15 minutes — or when 36 hours have passed, idle or not, so a Mac
that is never left alone is still tidied. Mac only: the away machine shares
the ledger, and two tidies would both merge the same lines.

Background thinking off (config.json `backgroundThinking: false`) means no
tidy. **stdout stays empty**: a no_agent job's stdout is a message to the
person. What it did is in $MOE_HOME/memory/tidy/<day>.json and one line in
$MOE_HOME/logs/memory-tidy.jsonl.
"""
import contextlib
import json
import os
import subprocess
import sys
import time

MIN_GAP_S = 20 * 3600
OVERDUE_S = 36 * 3600
IDLE_S = 15 * 60


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def background_thinking_on():
    try:
        with open(os.path.join(moe_home(), "config.json"), encoding="utf-8") as f:
            return json.load(f).get("backgroundThinking", True) is not False
    except (OSError, ValueError):
        return True


def on_mac():
    return (os.environ.get("MOE_RUNS_IN") or ("mac" if sys.platform == "darwin" else "cloud")) == "mac"


def idle_seconds():
    """Seconds since the last keyboard or mouse event; None when unknown."""
    try:
        out = subprocess.run(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if '"HIDIdleTime"' in line:
            try:
                return int(line.split("=")[-1].strip()) / 1e9
            except ValueError:
                return None
    return None


def last_run_path():
    return os.path.join(moe_home(), "memory", "tidy", "last-run")


def last_run():
    try:
        with open(last_run_path(), encoding="utf-8") as f:
            return float(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def due(now, last, idle):
    gap = now - last
    if gap >= OVERDUE_S:
        return True
    return gap >= MIN_GAP_S and idle is not None and idle >= IDLE_S


def mark(now):
    path = last_run_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("%.0f\n" % now)


def log(entry):
    path = os.path.join(moe_home(), "logs", "memory-tidy.jsonl")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main():
    if not on_mac() or not background_thinking_on():
        return 0
    now = time.time()
    if not due(now, last_run(), idle_seconds()) and os.environ.get("MOE_TIDY_NOW") != "1":
        return 0
    plugins = os.path.join(hermes_home(), "plugins")
    for p in (plugins, os.path.join(plugins, "moe-ledger"), os.path.join(moe_home(), "lib"),
              os.path.join(hermes_home(), "hermes-agent")):
        if os.path.isdir(p) and p not in sys.path:
            sys.path.insert(0, p)
    mark(now)
    try:
        import claimstore
        from claimstore import tidy
        from claimstore.cli import open_store
        import cheap_model
        # Anything printed on the way (a library's warning, a stray debug
        # line) would be delivered to the person: it goes to stderr instead.
        with contextlib.redirect_stdout(sys.stderr):
            store = open_store()
            entry = tidy.run(store, claimstore.resolve_targets(),
                             lambda m: cheap_model.call(m, max_tokens=3000, timeout=180))
    except Exception as e:  # noqa: BLE001 — stderr only; stdout is a message
        print("memory tidy failed: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        # Marked before the run so a crash is not retried every hour; this
        # makes it due again in three hours rather than tomorrow.
        mark(now - MIN_GAP_S + 3 * 3600)
        log({"at": now, "outcome": "failed", "error": "%s: %s" % (type(e).__name__, e)})
        return 1
    log({"at": now, "outcome": entry.get("outcome"), "changes": len(entry.get("changes") or []),
         "refused": len(entry.get("refused") or []), "sizes_before": entry.get("sizes_before"),
         "sizes_after": entry.get("sizes_after")})
    return 0


if __name__ == "__main__":
    sys.exit(main())

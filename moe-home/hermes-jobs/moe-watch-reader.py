#!/usr/bin/env python3
"""The monitor source for a per-connection WATCH job: read one connection,
deterministically, and print what is there.

Hermes runs this from $HERMES_HOME/scripts/ (cron accepts no other
directory), with its own venv interpreter, no arguments and a sanitised
environment. So: the connection to read comes from MOE_WATCH_CONNECTOR,
which the three-line shim beside this file sets (configure-hermes.py writes
one shim per recipe); the read itself is ~/.moe/lib/mcp_read.py, the one
helper the gather pass shares; and the MCP OAuth token comes from
~/.hermes/mcp-tokens/, a file, which the sanitised environment does not
touch.

What it prints is what Hermes hashes. Same bytes as last time: the agent is
not run and no model is spent. Different bytes: the diff goes in front of an
agent that holds the memory tool and NOTHING else (["memory", "no_mcp"] on
the job) and decides whether a sentence is worth saying. That split is the
whole point — see lib/mcp_read.py for why no model may hold the connection.
The reads are DECLARED in the recipe (~/.moe/watch/<connector>.json — the
person's own file for their own connection, never shipped), never chosen
by a model, and this script makes exactly those calls.

Three gates before anything is read, all printing the one word "disabled" —
the same bytes every tick, so a switched-off watch costs nothing:

  * Settings › Background › "Let Alfie get your attention" (`nudges` in
    ~/.moe/config.json) — the answer to "may Alfie speak up on its own";
  * Settings › Running in the background › "Learn from … and watch it" (one switch per source since 2026-09-29, over the older "Tell me when something happens here") for this
    connection (`speak` in its learning profile, learn/source_profile.py)
    — the same answer that decides whether the proactive pass may see its
    section of the brief, so one switch silences both ways Alfie could bring
    this connection up;
  * `learn/consent.sh check watch:<connector>` — the answer for THIS
    connection, off by default.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def _lib():
    """~/.moe/lib/mcp_read.py — the shared read. Imported lazily so the
    gates above run (and "disabled" prints) even if the lib is missing."""
    lib = os.path.join(moe_home(), "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    import mcp_read  # noqa: WPS433
    return mcp_read


def recipe_path(connector):
    # ~/.moe/watch/, not hermes-jobs/: a recipe is one person's own
    # configuration for one of their connections, never product. Nothing
    # under hermes-jobs/ survives an app update that does not ship it, and
    # nothing here is shipped.
    return os.path.join(moe_home(), "watch", "%s.json" % connector)


def load_recipe(connector):
    with open(recipe_path(connector), encoding="utf-8") as f:
        r = json.load(f)
    if not isinstance(r, dict) or r.get("connector") != connector:
        raise ValueError("recipe for %r does not describe %r" % (connector, connector))
    reads = r.get("reads")
    if not isinstance(reads, list) or not reads:
        raise ValueError("recipe for %r declares no reads" % connector)
    for call in reads:
        if not isinstance(call, dict) or not str(call.get("tool") or "").strip():
            raise ValueError("recipe for %r has a read without a tool name" % connector)
        if call.get("args") is not None and not isinstance(call["args"], dict):
            raise ValueError("recipe for %r: args must be an object" % connector)
    return r


# ── gates ────────────────────────────────────────────────────────────────

def nudges_on():
    try:
        with open(os.path.join(moe_home(), "config.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return True
    return not (isinstance(cfg, dict) and cfg.get("nudges") is False)


def may_speak(connector):
    """Is "Learn and watch" (its yes, and speak) on for this connection?

    `speak` in its learning profile — resolved from files by
    learn/source_profile.py, imported rather than run: this is a monitor
    and a subprocess per tick is a subprocess nobody sees the cost of.
    A resolver that is missing or will not load is not an answer, and a
    watch the person set up and consented to is not switched off by it."""
    path = os.path.join(moe_home(), "learn", "source_profile.py")
    try:
        spec = importlib.util.spec_from_file_location("moe_source_profile", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        prof = mod.resolve("mcp/%s" % connector)
    except Exception:
        return True
    return not (isinstance(prof, dict) and prof.get("speak") is False)


def consented(connector):
    script = os.path.join(moe_home(), "learn", "consent.sh")
    if not os.access(script, os.X_OK):
        # No way to check is a no, never a yes.
        return False
    try:
        return subprocess.run([script, "check", "watch:%s" % connector],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


# ── the read ─────────────────────────────────────────────────────────────

def read_connection(recipe, hermes_pair=None):
    """The watch entry point: the recipe's reads, through lib/mcp_read."""
    lib = _lib()
    return lib.read_connector(recipe["connector"], recipe["reads"],
                              recipe.get("max_chars") or lib.MAX_CHARS_DEFAULT,
                              hermes_pair=hermes_pair, task="moe-watch")


def main():
    connector = (os.environ.get("MOE_WATCH_CONNECTOR") or (sys.argv[1] if len(sys.argv) > 1 else "")).strip()
    if not re.match(r"^[a-z][a-z0-9_-]{0,31}$", connector):
        print("moe-watch: no connection named (MOE_WATCH_CONNECTOR)", file=sys.stderr)
        return 2
    if not nudges_on() or not may_speak(connector) or not consented(connector):
        print("disabled")
        return 0
    try:
        recipe = load_recipe(connector)
    except (OSError, ValueError) as e:
        print("moe-watch: %s" % e, file=sys.stderr)
        return 1
    try:
        sys.stdout.write(read_connection(recipe))
    except Exception as e:  # a failed read is an error, never a change
        print("moe-watch: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

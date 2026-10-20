#!/usr/bin/env python3
"""Keep one holder per chat app, while the Mac is awake.

A no_agent cron job. It runs `connectors/channel-holder.py heal`, which asks
each provider Moe's cloud is supposed to be receiving for where it actually
sends, and puts back one that has drifted — bounded to three repairs per
channel and never twice inside ten minutes, both enforced in that script.

**Why a job at all.** The holder is decided at two moments that are both
one-shot: `channels.py migrate`, when a machine is created, and
`configure-hermes.py`, at gateway start. Neither of them can see what happens
afterwards, and what happened afterwards on 2026-09-14 was that this Mac's
Telegram adapter deleted the edge's webhook to recover from a 409. The edge
still held the channel, the Mac still had its marker, and nothing on either
side was going to notice. A tick is the only thing that can.

Output discipline, as for every no_agent job: **stdout is a message to the
person**, so it stays empty unless somebody has to do something. A drift Moe
repaired itself is not that; a drift it has given up on is, and the sentence
comes out of `channel-holder.py` already written for a person.
"""
import os
import subprocess
import sys

HOME = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
SCRIPT = os.path.join(HOME, "connectors", "channel-holder.py")
CHANNELS = os.path.join(HOME, "connectors", "channels.py")


def ask_the_edge_who_reaches_the_owner():
    """`channels.py owner-status --quiet`: which chat apps reach the owner,
    as the CLOUD records it (never decided here), written to
    `cloud/owner-reach.json` for the brief. Silent: everything it says goes
    to the log, never to the person."""
    if not os.path.isfile(CHANNELS):
        return
    try:
        done = subprocess.run([sys.executable, CHANNELS, "owner-status", "--quiet"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=60)
        print((done.stdout or b"").decode("utf-8", "replace"), file=sys.stderr, end="")
    except (OSError, subprocess.SubprocessError) as e:
        print("channels.py owner-status: %s" % e, file=sys.stderr)


def main():
    if not os.path.isfile(SCRIPT):
        print("channel-holder.py is not installed at %s" % SCRIPT, file=sys.stderr)
        return 0
    done = subprocess.run([sys.executable, SCRIPT, "heal"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=300)
    said = (done.stdout or b"").decode("utf-8", "replace")
    # Everything it said goes to the log; only what is still wrong at the end
    # goes to the person, and `say` reads the file this run has just written.
    print(said, file=sys.stderr, end="")
    ask_the_edge_who_reaches_the_owner()
    if done.returncode != 2:
        return 0
    told = subprocess.run([sys.executable, SCRIPT, "say"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          timeout=60)
    for line in (told.stdout or b"").decode("utf-8", "replace").splitlines():
        if "\t" in line:
            print(line.split("\t", 1)[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())

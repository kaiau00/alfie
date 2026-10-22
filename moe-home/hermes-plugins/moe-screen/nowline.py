"""The Now line, for turns that arrive on a chat channel — ticket #9.

On the Mac's own island every turn leaves the Conductor with a first line
saying what time it is where the person is (``Sources/MoeBrain/NowLine.swift``).
A message on Telegram, WhatsApp, Slack — or anything the away machine answers
while the Mac sleeps — never passes through the Conductor: it arrives at
Hermes's gateway and goes straight to the agent. Without this, the only clock
those turns have is ``Conversation started: <date>`` in the system prompt,
which is what let Alfie call a 2 PM meeting "upcoming" at 6 PM.

``pre_gateway_dispatch`` fires once per inbound message on every chat
platform, before the agent, and ``event.channel_context`` is folded into the
user's turn as ``<context>\\n\\n[New message]\\n<text>`` (gateway/run.py). So
the line goes at the head of ``channel_context`` — the user turn, never the
system prompt, because a system prompt that changes respawns the Claude Code
child (5–7 s a turn). It is registered last and PREPENDS, so whatever the
other hooks attached (a follow-up note) reads after it, and the Now line is
the first thing the model sees.

Whose zone. The person's, never the machine's: an away machine's OS clock is
UTC by construction. In order: ``$MOE_HOME/tz.json`` (the Mac writes it on
launch, wake and every zone change and it travels to the machine as the
``tz`` document), then ``timezone:`` in Hermes's ``config.yaml`` (where the
same document lands on the machine), then ``HERMES_TIMEZONE``, then the OS.
A stale tz.json is still used: where the person last was is a better guess
than UTC, and the line names the zone it used.

The format is the Swift one, and ``Tests/MoeAppTests/ConductorNowLineTests``
holds the rule sentence below equal to ``BrainPrompt.nowRule``::

    Now: Wednesday 23 September 2026, 6:08 PM (evening), New York time (EDT, UTC-4).

Stdlib only. Nothing here may break dispatch: every failure is caught and the
message goes through without the line.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

PREFIX = "Now: "

#: How to read the line. Chat turns carry no delivery reminder, so the rule
#: rides with the line itself; constant text, in the user turn.
RULE = "The Now line at the top of each message is the only clock. Anything whose time has passed is over — never call it upcoming. Work out today, tomorrow and tonight from Now, not from the brief or from memory. Times you say are local unless you name the zone."  # noqa: E501 — one literal, so the Swift test can find it

_DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
_MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August",
           "September", "October", "November", "December")


def part_of_day(hour):
    if 5 <= hour < 8:
        return "early morning"
    if 8 <= hour < 12:
        return "morning"
    if 12 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 21:
        return "evening"
    return "night"


def _offset(seconds):
    if seconds == 0:
        return "UTC"
    sign = "-" if seconds < 0 else "+"
    m = abs(int(seconds)) // 60
    return "UTC%s%d" % (sign, m // 60) if m % 60 == 0 else "UTC%s%d:%02d" % (sign, m // 60, m % 60)


def _place(name):
    if not name or "/" not in name:
        return "UTC" if name in ("", "UTC", "GMT", "Etc/UTC") else name
    return name.rsplit("/", 1)[-1].replace("_", " ")


def line(now, zone_name=None):
    """The line for an aware `now`, already in the person's zone."""
    off = _offset(int(now.utcoffset().total_seconds()) if now.utcoffset() is not None else 0)
    # The abbreviation only for the Americas — the one place Foundation and
    # zoneinfo agree (Jerusalem: "GMT+3" vs "IDT"); NowLine.swift makes the
    # same cut, so the island and the chat read one line.
    abbr = now.tzname() or ""
    name = zone_name or ""
    if not (name.startswith(("America/", "US/")) or name == "Pacific/Honolulu") \
            or not (2 <= len(abbr) <= 5 and abbr.isalpha() and abbr.isupper()):
        abbr = ""
    hour12 = now.hour % 12 or 12
    stamp = "%s %d %s %d, %d:%02d %s" % (_DAYS[now.weekday()], now.day, _MONTHS[now.month - 1],
                                          now.year, hour12, now.minute, "AM" if now.hour < 12 else "PM")
    place = _place(zone_name or "")
    if off == "UTC" and place == "UTC":
        where = "UTC"
    else:
        where = "%s time (%s)" % (place, "%s, %s" % (abbr, off) if abbr else off)
    return "%s%s (%s), %s." % (PREFIX, stamp, part_of_day(now.hour), where)


def _moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def _hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def zone_name():
    """The person's IANA zone name, or "" for the OS's."""
    try:
        with open(os.path.join(_moe_home(), "tz.json"), encoding="utf-8") as f:
            name = str((json.load(f) or {}).get("iana") or "").strip()
        if name:
            return name
    except Exception:  # noqa: BLE001 — no file, not JSON: try the next
        pass
    try:
        with open(os.path.join(_hermes_home(), "config.yaml"), encoding="utf-8") as f:
            for raw in f:
                if raw.startswith("timezone:"):
                    name = raw.partition(":")[2].strip().strip("'\"")
                    if name:
                        return name
    except OSError:
        pass
    return os.environ.get("HERMES_TIMEZONE", "").strip()


def now_line(now=None):
    """The line for this moment in the person's zone."""
    name = zone_name()
    utc = now or datetime.now(timezone.utc)
    if name:
        try:
            from zoneinfo import ZoneInfo
            return line(utc.astimezone(ZoneInfo(name)), name)
        except Exception:  # noqa: BLE001 — an unknown zone name: the OS's
            logger.info("now line: unknown zone %r, using the OS's", name)
    local = utc.astimezone()
    return line(local, os.environ.get("TZ", "") or _os_zone_name())


def _os_zone_name():
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return ""


def attach(event=None, **kwargs):
    """`pre_gateway_dispatch`: put the Now line (and how to read it) at the
    head of this turn. Returns None always — dispatch as normal."""
    try:
        if event is None:
            return None
        text = getattr(event, "text", None)
        text = text if isinstance(text, str) else ""
        if text.lstrip().startswith("/"):
            return None          # a slash command is not a turn for the model
        head = "%s\n%s" % (now_line(), RULE)
        existing = getattr(event, "channel_context", None)
        try:
            event.channel_context = "%s\n\n%s" % (head, existing) if existing else head
        except Exception:  # noqa: BLE001 — a frozen event: say it in the text
            return {"action": "rewrite", "text": "%s\n\n%s" % (head, text)}
    except Exception as e:  # noqa: BLE001 — never break a turn over a clock
        logger.warning("now line: not attached: %s: %s", type(e).__name__, e)
    return None

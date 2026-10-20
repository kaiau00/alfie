#!/usr/bin/env python3
"""A word a few minutes before something in the calendar starts.

"If you look at my calendar, tell me a couple of minutes before my schedule
starts" is a promise about a CLOCK, and the proactive pass cannot keep it.
That job runs every 30 minutes and is hash-suppressed: it wakes only when
the brief's bytes move, which for a meeting is when it first appears in the
brief — hours before, or never, if it was already there. "Ten minutes
before" from a half-hourly, content-triggered pass is a coincidence, not a
feature.

So this is its own job: **every two minutes, no model, no network, no
Calendar**. It reads the copy of the calendar the ten-minute sync already
keeps in ``~/.moe/context/calendar.md`` — the same lines the brief is built
from, already on disk, already the thing Moe answers "what's on" from —
finds the events starting inside the window the person asked for, and says
one sentence about each. A tick with nothing to say costs a Python start
and two file reads, and prints nothing at all.

  ── How the message reaches the person ─────────────────────────────────

It is PRINTED, and the job's ``deliver: moe`` carries it. That is the same
delivery every reminder takes: for a ``no_agent`` job Hermes's scheduler
hands stdout straight to the platform (cron/scheduler.py — empty stdout is a
"silent run", never an error), and the ``moe`` platform IS
``hermes-plugins/moe-screen/deliver.py`` — the amber nudge on the island via
the 0600 inbox file, plus a ``hermes send`` to every connector the person
ticked in Settings › Background (``reminderChannels``, read at delivery
time). Importing ``deliver.py`` from here and calling it directly was the
alternative: it would mean reaching into ``$HERMES_HOME/plugins/`` from a
cron script whose environment is deliberately sanitised, and — because
stdout is delivered anyway — every heads-up would arrive twice. One
delivery path, and it is the one that already exists.

  ── Three gates, and every one of them is silent ───────────────────────

Nothing new starts speaking to somebody who did not ask for it, so:

  1. ``nudges`` in ~/.moe/config.json — Settings › Background › "Let Moe get
     your attention", the one autonomy switch, checked before anything at
     all is read;
  2. ``calendarHeadsUpMinutes`` in the same file — this feature's own
     switch, and it is **absent by default, which is off**. A whole number
     of minutes, 1 to 120;
  3. ``speak`` on the calendar's own learning profile — Settings ›
     Background › "Learn from Calendar and watch it" (its yes) for Calendar, the
     same answer that decides whether the proactive pass may see the
     calendar section of the brief, so one switch silences both ways Moe
     could bring the calendar up;

and then the file itself: no ``context/calendar.md`` (Calendar permission
never granted, or withdrawn), nothing to say. Each of those prints NOTHING
and exits 0 — for a no_agent job that is a silent tick, which is what an
off switch has to be.

  ── Once, and only once ────────────────────────────────────────────────

Every two minutes over a ten-minute window is five ticks, so the job
remembers what it has already said: ``~/.moe/proactive/calendar-said.json``,
0600 in a 0700 directory, written the way the open-loop ledger is written
(tmp, fsync, rename, and the tmp removed if any of that fails), pruned of
anything older than a day on the next write. An event is one entry, keyed on
its start and its title, so a meeting that MOVES is a new thing to say and a
meeting that does not is said once.

The entry is written BEFORE the sentence is printed, and nothing is printed
if it could not be: five identical nudges is a worse failure than a missed
one, and it is the failure this job would have by default.

  ── Reading somebody else's date format ────────────────────────────────

``calendar.md`` is what ``connectors/calendar.sh pull`` printed, which is
``Moe --calendar`` through ``MoeConnectors.ConnectorText`` — one line per
event:

    Saturday, October 31, 2026 at 9:00:00 AM | Standup | Room 4

The start is a ``DateFormatter`` with ``.full`` date and ``.medium`` time in
**the person's own locale**, which is not a format anything can parse
blindly ("samedi 31 octobre 2026 à 09:00:00", "2026年10月31日 土曜日
9:00:00"). It does not have to be parsed blindly. The window is at most two
hours, so the only days an event can start on are TODAY and TOMORROW, and
the job never derives a date — it CONFIRMS one: the clock time comes off the
last ``HH:MM`` in the field (with an am/pm marker if there is an ASCII one),
and a candidate day is accepted only if its day-of-month and its year appear
as whole numbers in what is left, and — when an English month name is there
to be read — its month matches too. A line that confirms neither day, or
both, says nothing. Silence on a line nobody can read is the only safe
answer; a wrong guess is Moe interrupting someone about a meeting that is
not happening.

Two things follow from that, and they are on purpose:

* **An all-day event is one whose start is exactly midnight**, and it is
  skipped. EventKit gives an all-day event a midnight start and the line
  carries no other mark, so this is the only signal there is — and the cost
  of getting it wrong the other way is announcing every all-day event at ten
  to midnight the night before.
* **Local time is real time.** Both instants go through ``time.mktime``,
  which asks the OS which offset was in force on that day. On the morning
  the clocks go back, 1:00 AM tomorrow is not "25 hours from midnight" and a
  naive subtraction would have Moe speak an hour early.

  ── And the copy has to be fresh ───────────────────────────────────────

The sync rewrites ``calendar.md`` every ten minutes. If it has not been
touched for 24 hours the sync is not running, and a heads-up built
from a day-old copy is a heads-up about a meeting that may have been moved
or cancelled since. Silence, then. The other end of the same limit: an event
added to Calendar five minutes before it starts may not be in the copy yet,
and this job will not have heard of it.

Python 3.9, stdlib only, ``/usr/bin/python3``-clean — but Hermes runs a
``.py`` cron script with its own venv interpreter (cron/scheduler.py
``_run_job_script``), so it must hold for both. It reads two files, writes
one, never leaves ``$MOE_HOME``, calls no model and opens no socket.
"""

import hashlib
import importlib.util
import json
import os
import re
import sys
import time

#: Settings › Background writes this. Absent or 0 is OFF — the state a
#: person who has never asked for this is in, and stays in.
CONFIG_KEY = "calendarHeadsUpMinutes"
#: The window, in minutes. Below the first the feature is off; above the
#: second is clamped, not refused: somebody who typed 240 has asked for a
#: lot of warning, not for silence.
MIN_MINUTES = 1
MAX_MINUTES = 120
#: The learning profile that governs whether Moe may bring the calendar up
#: on its own. Spelled the way source_profile.py spells a Mac connector.
SOURCE = "native/calendar"
#: What sync.sh keeps, from connectors/calendar.manifest's `context_file`.
CONTEXT_FILE = "calendar.md"
#: Where what has already been said is remembered. Beside the open-loop
#: ledger, in the directory Moe owns.
STATE_DIRNAME = "proactive"
STATE_FILENAME = "calendar-said.json"
#: How long an entry is kept. A day is long enough that nothing inside the
#: two-hour window can be said twice, and short enough that the file stays
#: a few hundred bytes.
STATE_KEEP_SECONDS = 24 * 3600
#: And a ceiling on the entries, for a calendar nobody could have.
STATE_MAX = 200
#: A calendar.md older than this is not a calendar, it is a memory of one.
MAX_STALE_HOURS = 24
#: Sentences in one message. Two meetings at once happens; five does not,
#: and a list read aloud is not a heads-up.
MAX_SAY = 3
#: Of somebody's own event title and location. The title is spoken.
MAX_TITLE = 80
MAX_LOCATION = 40
#: Lines read from the copy, so a file that grew a tail cannot cost a tick.
MAX_LINES = 2000

#: The last HH:MM[:SS] in the start field is the clock time. Nothing else in
#: a rendered date carries a colon in any locale Foundation writes.
_TIME = re.compile(r"(\d{1,2}):(\d{2})(?::(\d{2}))?")
#: An ASCII am/pm marker, after the time or (rarely) before it.
_AMPM = re.compile(r"\b([ap])\.?\s?m\.?", re.I)
#: Whole numbers in the date part: the day of the month, the year, and in
#: some locales the month. Never a fragment of one — "2026" is one number,
#: not a 26 hiding inside it.
_INT = re.compile(r"\d+")
#: English month names, whole words. Word-anchored because a substring test
#: reads the French for Tuesday, "mardi", as March. A name that does not
#: match is not an error: the day and the year still have to agree, and
#: they are what actually decides.
_MONTHS = ("january", "february", "march", "april", "may", "june", "july",
           "august", "september", "october", "november", "december")
_MONTH_RE = re.compile(
    r"\b(%s)\b" % "|".join(list(_MONTHS) + [m[:3] for m in _MONTHS]), re.I)
_MONTH_NUMBER = {}
for _i, _name in enumerate(_MONTHS):
    _MONTH_NUMBER[_name] = _i + 1
    _MONTH_NUMBER[_name[:3]] = _i + 1
#: Control characters never belong in something Moe reads out loud.
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
#: What a state key looks like, so a hand-edited file cannot grow keys.
_KEY = re.compile(r"^[0-9a-f]{16}\Z")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def clock():
    """Now, in epoch seconds.

    ``MOE_NOW`` overrides it, which is how the tests walk a window, a
    midnight and a clock change in one second without waiting for any of
    them. Nothing sets it in production; a garbled one is ignored rather
    than obeyed."""
    raw = os.environ.get("MOE_NOW")
    if raw:
        try:
            return float(raw)
        except ValueError:
            pass
    return time.time()


# ── the gates ────────────────────────────────────────────────────────────

def read_config(moe):
    try:
        with open(os.path.join(moe, "config.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def nudges_on(cfg):
    """Settings › Background › "Let Moe get your attention"."""
    return cfg.get("nudges", True) is not False


def window_minutes(cfg):
    """How many minutes of warning the person asked for, or 0 for none.

    Absent is 0 and so is anything that is not a whole number of minutes:
    this switch is off until somebody sets it, and a config nobody can read
    is not somebody setting it. A number past the ceiling is clamped."""
    raw = cfg.get(CONFIG_KEY)
    if isinstance(raw, bool) or raw is None:
        return 0
    try:
        minutes = int(raw)
    except (TypeError, ValueError):
        return 0
    if minutes < MIN_MINUTES:
        return 0
    return min(minutes, MAX_MINUTES)


def may_speak(moe):
    """Is "Learn and watch" (its yes, and speak) on for Calendar?

    ``speak`` on the calendar's learning profile, resolved from files by
    learn/source_profile.py — imported, not run: this ticks every two
    minutes and a subprocess per tick is a cost nobody sees. A resolver
    that is missing or will not load is not an answer, and must not be read
    as one in either direction; the switch above is what is off by
    default.

    Calendar's yes first (consent.json, its "Learn and watch" switch since
    2026-09-29): a copy of the calendar left behind after a revoke — or
    kept while the ten-minute sync is off — is never spoken from (review
    2026-09-29 #6)."""
    try:
        with open(os.path.join(moe, "memory", "profile", "consent.json"), encoding="utf-8") as f:
            grant = json.load(f).get("calendar")
    except (OSError, ValueError, AttributeError):
        grant = None
    if not (isinstance(grant, dict) and grant.get("granted") is True):
        return False
    path = os.path.join(moe, "learn", "source_profile.py")
    try:
        # source_profile.py resolves its own $MOE_HOME; this file already
        # resolved one, and the two must not disagree.
        os.environ["MOE_HOME"] = moe
        spec = importlib.util.spec_from_file_location("moe_source_profile", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        prof = mod.resolve(SOURCE)
    except Exception:
        return True
    return not (isinstance(prof, dict) and prof.get("speak") is False)


# ── the copy of the calendar ─────────────────────────────────────────────

def read_calendar(moe, now):
    """The lines of context/calendar.md, or None when there are none to
    have: no file, an empty one (sync's "connected, quiet"), one nobody can
    read, or one the sync stopped refreshing a day ago."""
    path = os.path.join(moe, "context", CONTEXT_FILE)
    try:
        age = now - os.stat(path).st_mtime
        if age > MAX_STALE_HOURS * 3600:
            return None
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()[:MAX_LINES]
    except OSError:
        return None
    return lines or None


def parse_start(field, now):
    """(epoch, is_midnight) for one start field, or None.

    See the module note: the clock time is read, the DAY is confirmed. Only
    today and tomorrow are ever candidates, because nothing further away can
    be inside a window of at most two hours, and a field that confirms
    neither of them — or both — is not an answer.

    Never raises. A line nobody can read is a line this job says nothing
    about; it is not a broken job."""
    m = None
    for m in _TIME.finditer(field):
        pass
    if m is None:
        return None
    hour, minute = int(m.group(1)), int(m.group(2))
    second = int(m.group(3) or 0)
    if hour > 23 or minute > 59 or second > 59:
        return None
    marker = (_AMPM.search(field[m.end():m.end() + 8])
              or _AMPM.search(field[max(0, m.start() - 8):m.start()]))
    if marker:
        half = marker.group(1).lower()
        if half == "p" and hour < 12:
            hour += 12
        elif half == "a" and hour == 12:
            hour = 0
    head = field[:m.start()]
    numbers = set()
    for token in _INT.findall(head):
        if len(token) <= 4:
            numbers.add(int(token))
    month_name = _MONTH_RE.search(head)
    month = _MONTH_NUMBER.get(month_name.group(1).lower()) if month_name else None

    found = []
    today = time.localtime(now)
    for offset in (0, 1):
        # Midday, then the offset, then the real clock time: the calendar
        # day after today is one calendar day away, whatever the offset was
        # doing at midnight.
        day = time.localtime(time.mktime((today.tm_year, today.tm_mon, today.tm_mday,
                                          12, 0, 0, 0, 0, -1)) + offset * 86400)
        if day.tm_mday not in numbers or day.tm_year not in numbers:
            continue
        if month is not None and month != day.tm_mon:
            continue
        try:
            when = time.mktime((day.tm_year, day.tm_mon, day.tm_mday,
                                hour, minute, second, 0, 0, -1))
        except (OverflowError, ValueError):
            continue
        found.append(when)
    if len(found) != 1:
        return None
    return found[0], (hour == 0 and minute == 0 and second == 0)


def plain(text, limit):
    """Somebody's own words, made safe to say out loud and to hand to the
    delivery path: one line, no control characters, no brackets (a title
    holding ``[[moe-open: …]]`` would otherwise be stripped out of the
    message by deliver.py, taking the sentence with it)."""
    out = " ".join(_CONTROL.sub(" ", str(text or "")).split())[:limit]
    return out.replace("[", "(").replace("]", ")")


def events(lines, now, minutes):
    """[(start, key, sentence)] for everything starting inside the window,
    soonest first. All-day events are not in it; nor is anything that has
    already started."""
    out = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("|")
        parsed = parse_start(parts[0], now)
        if parsed is None:
            continue
        start, midnight = parsed
        if midnight:
            continue                       # an all-day event, see the module note
        gap = start - now
        if gap < 0 or gap > minutes * 60:
            continue
        title = plain(parts[1] if len(parts) > 1 else "", MAX_TITLE)
        # Everything after the title used to be glued back together as the
        # location. Since the calendar line can carry a "join: <url>" field,
        # that swallowed the URL into the location string — and sentence()
        # refuses to speak a location containing "://", so a real room
        # ("Room 4") silently stopped being announced. Drop the labelled
        # fields; keep the rest as the location it always was.
        tail = [p for p in parts[2:] if not p.strip().lower().startswith("join:")]
        location = plain("|".join(tail), MAX_LOCATION) if tail else ""
        out.append((start, key_for(start, title), sentence(title, location, gap)))
    out.sort()
    return out


def key_for(start, title):
    """One event's identity: when it starts and what it is called. A meeting
    that MOVES is a new thing to say; one that does not is said once."""
    blob = "%d|%s" % (int(start), title)
    return hashlib.sha1(blob.encode("utf-8", "replace")).hexdigest()[:16]


def sentence(title, location, gap):
    """One line, as Moe would say it: plain prose, no markdown, no list."""
    minutes = int(round(gap / 60.0))
    if minutes <= 0:
        when = "is starting now"
    elif minutes == 1:
        when = "starts in a minute"
    else:
        when = "starts in %d minutes" % minutes
    text = "%s %s" % (title or "Something in your calendar", when)
    if location and "://" not in location:
        text += " — %s" % location
    return text + "."


# ── what has already been said ───────────────────────────────────────────

def state_dir(moe):
    return os.path.join(moe, STATE_DIRNAME)


def state_path(moe):
    return os.path.join(state_dir(moe), STATE_FILENAME)


def read_state(moe):
    """{key: when it was said}. Missing, corrupt, a directory, a shape from
    another world: all of them are "nothing has been said", which costs one
    repeated heads-up and never a crash. The next write replaces it."""
    try:
        with open(state_path(moe), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    said = data.get("said") if isinstance(data, dict) else None
    if not isinstance(said, dict):
        return {}
    out = {}
    for key, when in said.items():
        if (isinstance(key, str) and _KEY.match(key)
                and isinstance(when, (int, float)) and not isinstance(when, bool)):
            out[key] = float(when)
    return out


def write_state(moe, said):
    """Replace the file. Atomic, 0600 in a 0700 directory, exactly as
    deliver.py writes the open-loop ledger: fsync before the rename, the tmp
    removed if any of it fails — a zero-length file here reads as "nothing
    has ever been said", which is the same event announced again."""
    d = state_dir(moe)
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    path = state_path(moe)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"said": said}, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def prune(said, now):
    """Yesterday's answers, gone — and a ceiling, so a hand-edited file
    cannot grow without end."""
    out = {k: v for k, v in said.items() if 0 <= now - v <= STATE_KEEP_SECONDS}
    while len(out) > STATE_MAX:
        del out[min(out, key=lambda k: (out[k], k))]
    return out


# ── the tick ─────────────────────────────────────────────────────────────

class _state_lock(object):
    """flock on `calendar-said.json.lock`, beside the file."""

    def __init__(self, moe):
        self.path = state_path(moe) + ".lock"

    def __enter__(self):
        import fcntl
        self.fh = None
        try:
            self.fh = open(self.path, "a")
            fcntl.flock(self.fh, fcntl.LOCK_EX)
        except OSError:
            self.fh = None          # best effort, like deliver.ledger_lock
        return self

    def __exit__(self, *exc):
        import fcntl
        if self.fh is not None:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_UN)
            finally:
                self.fh.close()


def main():
    moe = moe_home()
    cfg = read_config(moe)
    # The master switch first, before anything of the person's is read.
    if not nudges_on(cfg):
        return 0
    minutes = window_minutes(cfg)
    if not minutes:
        return 0
    if not may_speak(moe):
        return 0
    now = clock()
    lines = read_calendar(moe, now)
    if lines is None:
        return 0

    return _tick(moe, lines, now, minutes)


def _tick(moe, lines, now, minutes):
    said = read_state(moe)
    # De-duplicated on the key, not only against what has been said: the
    # same meeting subscribed on two calendars is two identical lines in
    # the copy, and it is one thing happening.
    due, seen = [], set()
    for event in events(lines, now, minutes):
        if event[1] in said or event[1] in seen:
            continue
        seen.add(event[1])
        due.append(event)
    if not due:
        return 0

    # Written BEFORE anything is printed. Five ticks fit in a ten-minute
    # window, and a heads-up repeated every two minutes is worse than one
    # that never came — so if this cannot be recorded, it is not said.
    try:
        # Under the file's own lock, the one the Mac↔cloud merge takes too
        # (moeledger documents), re-reading what is there now: a merge landing
        # between the read above and this write lost the other side's
        # announcements (review 2026-09-29). Only when something is due, and
        # best effort — a lock that cannot be taken is no reason to crash.
        with _state_lock(moe):
            fresh = prune(dict(read_state(moe), **said), now)
            for _, key, _ in due:
                fresh[key] = now
            write_state(moe, fresh)
    except Exception as e:  # noqa: BLE001 — see above
        print("moe-calendar-heads-up: could not record what was said: %s: %s"
              % (type(e).__name__, e), file=sys.stderr)
        return 0

    for _, _, line in due[:MAX_SAY]:
        print(line)
    if len(due) > MAX_SAY:
        print("And %d more around the same time." % (len(due) - MAX_SAY))
    return 0


if __name__ == "__main__":
    sys.exit(main())

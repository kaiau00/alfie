#!/usr/bin/env python3
"""The learning profile of one source: how Moe reads it, and how often.

Every source Moe can read — a native connector (gmail, calendar…) or a
Hermes connection (mcp/notion, platform/telegram…) — has one profile:

    sync       every ten minutes, copy today's into the context cache
    speak      may Moe SPEAK UP about it on its own — the proactive pass
               (hermes-jobs/moe-brief-monitor.sh drops the brief sections of
               a source whose speak is no) and a watch job
    seed       once, after consent, read back `seed_days` and learn
    update     after the seed, catch up daily / weekly / monthly / never
    dated      can a read be scoped by date (--since N)? if not, an update
               re-reads the recipe and the merge works out what changed
    watch      may a watch recipe run on it (MCP only)
    origin     where the values came from: default | inferred | user
    why        one sentence a person can read

Three answers per source, and they are independent: `sync` is "keep today
ready", the crawl fields are "learn about me from it", and `speak` is "tell
me when something happens here". A person switching learning off for
WhatsApp was, until `speak` existed, told about a WhatsApp message anyway —
the proactive pass read the brief and no per-source answer gated it.

Where the values come from, most authoritative first:

    user      consent.json["<name>"]["modes"] — what the person set with
              `consent.sh mode <source> <key> <value>`; only the keys they set
    inferred  lib/profile_infer.py, for an MCP server nobody has researched:
              a keyword guess over Hermes's schema cache
    default   learn/profiles.json, the researched table, keyed kind/name
    built-in  per kind, the last resort: natives from their manifest
              (cadence, deep_crawl), Hermes connections read nothing until
              someone says so

Stamps — when a source was last seeded and last updated — live beside
consent.json in $MOE_PROFILE_DIR/stamps/<kind>_<name>.json (the directory
0700, each file 0600, written atomically). `due` turns a profile plus its
stamp into the one answer learn.sh needs: "seed", "update <since_days>",
or "no". A stamp from the future (a clock put back) counts as due and is
rewritten, so a wrong clock can cost one run, never every run after it.

`stamp` takes `--today YYYY-MM-DD` and the caller should pass it: the day
the crawl STARTED, not the day the merge finished. A seed that runs past
midnight would otherwise be stamped tomorrow, and the next update would
skip the day the crawl actually read.

    source_profile.py get <source>
    source_profile.py set <source> <key> <value>
    source_profile.py list
    source_profile.py due <source> [--today YYYY-MM-DD]
    source_profile.py stamp <source> seed|update [--today YYYY-MM-DD]

A source is spelled "gmail", "native/gmail", "mcp/notion",
"composio/github", "platform/x", "skill/x" or learn.sh's
"hermes:mcp:notion"; all are normalised to kind/name. The catalog's
"mac/<name>" (hermes-catalog.py's own rows, the same connectors as
native/<name>) is read as native. "composio/<slug>" is one of the brokered
services — a source in its own right since 2026-09-20, because until then
connecting GitHub offered the person nothing to say yes to.

In consent.json a native's modes sit under its bare name, beside its
yes/no; every other kind's sit under "kind/name". An MCP server can share
a name with a native (a gather recipe called calendar.json next to
calendar.manifest), and the two must never read each other's settings. learn/profile.py forwards these verbs here, so the app and the
scripts can keep calling one file.

Python 3.9, stdlib only — runs on the Mac's system interpreter. Everything
`get` needs is a file (the table, the cache, consent.json, a stamp), so
consent_list.py can resolve twenty profiles in one process with no
subprocess; only `set` and `list` ask hermes-connections.py for the names.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta

KINDS = ("native", "mcp", "composio", "platform", "skill", "auth")
#: A brokered service (Composio's GitHub) and a dedicated MCP server for the
#: same service read the same world, so they answer the same questions about
#: how often it changes — see table_entry.
GATHER_KINDS = ("mcp", "composio")
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
UPDATES = ("daily", "weekly", "monthly", "never")
UPDATE_DAYS = {"daily": 1, "weekly": 7, "monthly": 30}
SETTABLE = ("sync", "speak", "seed", "update", "watch", "seed_days")
FIELDS = ("sync", "speak", "seed", "seed_days", "update", "dated", "watch")
MAX_SEED_DAYS = 3650
TRUE_WORDS = ("true", "yes", "on", "1")
FALSE_WORDS = ("false", "no", "off", "0")


# ── where things are ─────────────────────────────────────────────────────

def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def conn_dir():
    return os.environ.get("CONN") or os.path.join(moe_home(), "connectors")


def profile_dir():
    return os.environ.get("MOE_PROFILE_DIR") or os.path.join(moe_home(), "memory", "profile")


def watch_dir():
    return os.environ.get("MOE_WATCH_DIR") or os.path.join(moe_home(), "watch")


def gather_dir():
    return os.environ.get("MOE_GATHER_DIR") or os.path.join(moe_home(), "gather")


def consent_file():
    return os.path.join(profile_dir(), "consent.json")


def stamps_dir():
    return os.path.join(profile_dir(), "stamps")


def table_path():
    """learn/profiles.json: beside this file when run from the checkout,
    under $MOE_HOME/learn once installed — the same lookup consent.sh uses
    for consent_list.py, so a test's scratch home and the real one agree."""
    for p in (os.path.join(moe_home(), "learn", "profiles.json"),
              os.path.join(os.path.dirname(os.path.abspath(__file__)), "profiles.json")):
        if os.path.isfile(p):
            return p
    return None


def today():
    v = os.environ.get("MOE_TODAY")
    if v:
        return parse_day(v)
    return date.today()


def parse_day(s):
    try:
        return datetime.strptime(str(s).strip(), "%Y-%m-%d").date()
    except ValueError:
        raise ValueError("not a date (YYYY-MM-DD): %r" % s)


_memo = {}


def read_json(path):
    """A dict from a JSON file, {} when missing or malformed. Memoised on
    the file's mtime and size: consent_list.py resolves every row in one
    process, and the schema cache alone is most of a megabyte — twenty
    parses of it is the second Settings cannot spare."""
    try:
        st = os.stat(path)
        tag = (st.st_mtime_ns, st.st_size)
    except OSError:
        _memo.pop(path, None)
        return {}
    hit = _memo.get(path)
    if hit and hit[0] == tag:
        return hit[1]
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        v = v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        v = {}
    _memo[path] = (tag, v)
    return v


def private_dir(d):
    """Make d, owner-only. An existing directory is tightened too: stamps/
    was once created 0755 inside the 0700 profile dir, and learn.sh chmods
    the profile dir but not what is under it."""
    os.makedirs(d, 0o700, exist_ok=True)
    try:
        if os.stat(d).st_mode & 0o077:
            os.chmod(d, 0o700)
    except OSError:
        pass


def write_json(path, data):
    """0600 and atomic: consent.json and the stamps say what a person
    agreed to and when Moe last read them; a half-written file would say
    neither."""
    private_dir(os.path.dirname(path))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    _memo.pop(path, None)


# ── naming ───────────────────────────────────────────────────────────────

def normalise(source):
    """'gmail' | 'native/gmail' | 'mcp/x' | 'hermes:mcp:x' → (kind, name),
    or None when the spelling is not one of those. A bare name is native:
    that is the consent.json namespace, and what a person types."""
    s = str(source or "").strip()
    if s.startswith("hermes:"):
        s = s[7:].replace(":", "/", 1)
    if "/" in s:
        kind, _, name = s.partition("/")
        # The catalog's kind for Moe's own connectors with a browser
        # sign-in (mac/drive-docs): the same manifest as native/drive-docs.
        if kind == "mac":
            kind = "native"
    else:
        kind, name = "native", s
    if kind not in KINDS or not NAME_RE.match(name):
        return None
    return kind, name


def key(kind, name):
    return "%s/%s" % (kind, name)


def consent_name(kind, name):
    """The consent.json entry a source's modes live in. A native's is the
    bare name, beside the yes/no consent.sh records under it. Every other
    kind's is kind/name: an MCP server may share a name with a native
    (gather/calendar.json beside calendar.manifest), and modes written
    under the bare name would then switch the native off — sync.sh would
    read sync=no for native/calendar and delete its context file. The
    granted flag stays bare: consent.sh's namespace, one yes per name."""
    return name if kind == "native" else key(kind, name)


# ── the layers ───────────────────────────────────────────────────────────

def manifest_fields(path):
    fields = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "=" not in line or line.lstrip().startswith("#"):
                    continue
                k, _, v = line.partition("=")
                fields[k.strip()] = v.strip()
    except OSError:
        pass
    return fields


def manifest_path(name):
    return os.path.join(conn_dir(), "%s.manifest" % name)


def builtin(kind, name):
    """The last resort. A native reads the way its manifest says: synced if
    it has a cadence, seeded if it is marked deep_crawl. A Hermes connection
    reads nothing until a table entry, a guess, or a person says otherwise —
    an MCP server may be watched, because a watch needs a recipe anyway.

    No `speak` here, and none in the table either unless someone wrote one:
    it follows the rest of the folded row (see resolve), so a layer that
    switches the ten-minute pull off switches speaking off with it rather
    than leaving a source nobody reads that Moe may still bring up."""
    if kind == "native":
        path = manifest_path(name)
        if not os.path.isfile(path):
            # No manifest, no connector: nothing is pulled, nothing is
            # crawled, and the sentence must not promise otherwise.
            return {
                "sync": False, "seed": False, "seed_days": 365, "update": "never",
                "dated": True, "watch": False,
                "why": "no connector for it on this Mac: nothing is read until one is installed",
            }
        f = manifest_fields(path)
        cadence = (f.get("cadence") or "").strip()
        crawl = f.get("deep_crawl") == "yes"
        # A manifest with no cadence line is a synced source: only an
        # explicit 0m switches the ten-minute pull off. (sync.sh reads
        # nothing else from the line — every synced source is pulled on
        # every tick.)
        sync = cadence != "0m"
        if sync and crawl:
            why = "the built-in setting for a Mac source: kept ready every ten minutes and caught up daily"
        elif sync:
            why = "the built-in setting for a Mac source: kept ready every ten minutes; it has no crawl, so there is nothing to catch up on"
        elif crawl:
            why = "the built-in setting for a Mac source: not kept ready (its connector says so), caught up daily"
        else:
            why = "the built-in setting for a Mac source: neither kept ready nor crawled (its connector says so)"
        return {
            "sync": sync,
            "seed": crawl,
            "seed_days": 365,
            # No crawl, nothing to catch up on: a source that cannot be
            # seeded cannot be updated either.
            "update": "daily" if crawl else "never",
            "dated": True,
            "watch": False,
            "why": why,
        }
    return {
        "sync": False,
        "seed": False,
        "seed_days": 365,
        "update": "never",
        "dated": False,
        "watch": kind in GATHER_KINDS,
        "why": "the built-in setting for a connection Moe knows nothing about: read nothing until you say so",
    }


def table_entry(kind, name):
    """The researched defaults for one source, or None. Only the fields
    with a sensible value are taken: a typo in the table degrades to the
    built-in for that one field, never to a crash.

    A `composio/<slug>` source falls back to the `mcp/<slug>` row, and that
    is a deliberate choice rather than an accident of lookup order. The 77
    researched rows answer a question about the SERVICE — how often does
    your GitHub change, is there anything personal in a docs index — and the
    answer does not depend on whether Moe reaches it through a dedicated MCP
    server or through Composio's broker. Duplicating the table under
    `composio/` keys would be 77 rows that have to be kept in step with 77
    others, and the day they drift the two spellings of one service disagree
    about the same person. So the table stays keyed on the service, a
    `composio/<slug>` key is still read FIRST for the case where a brokered
    service genuinely differs, and only the fallback is shared. What is NOT
    shared is the person's own answers: those are keyed by the real kind
    (consent_name), so nothing a person set for one transport is silently
    applied to the other."""
    p = table_path()
    if not p:
        return None
    table = read_json(p)
    e = table.get(key(kind, name))
    if not isinstance(e, dict) and kind == "composio":
        e = table.get(key("mcp", name))
    if not isinstance(e, dict):
        return None
    out = {}
    for k, v in e.items():
        ok, val = coerce(k, v)
        if ok:
            out[k] = val
    if isinstance(e.get("why"), str) and e["why"].strip():
        out["why"] = e["why"].strip()
    return out


class GuessUnavailable(Exception):
    """lib/profile_infer.py could not be loaded or run. Not a reason for
    `get` to fail: learn.sh and sync.sh switch profiles off for the whole
    run at the first `get` that exits non-zero, and a broken guesser must
    not turn every profile off — the built-in answers instead, and the
    sentence says the guess was unavailable."""


def load_infer():
    """lib/profile_infer.py by path: $MOE_HOME/lib once installed, the
    checkout's lib/ beside learn/ otherwise. None when there is no such
    file; GuessUnavailable when there is one and it will not load."""
    for p in (os.path.join(moe_home(), "lib", "profile_infer.py"),
              os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", "profile_infer.py")):
        if os.path.isfile(p):
            try:
                spec = importlib.util.spec_from_file_location("moe_profile_infer", p)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
            except Exception as e:  # a syntax error, an import it cannot make
                # The message first, the file after: this ends up inside a
                # `why` with a 120-character budget, and the real home is
                # "~/Library/Application Support/Moe/lib/profile_infer.py",
                # which spends all of it on a path the reader can guess.
                raise GuessUnavailable("%s (%s)" % (e, os.path.basename(p)))
            return mod
    return None


def inferred(kind, name):
    """A guess for an MCP server with no table entry, from the schema cache.
    None when there is no cache entry — then it is unknown, not guessed.
    Raises GuessUnavailable, and nothing else, when the guesser is broken;
    resolve() turns that into the built-in with an honest `why`.

    MCP only, and a `composio/<slug>` source is deliberately not guessed at:
    the cache is keyed by SERVER, and every brokered service shares the one
    "composio" server, so a guess for GitHub would be made from the session's
    twelve meta tools (measured 2026-09-20) — the same wrong guess for all
    1,378 of them. The researched table answers for the services worth
    answering for; the rest take the built-in, which reads nothing until the
    person says yes."""
    if kind != "mcp":
        return None
    try:
        infer = load_infer()
        if infer is None:
            return None
        entry = read_json(infer.cache_path()).get(name)
        if not isinstance(entry, dict):
            return None
        tools = entry.get("tools")
        tools = tools if isinstance(tools, list) else []
        g = infer.infer(tools)
        out = {k: g[k] for k in ("sync", "seed", "update", "dated", "why") if k in g}
    except GuessUnavailable:
        raise
    except Exception as e:
        raise GuessUnavailable("%s: %s" % (type(e).__name__, e))
    # Whatever the guesser returned, only well-formed fields are taken.
    for k in list(out):
        if k == "why":
            if not isinstance(out[k], str) or not out[k].strip():
                del out[k]
            continue
        ok, val = coerce(k, out[k])
        if ok:
            out[k] = val
        else:
            del out[k]
    return out


def user_modes(kind, name):
    """What the person set, and only that — every key checked again on the
    way in, because consent.json is a hand-editable file."""
    entry = read_json(consent_file()).get(consent_name(kind, name))
    modes = entry.get("modes") if isinstance(entry, dict) else None
    out = {}
    if isinstance(modes, dict):
        for k, v in modes.items():
            if k in SETTABLE:
                ok, val = coerce(k, v)
                if ok:
                    out[k] = val
    return out


def consent_granted(kind, name):
    """True when the person has said yes to reading this source at all.

    The BARE name, not consent_name(): the yes/no flag is consent.sh's
    namespace and it records one answer per name, whatever kind it is
    (only the modes are keyed kind/name, so an MCP cannot switch a native
    off). Reading it under the modes key found nothing and the override
    below silently never fired."""
    entry = read_json(consent_file()).get(name)
    return isinstance(entry, dict) and entry.get("granted") is True


def coerce(k, v):
    """(ok, value) for one profile field from JSON or the command line."""
    if k in ("sync", "speak", "seed", "dated", "watch"):
        if isinstance(v, bool):
            return True, v
        s = str(v).strip().lower()
        if s in TRUE_WORDS:
            return True, True
        if s in FALSE_WORDS:
            return True, False
        return False, None
    if k == "update":
        s = str(v).strip().lower()
        return (True, s) if s in UPDATES else (False, None)
    if k == "seed_days":
        if isinstance(v, bool):
            return False, None
        try:
            n = int(str(v).strip())
        except ValueError:
            return False, None
        return (True, n) if 1 <= n <= MAX_SEED_DAYS else (False, None)
    return False, None


def resolve(source):
    """The profile for one source, all layers folded: user over inferred
    over table over built-in. None when the source is not a source."""
    kn = normalise(source)
    if not kn:
        return None
    kind, name = kn
    prof = builtin(kind, name)
    origin = "default"
    t = table_entry(kind, name)
    if t is not None:
        prof.update(t)
    else:
        try:
            g = inferred(kind, name)
        except GuessUnavailable as e:
            g = None
            prof["why"] += " (Moe could not guess from its tool list: %s)" % short(str(e))
        if g is not None:
            prof.update(g)
            origin = "inferred"
    # `speak` — may Moe bring this source up on its own — after the layers
    # that decide what is read, and before the person's own answer. It is
    # the one field with no default of its own: a source Moe keeps up with
    # (sync) or may watch is one it may mention; a source nobody reads on a
    # clock and nobody watches cannot surprise anyone. Derived here rather
    # than in builtin() so that a table row switching sync off switches
    # speaking off with it, whether or not whoever wrote that row thought
    # about this field — the ones shipped in profiles.json say it outright.
    if "speak" not in prof:
        prof["speak"] = bool(prof["sync"] or prof["watch"])
    u = user_modes(kind, name)
    # A switch that is on and does nothing is worse than a switch that is
    # off. Some services ship "never" — a data platform, a payment
    # processor, a docs index — because reading them on a clock is usually
    # pointless or holds other people's records rather than the person's.
    # That is a default, and a default yields to an answer: when someone
    # has explicitly said yes to a source, the shipped never becomes "read
    # it, at the quietest cadence". What is READ does not change — the
    # auto-read keeps to safe metadata, the same as everywhere else.
    if (not u and prof["seed"] is False and prof["update"] == "never"
            and consent_granted(kind, name)):
        prof["seed"] = True
        prof["update"] = "monthly"
        origin = "user"
        prof["why"] = ("you said yes to this one, so Moe reads it back once and "
                       "then monthly; by default it would read nothing here")
    elif u:
        prof.update(u)
        origin = "user"
        prof["why"] = "you set %s yourself; otherwise %s" % (
            ", ".join("%s=%s" % (k, fmt(prof[k])) for k in SETTABLE if k in u), prof["why"])
    # One switch per source since 2026-09-29 ("Learn and watch", the owner:
    # it covers everything Moe does with a source by itself). A yes means
    # Moe may mention it, whatever a table row or an older per-source
    # "mention" answer said; and a Mac source is kept ready with it. A
    # service's ten-minute gather stays the table's call: for a dedicated
    # server each read is a sign-in (profiles.json `_mcp`).
    if consent_granted(kind, name):
        prof["speak"] = True
        if kind == "native":
            prof["sync"] = True
    out = {"source": key(kind, name)}
    for k in FIELDS:
        out[k] = prof[k]
    out["origin"] = origin
    out["why"] = prof["why"]
    return out


def fmt(v):
    return ("yes" if v else "no") if isinstance(v, bool) else str(v)


def short(msg, n=120):
    msg = " ".join(str(msg).split())
    return msg if len(msg) <= n else msg[:n - 1] + "…"


# ── stamps and due ───────────────────────────────────────────────────────

def stamp_path(kind, name):
    return os.path.join(stamps_dir(), "%s_%s.json" % (kind, name))


def read_stamp(kind, name):
    s = read_json(stamp_path(kind, name))
    out = {}
    for k in ("seeded", "updated"):
        try:
            out[k] = parse_day(s[k]) if s.get(k) else None
        except ValueError:
            out[k] = None
    return out


def write_stamp(kind, name, which, day):
    """seed → seeded and updated both today (a seed reads everything an
    update would have); update → updated only."""
    p = stamp_path(kind, name)
    s = read_json(p)
    if which == "seed":
        s["seeded"] = day.isoformat()
    s["updated"] = day.isoformat()
    write_json(p, s)
    return s


def due(prof, stamp, day):
    """'seed' | 'update N' | 'no'. No seed yet and seed wanted → seed. After
    that, update on its cadence: N is how far back to read — the days since
    the last update plus one for a dated source (yesterday's run and today
    overlap by a day on purpose, so nothing on the boundary is missed), the
    whole window for an undated one, never more than the window."""
    seed_days = prof["seed_days"]
    if prof["seed"] and not stamp.get("seeded"):
        return "seed"
    cadence = prof["update"]
    if cadence == "never":
        return "no"
    step = UPDATE_DAYS[cadence]
    last = stamp.get("updated") or stamp.get("seeded")
    if last is None:
        # Seed off, update on, nothing ever read: one cadence's worth (plus
        # the day of overlap), not the whole window — the person said no
        # to the seed, and an "update" reading a whole year would be one.
        n = min(step + 1, seed_days) if prof["dated"] else seed_days
        return "update %d" % n
    since = (day - last).days
    if 0 <= since < step:
        return "no"
    if since < 0:
        # A stamp from the future: the clock was put back. Due now, one
        # cadence's worth; cmd_due rewrites the stamp so it stays due
        # until a run succeeds, rather than "no" until the calendar
        # catches up with the mistake.
        since = step
    n = min(since + 1, seed_days) if prof["dated"] else seed_days
    return "update %d" % n


def future_stamp(kind, name, stamp, prof, day):
    """A stamp dated after today is rewritten so that `due` is honest from
    now on: seeded becomes today (it did happen, at some point before now),
    updated becomes today minus the cadence — exactly due, and still due
    tomorrow if today's run fails. Returns the rewritten stamp, or None."""
    if not any(v and v > day for v in stamp.values()):
        return None
    step = UPDATE_DAYS.get(prof["update"], 0)
    s = read_json(stamp_path(kind, name))
    if stamp.get("seeded") and stamp["seeded"] > day:
        s["seeded"] = day.isoformat()
    if stamp.get("updated") and stamp["updated"] > day:
        s["updated"] = (day - timedelta(days=step)).isoformat()
    write_json(stamp_path(kind, name), s)
    return s


# ── the sources there are ────────────────────────────────────────────────

def native_names():
    try:
        return sorted(fn[:-9] for fn in os.listdir(conn_dir())
                      if fn.endswith(".manifest") and NAME_RE.match(fn[:-9]))
    except OSError:
        return []


def hermes_names():
    """kind/name for every connection Hermes has, from the same probe the
    Connections pane uses (files only, under an alarm). Empty when the
    provider is missing or slow: a `set` then falls back to the recipes."""
    prov = os.path.join(conn_dir(), "hermes-connections.py")
    if not os.access(prov, os.X_OK):
        return []
    try:
        p = subprocess.run([prov, "names"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = []
    for line in p.stdout.splitlines():
        kn = normalise(line.strip())
        if kn and kn[0] != "native":
            out.append(key(*kn))
    return out


def recipe_names():
    """mcp/<c> for every watch or gather recipe: a recipe for a connection
    Hermes has dropped is still a source whose modes can be read and set."""
    out = set()
    for d in (watch_dir(), gather_dir()):
        try:
            for fn in os.listdir(d):
                if fn.endswith(".json") and NAME_RE.match(fn[:-5]):
                    out.add("mcp/" + fn[:-5])
        except OSError:
            pass
    return out


def all_sources():
    out = ["native/" + n for n in native_names()]
    seen = set(out)
    for s in sorted(set(hermes_names()) | recipe_names()):
        if s not in seen:
            out.append(s)
            seen.add(s)
    return out


def exists(kind, name):
    """Is this a source at all? A native needs its manifest; a Hermes
    connection must be one Hermes lists, or one the person keeps a recipe
    for — the same test consent.sh applies before recording an answer."""
    if kind == "native":
        return os.path.isfile(manifest_path(name))
    k = key(kind, name)
    return k in recipe_names() or k in hermes_names()


# ── the verbs ────────────────────────────────────────────────────────────

def cmd_get(args):
    if len(args) != 1:
        return usage()
    prof = resolve(args[0])
    if prof is None:
        return bad("'%s' is not a source (gmail, native/gmail, mcp/notion, platform/x, skill/x)" % args[0])
    print(json.dumps(prof, ensure_ascii=False))
    return 0


def cmd_set(args):
    if len(args) != 3:
        return usage()
    source, k, v = args
    kn = normalise(source)
    if not kn:
        return bad("'%s' is not a source (gmail, native/gmail, mcp/notion, platform/x, skill/x)" % source)
    if k not in SETTABLE:
        return bad("'%s' is not a setting; one of: %s" % (k, " ".join(SETTABLE)))
    ok, val = coerce(k, v)
    if not ok:
        if k == "update":
            return bad("update takes one of: %s" % " ".join(UPDATES))
        if k == "seed_days":
            return bad("seed_days takes a number of days, 1 to %d" % MAX_SEED_DAYS)
        return bad("%s takes yes or no" % k)
    kind, name = kn
    if not exists(kind, name):
        return bad("'%s' is not a connector or connection Moe knows" % source)
    path = consent_file()
    data = read_json(path)
    entry = data.get(consent_name(kind, name))
    if not isinstance(entry, dict):
        entry = {}
    modes = entry.get("modes")
    if not isinstance(modes, dict):
        modes = {}
    modes[k] = val
    entry["modes"] = modes
    data[consent_name(kind, name)] = entry
    write_json(path, data)
    print("%s: %s = %s" % (key(kind, name), k, fmt(val)))
    return 0


def cmd_list(args):
    if args:
        return usage()
    for s in all_sources():
        prof = resolve(s)
        if prof is not None:
            print(json.dumps(prof, ensure_ascii=False))
    return 0


def split_today(args):
    """Pull `--today YYYY-MM-DD` out of a verb's arguments."""
    rest, day = [], None
    i = 0
    while i < len(args):
        if args[i] == "--today":
            if i + 1 >= len(args):
                raise ValueError("--today needs a date")
            day = parse_day(args[i + 1])
            i += 2
        elif args[i].startswith("--today="):
            day = parse_day(args[i][8:])
            i += 1
        else:
            rest.append(args[i])
            i += 1
    return rest, (day or today())


def cmd_due(args):
    try:
        rest, day = split_today(args)
    except ValueError as e:
        return bad(str(e))
    if len(rest) != 1:
        return usage()
    prof = resolve(rest[0])
    if prof is None:
        return bad("'%s' is not a source" % rest[0])
    kind, name = normalise(rest[0])
    stamp = read_stamp(kind, name)
    fixed = future_stamp(kind, name, stamp, prof, day)
    if fixed is not None:
        print("profile: %s was stamped after today (%s); rewritten as %s" % (
            key(kind, name),
            ", ".join("%s %s" % (k, v.isoformat()) for k, v in sorted(stamp.items()) if v),
            ", ".join("%s %s" % kv for kv in sorted(fixed.items()))), file=sys.stderr)
        stamp = read_stamp(kind, name)
    print(due(prof, stamp, day))
    return 0


def cmd_stamp(args):
    try:
        rest, day = split_today(args)
    except ValueError as e:
        return bad(str(e))
    if len(rest) != 2 or rest[1] not in ("seed", "update"):
        return usage()
    kn = normalise(rest[0])
    if not kn:
        return bad("'%s' is not a source" % rest[0])
    s = write_stamp(kn[0], kn[1], rest[1], day)
    print("%s: %s %s" % (key(*kn), "seeded" if rest[1] == "seed" else "updated", s["updated"]))
    return 0


USAGE = ("usage: source_profile.py get <source> | set <source> <key> <value> | list\n"
         "       | due <source> [--today YYYY-MM-DD] | stamp <source> seed|update [--today YYYY-MM-DD]\n"
         "       (--today: the day the crawl started, so a run past midnight is not stamped tomorrow)")


def usage():
    print(USAGE, file=sys.stderr)
    return 2


def bad(msg):
    print("profile: " + msg, file=sys.stderr)
    return 2


VERBS = {"get": cmd_get, "set": cmd_set, "list": cmd_list, "due": cmd_due, "stamp": cmd_stamp}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in VERBS:
        return usage()
    return VERBS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main())

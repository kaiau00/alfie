#!/usr/bin/env python3
"""The consent list, in one process.

`consent.sh list` used to assemble its rows in shell: a python for each
source's recorded answer, a grep or two per manifest field, a python per
recipe field, a Hermes call per connection label — eighty-odd processes
for eighteen rows, eight seconds with no probe at all. Settings shows
nothing for those eight seconds. This does the same work once, in one
interpreter, and prints the same tab-separated rows:

    name  state  connected  label  what-it-reads  configured  profile

The seventh field is the source's learning profile, the way Settings
shows it: "sync=yes;speak=yes;seed=yes;update=daily;dated=yes;
seeded=2026-09-01;origin=default" (learn/source_profile.py resolves it
from files only — the defaults table, the schema cache, consent.json, the
stamp — so the quick list stays quick). `speak` is the third answer per
source — may Alfie say something about it on its own — and sits beside
`sync` because that is the order the pane asks the questions in. The
first six fields are unchanged (the app parses those positionally); the
app ignores fields it does not know.

  consent_list.py list            full: probe every source's live status
  consent_list.py list --quick    no probe: "connected" from the cache
  consent_list.py describe NAME   the one-sentence description

Full mode runs the probes in parallel (threads; each a subprocess under
its own timeout) and folds the answers into $MOE_HOME/status.json, which
quick mode and the ten-minute sync share. A source with no cached answer
reads as connected: a switch wrongly enabled for a moment is a smaller
wrong than one greyed out for sixteen seconds.

Python 3.9, stdlib only — this runs on the Mac's system interpreter.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

BACKGROUND = "background-learning"
SEEDING = "memory-seeding"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")

DESCRIBE = {
    BACKGROUND: "the sources you have already said yes to, once a day, without asking again",
    SEEDING: "what the crawl has learned about you, saved into Alfie's long-term memory so it carries across chats",
    "imessage": "your iMessage and SMS conversations: who wrote, when, and the full text",
    "whatsapp": "your WhatsApp chats mirrored by the bridge: who wrote, when, and the full text",
    "telegram": "your own Telegram chats: who wrote, when, and the full text",
    "gmail": "your mail (inbox and sent): sender, recipients, subject, and the text of each message",
    "mail": "the mail in the Mail app on this Mac, every account set up there (inbox and sent): "
            "sender, recipients, subject, and the text of each message",
    # The invite's notes are read (owner, 2026-09-25): they are where an
    # invitation's agenda and questions are, and noticing what a meeting
    # needs from the person is the point. Until then this promised the notes
    # were "never read out or stored"; the sentence changed with the reader.
    "calendar": "your calendar events: titles, times, locations, attendees, "
                "and the invite's notes (its agenda, dial-in and any questions)",
    "calls": "your phone call history: numbers, direction, duration — not audio",
    "call-recordings": "the transcripts of calls you recorded on your iPhone",
    "notes": "your Apple Notes: titles and full text of notes changed in the window",
    "reminders": "your Reminders: open tasks and recently completed ones",
    "drive": "the files Google Drive for Desktop has synced to this Mac: names, folders, dates, and the text of readable documents",
    "drive-docs": "the full text of the Google Docs, Sheets and Slides you picked yourself — those documents and nothing else in your Drive",
    "chrome": "your Chrome browsing history and bookmarks: page titles and sites, never the query strings in a URL",
}


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


def status_cache():
    return os.path.join(moe_home(), "status.json")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


# ── the answers ──────────────────────────────────────────────────────────

def consent_states():
    """name -> granted | refused, from consent.json; absent means unset.
    An entry holding only "modes" (consent.sh mode, set before any answer)
    is a setting, not an answer, and reads as unset too."""
    out = {}
    for k, v in read_json(os.path.join(profile_dir(), "consent.json")).items():
        if isinstance(v, dict) and "granted" in v:
            out[k] = "granted" if v.get("granted") is True else "refused"
    return out


# ── the learning profile ─────────────────────────────────────────────────

# The two standing answers are not sources: nothing is synced, seeded or
# updated for them, so their field says so in the same shape.
NO_PROFILE = "sync=no;speak=no;seed=no;update=never;dated=no;seeded=never;origin=default"

_sp = None


def source_profile():
    """learn/source_profile.py, beside this file, loaded by path (learn/
    has plain module names). None when it is missing, so a list from an
    install without it still comes out — with the field empty."""
    global _sp
    if _sp is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "source_profile.py")
        try:
            spec = importlib.util.spec_from_file_location("moe_source_profile", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _sp = mod
        except Exception:
            _sp = False
    return _sp or None


def profile_field(source):
    """The seventh field for one kind/name source."""
    sp = source_profile()
    if sp is None:
        return ""
    try:
        prof = sp.resolve(source)
        if prof is None:
            return ""
        kind, name = sp.normalise(source)
        seeded = sp.read_stamp(kind, name).get("seeded")
    except Exception:
        return ""
    yn = lambda b: "yes" if b else "no"  # noqa: E731
    return "sync=%s;speak=%s;seed=%s;update=%s;dated=%s;seeded=%s;origin=%s" % (
        yn(prof["sync"]), yn(prof.get("speak")), yn(prof["seed"]), prof["update"],
        yn(prof["dated"]), seeded.isoformat() if seeded else "never", prof["origin"])


# ── native connectors ────────────────────────────────────────────────────

def manifest_fields(path):
    """key=value lines; last wins; whitespace around = and ends ignored."""
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


def natives():
    """[(name, fields)] for every Mac source Alfie reads by itself: one it
    reads back (deep_crawl + crawl), keeps ready (pull) or watches (items).
    Since 2026-09-29 every one of them needs its own "Learn and watch" yes,
    so one Alfie only keeps ready (Apple Mail) has a row too — without one it
    could never be switched on (review 2026-09-29 #2)."""
    d = conn_dir()
    out = []
    try:
        names = sorted(fn[:-9] for fn in os.listdir(d) if fn.endswith(".manifest"))
    except OSError:
        return out
    for name in names:
        if not NAME_RE.match(name):
            continue
        f = manifest_fields(os.path.join(d, "%s.manifest" % name))
        verbs = f.get("verbs", "").split()
        reads_back = f.get("deep_crawl") == "yes" and "crawl" in verbs
        if not (reads_back or "pull" in verbs or "items" in verbs):
            continue
        out.append((name, f))
    return out


def connector_script(name):
    for ext in (".sh", ".py"):
        p = os.path.join(conn_dir(), name + ext)
        if os.path.isfile(p):
            return p
    return None


# ── Hermes connections ───────────────────────────────────────────────────

def hermes_provider():
    p = os.path.join(conn_dir(), "hermes-connections.py")
    return p if os.access(p, os.X_OK) else None


def run(argv, timeout):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=timeout)
        return p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def recipe(dirpath, name):
    p = os.path.join(dirpath, "%s.json" % name)
    return read_json(p) if os.path.isfile(p) else None


def recipe_names(dirpath):
    try:
        return [fn[:-5] for fn in os.listdir(dirpath) if fn.endswith(".json") and NAME_RE.match(fn[:-5])]
    except OSError:
        return []


# ── describe ─────────────────────────────────────────────────────────────

def gather_recipe(name, kind="mcp"):
    """A hand-written gather recipe for one connection.

    The file stem is lib/mcp_autoread.stem's: the bare name for an MCP
    server of its own, "composio-<slug>" for a brokered service — so
    Composio's Notion and a dedicated Notion server cannot overwrite each
    other's reads. `describe NAME` on the command line has only the bare
    name, so it falls back to the brokered stem rather than answering about
    a file it did not look for."""
    return (recipe(gather_dir(), "composio-%s" % name) if kind == "composio"
            else recipe(gather_dir(), name) or recipe(gather_dir(), "composio-%s" % name))


def describe(name, kind="mcp"):
    base = _describe(name, kind)
    if kind == "composio":
        # Since 2026-09-29 the daily pass also learns from what a service's
        # messages SAY (learn.sh + lib/feed_crawl.py). Said for every
        # brokered service, conditionally: at the moment a yes is asked for,
        # the engine has not planned its read yet, so "does it have
        # messages" is not known — and a yes given to "metadata only" must
        # never become one to message text (review 2026-09-29 #4).
        base = base.replace(" (metadata only, never rows, messages or writes)", "")
        base += ("; and, where it holds messages, what they say — everything in it, automated "
                 "mail left out — from what Alfie already reads to watch it (never writes)")
    return base


def reads_messages(slug):
    """A Composio service Alfie watches through a read plan (lib/composio_items.py)
    has messages the daily pass learns from."""
    plan = read_json(os.path.join(moe_home(), "gather", "composio-%s.items.json" % slug))
    return isinstance(plan, dict) and bool(plan.get("tool"))


def _describe(name, kind="mcp"):
    if name in DESCRIBE:
        return DESCRIBE[name]
    if name.startswith("watch:"):
        c = name[6:]
        r = recipe(watch_dir(), c) or {}
        return str(r.get("describe") or
                   "the %s connection, on a schedule, to tell you when something there needs you" % c)
    r = gather_recipe(name, kind)
    if r and r.get("describe"):
        return str(r["describe"])
    f = manifest_fields(os.path.join(conn_dir(), "%s.manifest" % name))
    if f.get("label"):
        return f["label"]
    # A bare MCP connection (no native manifest, no recipe): its gather row,
    # which auto-read reads on the daily pass.
    return ("what Alfie learns from your %s connection — the accounts, projects, "
            "definitions and structure it holds, read to understand your world "
            "(metadata only, never rows, messages or writes)" % name)


# ── probes ───────────────────────────────────────────────────────────────

def probe_native(name):
    script = connector_script(name)
    if not script or not os.access(script, os.X_OK):
        return False
    return run([script, "status"], 12).split("\n", 1)[0].startswith("ok:")


def mcp_states():
    """{name: (connected, label, kind)} for every connection Hermes has that
    the learn pass can read back, from `hermes-connections.py list --json`:
    one process, about a second, and the same verdict the Connections screen
    shows — the token files plus the gateway's own word on whether it is
    using them.

    TWO kinds, not one. An `mcp` row is a server of its own. A `composio`
    row is one of the brokered services — GitHub, Slack, Notion — and until
    2026-09-20 this filtered them out, so connecting GitHub asked the owner
    nothing and Settings › Background never offered it a switch. Measured on
    this Mac that day: `hermes-connections.py list --json` returned 20
    `composio` rows, 2 `platform` rows and ZERO `mcp` rows, so the filter was
    keeping out every service there was.

    A composio row is kept only when it is CONNECTED (and never the
    "composio" broker row itself), which is the same line
    hermes-connections.py's GATHERABLE draws: an unconnected brokered service
    has nothing to read back, and a consent question whose yes leads to an
    empty crawl is worse than no question. An mcp row is listed connected or
    not, as it always was — Hermes lists only servers someone configured.

    Not a `status mcp/<name>` per connection, and never a live test: each
    of those was a fresh Hermes process opening its own OAuth session,
    which is how a status check could cost the person their Cloudflare
    sign-in (hermes-connections.py, LIVE_OAUTH). The gateway is the one
    process that talks to these servers; asking it, not them, is what
    makes this both instant and safe to run on every visit to Settings."""
    prov = hermes_provider()
    if not prov:
        return {}
    out = run([prov, "list", "--json"], 30)
    start = out.find("{")
    if start < 0:
        return {}
    try:
        conns = json.loads(out[start:]).get("connections") or []
    except ValueError:
        return {}
    states = {}
    for c in conns:
        if not isinstance(c, dict):
            continue
        kind = c.get("kind")
        name = str(c.get("name") or "")
        ok = c.get("state") == "ok"
        if kind == "composio" and (name == "composio" or not ok):
            continue
        if kind not in ("mcp", "composio") or not NAME_RE.match(name):
            continue
        # One name, one row. A dedicated MCP server wins over a brokered
        # service of the same name: it is the more specific connection, and
        # its `mcp/<name>` profile is the one the researched table is keyed
        # on anyway.
        if name in states and states[name][2] == "mcp":
            continue
        states[name] = (ok, str(c.get("label") or name), kind)
    return states


def merge_cache(results, by, extra=None):
    path = status_cache()
    cache = read_json(path)
    now = time.time()
    for name, connected in results.items():
        cache[name] = {"connected": bool(connected), "at": now, "by": by}
    cache.update(extra or {})
    tmp = path + ".tmp"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f, indent=1, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass


# ── the list ─────────────────────────────────────────────────────────────

def cached_flag(cache, name):
    """The cache's answer for one source; unknown reads as connected."""
    e = cache.get(name)
    return not (isinstance(e, dict) and e.get("connected") is False)


def build(quick):
    nat = natives()
    cache = read_json(status_cache())

    if quick:
        # No probe: natives from the cache the last full list (or the
        # ten-minute sync) left, Hermes connections from the cache too —
        # or, before any full list has run, from one files-only call.
        connected = {name: cached_flag(cache, name) for name, _ in nat}
        labels = cache.get("_mcp_labels") or {}
        # A cache written before composio rows existed carries no kinds at
        # all; "mcp" is what every name in it meant, so that is the default.
        kinds = cache.get("_mcp_kinds") or {}
        mcp = {str(n): (cached_flag(cache, str(n)), str(labels.get(str(n)) or n),
                        str(kinds.get(str(n)) or "mcp"))
               for n in (cache.get("_mcp_names") or []) if NAME_RE.match(str(n))}
        if not mcp:
            mcp = mcp_states()
    else:
        connected, mcp = {}, {}
        with ThreadPoolExecutor(max_workers=16) as pool:
            futs = {name: pool.submit(probe_native, name) for name, _ in nat}
            mcp_fut = pool.submit(mcp_states)
            for name, fut in futs.items():
                try:
                    connected[name] = bool(fut.result())
                except Exception:
                    connected[name] = False
            try:
                mcp = mcp_fut.result()
            except Exception:
                mcp = {}
        # The Mac sources' verdicts are cached only from inside the app
        # (ScriptRunner sets MOE_FROM_APP): a terminal has none of the
        # app's permissions, and its "calendar: no" would otherwise sit in
        # the cache until the next sync, hiding Calendar from Settings.
        # The Hermes verdicts are files and the same from anywhere.
        results = dict(connected) if os.environ.get("MOE_FROM_APP") == "1" else {}
        results.update({n: ok for n, (ok, _, _k) in mcp.items()})
        merge_cache(results, "consent", extra={
            "_mcp_names": sorted(mcp),
            "_mcp_labels": {n: label for n, (_, label, _k) in mcp.items()},
            "_mcp_kinds": {n: kind for n, (_, _l, kind) in mcp.items()},
        })

    for n, (ok, _, _k) in mcp.items():
        connected[n] = ok
    # A recipe for a connection Hermes no longer has is a recipe for
    # nothing: listed, so the answer can still be withdrawn, never connected.
    # `composio-<slug>` is not a connection name: it is the file stem a
    # brokered service's read-set and hand recipe use (lib/mcp_autoread.stem,
    # so composio's Notion cannot overwrite a dedicated Notion server's), and
    # its row comes from the connections list under the bare slug.
    recipes = set(recipe_names(watch_dir())) | set(recipe_names(gather_dir()))
    conns = sorted(set(mcp) | {r for r in recipes if not r.startswith("composio-")})

    # Read last, after the probes, not first: a switch flipped while this
    # list was being built must come out the way the person left it. Read
    # first, a ten-second full list handed Settings the answers from before
    # the flip, and the switch went back on its own.
    states = consent_states()

    yn = lambda b: "yes" if b else "no"  # noqa: E731
    rows = []
    for name, f in nat:
        rows.append((name, states.get(name, "unset"), yn(connected.get(name, True)),
                     f.get("label") or name, describe(name), "yes", profile_field("native/" + name)))
    for name in (BACKGROUND, SEEDING):
        rows.append((name, states.get(name, "unset"), "yes", name, describe(name), "yes", NO_PROFILE))
    for c in conns:
        w = recipe(watch_dir(), c)
        entry = mcp.get(c) or (False, "", "mcp")
        label = (w or {}).get("label") or entry[1] or c
        # The watch row and the gather row are two answers about one
        # connection, and the profile is the connection's: the same field
        # on both. Keyed by the connection's OWN kind — `composio/github`,
        # not `mcp/github` — so a person's answers for one cannot be read as
        # the other's. (The researched defaults are shared; the aliasing is
        # source_profile.table_entry's, and the reason is written there.)
        prof = profile_field("%s/%s" % (entry[2], c))
        rows.append(("watch:%s" % c, states.get("watch:%s" % c, "unset"), yn(connected.get(c, False)),
                     label, describe("watch:%s" % c), yn(w is not None), prof))
        # A gather (learning) row for every Hermes connection the learn pass
        # can read — auto-read discovers what to read, so it is not gated on a
        # recipe; a hand recipe for a connection Hermes no longer lists still
        # shows one.
        g = gather_recipe(c, entry[2])
        if c in mcp or g is not None:
            rows.append((c, states.get(c, "unset"), yn(connected.get(c, False)),
                         (g or {}).get("label") or label, describe(c, entry[2]), "yes", prof))
    return rows


def main(argv):
    if not argv:
        print("usage: consent_list.py list [--quick] | describe NAME", file=sys.stderr)
        return 2
    if argv[0] == "describe":
        print(describe(argv[1] if len(argv) > 1 else ""))
        return 0
    if argv[0] == "list":
        quick = "--quick" in argv[1:]
        for row in build(quick):
            print("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in row))
        return 0
    print("usage: consent_list.py list [--quick] | describe NAME", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

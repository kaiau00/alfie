"""Auto-read: turn any connected Hermes connection into a GATHER source with
no per-connector authoring — an MCP server of its own ("notion") or one of
Composio's ~1,400 brokered toolkits ("composio/github"). A connection is
gatherable just by being connected; nothing about it is named in the shipped
payload.

The problem this solves: MCP gives no reliable read/write signal. Measured
2026-09-02, Pulse, Supabase and Cloudflare set readOnlyHint=False on EVERY
tool and declare no required args — so neither the platform nor the schema
can tell a safe catalog read from run_sql. So the classifier here is
NAME-based and DEFAULT-DENY: a tool is a candidate read only if its verb is
a lister/describer AND no part of its name is a write verb, a content/record
word, or a secret — and a short deny-list of description phrases ("file
contents", "row-level") is a backstop. On Pulse that resolves to exactly
{find_definitions, search_schema} and drops run_sql / fetch_result /
list_values / search_messages / read_document / person_card / my_calendar.

Because a name heuristic can never be proof for a records connection, the
resolved read-set is written to ~/.moe/gather/<conn>.reads.json so a person
can see — and trim — exactly what gather will touch before it runs
unattended. A hand-written ~/.moe/gather/<conn>.json (a "reads" list) wins
over the auto plan, for a connection someone wants to pin by hand.

How a call+args is chosen: a NO_TOOLS model turn (prompts/learn-gather-plan.md)
reads the candidate tools' names+descriptions and proposes the few most
informative calls with sensible args (the descriptions are the only place
arg names live). Its output is validated back against the candidate set, so
the model can never widen past what the classifier allowed. The reads are
then executed by lib/mcp_read — the same deterministic executor watch uses —
so NO LLM turn ever holds a live connection tool. The understand step is a
separate NO_TOOLS turn (learn.sh → distil.py --profile gather).

The window. `crawl --since N` reaches `crawl("<kind>/<name>", since_days=N)` — sync.sh
says 1, learn.sh the profile's seed_days or the days since its stamp — and
a read says where the number goes by putting a placeholder in its args:

  "{since_days}"    replaced by the number of days (an int when it is the
                    whole value, the digits when it sits inside a string)
  "{since_date}"    replaced by the ISO date N-1 days before today (so
                    --since 1 is today), the same two ways

  {"tool": "search", "args": {"query": "updated after {since_date}"}}
  {"tool": "list_pages", "args": {"days": "{since_days}"}}

Only a hand recipe carries a placeholder: the auto plan (and its cached
reads.json) is a catalog read with no window, so it is the same read
whatever --since says — which is why the MCP profiles ship dated=false, and
an update of such a source re-reads the plan and lets distil/merge compare.
The substitution is textual and has NO escape: an arg that must contain
the literal text "{since_days}" or "{since_date}" cannot be expressed, and
is substituted like any other. With no --since a placeholder is left as it
is, so a hand recipe that wants a default window must be called with one.

Runs under Hermes's venv interpreter (mcp_read imports Hermes). Import-safe;
nothing runs at import. Python 3.9+, stdlib only besides Hermes.
"""

import json
import os
import re
import subprocess
import sys
from datetime import date, timedelta

MAX_CHARS_DEFAULT = 6000
SESSION_KEY = "moe-learn"        # scopes Hermes memory away from the conversation
PLAN_CANDIDATE_CAP = 40          # a 1900-tool server would blow the plan prompt
PLAN_READS_CAP = 8
COMPOSIO_TOOLS_TTL_DAYS = 7      # how long a toolkit's tool list is reused


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def gather_dir():
    return os.environ.get("MOE_GATHER_DIR") or os.path.join(moe_home(), "gather")


# ── which connection, and where its tools come from ───────────────────────
# A source is spelled either "<name>" / "mcp/<name>" — an MCP server of its
# own, whose tools Hermes has cached — or "composio/<slug>", one of the
# ~1,400 toolkits reached through the ONE Composio session. The two differ
# in three ways and in nothing else:
#
#   server    every composio toolkit is served by the single "composio"
#             MCP server, and its tools are NOT callable by name there —
#             the router dispatches only what is in the session's current
#             list. They go through the multiplexer instead; see
#             COMPOSIO_MUX and `dispatch`, which carry the measurement.
#   tools     Hermes's schema cache holds the SESSION's tool list, not the
#             toolkit's. Measured on this Mac 2026-09-20: one server,
#             twelve tools, while the connected GitHub alone offers 823. So
#             a composio toolkit's tools come from Composio's own catalog
#             route instead (connectors/composio.py tools <slug>), cached.
#   classifier Composio annotates every tool (readOnlyHint / destructiveHint
#             / updateHint / mcpIgnore) — the reliable read/write signal MCP
#             does not have. See classify_composio.
#
# Files on disk are keyed by a STEM, not the bare name: "composio-notion"
# must not collide with a dedicated "notion" MCP server's read-set.
SOURCE_KINDS = ("mcp", "composio")
NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


def split(source):
    """'github' | 'mcp/github' | 'composio/github' → (kind, name).

    A bare name is an MCP server of its own: that is what every caller
    meant before Composio toolkits became sources, and what learn.sh's
    hermes:mcp:<name> still resolves to."""
    s = str(source or "").strip()
    if s.startswith("hermes:"):
        s = s[7:].replace(":", "/", 1)
    kind, sep, name = s.partition("/")
    if not sep:
        kind, name = "mcp", kind
    if kind not in SOURCE_KINDS or not NAME_RE.match(name or ""):
        raise ValueError("not a gatherable connection: %r" % (source,))
    return kind, name


def server(source):
    """The MCP server the reads are made against."""
    kind, name = split(source)
    return "composio" if kind == "composio" else name


def stem(source):
    """The file-name stem for this source under ~/.moe/gather."""
    kind, name = split(source)
    return name if kind == "mcp" else "%s-%s" % (kind, name)


def recipe_path(source):
    """A hand-pinned reads list (Option B). Wins over the auto plan."""
    return os.path.join(gather_dir(), "%s.json" % stem(source))


def reads_path(source):
    """The auto-resolved read-set — inspectable and trimmable."""
    return os.path.join(gather_dir(), "%s.reads.json" % stem(source))


def tools_cache_path(slug):
    """Composio's catalog answer for one toolkit, kept so the crawl is not
    a live call per run — and never a call per service in a loop."""
    return os.path.join(gather_dir(), "composio-%s.tools.json" % slug)


# ── the classifier ────────────────────────────────────────────────────────
# First token must be a lister/describer; no token may be a write verb, a
# content/record word or a secret. Default-deny: anything unexpected is out.
READ_VERBS = ("get", "list", "search", "find", "describe", "show", "count",
              "inspect", "explain", "catalog", "lookup", "summar")

WRITE_TOKENS = frozenset((
    "create", "delete", "remove", "update", "insert", "put", "post", "patch",
    "apply", "deploy", "define", "request", "run", "exec", "execute", "merge",
    "reset", "rebase", "pause", "restore", "drop", "truncate", "revoke",
    "grant", "rotate", "purge", "move", "upload", "write", "send", "set",
    "add", "cancel", "refund", "charge", "provision", "destroy", "disable",
    "enable", "start", "stop", "restart", "suspend", "import", "export",
    "sync", "trigger", "invoke", "confirm", "generate", "edit", "modify",
    "rename", "copy", "clone", "install", "uninstall", "register",
    "unregister", "approve", "reject", "assign", "unassign", "attach",
    "detach", "publish", "unpublish", "activate", "deactivate", "submit",
    "save", "flush", "clear", "kill", "terminate", "close", "open",
))

CONTENT_TOKENS = frozenset((
    "value", "values", "result", "results", "row", "rows", "record",
    "records", "message", "messages", "mail", "email", "emails", "file",
    "files", "document", "documents", "doc", "docs", "attachment",
    "attachments", "card", "cards", "person", "people", "patient",
    "patients", "contact", "contacts", "calendar", "event", "events", "sql",
    "query", "queries", "log", "logs", "blob", "content", "contents",
    "photo", "photos", "image", "images", "transaction", "transactions",
    "invoice", "invoices", "payment", "payments", "customer", "customers",
    "body", "note", "notes", "comment", "comments", "chat", "chats",
    "conversation", "conversations", "thread", "threads", "member",
    "members", "user", "users", "profile", "profiles", "session",
    "sessions", "address", "addresses", "phone", "ssn", "dob",
))

SECRET_TOKENS = frozenset((
    "key", "keys", "secret", "secrets", "token", "tokens", "password",
    "passwords", "credential", "credentials", "apikey", "apikeys",
))

DENY_TOKENS = WRITE_TOKENS | CONTENT_TOKENS | SECRET_TOKENS

DENY_PHRASES = (
    "file contents", "contents of", "full text", "row-level", "returns rows",
    "the rows", "message body", "the text of", "personal data",
    "personally identifiable", " patient", "medical record", "phi",
)


def _tokens(name):
    return [t for t in re.split(r"[^a-z0-9]+", str(name or "").lower()) if t]


def classify(name, description=""):
    """True when `name` is a safe metadata/catalog read to offer the planner."""
    toks = _tokens(name)
    if not toks:
        return False
    if any(t in DENY_TOKENS for t in toks):
        return False
    if not any(toks[0].startswith(v) for v in READ_VERBS):
        return False
    d = " " + (description or "").lower()
    if any(p in d for p in DENY_PHRASES):
        return False
    return True


# ── the Composio classifier ───────────────────────────────────────────────
# The name heuristic above exists because MCP gives no reliable read/write
# signal (measured 2026-09-02: Pulse, Supabase and Cloudflare set
# readOnlyHint=False on every tool). Composio is the exception and it was
# measured too, on 2026-09-20 against `GET /api/v3/tools?toolkit_slug=…`:
# every tool carries Composio's own annotations, per toolkit —
#
#   github  823 tools: 411 readOnlyHint, 154 destructiveHint, 85 updateHint
#   gmail    23 tools:  11 readOnlyHint,   4 destructiveHint
#
# — so for a Composio toolkit the ANNOTATION is the read/write answer and
# the name heuristic is not. Applying the MCP classifier to Composio names
# instead resolves GitHub to ZERO reads, because every one of its three
# no-argument catalog tools is spelled "…FOR_THE_AUTHENTICATED_USER" and
# "user" is a content word. An offer that leads to a crawl returning
# nothing is worse than no offer, so the rule here is Composio's own:
#
#   readOnlyHint            Composio says the call does not write
#   not destructive/update  belt and braces: a tool tagged both is a write
#   not mcpIgnore           670 of GitHub's 823 are hidden from the router;
#                           a read that cannot be dispatched is not a read
#   no required arguments   a catalog read. This is also why "user" can be
#                           dropped from the content deny-list below: with
#                           no argument to pass there is no id to look up,
#                           so a "…_USER" call is you or your own directory,
#                           never a named person's record.
#
# and then the SAME content/secret deny-list as MCP, because readOnlyHint
# means "does not write", not "is not your mail". That backstop is what
# keeps GMAIL_FETCH_EMAILS, GMAIL_GET_CONTACTS and GMAIL_LIST_THREADS out
# of a gather whose consent sentence promises metadata only — measured, it
# drops 5 of gmail's 7 candidates and 13 of slack's 28.
COMPOSIO_TAG_DENY = frozenset(("destructiveHint", "updateHint", "mcpIgnore"))
COMPOSIO_DENY_TOKENS = (CONTENT_TOKENS - {"user", "users"}) | SECRET_TOKENS


def _unprefixed(name):
    """A Composio tool name without its toolkit prefix: the prefix names the
    service, not what the call returns, and a toolkit called `contacts` or
    `notes` would otherwise deny every tool it has."""
    head, sep, tail = str(name or "").partition("_")
    return tail if sep and tail else str(name or "")


def classify_composio(name, description="", tags=(), required=()):
    """True when this Composio tool is a safe metadata read to offer."""
    tagset = set(tags or ())
    if "readOnlyHint" not in tagset or (tagset & COMPOSIO_TAG_DENY):
        return False
    if required:
        return False
    toks = _tokens(_unprefixed(name))
    if not toks:
        return False
    if any(t in COMPOSIO_DENY_TOKENS for t in toks):
        return False
    d = " " + (description or "").lower()
    if any(p in d for p in DENY_PHRASES):
        return False
    return True


# ── candidate discovery from Hermes's schema cache (offline) ───────────────
def _cache_tools(connector):
    """[(name, description)] for one server, from ~/.hermes/cache. No connect."""
    path = os.path.join(hermes_home(), "cache", "mcp_schema_cache.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    entry = data.get(connector)
    tools = entry.get("tools") if isinstance(entry, dict) else None
    out = []
    for t in tools or []:
        if isinstance(t, dict) and t.get("name"):
            out.append((str(t["name"]), str(t.get("description") or "")))
    return out


# ── candidate discovery for a Composio toolkit (catalog route, cached) ────
def _composio_script():
    return os.path.join(moe_home(), "connectors", "composio.py")


def _fetch_composio_tools(slug):
    """connectors/composio.py tools <slug> --json → the raw rows, or None.

    A pure catalog GET with the project key: it opens no session of its own,
    mints no connection request and touches no OAuth — the three things a
    status probe has cost this Mac a sign-in for."""
    script = _composio_script()
    if not os.path.exists(script):
        return None
    try:
        r = subprocess.run([sys.executable, script, "tools", slug, "--json"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        obj = json.loads(r.stdout or "")
    except ValueError:
        return None
    tools = obj.get("tools") if isinstance(obj, dict) else None
    return tools if isinstance(tools, list) else None


def _composio_tools(slug, refresh=False):
    """[(name, description, tags, required)] for one toolkit.

    Cached for COMPOSIO_TOOLS_TTL_DAYS: the daily pass must not turn into
    a catalog fetch per connected service per run. A fetch that fails falls
    back to whatever is cached, however old — a stale read-set is a read-set;
    no read-set at all is a source that silently learns nothing."""
    path = tools_cache_path(slug)
    cached = None
    try:
        with open(path, encoding="utf-8") as f:
            cached = json.load(f)
    except (OSError, ValueError):
        cached = None
    fresh = False
    if isinstance(cached, dict) and isinstance(cached.get("tools"), list):
        try:
            age = (_today() - date.fromisoformat(str(cached.get("fetched")))).days
            fresh = 0 <= age < COMPOSIO_TOOLS_TTL_DAYS
        except (TypeError, ValueError):
            fresh = False
    if not refresh and fresh:
        rows = cached["tools"]
    else:
        rows = _fetch_composio_tools(slug)
        if rows is None:
            rows = cached.get("tools") if isinstance(cached, dict) else None
            if not isinstance(rows, list):
                return []
        else:
            _save_composio_tools(slug, rows)
    out = []
    for t in rows:
        if not isinstance(t, dict) or not t.get("slug"):
            continue
        out.append((str(t["slug"]), str(t.get("description") or ""),
                    [str(x) for x in (t.get("tags") or []) if isinstance(x, str)],
                    [str(x) for x in (t.get("required") or []) if isinstance(x, str)]))
    return out


def _save_composio_tools(slug, rows):
    os.makedirs(gather_dir(), exist_ok=True)
    try:
        os.chmod(gather_dir(), 0o700)
    except OSError:
        pass
    path = tools_cache_path(slug)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"toolkit": slug, "fetched": _today().isoformat(), "tools": rows}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass


def candidates(source):
    """The classifier's verdict over the connection's tools: safe reads only."""
    kind, name = split(source)
    if kind == "composio":
        return [(n, d) for n, d, tags, req in _composio_tools(name)
                if classify_composio(n, d, tags, req)]
    return [(n, d) for n, d in _cache_tools(name) if classify(n, d)]


def allower(source):
    """The predicate `plan` re-checks the model's choices against — the same
    classifier that produced the candidates, never a looser one."""
    kind, name = split(source)
    if kind != "composio":
        return lambda tool: classify(tool)
    meta = {t[0]: t for t in _composio_tools(name)}
    return lambda tool: tool in meta and classify_composio(*meta[tool])


def _score(name):
    """Lower is more top-level: fewer segments, no id placeholder."""
    toks = _tokens(name)
    s = len(toks)
    if "by" in toks:
        s += 4
    if "id" in toks or "identifier" in toks:
        s += 4
    return s


# ── the plan turn (NO tools) ───────────────────────────────────────────────
def _hermes_client():
    learn = os.path.join(moe_home(), "learn")
    if learn not in sys.path:
        sys.path.insert(0, learn)
    import hermes_client  # noqa: WPS433
    return hermes_client


def _prompt_text(name):
    with open(os.path.join(moe_home(), "prompts", name), encoding="utf-8") as f:
        return f.read()


def plan(connector, cands, chat=None, extract=None, allow=None):
    """Ask a no-tools turn which calls to make. Validated back to `cands`."""
    if not cands:
        return []
    if allow is None:
        try:
            allow = allower(connector)
        except ValueError:
            allow = classify
    hc = None
    if chat is None or extract is None:
        hc = _hermes_client()
    chat = chat or hc.chat
    extract = extract or hc.extract_json
    no_tools = hc.NO_TOOLS if hc else "none"
    ranked = sorted(cands, key=lambda nd: _score(nd[0]))[:PLAN_CANDIDATE_CAP]
    allowed = {n for n, _ in ranked}
    listing = "\n".join("- %s: %s" % (n, (d or "").splitlines()[0][:160])
                        for n, d in ranked)
    system = _prompt_text("learn-gather-plan.md")
    user = ("Service: %s\n\nRead tools available (choose ONLY from these):\n%s"
            % (connector, listing))
    reply = chat(system, user, SESSION_KEY, enabled_toolsets=[no_tools])
    try:
        obj = extract(reply)
    except ValueError:
        return []
    reads, seen = [], set()
    for r in (obj.get("reads") if isinstance(obj, dict) else None) or []:
        if not isinstance(r, dict):
            continue
        tool = str(r.get("tool") or "").strip()
        # the model can never widen past what the classifier allowed
        if tool not in allowed or not allow(tool):
            continue
        if tool in seen:
            continue
        seen.add(tool)
        reads.append({"tool": tool, "args": dict(r.get("args") or {})})
        if len(reads) >= PLAN_READS_CAP:
            break
    return reads


def _load_reads_file(path):
    with open(path, encoding="utf-8") as f:
        obj = json.load(f)
    reads = obj.get("reads") if isinstance(obj, dict) else None
    return reads if isinstance(reads, list) and reads else None


def resolve(connector, refresh=False, chat=None, extract=None):
    """→ (reads, how). A hand recipe wins; else the cached auto plan; else
    plan afresh and cache it. `how` is 'recipe' | 'cached' | 'auto'."""
    split(connector)                       # refuse a spelling early, loudly
    hand = recipe_path(connector)
    if os.path.exists(hand):
        reads = _load_reads_file(hand)
        if reads:
            return reads, "recipe"
    cache = reads_path(connector)
    if os.path.exists(cache) and not refresh:
        reads = _load_reads_file(cache)
        if reads:
            return reads, "cached"
    cands = candidates(connector)
    reads = plan(connector, cands, chat=chat, extract=extract)
    _save_reads(connector, cands, reads)
    return reads, "auto"


def _save_reads(connector, cands, reads):
    os.makedirs(gather_dir(), exist_ok=True)
    try:
        os.chmod(gather_dir(), 0o700)
    except OSError:
        pass
    kind, name = split(connector)
    leaf = stem(connector)
    payload = {
        "connector": name,
        "kind": kind,
        "server": server(connector),
        "generated": os.environ.get("MOE_TODAY") or date.today().isoformat(),
        "source": "auto",
        "_comment": ("Auto-resolved by lib/mcp_autoread from %s's read tools. "
                     "These are the calls gather will make — trim any you do "
                     "not want read, or replace this file with a %s.json to "
                     "pin reads by hand." % (name, leaf)),
        "candidates": [n for n, _ in cands],
        "reads": reads,
    }
    path = reads_path(connector)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# ── executing the reads (deterministic; no model holds the connection) ─────
def _mcp_read():
    lib = os.path.join(moe_home(), "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    import mcp_read  # noqa: WPS433
    return mcp_read


#: Composio's tool router will NOT dispatch a toolkit tool by name unless
#: that tool is in the session's current list — measured 2026-09-20 against
#: this Mac's live session, calling the tool directly:
#:
#:     MCP error -32602: Tool GITHUB_LIST_REPOSITORIES_FOR_… not found
#:
#: and that session lists twelve tools, none of them GitHub's 823. The
#: multiplexer is the route that works: the same session, the same call,
#: and in the same probe it returned the owner's real repositories. It is
#: also the cheaper path — through it the MIME payload is absent entirely
#: (docs/COMPOSIO.md fact 8, "the invocation path changes the answer").
#:
#: This matters more than it looks. Every other piece of this — the offer at
#: connect, the row in Settings, the profile, the candidate set — is
#: perfectly well-formed with a direct call too, and every one of them would
#: have gone on working while the crawl came back empty for ever.
COMPOSIO_MUX = "COMPOSIO_MULTI_EXECUTE_TOOL"


def dispatch(source, read):
    """One read as the server will actually take it.

    An MCP server takes its own tool by name. A Composio toolkit's tool has
    to go through the multiplexer, so the read is wrapped — and labelled,
    so the gathered text still says which tool answered rather than naming
    the multiplexer eight times over."""
    kind, _name = split(source)
    if kind != "composio" or not isinstance(read, dict):
        return read
    tool = str(read.get("tool") or "").strip()
    args = dict(read.get("args") or {})
    return {"tool": COMPOSIO_MUX,
            "label": tool if not args else "%s %s" % (tool, json.dumps(args, sort_keys=True)),
            "args": {"tools": [{"tool_slug": tool, "arguments": args}]}}


# ── the window (see the module docstring) ─────────────────────────────────
PLACEHOLDERS = ("{since_days}", "{since_date}")


def _has_placeholder(value):
    if isinstance(value, str):
        return any(p in value for p in PLACEHOLDERS)
    if isinstance(value, dict):
        return any(_has_placeholder(v) for v in value.values())
    if isinstance(value, list):
        return any(_has_placeholder(v) for v in value)
    return False


def _today():
    t = os.environ.get("MOE_TODAY")
    return date.fromisoformat(t) if t else date.today()


def _fill(value, since_days):
    """Substitute the placeholders through nested args. A string that IS a
    placeholder becomes the typed value (int days; str date); a string that
    contains one keeps its shape with the text spliced in. No escape."""
    if isinstance(value, str):
        if value == "{since_days}":
            return int(since_days)
        since_date = (_today() - timedelta(days=max(int(since_days) - 1, 0))).isoformat()
        if value == "{since_date}":
            return since_date
        return value.replace("{since_days}", str(int(since_days))).replace("{since_date}", since_date)
    if isinstance(value, dict):
        return {k: _fill(v, since_days) for k, v in value.items()}
    if isinstance(value, list):
        return [_fill(v, since_days) for v in value]
    return value


def windowed_reads(reads, since_days=None):
    """The reads with the window filled into each one's args. None leaves
    them untouched; a read with no placeholder is untouched either way."""
    if since_days is None:
        return reads
    if not isinstance(since_days, int) or isinstance(since_days, bool) or since_days < 1:
        raise ValueError("since_days must be a positive number of days, not %r" % (since_days,))
    out = []
    for r in reads:
        if isinstance(r, dict) and _has_placeholder(r.get("args")):
            r = dict(r, args=_fill(r.get("args"), since_days))
        out.append(r)
    return out


def parse_since(argv):
    """`--since N` / `--since=N` out of a crawl's arguments → N or None.
    Raises ValueError on a value that is not a positive number of days."""
    since = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--since":
            if i + 1 >= len(argv):
                raise ValueError("--since needs a number of days")
            val, i = argv[i + 1], i + 2
        elif a.startswith("--since="):
            val, i = a[len("--since="):], i + 1
        else:
            i += 1
            continue
        if not val.isdigit() or int(val) < 1:
            raise ValueError("--since wants a positive number of days, not %r" % val)
        since = int(val)
    return since


def crawl(connector, hermes_pair=None, log=None, since_days=None):
    """Resolve the read-set, window it (only where a read says where the
    window goes), then execute it read by read — each one wrapped the way
    its server will take it (see `dispatch`). A read that fails (a bad arg
    the planner guessed, a tool that needs an id) is skipped, not fatal —
    the others still land."""
    reads, how = resolve(connector)
    reads = windowed_reads(reads, since_days)
    srv = server(connector)
    if log:
        log("gather %s: %d read(s) (%s, via %s)" % (connector, len(reads), how, srv))
    if not reads:
        return ""
    mcp_read = _mcp_read()
    parts = []
    failed = []
    for r in reads:
        try:
            parts.append(mcp_read.read_connector(
                srv, [dispatch(connector, r)], MAX_CHARS_DEFAULT,
                hermes_pair=hermes_pair, task="moe-gather"))
        except Exception as e:  # one read's failure is not the crawl's
            failed.append("%s (%s)" % (r.get("tool"), e))
            if log:
                log("gather %s: skipped %s (%s)" % (connector, r.get("tool"), e))
    if failed and len(failed) == len(reads):
        # Every read failed: that is a crawl that could not read, not one
        # that found nothing. Returning "" here made learn.sh say "nothing
        # to read (exit 0)" for two days of `No module named 'ruamel'`
        # (2026-10-11/12) — a broken reader filed as a quiet source.
        raise RuntimeError("all %d read(s) failed — first: %s" % (len(failed), failed[0]))
    if failed and log:
        log("gather %s: %d of %d read(s) failed" % (connector, len(failed), len(reads)))
    return "".join(parts)


def status(connector):
    """Reuse the connections provider's live check, like the watch reader."""
    provider = os.path.join(moe_home(), "connectors", "hermes-connections.py")
    if not os.path.exists(provider):
        return "unavailable: hermes-connections.py missing"
    kind, name = split(connector)
    try:
        out = subprocess.run([sys.executable, provider, "status", "%s/%s" % (kind, name)],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        return "unavailable: could not check %s (%s)" % (connector, e)
    line = (out.stdout or out.stderr or "").strip().splitlines()
    return line[0] if line else "unavailable: %s did not answer" % connector


def main(connector, argv, hermes_pair=None):
    cmd = argv[0] if argv else ""
    if cmd == "status":
        print(status(connector))
        return 0
    if cmd == "resolve":
        reads, how = resolve(connector, refresh="--refresh" in argv)
        print(json.dumps({"connector": connector, "how": how, "reads": reads}, indent=1))
        return 0
    if cmd == "crawl":
        try:
            since = parse_since(argv[1:])
        except ValueError as e:
            print("mcp-autoread %s: %s" % (connector, e), file=sys.stderr)
            return 2
        try:
            sys.stdout.write(crawl(connector, hermes_pair=hermes_pair, since_days=since,
                                   log=lambda m: print(m, file=sys.stderr)))
        except Exception as e:
            print("mcp-autoread %s: %s" % (connector, e), file=sys.stderr)
            return 1
        return 0
    print("usage: <connector> status | resolve [--refresh] | crawl [--since DAYS]", file=sys.stderr)
    return 2

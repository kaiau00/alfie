#!/usr/bin/env python3
"""Composio's toolkits as Alfie connections, one row per service.

Composio brokers ~500 services behind ONE Hermes MCP server. That is the
right shape for the engine — five meta tools reach the model instead of five
hundred — and the wrong shape for a person, who does not want to connect
"Composio", they want to connect Gmail.

So this splits the one server into one row per service, and the rows are
DISCOVERED, never listed here: what is connected comes from Composio's
connected_accounts, what could be connected comes from its toolkit catalogue.
Hard-coding a set of services is how Alfie ends up showing a fifth of what it
can actually reach, which is the mistake this whole surface exists to undo.

  composio.py list [--json]        one row per service, connected first
  composio.py search <query>       the catalogue, for services not yet added
  composio.py status <slug>        ok: / needs-setup: / unavailable:, exit 0/1/3
  composio.py connect <slug>       prints a URL for the person to open
  composio.py fields <slug>        what to paste for a service Composio holds
                                   no sign-in for: its own field names, as JSON
  composio.py connect <slug> --key the pasted key(s) on stdin, `name=value`
                                   per line; the account is live at once
  composio.py disconnect <slug>    forgets the account at Composio
  composio.py manifest <slug>      KEY=value, the connectors/*.manifest shape
  composio.py tools <slug> [--json] every tool the toolkit has, with Composio's
                                   own annotations — what lib/mcp_autoread
                                   classifies a safe read out of
  composio.py sweep [--all]        remove this Mac's abandoned sign-ins at Composio
                                   (list does it too, a few at a time)
  composio.py sync-session         point the session at every pasted key (list does it too)
  composio.py session-url          the MCP URL of this Mac's session; created on first call
  composio.py session-url --multi-account   …and replaced once if it is an older, preloading one

**No browser is opened here.** This prints a URL and exits; opening it is the
app's job (or the person's). A connector that launches a browser cannot be
run from a cron job, a test, or the cloud tier, and every other connector in
this directory holds to the same line.

**The key never leaves this process.** It is a PROJECT credential — it can
act on every account every user has connected — so it is read from the login
Keychain rather than from .env where every tool on the Mac can see it, it is
never printed, and it is never passed as an argv element where `ps` would
show it. `~/.hermes/.env` holds it too, because Hermes's MCP client needs it
to reach the server at all; that is Hermes's copy, and it is on the terminal
env blocklist so the model cannot read it back.

**Tiering, because it constrains what may be built on this.** On a free Mac
these calls are billed to THE PERSON'S OWN Composio account (100K/month on
their free plan). So anything that runs on a clock — a cron job, a trigger, a
watch, a background pass — is a PAID feature, and interactive use is free.
Decided 2026-09-04; the reasoning and the arithmetic are in HERMES-SURFACES
§3.1. Nothing here enforces it yet, which is the honest state: no gate stops a
free Mac's cron from calling these, and one has to be built.

$HOME / $HERMES_HOME / $COMPOSIO_API_BASE redirect everything, for tests.
"""
import base64
import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import uuid
import urllib.error
import urllib.parse
import urllib.request

#: Where every call goes. Composio itself by default; since 2026-10-19,
#: normally the edge's Composio proxy (`<edge>/v1/composio/proxy`), which
#: configure-hermes.py writes into ~/.hermes/.env as COMPOSIO_API_BASE beside
#: the proxy token it copies in as COMPOSIO_API_KEY. The process environment
#: wins (tests point it at a fake). Resolved once the helpers below exist.
DIRECT_BASE = "https://backend.composio.dev"
BASE = DIRECT_BASE
#: The header that tells the edge a call runs on a clock (a cron job, a
#: background pass), which the free plan does not include. Set by a caller
#: that runs on one, through MOE_COMPOSIO_CLOCK=scheduled.
CLOCK_HEADER = "x-moe-clock"
#: Scoped first, always. Both kinds are `ak_`-prefixed and identical to the
#: eye, and the difference is "acts as one person" versus "can read every
#: connected account's Google refresh token in plaintext". The unscoped one
#: remains only as a fallback for a Mac that has not been given a scoped key
#: yet; `scripts/check-composio-key.sh` says which is in force.
KEYCHAIN_SERVICES = ("moe-composio-scoped", "moe-composio")
KEYCHAIN_ACCOUNT = "api-key"
TIMEOUT = 30

# The one place the session id lives is ~/.hermes/.env, because that is what
# Hermes itself reads to reach the server. Parsing it back out of the URL
# rather than storing it twice means the two can never disagree — a second
# copy is a second thing to be wrong.
SESSION_RE = re.compile(r"/tool_router/(trs_[A-Za-z0-9_-]+)/mcp")


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")


def _env_file():
    """`~/.hermes/.env` as a dict. Values stay in this process."""
    out = {}
    path = os.path.join(hermes_home(), ".env")
    try:
        with open(path, encoding="utf-8-sig") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def _resolve_base():
    explicit = (os.environ.get("COMPOSIO_API_BASE") or "").strip()
    if explicit:
        return explicit.rstrip("/")
    written = (_env_file().get("COMPOSIO_API_BASE") or "").strip().rstrip("/")
    if written.startswith("https://") or written.startswith("http://127.0.0.1:") \
            or written.startswith("http://localhost:"):
        return written
    return DIRECT_BASE


BASE = _resolve_base()


def _clock_headers(req):
    """Mark a scheduled call as one: the edge refuses it on the free plan,
    and an honest Mac says so rather than letting the edge guess."""
    if (os.environ.get("MOE_COMPOSIO_CLOCK") or "").strip().lower() == "scheduled":
        req.add_header(CLOCK_HEADER, "scheduled")


#: The key as this process first read it (api_key). Empty until then.
_KEY = []
#: How long the `security` reads may take between them, at most.
KEYCHAIN_TIMEOUT_S = 10


def api_key():
    """The project key: Keychain first, then .env, then the environment.

    Keychain first on purpose. .env is readable by every tool and subprocess
    on this Mac; the Keychain item is not. .env still holds a copy because
    Hermes's own MCP client resolves ${COMPOSIO_API_KEY} from there, and that
    copy is on Hermes's terminal env blocklist so the model cannot echo it.

    Read ONCE per process, and inside the budget. It used to run both
    `security` reads (10 s each) on every call(), before the budget was
    checked: a keychain that stalled (locked, or an access prompt nobody
    answers) made a 40 s Disconnect take six reads and the app's 60 s kill,
    with nothing said. A read the budget cut short is not remembered — the
    answer was never heard — so a later call outside the budget asks again.
    """
    if _KEY:
        return _KEY[0]
    heard = True
    until = time.monotonic() + KEYCHAIN_TIMEOUT_S
    for service in KEYCHAIN_SERVICES:
        now = time.monotonic()
        wait, by_budget = until - now, False
        if _DEADLINE is not None and _DEADLINE - now < wait:
            wait, by_budget = _DEADLINE - now, True
        if wait <= 0.05:
            heard = heard and not by_budget
            break
        try:
            r = subprocess.run(
                ["/usr/bin/security", "find-generic-password",
                 "-s", service, "-a", KEYCHAIN_ACCOUNT, "-w"],
                capture_output=True, text=True, timeout=wait)
            if r.returncode == 0 and r.stdout.strip():
                _KEY[:] = [r.stdout.strip()]
                return _KEY[0]
        except subprocess.TimeoutExpired:
            heard = heard and not by_budget
            continue
        except Exception:
            continue
    key = (_env_file().get("COMPOSIO_API_KEY")
           or os.environ.get("COMPOSIO_API_KEY") or "").strip()
    if heard:
        _KEY[:] = [key]
    return key


def session_id():
    url = _env_file().get("COMPOSIO_MCP_URL") or os.environ.get("COMPOSIO_MCP_URL") or ""
    m = SESSION_RE.search(url)
    return m.group(1) if m else ""


def _fold(value):
    """Enough of an identifier to tell two apart, never enough to reuse.

    A Composio `user_id` is a CAPABILITY, not a name. moe-47 measured it: a
    scoped project key cannot ENUMERATE users, but it can act as any user_id
    it is given — so the boundary is unguessability, and anything that writes
    one into a log, an error, a support transcript or a prompt the model can
    see converts it into access to that person's Google.

    Both of my error messages quoted identifiers in full, one of them two at
    once. This is why they no longer do.
    """
    text = str(value or "")
    if len(text) <= 8:
        return "…"
    return text[:4] + "…" + text[-2:]


class NoIdentity(RuntimeError):
    """Raised when who this Mac acts as cannot be established. Never guessed."""


#: Where the Composio identity lives. Its OWN file, deliberately: not the
#: ledger's device id (per-runtime, so a person's two machines would become
#: two Composio users and stop sharing connections made once), and not the
#: ledger's credential (a free Mac has none — see below).
IDENTITY_FILE = "composio-identity.json"


def identity_path():
    home = os.environ.get("MOE_HOME") or os.path.join(os.path.expanduser("~"), ".moe")
    return os.path.join(home, IDENTITY_FILE)


def enrolled_tenant():
    """The tenant this Mac is enrolled in, or "" when it is not enrolled.

    Not an error to be missing. `CLOUD-PLAN` §15: the ledger is not a cloud
    feature — a free Mac keeps its own chain from first launch and CloudSync
    is simply off.

    **Do not read this as "paid".** It used to be true that most Macs have no
    tenant and never will; the owner decided on 2026-09-04 that a free Mac
    enrols at its first connection, so the edge can mint it its own Composio
    project (`HERMES-SURFACES.md` §3.3). A tenant is now an identity, not a
    tier, and the clock rule in §3.1 — background Composio work is paid —
    needs a signal this function does not carry. `credential.json` has a
    `"sync"` field that separates an Away enrolment from a connections-only
    one, and `Alfie --cloud-json` reads it; that is a stopgap, and the real
    answer is a tier on the tenant record.

    This function is still right for what it is used for here: pinning the
    Composio identity to the tenant it was minted under, so a Mac cannot act
    as another tenant's Composio user.
    """
    home = os.environ.get("MOE_HOME") or os.path.join(os.path.expanduser("~"), ".moe")
    try:
        with open(os.path.join(home, "cloud", "credential.json"), encoding="utf-8") as fh:
            t = (json.load(fh) or {}).get("tenant")
    except (OSError, ValueError):
        return ""
    return t.strip() if isinstance(t, str) else ""


def _local_identity(create=False):
    """The stable id this Mac uses at Composio. Minted once, never re-derived.

    **Why not the tenant.** My first version read the tenant and raised when
    absent. moe-47 caught that it breaks every FREE user: no enrolment means
    no credential, so Composio would stop working for people it works for
    today — an outage, not a deferral, and it left the free tier with no
    identifier at all while sharing one Composio project with everyone else.

    **Why it is never switched to the tenant later.** Re-deriving at enrolment
    would strand every connection made while free under an id nobody uses any
    more. That is the same class of split as §15.1's two-Macs memory-key
    defect, which is unfixed and expensive precisely because it was noticed
    late.

    The tenant is still used — to VALIDATE. Once enrolled, the recorded
    tenant must match the one this Mac is now in. A mismatch means the file
    belongs to another account — travelled between people, or (the case that
    actually happened, owner's Mac, 2026-09-11) left behind by an account
    that was deleted and replaced by a new sign-in. The old id is NEVER used:
    it could name another person's Composio user. It used to be refused
    outright, which left the new account with no session and every connect
    failing with "no Composio session configured". Now a connect mints a
    fresh id for this account; a random id names nobody, so nothing of
    anyone else's is reachable, and nothing made under the old one is lost
    to this account, which never had it.

    Created only when `create` is true, which is the first connect. Reading
    never mints: a read that silently creates identity makes "who is this"
    depend on who asked first.
    """
    path = identity_path()
    tenant = enrolled_tenant()
    try:
        with open(path, encoding="utf-8") as fh:
            blob = json.load(fh) or {}
    except (OSError, ValueError):
        blob = {}

    who = blob.get("user_id")
    if isinstance(who, str) and who.strip():
        seen = blob.get("tenant") or ""
        if tenant and seen and tenant != seen:
            if not create:
                raise NoIdentity(
                    "This Mac's Composio identity belongs to another account "
                    "(%s, not %s); it is never used, and a new one is made on "
                    "the next connect." % (_fold(seen), _fold(tenant))
                )
            print("composio: the identity on this Mac belonged to another account "
                  "(%s); making a new one for this account (%s) and never using the old"
                  % (_fold(seen), _fold(tenant)), file=sys.stderr)
            who = None
        # First enrolment after minting: record the tenant, keep the id.
        if who is not None:
            if tenant and not seen:
                blob["tenant"] = tenant
                _write_identity(path, blob)
            return who.strip()

    if not create:
        raise NoIdentity(
            "This Mac has no Composio identity yet. It is minted on the first "
            "connect; nothing else may invent one."
        )

    who = "moe-" + uuid.uuid4().hex[:20]
    blob = {
        "README": "Who this Mac is at Composio. Minted once on the first "
                  "connect and never re-derived — changing it strands every "
                  "connection made under the old value.",
        "user_id": who,
        "tenant": tenant,
        "minted_at": time.time(),
    }
    _write_identity(path, blob)
    return who


def local_identity(create=False):
    """See _local_identity. Minting happens under a lock beside the file, so
    two first connects at once make ONE identity — not two, the second
    overwriting the first and stranding whatever was made under it."""
    if create:
        with _file_lock(identity_path() + ".lock"):
            return _local_identity(create)
    return _local_identity(create)


def _atomic_write_json(path, blob, indent=1):
    """`blob` as JSON at `path`, mode 0600, so that no reader ever sees half a
    file and no two writers ever share a temporary one.

    Every writer here used to write `path + ".tmp"` and rename it. Two
    processes writing at once — the Connections screen runs the catalogue
    and the connections scripts together, and each runs `composio.py list` —
    opened the SAME temporary file: one renamed it away from under the other
    (FileNotFoundError, thousands of times in a review's run, which crashed
    `list` and made the screen say Composio could not be reached), and a
    reader caught a file the other writer was still filling. A temporary
    file of its own per write, in the same directory so the rename stays
    atomic, ends both."""
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(blob, fh, indent=indent)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


#: Locks this process holds: {path: [fd, depth]}. An flock belongs to an open
#: file, so a second open of the same lock file in this process would wait on
#: itself; taking a lock already held here is counted instead.
_HELD_LOCKS = {}


@contextlib.contextmanager
def _file_lock(path, wait=None):
    """An exclusive flock on `path` (made 0600) for the `with` block; yields
    whether it is held. `wait` None blocks; a number is how many seconds to
    keep trying (0: once) before yielding False — the caller decides what
    not holding it means. A process that dies lets go of it."""
    if path in _HELD_LOCKS:
        _HELD_LOCKS[path][1] += 1
        try:
            yield True
        finally:
            _HELD_LOCKS[path][1] -= 1
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    got = False
    try:
        try:
            os.fchmod(fd, 0o600)
        except OSError:
            pass
        if wait is None:
            fcntl.flock(fd, fcntl.LOCK_EX)
            got = True
        else:
            give_up = time.monotonic() + wait
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    got = True
                    break
                except OSError:
                    if time.monotonic() >= give_up:
                        break
                    time.sleep(0.05)
        if got:
            _HELD_LOCKS[path] = [fd, 0]
        yield got
    finally:
        if got:
            _HELD_LOCKS.pop(path, None)
        os.close(fd)


def _write_identity(path, blob):
    _atomic_write_json(path, blob)


_session_user = None


def user_id(create=False):
    """Who this session acts as at Composio.

    The session's own `config.user_id` is authoritative about what the session
    IS — but, as moe-47 points out, not that it is the RIGHT session for this
    person: a wrong sid would be confirmed confidently. So the local identity
    is the source of truth and the session is checked against it.
    """
    global _session_user
    if _session_user:
        return _session_user
    sid = session_id()
    try:
        mine = local_identity(create=create)
    except NoIdentity:
        # A session that predates this file: adopt the id it already uses
        # rather than minting a new one and declaring the live connections
        # someone else's. This is the migration path for every Mac that
        # connected Composio before the identity file existed — including the
        # one this was written on, whose session says "moe-owner".
        mine = ""
        if sid:
            status, body = call("GET", "/api/v3.1/tool_router/session/" + sid)
            if status == 200 and isinstance(body, dict):
                mine = ((body.get("config") or {}).get("user_id") or "").strip()
        if not mine:
            raise
        _write_identity(identity_path(), {
            "README": "Adopted from the session that was already configured "
                      "here. Minted once and never re-derived.",
            "user_id": mine,
            "tenant": enrolled_tenant(),
            "adopted_at": time.time(),
        })
        _session_user = mine
        return mine
    if sid:
        status, body = call("GET", "/api/v3.1/tool_router/session/" + sid)
        if status == 200 and isinstance(body, dict):
            theirs = ((body.get("config") or {}).get("user_id") or "").strip()
            if theirs and theirs != mine:
                raise NoIdentity(
                    "The configured Composio session acts as a different user "
                    "(%s) than this Mac (%s). Refusing to use a session "
                    "belonging to someone else."
                    % (_fold(theirs), _fold(mine))
                )
    _session_user = mine
    return mine


#: When set (time.monotonic()), every call() must be answered by then: the
#: cleanup sweep inside `list` shares one budget between all its requests,
#: and so does a Disconnect.
_DEADLINE = None
#: Requests this process has actually sent (not ones call() declined because
#: the budget was already spent). The sweep reads it to tell a toolkit it
#: tried from one it never reached.
_SENT = [0]


@contextlib.contextmanager
def _budget(seconds):
    """Every call() inside the block shares `seconds` (or less, when an outer
    budget ends sooner); the outer budget is back when the block ends."""
    global _DEADLINE
    outer = _DEADLINE
    mine = time.monotonic() + seconds
    _DEADLINE = mine if outer is None else min(outer, mine)
    try:
        yield _DEADLINE
    finally:
        _DEADLINE = outer


#: What call() says when the budget ran out before Composio finished
#: answering — or before the request could be sent at all.
OUT_OF_TIME = "couldn't reach Composio in time"
#: A request with no budget around it still ends, this long after it began.
REQUEST_CAP_S = 90


def _read_by(resp, deadline):
    """The body of `resp`, read in pieces against `deadline`. urllib's
    timeout bounds one socket read, not the answer: a server sending a byte a
    second never trips it (a 3 s budget took 72.8 s)."""
    read = getattr(resp, "read1", None) or resp.read
    chunks = []
    while True:
        if time.monotonic() >= deadline:
            raise TimeoutError(OUT_OF_TIME)
        piece = read(65536)
        if not piece:
            return b"".join(chunks)
        chunks.append(piece)


def _bounded(req, data, deadline):
    """(status, raw text) for `req`, or (0, {"error": …}) — and it returns by
    `deadline` whatever the network does. The request runs on a daemon
    thread the caller stops waiting for at the deadline, so nothing in it can
    hold the caller past it: the name lookup (getaddrinfo takes no timeout),
    the connect, headers sent a byte at a time, or a slow body. The thread
    itself stops at its next read once the deadline passes (_read_by, and a
    socket timeout no longer than what is left); a process that exits sooner
    takes it with it."""
    box = {}

    def run():
        try:
            left = max(0.05, deadline - time.monotonic())
            try:
                with urllib.request.urlopen(req, data, timeout=min(TIMEOUT, left)) as r:
                    box["answer"] = (r.status, _read_by(r, deadline).decode("utf-8", "replace"))
            except urllib.error.HTTPError as e:
                box["answer"] = (e.code, _read_by(e, deadline).decode("utf-8", "replace"))
        except BaseException as e:  # noqa: B902 — anything, reported as no answer
            box["answer"] = (0, {"error": "%s: %s" % (type(e).__name__, e)})

    worker = threading.Thread(target=run, name="composio-request", daemon=True)
    worker.start()
    worker.join(max(0.0, deadline - time.monotonic()))
    answer = box.get("answer")
    if answer is None or (answer[0] == 0 and time.monotonic() >= deadline - 0.1):
        return 0, {"error": OUT_OF_TIME}
    return answer


def call(method, path, body=None):
    """One API call. Returns (status, parsed-or-text). Never raises for HTTP.
    Status 0 means no answer at all: no key, no network, a timeout, or a
    budget already spent — never a refusal from Composio.

    The budget is checked before anything else, the key included (api_key
    can wait on the Keychain), and the whole request — lookup, connect,
    answer — ends by the budget's deadline (_bounded), or REQUEST_CAP_S after
    it began when there is no budget."""
    if _DEADLINE is not None and _DEADLINE - time.monotonic() <= 0.05:
        return 0, {"error": OUT_OF_TIME}
    key = api_key()
    if not key:
        return 0, {"error": "no Composio key"}
    deadline = time.monotonic() + REQUEST_CAP_S
    if _DEADLINE is not None:
        deadline = min(deadline, _DEADLINE)
        if deadline - time.monotonic() <= 0.05:
            return 0, {"error": OUT_OF_TIME}
    _SENT[0] += 1
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("x-api-key", key)
    _clock_headers(req)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    status, raw = _bounded(req, data, deadline)
    if status == 0:
        return status, raw
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, raw


#: The meta tool that STARTS a sign-in. On a multi-account session it makes
#: a new connection record every time it is called, connected or not.
MINTING_TOOL = "COMPOSIO_MANAGE_CONNECTIONS"


def mcp(name, arguments, mint=False):
    """Call one of the session's meta tools.

    `mint`: MINTING_TOOL is refused unless the caller says, in so many words,
    that it means to start a sign-in. Only cmd_connect does — a person
    pressed Connect. On 2026-09-30 a read path ("what is this account
    called?") had been calling it on every refresh for a week and made 1,815
    records; a rule in a comment ("only ever call this for connected
    slugs") did not stop it, because the rule was wrong about multi-account
    sessions and nothing enforced it. This does, for every caller in this
    file and any added later.

    The same path the model takes, on purpose: a connector that reaches the
    service by a different route than the model can succeed while the model
    still fails, and then the Connections screen says connected about
    something that does not work.
    """
    if name == MINTING_TOOL and not mint:
        return {"error": "refused: %s starts a sign-in, and only Connect may start one"
                         % MINTING_TOOL}
    sid = session_id()
    if not sid:
        return {"error": "no Composio session configured"}
    key = api_key()
    if not key:
        return {"error": "no Composio key"}
    payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": name, "arguments": arguments}}
    req = urllib.request.Request(
        "%s/tool_router/%s/mcp" % (BASE, sid), method="POST",
        data=json.dumps(payload).encode())
    req.add_header("x-api-key", key)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    _clock_headers(req)
    deadline = time.monotonic() + REQUEST_CAP_S
    if _DEADLINE is not None:
        deadline = min(deadline, _DEADLINE)
    status, raw = _bounded(req, None, deadline)
    if status == 0:
        return raw
    # The transport is SSE: one or more `data: {...}` lines.
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            line = line[5:].strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        result = obj.get("result") or {}
        content = (result.get("content") or [{}])[0].get("text", "")
        try:
            return json.loads(content)
        except ValueError:
            return {"text": content}
    return {"error": "no result from the Composio session"}


#: Where a provider will tell you who its token belongs to. The account
#: record at Composio does NOT know — every field is absent and `id_token` is
#: an empty string — so the answer has to come from the provider itself, and
#: `proxy_execute` is how: Composio signs the request with the connected
#: account and never hands over the token.
#:
#: Keyed by prefix rather than by exact slug so a Google service added later
#: is covered without editing this. A toolkit with no entry is simply not
#: identified — better than calling an endpoint that was guessed at.
IDENTITY_ENDPOINTS = {
    # Tried in order. The FIRST one is the generic OIDC endpoint, which works
    # whenever the sign-in included the `userinfo.email` scope — Gmail's and
    # Drive's do. Google Calendar's does not, and it answers 401
    # UNAUTHENTICATED, which is why every service also names an endpoint on
    # its OWN api: a token that can read your calendar can always ask whose
    # calendar it is.
    #
    # Measured per service rather than assumed. A wrong endpoint here fails
    # loudly (no name) rather than quietly (the wrong name), which is the
    # right way round.
    "google": [
        ("https://www.googleapis.com/oauth2/v2/userinfo", ("email", "name")),
    ],
    "gmail": [
        ("https://www.googleapis.com/oauth2/v2/userinfo", ("email",)),
        ("https://gmail.googleapis.com/gmail/v1/users/me/profile", ("emailAddress",)),
    ],
    "googlecalendar": [
        ("https://www.googleapis.com/oauth2/v2/userinfo", ("email",)),
        # calendarList/primary's `id` IS the address of the primary calendar,
        # which for a personal account is the account.
        ("https://www.googleapis.com/calendar/v3/users/me/calendarList/primary", ("id",)),
    ],
    "googledrive": [
        ("https://www.googleapis.com/oauth2/v2/userinfo", ("email",)),
        ("https://www.googleapis.com/drive/v3/about?fields=user",
         ("user.emailAddress",)),
    ],
}


def _identity_candidates(slug):
    """Endpoints to try for this toolkit, most general first."""
    if slug in IDENTITY_ENDPOINTS:
        return IDENTITY_ENDPOINTS[slug]
    for prefix, candidates in IDENTITY_ENDPOINTS.items():
        if slug.startswith(prefix):
            return candidates
    return []


def _dig(data, path):
    """`user.emailAddress` out of a nested answer, or "" if it is not there."""
    node = data
    for key in path.split("."):
        if not isinstance(node, dict):
            return ""
        node = node.get(key)
    return node.strip() if isinstance(node, str) and node.strip() else ""


def account_identity(slug):
    """Ask the service whose account this is. Returns "" when it cannot say.

    Nothing here ever sees a token: `proxy_execute` signs the request with the
    connected account on Composio's side.

    **The proxy answers 200 even when the provider refused.** The provider's
    own status is inside `data`, so a caller that reads only the HTTP code
    treats "401 UNAUTHENTICATED" as a successful answer with no email in it —
    indistinguishable from a service that simply does not report one, and the
    reason the calendar looked unnameable rather than under-scoped.

    Caveat with several accounts: the proxy resolves THE user's connected
    account for a toolkit, so with two signed in it answers for one of them.
    That is why this is called at connect time, when the account just added is
    the one being asked about.
    """
    sid = session_id()
    if not sid:
        return ""
    for endpoint, fields in _identity_candidates(slug):
        status, body = call(
            "POST", "/api/v3.1/tool_router/session/%s/proxy_execute" % sid,
            {"toolkit_slug": slug, "endpoint": endpoint, "method": "GET"})
        if status != 200 or not isinstance(body, dict):
            continue
        inner = body.get("status")
        if isinstance(inner, int) and inner >= 400:
            continue                      # the provider refused; try the next
        data = body.get("data")
        if not isinstance(data, dict) or "error" in data:
            continue
        for f in fields:
            found = _dig(data, f)
            if found:
                return found
    return ""


def name_account_from_service(slug, account_id):
    """Give a just-connected account the name the service knows it by.

    Stored as Composio's `alias`, so the name lives with the account and a
    second device sees it too. Never overwrites a name a person chose.
    """
    who = account_identity(slug)
    if not who:
        return ""
    status, _ = call("PATCH", "/api/v3/connected_accounts/" + urllib.parse.quote(str(account_id), safe=""),
                     {"alias": who})
    return who if status == 200 else ""


#: The tools the model sees BY NAME, beside the four meta ones. Everything
#: else stays behind COMPOSIO_SEARCH_TOOLS and runs through
#: COMPOSIO_MULTI_EXECUTE_TOOL.
#:
#: Why this exists: with only the meta tools, the model had to think to search
#: — and next to a local connector it could see directly, it did not. Asked to
#: find a document on Drive it reported that Drive was not connected, because
#: the tool it could SEE (the local docs connector) held one file. Discovery
#: that depends on the model choosing to discover is not discovery.
#:
#: Until 2026-09-24 these were Composio's own `preload`. Composio refuses
#: preload on a session that holds more than one account of a service, and on
#: that day the owner had two Gmail accounts connected and a mail to send from
#: one of them, which nothing could choose (ticket #12). So the session is now
#: multi-account, and HERMES offers these by name: `configure-hermes.py`
#: writes them as `mcp_servers.composio.composio_tools`, the fork's
#: tools/mcp_composio_proxy.py fetches their schemas, adds an `account`
#: parameter, and sends each call through the multiplexer. The names the
#: model and every hook see are the ones the preload produced.
#:
#: The eight reads were the preload; the six writes joined when the route
#: could carry an account, because "send it from my work address" is the
#: question the ticket asked. Every slug here was DISCOVERED — confirmed by
#: COMPOSIO_GET_TOOL_SCHEMAS against the live API on 2026-09-24 — never typed
#: from memory: a plausible wrong one would be offered with no schema.
#: configure-hermes.py's COMPOSIO_NAMED_TOOLS is this list; a test pins them.
NAMED_TOOLS = [
    "GMAIL_FETCH_EMAILS",
    "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    "GOOGLEDRIVE_FIND_FILE",
    "GOOGLEDRIVE_DOWNLOAD_FILE",
    "GOOGLECALENDAR_EVENTS_LIST_ALL_CALENDARS",
    "GOOGLEDOCS_GET_DOCUMENT_BY_ID",
    "GOOGLESHEETS_SEARCH_SPREADSHEETS",
    "GOOGLESHEETS_BATCH_GET",
    "GMAIL_GET_PROFILE",
    "GMAIL_SEND_EMAIL",
    "GMAIL_CREATE_EMAIL_DRAFT",
    "GMAIL_REPLY_TO_THREAD",
    "GOOGLECALENDAR_FIND_EVENT",
    "GOOGLECALENDAR_CREATE_EVENT",
]


def cmd_preload(argv):
    """Retired: the session is multi-account, and Composio refuses a preload
    there. Prints the tools Hermes offers by name instead, and changes nothing."""
    print("the session is multi-account; Composio refuses preload on it. Hermes offers "
          "these by name (mcp_servers.composio.composio_tools):")
    for t in NAMED_TOOLS:
        print("  " + t)
    return 0


def session_is_multi_account(sid):
    """True / False from the session's own config; None when it cannot be read."""
    status, body = call("GET", "/api/v3.1/tool_router/session/" + sid)
    if status == 404:
        return False  # gone: a new one is the only working answer
    if status != 200 or not isinstance(body, dict):
        return None
    cfg = body.get("config") if isinstance(body.get("config"), dict) else {}
    multi = cfg.get("multi_account") if isinstance(cfg.get("multi_account"), dict) else {}
    return multi.get("enable") is True


# ── the rows ─────────────────────────────────────────────────────────────

#: Composio account states, and what each means to a person. Anything not
#: listed is treated as "in progress" rather than guessed at.
LIVE = "ACTIVE"
DEAD = ("EXPIRED", "FAILED", "REVOKED", "DELETED", "INACTIVE", "DISABLED")
#: What connected_accounts asks for in full. EXPIRED is read one page deep.
NOT_EXPIRED = ("ACTIVE", "INITIALIZING", "INITIATED", "FAILED", "INACTIVE")
#: A sign-in link lives ten minutes (Composio's own instruction text). A
#: record still pending after this is a link nobody finished.
STALE_PENDING_S = 15 * 60


class AccountsUnreadable(RuntimeError):
    """Composio's account list could not be read — which is not "no accounts".
    `status` is the HTTP status Composio answered with (0: no answer)."""

    def __init__(self, why, status=0):
        super().__init__(why)
        self.status = status


def connected_accounts(strict=False):
    """{slug: [account, ...]} — EVERY account, because people have several.

    `strict`: raise AccountsUnreadable when the list cannot be read, rather
    than answer {}. A caller that acts on "none" (Disconnect) must: {} made
    Disconnect say "not connected" about a service that still was, whenever
    the network was down or a legacy scoped key was answered 403.

    The first version collapsed this to one account per service, which was
    wrong twice over. It hid second accounts (most people have a personal and
    a work Google), and it made a dead account indistinguishable from none:
    a service whose sign-in had EXPIRED reported "not connected", so the row
    said "sign in once" to someone who had signed in and needed to do it
    again for a different reason.

    Accounts are returned newest-usable first: live ones, then the rest.
    """
    out = {}
    # Asked for THIS Mac's user, not the project. The list is project-wide
    # unless filtered, 100 a page, and the non-strict read took page one: on
    # 2026-09-24 the owner's second Gmail (connected 09-20) was past it, so
    # Moe knew one of his two accounts and read mail from only that one
    # (ticket #13). `user_ids` is Composio's own filter; the client-side
    # check below stays, because a filter is a request, not a guarantee.
    try:
        mine_q = "&user_ids=" + urllib.parse.quote(user_id(), safe="")
    except NoIdentity:
        mine_q = ""
    # Every state but EXPIRED, all of it; EXPIRED only as far as one page.
    # Each sign-in link that is opened and not finished leaves an EXPIRED
    # record forever, and on 2026-09-30 one person had 1,795 of them: the
    # read gave up at LIST_MAX_PAGES and reported every service "not
    # connected" while eight were live. A recent expiry is still worth
    # showing ("the sign-in ran out"), an old abandoned one is not.
    route = ("/api/v3/connected_accounts?limit=50&statuses=" + ",".join(NOT_EXPIRED)
             + mine_q)
    expired_q = "/api/v3/connected_accounts?limit=50&statuses=EXPIRED" + mine_q
    if strict:
        # Every page: a read that does not finish is "couldn't read", never a
        # partial answer — Disconnect acts on "none".
        items, why, status = _list_all(route)
        if items is None:
            raise AccountsUnreadable(why if status or why == OUT_OF_TIME else "no answer from Composio", status)
    else:
        items, _why, status = _list_all(route)
        if items is None:
            return out
    st, body = call("GET", expired_q)
    if st == 200 and isinstance(body, dict) and isinstance(body.get("items"), list):
        live_slugs = {((a.get("toolkit") or {}).get("slug") or "").lower()
                      for a in items if isinstance(a, dict)}
        # An account that was once live and ran out — not a link nobody opened.
        items = items + [a for a in body["items"] if isinstance(a, dict)
                         and "before authorization" not in str(a.get("status_reason") or "")
                         and ((a.get("toolkit") or {}).get("slug") or "").lower() not in live_slugs]
    # ONLY this Mac's user. The accounts list is project-wide: it returns
    # every user's connected accounts, and without this filter a row showed
    # "connected ×2" after a re-mint because it was counting the retired
    # identity's accounts alongside the new ones. On a project with more than
    # one person that is not a cosmetic error — it is one person's screen
    # reporting another's connections.
    try:
        mine = user_id()
    except NoIdentity:
        return out
    for a in items:
        if not isinstance(a, dict):
            continue
        slug = ((a.get("toolkit") or {}).get("slug") or "").lower()
        if not slug:
            continue
        if (a.get("user_id") or "") != mine:
            continue
        out.setdefault(slug, []).append({
            "status": (a.get("status") or "").upper(),
            "id": a.get("id") or "",
            # What the person will recognise: the address or handle Composio
            # recorded for the account, when it has one.
            "who": _account_label(a),
            "created": a.get("created_at") or "",
        })
    for slug in out:
        out[slug].sort(key=lambda a: (a["status"] != LIVE, a["created"]), reverse=False)
    return out


def _account_label(a):
    """Which account this is, in the words the person would use.

    Composio records no email field on a connected account — every obvious
    path (`meta.email`, `data.email`, …) is absent, which is worth knowing
    before someone goes looking for it again. Two things do carry it:

      `alias`         a label a person set themselves. Wins when present.
      `data.id_token` the OIDC token from the sign-in, whose payload is a
                      plain JSON object containing `email`.

    The token is READ, never logged, and nothing here verifies its signature
    because nothing here trusts it: it is our own record of our own account,
    used only to put a name on a row. The account object also carries
    `access_token` and `refresh_token` in plaintext — which is a fact about
    what the project key can reach, and another reason the edge has to proxy
    rather than hand this key to anyone's Mac.
    """
    alias = a.get("alias")
    if isinstance(alias, str) and alias.strip():
        return alias.strip()
    token = ((a.get("data") or {}).get("id_token")
             or (a.get("params") or {}).get("id_token") or "")
    if not isinstance(token, str) or token.count(".") < 2:
        return ""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)          # base64url needs padding
        claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8", "replace"))
    except Exception:
        return ""
    for key in ("email", "preferred_username", "name"):
        v = claims.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def live_accounts(accounts):
    return [a for a in accounts if a["status"] == LIVE]


def session_toolkits():
    """The toolkits this session is scoped to, in the order Composio gives."""
    sid = session_id()
    if not sid:
        return []
    status, body = call("GET", "/api/v3.1/tool_router/session/" + sid)
    if status != 200 or not isinstance(body, dict):
        return []
    tk = ((body.get("config") or {}).get("toolkits") or {})
    return [str(s).lower() for s in (tk.get("enabled") or [])]


CACHE_TTL = 24 * 60 * 60


def _cache_path():
    home = os.environ.get("MOE_HOME") or os.path.join(os.path.expanduser("~"), ".moe")
    return os.path.join(home, "cache", "composio-toolkits.json")


def toolkit_meta(slugs):
    """Display name and tool count for each slug, asked for BY SLUG.

    The first version fetched `/toolkits?limit=500` and looked each slug up in
    the result. Composio has 1,502 toolkits over 4 pages, so that list is a
    truncated slice in no guaranteed order: the same code returned "Google
    Calendar" to one caller and fell back to the raw slug for another, minutes
    apart, and the Connections screen showed `googlecalendar` as a service
    name. A lookup in a truncated list does not fail — it silently misses,
    which is worse, because the fallback looked like a reasonable answer.

    So: one exact request per slug against `/toolkits/<slug>`, plus a day-long
    disk cache, because these are names and tool counts rather than state and
    a screen should not spend five HTTPS round trips to draw five labels.
    """
    meta = {}
    if not slugs:
        return meta

    cache, path = {}, _cache_path()
    try:
        with open(path, encoding="utf-8") as fh:
            blob = json.load(fh)
        if time.time() - float(blob.get("at") or 0) < CACHE_TTL:
            cache = blob.get("toolkits") or {}
    except Exception:
        cache = {}

    fetched = False
    for slug in slugs:
        if slug in cache:
            meta[slug] = cache[slug]
            continue
        status, body = call("GET", "/api/v3/toolkits/" + urllib.parse.quote(slug, safe=""))
        if status != 200 or not isinstance(body, dict):
            continue
        m = body.get("meta") or {}
        entry = {
            "label": body.get("name") or slug,
            "tools": m.get("tools_count"),
            "logo": m.get("logo") or "",
        }
        meta[slug] = cache[slug] = entry
        fetched = True

    if fetched:
        try:
            _atomic_write_json(path, {"at": time.time(), "toolkits": cache}, indent=None)
        except Exception:
            pass          # a cache that cannot be written is not an error
    return meta


def session_toolkit_view():
    """Every toolkit in the session, with its connection, in ONE call.

    `GET /tool_router/session/{sid}/toolkits` is the right source and it took
    a while to find. It carries the display name, the logo and — the part that
    matters — `connected_account: {id, user_id, status}` or null, per toolkit.

    Three reasons it beats what this used to do:

    - **It works with a SCOPED key.** `GET /connected_accounts` is refused by
      a key that has write-but-not-read on connected accounts, which is the
      shape that closes the token-exfiltration hole (moe-47, CLOUD-PLAN
      §18.22). Under that key the old path 403'd and every service read "not
      connected" while plainly connected — the exact failure this screen was
      built to stop telling people.
    - **It has no side effects.** The other session route that reports
      connection state, COMPOSIO_MANAGE_CONNECTIONS, MINTS a connection
      request for anything unconnected. Using it as a status read would
      recreate the duplicate-account bug by way of the status check itself.
    - **It is one request.** This used to be a connected-accounts list, a
      session fetch and a per-slug toolkit lookup with a disk cache.

    Returns {slug: {label, logo, account}} where account is None or the
    inline connected_account.
    """
    sid = session_id()
    if not sid:
        return {}
    status, body = call("GET", "/api/v3.1/tool_router/session/%s/toolkits" % sid)
    if status != 200 or not isinstance(body, dict):
        return {}
    out = {}
    for item in body.get("items") or []:
        slug = (item.get("slug") or "").lower()
        if not slug:
            continue
        meta = item.get("meta") or {}
        out[slug] = {
            "label": item.get("name") or slug,
            "logo": meta.get("logo") or "",
            # This route carries description/logo/isNoAuth and NOT a tool
            # count. The count is a nice line in the pane and not worth a
            # second request per service, so it is filled in from the cache
            # toolkit_meta already keeps and left absent when there is none.
            "tools": None,
            # Whether Composio holds the sign-in: non-empty means Connect is
            # one click and there is nothing to paste, which is what the
            # Connections row promises. 119 of 1,378 on 2026-09-07, and it is
            # what decides whether the pane lists a service or only finds it
            # by search (docs/COMPOSIO.md §Which services the pane shows).
            "managed_auth": bool(item.get("composio_managed_auth_schemes")),
            "account": item.get("connected_account"),
        }
    return out


def session_identities(slugs):
    """Retired: always {}. Kept so an older caller does not break.

    It asked COMPOSIO_MANAGE_CONNECTIONS for `current_user_info`, on the
    belief that the call only mints for UNconnected toolkits. On a
    multi-account session (since 2026-09-24) it mints for connected ones too —
    it is how a second account is added. rows() called it on every refresh
    for each connected service without a name, and by 2026-09-30 that had made
    1,815 connection records for one person at ~45 an hour (GitHub, LinkedIn,
    Calendar, Gmail — exactly the unnamed ones). Three abandoned Gmail
    attempts filled Composio's five-per-service cap, so "add another inbox"
    was refused, and the list grew past LIST_MAX_PAGES, so every service read
    "not connected" (Reddit, freshly signed in). Names now come only from
    account_identity(), a proxied read of the service's own profile, and are
    saved as the account's alias so they are asked for once.
    """
    return {}


def rows():
    """One row per service: what the session offers, and what is signed in."""
    view = session_toolkit_view()
    if not view:
        return []
    # Tool counts come from the cached per-slug lookup — a day-long disk cache,
    # so this is usually free and never blocks a row from being drawn.
    counts = toolkit_meta(list(view))
    for slug, info in view.items():
        info["tools"] = (counts.get(slug) or {}).get("tools")

    # A second account per service is only visible through the accounts list,
    # which a scoped key cannot read. Ask, and carry on without it when
    # refused: one account named correctly beats no rows at all.
    extra = connected_accounts()

    def row(slug, info, accts):
        live = live_accounts(accts)
        if live:
            state = "ACTIVE"
        elif any(a["status"] in DEAD for a in accts):
            state = "EXPIRED"
        elif accts:
            state = "PENDING"
        else:
            state = "NOT_CONNECTED"
        return {
            "slug": slug,
            "name": "composio/" + slug,
            "label": info["label"],
            "tools": info["tools"],
            "logo": info["logo"],
            "managed_auth": info.get("managed_auth", False),
            "connected": bool(live),
            "state": state,
            "accounts": [{"id": a["id"], "who": a["who"], "status": a["status"]}
                         for a in accts],
            "account_count": len(live),
            "account_id": (live[0]["id"] if live else (accts[0]["id"] if accts else "")),
            "in_session": True,
        }

    out = []
    for slug, info in view.items():
        accts = extra.get(slug) or []
        if not accts and info["account"]:
            a = info["account"]
            accts = [{
                "id": a.get("id") or "",
                "who": (a.get("alias") or "").strip(),
                "status": (a.get("status") or "").upper(),
            }]
        out.append(row(slug, info, accts))

    # Connected, and not on the page the view showed. The toolkits route
    # pages by cursor, twenty at a time, with no page-size knob, and
    # session_toolkit_view reads the first page only — so a service outside
    # those twenty (TickTick, say) could be connected, live, and absent from
    # everything this feeds: the pane's "Yours", sync.sh's brokered set, and
    # context/_connections.md, which tells the model what it may not deny.
    # Measured 2026-09-11: ~/.moe/cache/composio-toolkits.json held exactly
    # twenty slugs on a session scoped to the whole catalogue. Anything the
    # accounts list says is this Mac's is a row, whatever page it is on;
    # names come from the cached per-slug lookup, one request each and only
    # for these, so a scoped key that cannot read accounts loses nothing.
    seen = {r["slug"] for r in out}
    beyond = [slug for slug in extra if slug not in seen]
    if beyond:
        names = toolkit_meta(beyond)
        for slug in beyond:
            m = names.get(slug) or {}
            out.append(row(slug, {
                "label": m.get("label") or slug,
                "tools": m.get("tools"),
                "logo": m.get("logo") or "",
                # It has an account, so Composio held a way to sign in.
                "managed_auth": True,
            }, extra[slug]))
    # Put a name on the connected ones. The alias is unreadable under a scoped
    # key, so ask the services themselves — and only the connected ones, or
    # this call would mint connection requests for the rest.
    unnamed = [r["slug"] for r in out
               if r["connected"] and not any(a["who"] for a in r["accounts"])]
    if unnamed:
        # A proxied read of the service's own profile — never
        # MANAGE_CONNECTIONS, which mints (session_identities). Saved as the
        # alias when there is one live account, so the next refresh has a
        # name and asks nothing.
        found = {}
        for slug in unnamed:
            who = account_identity(slug)
            if not who:
                continue
            found[slug] = who
            for r in out:
                live = [a for a in r["accounts"] if a["status"] == LIVE] if r["slug"] == slug else []
                if len(live) == 1 and live[0]["id"]:
                    call("PATCH", "/api/v3/connected_accounts/"
                         + urllib.parse.quote(str(live[0]["id"]), safe=""), {"alias": who})
        for slug, who in found.items():
            for r in out:
                if r["slug"] == slug:
                    for a in r["accounts"]:
                        if not a["who"]:
                            a["who"] = who
    # A cleanup still pending at Composio (prune_auth_configs, "Again") keeps
    # Disconnect on its service's row, connected or not: pressing it is how a
    # person retries one Moe has stopped retrying, and its message says so.
    # A not-connected row offered no Disconnect, so that message named a
    # button that was not there. A pending service with no row of its own
    # (no account, not on the view's page) gets one, named from the cache.
    pending = _read_ledger()["retry"]
    listed = {r["slug"] for r in out}
    for slug in sorted(s for s in pending if s not in listed):
        m = toolkit_meta([slug]).get(slug) or {}
        # No name cached (and none to be had just now): a bare slug on the
        # screen reads as a glitch, so say what it is.
        out.append(row(slug, {"label": m.get("label") or "A Composio service (%s)" % slug,
                              "tools": m.get("tools"),
                              "logo": m.get("logo") or "", "managed_auth": False}, []))
    for r in out:
        r["cleanup_pending"] = r["slug"] in pending
    out.sort(key=lambda r: (not r["connected"], r["label"].lower()))
    return out


# ── verbs ────────────────────────────────────────────────────────────────

def cmd_list(argv):
    started = time.monotonic()
    _print_rows(rows(), "--json" in argv)
    # The cleanup retry goes AFTER the answer and inside a budget (see
    # sweep_pending_prunes): `list` runs under its caller's 25 s timeout, and
    # a `list` that is killed shows the screen nothing at all. One that has
    # already spent SWEEP_SKIP_AFTER_S on its own reads does not sweep.
    sys.stdout.flush()
    if api_key() and time.monotonic() - started < SWEEP_SKIP_AFTER_S:
        try:
            sweep_pending_prunes()
        except Exception as exc:
            print("composio: retrying Alfie's cleanup at Composio did not run (%s)"
                  % type(exc).__name__, file=sys.stderr)
    if api_key() and time.monotonic() - started < SWEEP_SKIP_AFTER_S:
        try:
            sync_session_auth_configs()
        except Exception as exc:
            print("composio: pointing the session at pasted keys did not run (%s)"
                  % type(exc).__name__, file=sys.stderr)
    if api_key() and time.monotonic() - started < SWEEP_SKIP_AFTER_S:
        try:
            sweep_abandoned_signins()
        except Exception as exc:
            print("composio: sweeping abandoned sign-ins did not run (%s)"
                  % type(exc).__name__, file=sys.stderr)
    return 0


def _print_rows(data, as_json):
    if as_json:
        print(json.dumps({"connections": data}, indent=1))
        return
    if not data:
        print("no Composio services configured")
        return
    for r in data:
        n = r["account_count"]
        if n > 1:
            mark = "connected ×%d" % n
        elif n == 1:
            mark = "connected"
        else:
            mark = r["state"].lower().replace("_", " ")
        who = ", ".join(a["who"] for a in r["accounts"] if a["who"] and a["status"] == LIVE)
        tools = ("%s tools" % r["tools"]) if r["tools"] else ""
        print("%-28s %-15s %-11s %s" % (r["name"], mark, tools, who))


def cmd_search(argv):
    if not argv:
        print("search needs a word", file=sys.stderr)
        return 2
    q = " ".join(argv)
    status, body = call("GET", "/api/v3/toolkits?search=%s&limit=25"
                        % urllib.parse.quote(q))
    if status != 200 or not isinstance(body, dict):
        print("could not reach Composio", file=sys.stderr)
        return 1
    for t in body.get("items") or []:
        meta = t.get("meta") or {}
        print("%-28s %-30s %s tools" % (
            t.get("slug") or "", t.get("name") or "", meta.get("tools_count") or 0))
    return 0


#: Pages of 200 is Composio's cap; GitHub's 823 tools are five of them. A
#: ceiling rather than "while there is a cursor": a catalog route that never
#: stops paginating must not become an unbounded loop inside a background pass.
TOOLS_PAGE = 200
TOOLS_MAX_PAGES = 10


def _compact_schema(params):
    """{name: {type, description ≤160, enum?}} out of a tool's input
    parameters — what a planner needs to fill a read's arguments, and no
    more."""
    props = params.get("properties") if isinstance(params, dict) else None
    out = {}
    for name, spec in (props or {}).items():
        if not isinstance(spec, dict):
            continue
        row = {"type": str(spec.get("type") or ""),
               "description": " ".join(str(spec.get("description") or "").split())[:160]}
        if isinstance(spec.get("enum"), list):
            row["enum"] = [str(x) for x in spec["enum"][:12]]
        out[str(name)] = row
    return out


def toolkit_tools(slug, schemas=False):
    """Every tool Composio lists for one toolkit → [{slug, description, tags,
    required}], or None when the catalog could not be read.

    `GET /api/v3/tools?toolkit_slug=<slug>` is a PURE CATALOG READ: it is not
    scoped to this Mac's session, opens no MCP connection, touches no OAuth
    and mints nothing. That distinction is the whole reason it is used here
    rather than COMPOSIO_SEARCH_TOOLS or COMPOSIO_MANAGE_CONNECTIONS — the
    latter reports status *and creates a connection request for anything
    unconnected* (docs/COMPOSIO.md fact 3), and a probe that opens its own
    session has cost this Mac a sign-in.

    `tags` is Composio's own per-tool annotation set — readOnlyHint,
    destructiveHint, updateHint, mcpIgnore — and `required` its required
    argument names. Measured 2026-09-20: github 823 tools / 411 readOnlyHint,
    gmail 23 / 11. Those two fields are the read/write signal plain MCP does
    not have, and lib/mcp_autoread classifies on them."""
    out, cursor = [], None
    for _ in range(TOOLS_MAX_PAGES):
        route = "/api/v3/tools?toolkit_slug=%s&limit=%d" % (
            urllib.parse.quote(slug), TOOLS_PAGE)
        if cursor:
            route += "&cursor=" + urllib.parse.quote(cursor)
        status, body = call("GET", route)
        if status != 200 or not isinstance(body, dict):
            return out or None
        for t in body.get("items") or []:
            if not isinstance(t, dict) or not t.get("slug"):
                continue
            params = t.get("input_parameters")
            required = (params.get("required") or []) if isinstance(params, dict) else []
            row = {
                "slug": str(t["slug"]),
                "description": str(t.get("description") or ""),
                "tags": [str(x) for x in (t.get("tags") or []) if isinstance(x, str)],
                "required": [str(x) for x in required if isinstance(x, str)],
            }
            if schemas:
                row["parameters"] = _compact_schema(params)
            out.append(row)
        cursor = body.get("next_cursor")
        if not cursor:
            break
    return out


def cmd_tools(argv):
    if not argv:
        print("tools needs a service", file=sys.stderr)
        return 2
    slug = argv[0].split("/")[-1].lower()
    # --schemas: each tool's argument names, types and descriptions too — what
    # the situations engine's item planner (lib/composio_items.py) fills a
    # read's window from. Off by default: the gather classifier needs none of it.
    rows = toolkit_tools(slug, schemas="--schemas" in argv[1:])
    if rows is None:
        print("could not reach Composio", file=sys.stderr)
        return 1
    if "--json" in argv[1:]:
        json.dump({"toolkit": slug, "tools": rows}, sys.stdout, indent=1)
        print()
        return 0
    for t in rows:
        print("%-60s %s" % (t["slug"], " ".join(sorted(t["tags"]))))
    return 0


def cmd_status(argv):
    if not argv:
        print("unavailable: status needs a service")
        return 3
    slug = argv[0].split("/")[-1].lower()
    if not api_key():
        print("unavailable: no Composio key on this Mac")
        return 3
    if not session_id():
        print("unavailable: no Composio session in ~/.hermes/.env")
        return 3
    accts = connected_accounts().get(slug) or []
    live = live_accounts(accts)
    if live:
        who = ", ".join(a["who"] for a in live if a["who"])
        if len(live) > 1:
            print("ok: connected (%d accounts%s)" % (len(live), ": " + who if who else ""))
        else:
            print("ok: connected%s" % (" as " + who if who else ""))
        return 0
    if any(a["status"] in DEAD for a in accts):
        print("needs-setup: the sign-in ran out — connect again")
        return 1
    if accts:
        print("needs-setup: sign-in started but not finished")
        return 1
    print("needs-setup: not connected")
    return 1


def cmd_connect(argv):
    """Print the URL the person opens. Never opens it."""
    if not argv:
        print("connect needs a service", file=sys.stderr)
        return 2
    slug = argv[0].split("/")[-1].lower()
    # Every call to MANAGE_CONNECTIONS mints a NEW connection request, so
    # clicking Connect on something already connected quietly accumulated
    # duplicates — this Mac had three Gmail accounts, one live and two dead,
    # entirely from re-clicking. Adding a second account is a real thing
    # people want, so it stays possible; it just has to be asked for.
    another = "--another" in argv
    # A pasted key, for the services Composio holds no sign-in for. The
    # values are on stdin — never argv, where `ps` would show them — and the
    # account is live as soon as it is made; see connect_with_key.
    if "--key" in argv:
        return connect_with_key(slug, another=another)
    accts = connected_accounts().get(slug) or []
    if not another and live_accounts(accts):
        print("already connected")
        return 0
    # Composio holds five accounts per service, and a pending sign-in holds a
    # slot until it is removed — it does not give it back when its link
    # expires. Three abandoned Gmail attempts refused the owner's third inbox
    # on 2026-09-30. Free them first: only pending ones older than a link
    # lives, never a live one.
    prune_stale_pending(accts)
    res = mcp(MINTING_TOOL,
              {"toolkits": [slug], "reinitiate_all": True} if another
              else {"toolkits": [slug]}, mint=True)
    if res.get("error"):
        print("could not start the sign-in: %s" % res["error"], file=sys.stderr)
        return 1
    results = ((res.get("data") or {}).get("results") or {})
    entry = results.get(slug) or {}
    url = entry.get("redirect_url") or ""
    if not url:
        # Already connected is a success, not a failure: the person asked to
        # connect something that is connected, and saying "no URL" would read
        # as a fault.
        if (entry.get("status") or "").lower() in ("active", "connected"):
            print("already connected")
            return 0
        # Composio's own reason, when it gave one — "Maximum of 5 accounts
        # per toolkit reached" is something a person can act on; "no link"
        # is not.
        why = str(entry.get("error_message") or "").strip()
        if "maximum" in why.lower() and "accounts" in why.lower():
            print("%s already has the most accounts Composio allows (5). "
                  "Disconnect one you no longer use, then add this one." % slug,
                  file=sys.stderr)
        elif why:
            print("Composio could not start a sign-in for %s: %s" % (slug, why), file=sys.stderr)
        else:
            print("Composio did not return a sign-in link for %s" % slug, file=sys.stderr)
        return 1
    print(url)
    return 0


def _age_s(iso):
    try:
        from datetime import datetime, timezone
        t = datetime.strptime(str(iso)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - t).total_seconds()
    except Exception:
        return 0.0


#: How often `list` sweeps abandoned sign-ins, and how many it removes at
#: most in one go (it runs after the answer, inside list's budget).
ABANDONED_SWEEP_EVERY_S = 30 * 60
ABANDONED_SWEEP_MAX = 60


def _abandoned(a):
    """A sign-in nobody finished: still pending after a link's life, or
    expired before its page was ever used. Never a live account, and never
    one that was live once and ran out — that one's row says "sign in again"."""
    st = str(a.get("status") or "").upper()
    if st in ("INITIALIZING", "INITIATED"):
        return _age_s(a.get("created_at")) > STALE_PENDING_S
    return st == "EXPIRED" and "before authorization" in str(a.get("status_reason") or "")


def sweep_abandoned_signins(limit=ABANDONED_SWEEP_MAX, force=False):
    """Delete this Mac's abandoned sign-ins at Composio. Returns how many.

    Whatever starts a sign-in — Connect pressed and the page closed, the
    model offering a link nobody opened, or a bug like the one that made
    1,815 — leaves a record that holds one of the service's five slots and
    lengthens every account read, forever. Nothing at Composio removes them.
    So every Mac removes its own, a few at a time, on the refresh it already
    makes: the pile cannot grow whatever caused it. Only this Mac's user,
    only abandoned records (_abandoned), throttled to once per
    ABANDONED_SWEEP_EVERY_S unless `force`.
    """
    stamp = os.path.join(os.path.dirname(_cache_path()), "composio-sweep.json")
    if not force:
        try:
            with open(stamp, encoding="utf-8") as fh:
                if time.time() - float(json.load(fh).get("at") or 0) < ABANDONED_SWEEP_EVERY_S:
                    return 0
        except Exception:
            pass
    try:
        mine = user_id()
    except NoIdentity:
        return 0
    gone = 0
    for statuses in ("INITIALIZING,INITIATED", "EXPIRED"):
        cursor = ""
        while gone < limit:
            st, body = call("GET", "/api/v3/connected_accounts?limit=50&statuses=%s&user_ids=%s%s"
                            % (statuses, urllib.parse.quote(mine, safe=""),
                               "&cursor=" + urllib.parse.quote(cursor, safe="") if cursor else ""))
            if st != 200 or not isinstance(body, dict) or not isinstance(body.get("items"), list):
                break
            for a in body["items"]:
                if gone >= limit:
                    break
                if isinstance(a, dict) and a.get("user_id") == mine and a.get("id") and _abandoned(a):
                    d, _ = call("DELETE", "/api/v3/connected_accounts/"
                                + urllib.parse.quote(str(a["id"]), safe=""))
                    gone += d in (200, 204)
            cursor = str(body.get("next_cursor") or "")
            # Deleting shifts the pages under us; a full pass next time
            # picks up whatever this one stepped over.
            if not cursor:
                break
    try:
        os.makedirs(os.path.dirname(stamp), exist_ok=True)
        _atomic_write_json(stamp, {"at": time.time(), "removed": gone}, indent=None)
    except Exception:
        pass
    return gone


def cmd_sweep(argv):
    """composio.py sweep [--all]: remove this Mac's abandoned sign-ins now."""
    if not api_key():
        print("no Composio key on this Mac", file=sys.stderr)
        return 3
    limit = 100000 if "--all" in argv else ABANDONED_SWEEP_MAX
    total = 0
    while True:
        n = sweep_abandoned_signins(limit=limit, force=True)
        total += n
        if n == 0 or "--all" not in argv:
            break
    print("removed %d abandoned sign-in(s)" % total)
    return 0


def sync_session_auth_configs():
    """Point this Mac's session at the auth config each pasted-key account
    lives on. Returns the slugs it had to add or change ([] when current).

    A pasted key is an account on an auth config of Alfie's (`moe-<slug>`,
    connect_with_key). A tool router session only reads Composio's own
    config for a service unless told otherwise, so until 2026-09-30 every
    pasted key was saved, listed as connected, and refused by every tool
    call: "No active connection found for toolkit(s) 'cloudflare' in this
    session". Measured that day: the owner's Cloudflare key, LIST_ZONES
    refused; the same session given `auth_configs: {cloudflare: <Alfie's>}`
    by PATCH — which Composio keeps, multi-account intact — listed his zones.
    Run after every key connect and on every list, so a session made before
    this fix, or on another Mac, is repaired by the next refresh.
    """
    sid = session_id()
    if not sid:
        return []
    try:
        mine = user_id()
    except NoIdentity:
        return []
    st, body = call("GET", "/api/v3/connected_accounts?limit=50&statuses=ACTIVE&user_ids="
                    + urllib.parse.quote(mine, safe=""))
    if st != 200 or not isinstance(body, dict) or not isinstance(body.get("items"), list):
        return []
    want = {}
    # Newest last, so where a service has accounts on two of Moe's configs
    # the most recent paste is the one the session uses.
    for a in sorted((a for a in body["items"] if isinstance(a, dict)),
                    key=lambda a: str(a.get("created_at") or "")):
        ac = a.get("auth_config") or {}
        slug = ((a.get("toolkit") or {}).get("slug") or "").lower()
        if a.get("user_id") == mine and slug and ac.get("id") and not ac.get("is_composio_managed"):
            want[slug] = ac["id"]
    if not want:
        return []
    st, sess = call("GET", "/api/v3.1/tool_router/session/" + sid)
    if st != 200 or not isinstance(sess, dict):
        return []
    have = dict((sess.get("config") or {}).get("auth_configs") or {})
    changed = [k for k, v in want.items() if have.get(k) != v]
    if not changed:
        return []
    have.update(want)
    st, _ = call("PATCH", "/api/v3.1/tool_router/session/" + sid, {"auth_configs": have})
    return changed if st == 200 else []


def cmd_sync_session(argv):
    """composio.py sync-session: point the session at every pasted key's config."""
    if not api_key():
        print("no Composio key on this Mac", file=sys.stderr)
        return 3
    changed = sync_session_auth_configs()
    print("session now uses Alfie's config for: %s" % ", ".join(changed) if changed
          else "session already current")
    return 0


def prune_stale_pending(accts):
    """Delete this service's sign-ins that were started and never finished,
    once they are older than a link lives. Returns how many went."""
    gone = 0
    for a in accts:
        if a.get("status") in ("INITIALIZING", "INITIATED") and a.get("id") \
                and _age_s(a.get("created")) > STALE_PENDING_S:
            st, _ = call("DELETE", "/api/v3/connected_accounts/"
                         + urllib.parse.quote(str(a["id"]), safe=""))
            gone += st in (200, 204)
    return gone


# ── keys: the services Composio holds no sign-in for ────────────────────
#
# 119 of the 1,378 toolkits have a Composio-managed OAuth app, and for those
# `cmd_connect` above is the whole story: a link, a sign-in, done. The other
# ~1,250 do not — measured 2026-09-07, docs/COMPOSIO.md "Nine in ten" — and
# 1,122 of them want an API key from the service's own settings page. Until
# 2026-09-11 nothing here could take one: Connect asked the session for a
# redirect and printed "Composio did not return a sign-in link".
#
# The key goes to Composio, not to this Mac. That is deliberate and it is the
# same reason the OAuth route exists: a connected account at Composio works
# from the Mac and from the away machine alike, through one session, with
# nothing to copy between them. The .env route (a skill's key, an MCP
# server's bearer) is for things Hermes reaches directly.

#: Auth schemes where the person supplies the credential and the account is
#: live the moment it is created. OAuth schemes redirect instead and take the
#: route above. Composio's own names, from `auth_schemes` in the catalogue.
KEY_SCHEMES = ("API_KEY", "BEARER_TOKEN", "BASIC", "BASIC_WITH_JWT")
#: The field names that are NOT secrets: typed where they can be seen, and
#: taken out of a refusal only where they appear exactly. EVERY other field
#: is a secret — typed blind, and taken out of a refusal in every form.
#:
#: An allowlist, because the other way round leaked. This was a list of
#: words meaning secret (key, token, secret, password, jwt, credential), and
#: a review found passphrase, pat, bearer, authorization, dsn, webhook_url,
#: connection_string, database_url, service_account_json, cookie, pin,
#: access_code, signature, hmac, pwd and pass all falling through it: a
#: masked, lower-cased or split echo of any of them came back whole.
#: Composio's field schema has no is_secret to ask instead. A plain name
#: missing from this list costs a refusal some readability; a secret name
#: missing from a list of secret words cost the secret.
PLAIN_FIELDS = frozenset((
    "subdomain", "region", "domain", "host", "hostname", "base_url", "url",
    "instance", "instance_url", "site", "site_url", "username", "user_name",
    "email", "client_id", "account_id", "workspace", "org", "organization",
    "tenant", "tenant_id", "project_id",
))
#: Plain names whose answer is an address — which can carry a secret of its
#: own (`https://user:pw@host`, `…?token=…`, `hooks.slack.com/services/…/<token>`).
URL_FIELDS = frozenset(("base_url", "url", "instance_url", "site_url"))
#: Plain names whose answer is a host, which can be written with a secret in
#: it too (`admin:<password>@db.example.com`, no scheme).
HOST_FIELDS = frozenset(("host", "hostname", "domain", "subdomain", "instance", "site"))
_BARE_HOST = re.compile(r"^(?:[A-Za-z0-9.-]*|\[[0-9A-Fa-f:.]+\])(?::[0-9]{0,5})?$")


def _url_carries_secret(value):
    """True unless `value` is a bare host or origin: `acme.example.com`,
    `https://acme.example.com`, `…:8443`, with at most a trailing `/`.

    A path counts. The review's shapes: a Slack webhook
    (`https://hooks.slack.com/services/T…/B…/<token>`) and a Discord
    `base_url` (`…/api/webhooks/<id>/<token>`) carry the token in the path,
    and were typed visibly and taken out of a refusal only where they
    appeared whole — the token alone, URL-quoted, `\\/`-escaped,
    lower-cased or masked came back. So did a host with a password and no
    scheme. Anything that is not a plain host is a secret: a refusal loses
    some readability about an address, never a token."""
    text = str(value or "").strip()
    try:
        parts = urllib.parse.urlsplit(text if "://" in text else "//" + text)
        if parts.username or parts.password or parts.query or parts.fragment:
            return True
        if parts.path not in ("", "/"):
            return True
        return not _BARE_HOST.match(parts.netloc)
    except ValueError:
        return True


def _address_pieces(value):
    """The parts of a secret address a service might quote back on their own:
    the whole, and each of user, password, path segment, query key and value,
    and fragment — as written and URL-unquoted. _redact takes each out in
    every form (and ignores any under REDACT_MIN)."""
    text = str(value or "").strip()
    out = [text]
    try:
        parts = urllib.parse.urlsplit(text if "://" in text else "//" + text)
        pieces = [parts.username, parts.password, parts.fragment]
        pieces += parts.path.split("/") + re.split(r"[&=;]", parts.query)
        if not _BARE_HOST.match(parts.netloc):
            pieces += re.split(r"[:@]", parts.netloc)
    except ValueError:
        pieces = re.split(r"[/:@?#&=;]+", text)
    for piece in pieces:
        if piece:
            out += [piece, urllib.parse.unquote(piece)]
    return out


def _is_secret_field(name, value=None):
    """True unless `name` is on PLAIN_FIELDS — and, for an address (a URL
    or host field, or any plain answer written `scheme://…`), unless `value`
    is a bare host or origin (_url_carries_secret). Without a value (the
    paste sheet deciding what to type blind) an address field is plain."""
    low = str(name or "").strip().lower().replace("-", "_")
    if low not in PLAIN_FIELDS:
        return True
    if value is not None and (low in URL_FIELDS or low in HOST_FIELDS or "://" in str(value)):
        return _url_carries_secret(value)
    return False


def toolkit_key_fields(slug):
    """What the person must paste to connect `slug`, in Composio's own words.

    `GET /api/v3/toolkits/<slug>` carries `auth_config_details`: one entry
    per auth scheme, each naming the fields an auth config needs when it is
    made (`auth_config_creation`) and the fields a connected account needs
    when it is started (`connected_account_initiation`), with a display name
    and a description that usually says where to find the thing. Read at
    connect time, never typed here: what Firecrawl calls its key (`api_key`),
    what another service calls it (`token`, `generic_api_key`), and whether a
    `subdomain` must come with it, are facts about the service that a table
    in this file would get wrong for some of 1,250 rows and nobody would
    notice until a paste landed in a field the service never reads.

    Returns {"scheme", "managed", "fields": [...], "help_url"}. `fields` is
    [{"name", "label", "help", "secret", "required", "stage"}] with stage
    "auth_config" or "account"; `scheme` is "" when the toolkit offers no key
    scheme at all (OAuth only, or no auth), and `managed` says whether
    Composio holds a sign-in for it — in which case the link route is the
    one to take and this is only informational.
    """
    status, body = call("GET", "/api/v3/toolkits/" + urllib.parse.quote(slug, safe=""))
    if status != 200 or not isinstance(body, dict):
        return {"scheme": "", "managed": False, "fields": [], "help_url": "",
                "error": "could not read the service's record (HTTP %s)" % status}
    managed = bool(body.get("composio_managed_auth_schemes"))
    chosen = None
    for detail in body.get("auth_config_details") or []:
        if not isinstance(detail, dict):
            continue
        mode = str(detail.get("mode") or "").upper()
        if mode in KEY_SCHEMES:
            # First key scheme in Composio's order wins; API_KEY is listed
            # first wherever it exists, and it is the one a settings page
            # hands out.
            if chosen is None or KEY_SCHEMES.index(mode) < KEY_SCHEMES.index(chosen[0]):
                chosen = (mode, detail)
    if chosen is None:
        return {"scheme": "", "managed": managed, "fields": [], "help_url": ""}
    scheme, detail = chosen
    fields, help_url = [], ""
    groups = detail.get("fields") if isinstance(detail.get("fields"), dict) else {}
    for stage_key, stage in (("auth_config_creation", "auth_config"),
                             ("connected_account_initiation", "account")):
        group = groups.get(stage_key) if isinstance(groups.get(stage_key), dict) else {}
        # Required only. An optional field is one the service works without,
        # and a sheet that asks for six things when one will do is the
        # sheet nobody finishes.
        for f in group.get("required") or []:
            if not isinstance(f, dict) or not f.get("name"):
                continue
            name = str(f["name"])
            help_text = str(f.get("description") or "").strip()
            m = re.search(r"https://\S+", help_text)
            if m and not help_url:
                help_url = m.group(0).rstrip(".,;)")
            fields.append({
                "name": name,
                "label": str(f.get("displayName") or f.get("display_name") or name),
                "help": help_text,
                "secret": _is_secret_field(name),
                "required": True,
                "stage": stage,
            })
    return {"scheme": scheme, "managed": managed, "fields": fields, "help_url": help_url}


def cmd_fields(argv):
    """The fields a key connect needs, as JSON on stdout — for the app's paste
    sheet and for connect.sh, both of which ask before they run anything."""
    if not argv:
        print("fields needs a service", file=sys.stderr)
        return 2
    slug = argv[0].split("/")[-1].lower()
    if not api_key():
        print("no Composio key on this Mac", file=sys.stderr)
        return 3
    info = toolkit_key_fields(slug)
    info["slug"] = slug
    print(json.dumps(info, indent=1))
    if info.get("error"):
        return 1
    return 0 if info["scheme"] else 1


def _read_pasted(stream):
    """`name=value` lines → {name: value}. The names are matched to the
    toolkit's fields case-insensitively (`API_KEY=` for `api_key`), a
    trailing CR from a paste is dropped, and nothing is ever echoed."""
    out = {}
    for raw in stream:
        line = raw.rstrip("\r\n")
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip().lower()] = v.strip()
    return out


#: A value shorter than this is not taken out of a refusal. A subdomain like
#: `acme` or a region like `eu` is not a secret, and redacting four letters
#: wherever they occur turns "rejected" into "…ed" — the reason stops being
#: readable, which is its whole job.
REDACT_MIN = 8

#: What a service puts where a key's tail used to be when it echoes a
#: masked copy back: `sk_live_0123****`, `sk_live_0123••••`, `…xxxx`, `….`.
_MASK = "[*•x.…]+"
#: Between two characters of a key: nothing, or what a service (or a
#: JSON/repr escape of it) broke the key across lines with — whitespace, an
#: HTML `<br>` or `<br/>`, or a hyphen before a line break.
_GAP = r"(?:\s|\\+[nrt]|(?i:<br\s*/?>)|-(?=\s|\\+[nrt]))*"
#: An ASCII value at least this long is matched in any letter case: a
#: service that lower-cases what it quotes back has still quoted the key. A
#: shorter one is not — matched caselessly, a short value is an ordinary
#: word more often than it is a key.
CASELESS_MIN = 16
#: Anchored at the start of a backslash run: unanchored, a megabyte of
#: backslashes with no `u` after them was rescanned from every offset.
_U_ESCAPE = re.compile(r"(?<!\\)(\\+)u([0-9a-fA-F]{4})")


def _char_pattern(c):
    """Every way one character of a key can come back in someone's text."""
    forms = {re.escape(c)}
    # Any run of backslashes before a character: `\"` (JSON), `\\` (JSON of a
    # backslash, or Python's repr of one), `\\\\` (a repr of a JSON escape),
    # `\/` (a serialiser that escapes slashes).
    if not c.isalnum():
        forms.add(r"\\*" + re.escape(c))
    for enc in (json.dumps(c)[1:-1], repr(c)[1:-1]):
        forms.add(re.escape(enc).replace(r"\\", r"\\+"))
    pct = urllib.parse.quote(c, safe="")
    if pct != c:
        # %2B or %2b, doubly-quoted %252B, trebly-quoted %25252B.
        forms.add("(?i:%s)" % "".join("%(?:25){0,2}" + re.escape(h) for h in pct.split("%")[1:]))
    if c == " ":
        forms.add(r"\+")
    return "(?:%s)" % "|".join(sorted(forms, key=len, reverse=True))


#: A run of a value's front this long — or half the value, when that is
#: shorter, and never under REDACT_MIN — is taken out whether or not a mask
#: follows it: that much of a key in order IS the key's front, and a service
#: that quotes most of a value back (a JWT less its signature) has not
#: masked anything.
FRONT_RUN = 32
_MASK_RE = re.compile(_MASK)
_MASK_CHARS = "*•x.…"


class _SecretForms:
    """One value's patterns, built so that no regex nests deeper than
    FRONT_RUN groups whatever the value's length.

    It used to be one pattern with a nested optional group per character (the
    masked-front branch): Python's regex compiler recurses once per level, so
    a value of about 490 characters — a JWT, a PEM, a service-account JSON —
    raised RecursionError, the refusal became a stack trace, and the prune
    after a refused paste never ran. Now:

    - `front` is the first REDACT_MIN characters then at most
      FRONT_RUN - REDACT_MIN nested optionals, capturing where each
      character ends so a mask can be looked for after any of them;
    - `block(k, n)` is characters k..k+n as a flat sequence, compiled on
      demand, which extends a front run past FRONT_RUN to the value's end.

    The whole value is a front run that reaches the end, so it needs no
    pattern of its own. It had one (a flat sequence) for a while, and on a
    periodic value — `Zq9Zq9…`, 1,200 characters, in a 1 MB body — that
    pattern re-walked the value from every offset: 9 s, where the front walk,
    which skips past each span it takes, is linear.
    """

    def __init__(self, secret):
        self.n = len(secret)
        self.flags = re.IGNORECASE if secret.isascii() and self.n >= CASELESS_MIN else 0
        self.chars = [_char_pattern(c) for c in secret]
        self.run = min(self.n, FRONT_RUN, max(REDACT_MIN, (self.n + 1) // 2))
        tail = ""
        for cp in reversed(self.chars[REDACT_MIN:self.run]):
            tail = "(?:%s(%s)%s)?" % (_GAP, cp, tail)
        self.front = re.compile("(%s)%s" % (_GAP.join(self.chars[:REDACT_MIN]), tail), self.flags)
        self._blocks = {}

    def block(self, k, n):
        key = (k, n)
        if key not in self._blocks:
            self._blocks[key] = re.compile(_GAP + _GAP.join(self.chars[k:k + n]), self.flags)
        return self._blocks[key]

    def extend(self, text, k, pos):
        """From `pos`, just after character k-1, as far along the value as
        the text follows it. Returns the end."""
        step = 64
        while k < self.n:
            b = min(step, self.n - k)
            m = self.block(k, b).match(text, pos)
            if m:
                k, pos = k + b, m.end()
                continue
            lo, hi, lo_end = 0, b, pos
            while hi - lo > 1:
                mid = (lo + hi) // 2
                m = self.block(k, mid).match(text, pos)
                if m:
                    lo, lo_end = mid, m.end()
                else:
                    hi = mid
            return lo_end
        return pos

    def front_spans(self, text):
        """Spans of a front of the value: REDACT_MIN or more characters then
        a mask run, or `run` or more characters with or without one."""
        spans, pos = [], 0
        run = self.run
        while pos < len(text):
            m = self.front.search(text, pos)
            if not m:
                break
            ends = [m.end(1)]
            for g in range(2, self.front.groups + 1):
                if m.end(g) < 0:
                    break
                ends.append(m.end(g))
            k = REDACT_MIN + len(ends) - 1
            stop = None
            if k >= run:
                stop = self.extend(text, k, ends[-1])
                mm = _MASK_RE.match(text, stop)
                if mm:
                    stop = mm.end()
            else:
                for e in reversed(ends):
                    if e < len(text) and text[e] in _MASK_CHARS:
                        stop = _MASK_RE.match(text, e).end()
                        break
            if stop is None:
                pos = m.start() + 1
                continue
            spans.append((m.start(), stop))
            pos = stop
        return spans


def _decoded(text, keep=True):
    """`text` with JSON `\\uXXXX` escapes turned back into characters and its
    unicode in one form (NFKC), so a key quoted back with one character
    escaped, or with its accents decomposed (NFD), is the key again.

    `keep`: a run of backslashes before the `u` loses only the one that makes
    the escape, because the one before it can be the key's own (`w\\R` quoted
    back as `w\\\\u0052`). Without `keep` the whole run goes: the second pass,
    for an escape that was itself escaped."""
    if "\\" in text:
        text = _U_ESCAPE.sub(lambda m: ("\\" * (len(m.group(1)) - 1) if keep else "")
                             + chr(int(m.group(2), 16)), text)
        try:
            text = text.encode("utf-16", "surrogatepass").decode("utf-16")
        except UnicodeError:
            text = text.encode("utf-8", "replace").decode("utf-8")
    return unicodedata.normalize("NFKC", text)


def _redact(text, secrets, plain=()):
    """`text` with every value in `secrets` taken out, in every form a
    service can quote it back in: as pasted, in any letter case (ASCII, 16
    characters or more), URL-quoted up to three times (`quote` and
    `quote_plus`), JSON-escaped (`\\"`, or `\\uXXXX`), repr-escaped (an
    `error` given as a list is printed with its backslashes doubled), broken
    across lines (whitespace, `<br>`, a hyphen and a break), in another
    unicode form, or as a front — masked (`sk_live_0123****`) or simply most
    of it. Replacing only the exact value left the key in five of eleven
    shapes an adversarial review tried. Any length of value: see
    _SecretForms.

    Only `secrets` — values of fields the service names as secret (a key, a
    token, a password: _is_secret_field) — get all of that. A `plain` answer
    (a region, a subdomain, an email address) is taken out only where it
    appears exactly: the front rules on a pasted `us-east-1` turned a
    refusal's "use us-east-2" into "use …2", and a refusal that can no
    longer say which region it wants has stopped doing its job."""
    secrets = sorted({unicodedata.normalize("NFKC", str(v)) for v in secrets if v}, key=len, reverse=True)
    secrets = [s for s in secrets if len(s) >= REDACT_MIN]
    if secrets:
        once = _redact_forms(_decoded(text), secrets)
        if _U_ESCAPE.search(text):
            # A run of backslashes before `u` is either the key's own
            # backslash and an escape, or an escape escaped again: read it
            # both ways, and keep the reading that found more of the key.
            twice = _redact_forms(_decoded(text, keep=False), secrets)
            if twice.count("…") > once.count("…"):
                once = twice
        text = once
    for value in sorted({str(v) for v in plain if v and len(str(v)) >= REDACT_MIN}, key=len, reverse=True):
        text = text.replace(value, "…")
    return text


def _redact_forms(text, secrets):
    for secret in secrets:
        spans = _SecretForms(secret).front_spans(text)
        if spans:
            # One join, not a slice per span: a slice per span copies the
            # whole text each time, which on a large body is the slow part.
            parts, at = [], 0
            for a, b in spans:
                parts += [text[at:a], "…"]
                at = b
            parts.append(text[at:])
            text = "".join(parts)
    return text


def _refusal(body, status, values, limit=160):
    """Composio's reason for a refusal, safe to print. `values` is {field
    name: value}, or (name, value) pairs: a secret field's value is taken out
    in every form, any other where it appears exactly (see _redact).

    Its error text can quote the request back — the key a person pasted, a
    subdomain, a client secret. So the values are taken out FIRST and the
    text is cut after: cutting first (it used to be `str(body)[:200]`, then
    the replace) leaves the front of a key that straddles the cut in the
    message, because the whole value is no longer there to be found.
    """
    why = body.get("error") if isinstance(body, dict) else body
    if isinstance(why, dict):
        why = why.get("message") or json.dumps(sorted(why.keys()))
    why = str(why or "HTTP %s" % status)
    secret, plain = [], []
    for name, value in (values.items() if isinstance(values, dict) else values):
        if not _is_secret_field(str(name), value):
            plain.append(value)
        elif str(name or "").strip().lower().replace("-", "_") in PLAIN_FIELDS:
            # An address that carries a secret: its pieces too.
            secret += _address_pieces(value)
        else:
            secret.append(value)
    return _redact(why, secret, plain)[:limit]


def ensure_auth_config(slug, scheme, creation_values):
    """The auth config a key account hangs off, made once per service.

    Composio needs one even for a scheme where there is nothing to configure:
    it is the record that says "accounts on this toolkit authenticate by
    API_KEY". An existing one for the same toolkit and scheme is reused —
    every connect used to be a chance to mint another, and a project with
    one auth config per click is a project nobody can read. Where the scheme
    takes values at creation (a per-person subdomain, say) a fresh one is
    made, because those values are this person's.
    """
    if not creation_values:
        status, body = call("GET", "/api/v3/auth_configs?toolkit_slug=%s&limit=50"
                            % urllib.parse.quote(slug))
        if status == 200 and isinstance(body, dict):
            for ac in body.get("items") or []:
                if not isinstance(ac, dict):
                    continue
                if str(ac.get("auth_scheme") or "").upper() != scheme:
                    continue
                if ac.get("is_composio_managed"):
                    continue
                if ac.get("id"):
                    # Reused by a paste that is about to hang an account
                    # off it: marked so no prune takes it meanwhile.
                    _ledger_in_flight(ac["id"], True)
                    return ac["id"], ""
    status, body = call("POST", "/api/v3/auth_configs", {
        "toolkit": {"slug": slug},
        "auth_config": {
            "type": "use_custom_auth",
            "authScheme": scheme,
            "credentials": creation_values,
            "name": "moe-%s" % slug,
        },
    })
    if status not in (200, 201) or not isinstance(body, dict):
        why = _refusal(body, status, creation_values)
        return "", "Composio would not make an auth config for %s: %s" % (slug, why)
    ac = body.get("auth_config") if isinstance(body.get("auth_config"), dict) else body
    ac_id = str(ac.get("id") or "").strip()
    if not ac_id:
        return "", "Composio made an auth config for %s but answered with no id" % slug
    # Recorded before anything else can fail: this record is the only thing
    # that lets a later prune delete it (see prune_auth_configs). In flight
    # until connect_with_key has made (or failed to make) its account.
    _ledger_add(ac_id, slug, in_flight=True)
    return ac_id, ""


AC_DELETE_DOC = "https://docs.composio.dev/reference/v3/api-reference/auth-configs/deleteAuthConfigsByNanoid"
AC_LIST_DOC = "https://docs.composio.dev/reference/v3/api-reference/auth-configs/getAuthConfigs"

#: The auth configs THIS Mac made at Composio, beside composio-identity.json
#: (0600): {"configs": {id: {"toolkit", "made_at", "in_flight_at"?}},
#: "retry": {toolkit: {"at", "misses", "why"}}}. Only an id in here is ever
#: deleted.
AUTH_CONFIG_LEDGER = "composio-auth-configs.json"
#: Held while the ledger is read, changed and written back: the Connections
#: screen runs two `list`s at once, and without it one's write dropped the
#: ids the other had just recorded.
LEDGER_LOCK = AUTH_CONFIG_LEDGER + ".lock"
#: Held by a key connect for ONE toolkit, from choosing its auth config until
#: its account exists: `<this><slug>.lock` (_connect_lock). A prune of that
#: toolkit that cannot take it at once leaves it for later. Per toolkit
#: because one lock for all of them let a paste whose account post hung block
#: Firecrawl's Disconnect cleanup (reported as a failure) and another
#: service's paste (19 s) behind it. Lock order: this, then LEDGER_LOCK.
CONNECT_LOCK_PREFIX = AUTH_CONFIG_LEDGER + ".connect."
#: A ledger that does not parse, or parses into a shape this never writes, is
#: moved to `<this>.<when>`, bytes intact, before a fresh one starts. The
#: newest LEDGER_ASIDE_KEEP are kept, and the ids in them are salvaged into
#: the fresh ledger (_salvage_ids) with a retry each, so nothing Moe made is
#: forgotten — and nothing is deleted at Composio on a damaged file's word
#: alone: a salvaged id goes through the same checks as any other.
LEDGER_ASIDE_PREFIX = AUTH_CONFIG_LEDGER + ".unreadable"
LEDGER_ASIDE_KEEP = 5
#: Every file composio.py keeps in Moe's home, by name — and, for the ones
#: named per toolkit or per event, by prefix. Deleting the account removes
#: each (the closed cloud half's CloudSync+Delete.swift, `composioFiles` and
#: `composioPrefixes`; test-composio-session.sh fails when one is missing
#: there).
LOCAL_FILES = (IDENTITY_FILE, IDENTITY_FILE + ".lock", AUTH_CONFIG_LEDGER, LEDGER_LOCK)
LOCAL_FILE_PREFIXES = (CONNECT_LOCK_PREFIX, LEDGER_ASIDE_PREFIX)
#: A recorded config a key connect marked in flight this recently is never
#: pruned, lock or no lock. A connect that died between its config and its
#: account leaves the mark behind, so it expires.
IN_FLIGHT_GRACE_S = 15 * 60
#: How long a key connect waits for its toolkit's connect lock before going ahead on the
#: in-flight mark alone.
CONNECT_LOCK_WAIT_S = 60
#: A prune that could not finish is tried again by `list`, at most this often.
PRUNE_RETRY_S = 10 * 60
#: Tries in a row that could not finish (a list that could not be read, a
#: delete Composio refused) before `list` stops trying on its own; the ledger
#: keeps why. A legacy scoped key that may not read accounts would otherwise
#: be retried every ten minutes for ever. Disconnect and a key connect for
#: the service still try, and one that finishes clears the count.
PRUNE_MAX_MISSES = 3
#: The whole sweep inside one `list`, every request included. `list` runs
#: under a 25 s timeout (hermes-connections.py and hermes-catalog.py, inside
#: the app's own 30 s), and a `list` that is killed shows the screen nothing.
SWEEP_BUDGET_S = 5
#: A `list` that has already spent this long on its own reads does not sweep.
SWEEP_SKIP_AFTER_S = 12
#: Pages a list read follows before it counts as unfinished.
LIST_MAX_PAGES = 20
#: A whole Disconnect — the account read, the deletes, the cleanup — shares
#: this, inside the 60 s the app gives `connect.sh --remove`. A cleanup cut
#: off by it is left pending and said so, not waited out.
DISCONNECT_BUDGET_S = float(os.environ.get("MOE_COMPOSIO_DISCONNECT_BUDGET_S") or 40)  # env: tests


def _ledger_file(name):
    return os.path.join(os.path.dirname(identity_path()), name)


def _ledger_path():
    return _ledger_file(AUTH_CONFIG_LEDGER)


def _connect_lock(slug):
    """The connect lock for one toolkit (CONNECT_LOCK_PREFIX). Two slugs that
    sanitise alike share one, which only ever waits more, never less."""
    safe = re.sub(r"[^a-z0-9_-]", "_", str(slug or "").lower())[:80] or "_"
    return _ledger_file(CONNECT_LOCK_PREFIX + safe + ".lock")


def _ledger_shape_ok(blob):
    """The shape _write_ledger writes: a dict whose `configs` and `retry`,
    when present, are dicts, and whose every config entry is a dict."""
    if not isinstance(blob, dict):
        return False
    for k in ("configs", "retry"):
        if k in blob and not isinstance(blob[k], dict):
            return False
    return all(isinstance(e, dict) for e in (blob.get("configs") or {}).values())


#: One entry as _ledger_add writes it, found without parsing the file: what
#: is left to read in a ledger that was cut off part-way.
_LEDGER_ENTRY_RE = re.compile(r'"([A-Za-z0-9_.:~-]{1,200})"\s*:\s*\{\s*"toolkit"\s*:\s*"([A-Za-z0-9_.-]{1,200})"')


def _salvage_ids(text):
    """{auth config id: toolkit} out of a ledger this could not use: from its
    parse when it parses (`configs` as a dict, or a list of [id, toolkit]
    pairs or {"id", "toolkit"} objects), else entry by entry as _ledger_add
    writes them, which still finds every entry before a truncation."""
    try:
        blob = json.loads(text)
    except ValueError:
        return {m.group(1): m.group(2).lower() for m in _LEDGER_ENTRY_RE.finditer(text)}
    configs = blob.get("configs") if isinstance(blob, dict) else blob
    pairs = []
    if isinstance(configs, dict):
        pairs = [(k, v.get("toolkit") if isinstance(v, dict) else v) for k, v in configs.items()]
    elif isinstance(configs, list):
        for x in configs:
            if isinstance(x, (list, tuple)) and len(x) >= 2:
                pairs.append((x[0], x[1]))
            elif isinstance(x, dict):
                pairs.append((x.get("id"), x.get("toolkit")))
    out = {}
    for ac_id, slug in pairs:
        if isinstance(ac_id, str) and ac_id.strip() and isinstance(slug, str) and slug.strip():
            out.setdefault(ac_id.strip(), slug.strip().lower())
    return out


def _aside_files():
    """The set-aside ledgers (LEDGER_ASIDE_PREFIX), oldest first."""
    folder = os.path.dirname(_ledger_path())
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    return sorted(os.path.join(folder, n) for n in names if n.startswith(LEDGER_ASIDE_PREFIX))


def _salvaged(raw):
    """Ids salvaged from `raw` (the ledger as it is now) and from every
    set-aside ledger still kept."""
    out = {}
    for path in _aside_files():
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                out.update(_salvage_ids(fh.read(4 * 1024 * 1024)))
        except OSError:
            continue
    out.update(_salvage_ids(raw))
    return out


def _set_aside():
    """Move the ledger to a fresh `LEDGER_ASIDE_PREFIX.<UTC time>-<n>` and
    keep only the newest LEDGER_ASIDE_KEEP. A second damaged ledger used to
    overwrite the first one set aside."""
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    target = ""
    for n in range(1000):
        target = "%s.%s-%03d" % (_ledger_file(LEDGER_ASIDE_PREFIX), stamp, n)
        if not os.path.exists(target):
            break
    try:
        os.replace(_ledger_path(), target)
    except OSError:
        return
    for old in _aside_files()[:-LEDGER_ASIDE_KEEP]:
        try:
            os.unlink(old)
        except OSError:
            pass


def _load_ledger():
    """(blob, readable, raw). No file is an empty ledger. A file that does not
    parse, or parses into a shape this never writes, is NOT readable: the blob
    is then a fresh ledger holding the ids salvaged from it and from the
    ledgers set aside before it (marked `salvaged`), and `raw` is its text."""
    raw = None
    try:
        with open(_ledger_path(), encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except FileNotFoundError:
        pass
    except OSError:
        raw = ""
    blob, readable = {}, True
    if raw is not None:
        try:
            blob = json.loads(raw)
            readable = _ledger_shape_ok(blob)
        except ValueError:
            readable = False
    if not readable:
        blob = {}
    for k in ("configs", "retry"):
        if not isinstance(blob.get(k), dict):
            blob[k] = {}
    if not readable:
        for ac_id, slug in _salvaged(raw or "").items():
            blob["configs"].setdefault(ac_id, {"toolkit": slug, "made_at": 0.0, "salvaged": True})
    return blob, readable, raw


def _read_ledger():
    """The ledger, to read. Nothing is written, moved or forgotten here: a
    damaged file reads as the ids that can be salvaged from it."""
    return _load_ledger()[0]


@contextlib.contextmanager
def _ledger_edit():
    """The ledger to change, under LEDGER_LOCK; written back (only if it
    changed) when the block ends without an exception. A damaged one is set
    aside first (_set_aside), never overwritten, and the fresh one starts
    with every id salvaged from it and the ledgers set aside before, each
    toolkit with a retry — nothing records what was pending in a file that
    could not be read, so the sweep looks."""
    with _file_lock(_ledger_file(LEDGER_LOCK)):
        blob, readable, raw = _load_ledger()
        if not readable and raw is not None:
            _set_aside()
            for entry in blob["configs"].values():
                if entry.get("salvaged") and isinstance(entry.get("toolkit"), str):
                    blob["retry"].setdefault(entry["toolkit"], {
                        "at": 0.0, "misses": 0, "why": "recovered from a damaged record"})
        before = json.dumps(blob, sort_keys=True)
        yield blob
        if not readable or json.dumps(blob, sort_keys=True) != before:
            _write_ledger(blob)


def _write_ledger(blob):
    blob["README"] = ("The auth configs this Mac made at Composio. Alfie deletes one only "
                      "when it is listed here, once no connected account uses it.")
    _atomic_write_json(_ledger_path(), blob)


def _ledger_add(ac_id, slug, in_flight=False):
    with _ledger_edit() as blob:
        entry = {"toolkit": slug, "made_at": time.time()}
        if in_flight:
            entry["in_flight_at"] = entry["made_at"]
        blob["configs"][str(ac_id)] = entry


def _ledger_in_flight(ac_id, on):
    """Mark (or clear) a recorded config as one a key connect is using. One
    that is not recorded is not Alfie's to prune, so it needs no mark."""
    with _ledger_edit() as blob:
        entry = blob["configs"].get(str(ac_id))
        if isinstance(entry, dict):
            if on:
                entry["in_flight_at"] = time.time()
            else:
                entry.pop("in_flight_at", None)


def _in_flight(entry, now):
    at = entry.get("in_flight_at") if isinstance(entry, dict) else None
    # A mark a little in the future (the clock went back) still holds; one
    # further out than the window is no connect anybody is waiting on.
    return isinstance(at, (int, float)) and abs(now - at) < IN_FLIGHT_GRACE_S


def _ledger_ids(slug):
    return {i for i, e in _read_ledger()["configs"].items()
            if isinstance(e, dict) and e.get("toolkit") == slug}


def _retry_entry(value):
    """A retry record in either shape: {"at", "misses", "why"}, or the bare
    last-tried time 75f3b3bf wrote."""
    if isinstance(value, dict):
        at, misses = value.get("at"), value.get("misses")
        return {"at": float(at) if isinstance(at, (int, float)) else 0.0,
                "misses": misses if isinstance(misses, int) else 0,
                "why": str(value.get("why") or "")}
    return {"at": float(value) if isinstance(value, (int, float)) else 0.0, "misses": 0, "why": ""}


def _retry_later(slug, attempt_at, why, *, miss):
    """Leave the prune of `slug` pending. `miss` counts it towards
    PRUNE_MAX_MISSES, and only a definite answer from Composio may: a refusal
    (an HTTP error) or an answer that cannot be used. No answer — offline, a
    timeout, the sweep's budget spent — and a config a paste was using say
    nothing about whether the next try will work, and never count. Keyword
    only, with no default: counting by default is how three refreshes on a
    laptop without a network gave the cleanup up for good."""
    with _ledger_edit() as blob:
        entry = _retry_entry(blob["retry"].get(slug))
        entry["at"] = attempt_at
        entry["why"] = why
        if miss:
            entry["misses"] += 1
        blob["retry"][slug] = entry


def _retry_clear(slug):
    """Nothing is pending for `slug` any more."""
    if slug in _read_ledger()["retry"]:
        with _ledger_edit() as blob:
            blob["retry"].pop(slug, None)


def _retry_words(slug):
    """What a person is told about the retry of `slug`'s cleanup. Names the
    button that exists: a row with cleanup pending keeps Disconnect, connected
    or not (rows() `cleanup_pending`; ConnectionDetail.canDisconnect)."""
    retry = _read_ledger()["retry"]
    entry = _retry_entry(retry.get(slug))
    if slug in retry and entry["misses"] >= PRUNE_MAX_MISSES:
        return ("Composio refused %d times in a row (%s), so Alfie has stopped retrying on its own — "
                "press Disconnect on it in Connections to try again"
                % (entry["misses"], entry["why"] or "no reason recorded"))
    if slug in retry and OUT_OF_TIME in entry["why"]:
        return "%s, so Alfie will try again" % OUT_OF_TIME
    return "Alfie will try again"


def _list_all(path):
    """(every item, "", 200) of a paged list read, following `next_cursor` for
    at most LIST_MAX_PAGES pages; (None, why, status) when a page is not
    answered or not usable, or the pages do not end — a caller deciding what
    to delete must not act on a part. `status` is 0 when Composio did not
    answer and otherwise what it answered (200 for pages that do not end), so
    a caller can tell "no answer" from "refused"."""
    items, cursor = [], ""
    for _ in range(LIST_MAX_PAGES):
        status, body = call("GET", path + ("&cursor=" + urllib.parse.quote(cursor, safe="")
                                           if cursor else ""))
        if status != 200 or not isinstance(body, dict) or not isinstance(body.get("items"), list):
            if status:
                why = "HTTP %s" % status
            elif isinstance(body, dict) and body.get("error") == OUT_OF_TIME:
                why = OUT_OF_TIME
            else:
                why = "no answer"
            return None, why, status
        items += body["items"]
        cursor = str(body.get("next_cursor") or "")
        if not cursor:
            return items, "", 200
    return None, "more than %d pages" % LIST_MAX_PAGES, 200


def _moe_auth_configs(slug, mine):
    """(([config], {every id listed}), "", 200) for the configs in `mine` that
    are still named `moe-<slug>`, for `slug`, and not Composio-managed; (None,
    why, status) when the list could not be read to its end (see _list_all).
    Disabled configs are asked for too (`show_disabled`), or a disabled one
    of Alfie's would read as gone and be dropped from the ledger with its
    values still at Composio."""
    items, why, status = _list_all("/api/v3/auth_configs?toolkit_slug=%s&show_disabled=true&limit=50"
                                   % urllib.parse.quote(slug, safe=""))
    if items is None:
        return None, "the auth config list could not be read (%s)" % why, status
    out, seen = [], set()
    for ac in items:
        if not isinstance(ac, dict) or not ac.get("id"):
            continue
        seen.add(str(ac["id"]))
        if str(ac["id"]) not in mine or ac.get("is_composio_managed"):
            continue
        if str(ac.get("name") or "") != "moe-%s" % slug:
            continue
        if str(((ac.get("toolkit") or {}).get("slug")) or slug).lower() != slug:
            continue
        out.append(ac)
    return (out, seen), "", 200


def _auth_config_uses(slug):
    """({auth_config_id: accounts using it}, "", 200) across the WHOLE project
    — not just this Mac's user, because an auth config is project-wide and
    another person's account can hang off one Alfie made. Every page is read;
    (None, why, status) when the answer is incomplete (see _list_all), which
    callers must treat as "everything is in use"."""
    items, why, status = _list_all("/api/v3/connected_accounts?toolkit_slugs=%s&limit=100"
                                   % urllib.parse.quote(slug, safe=""))
    if items is None:
        return None, "the account list could not be read (%s)" % why, status
    uses = {}
    for a in items:
        if not isinstance(a, dict):
            continue
        if str(((a.get("toolkit") or {}).get("slug")) or "").lower() != slug:
            continue
        ac_id = str((a.get("auth_config") or {}).get("id") or "")
        if ac_id:
            uses.setdefault(ac_id, set()).add(str(a.get("id") or ""))
    return uses, "", 200


def prune_auth_configs(slug, keep=(), just_deleted=(), attempt_at=0):
    """Delete the auth configs this Mac made for `slug` that no connected
    account uses. Returns (deleted, failed, incomplete).

    Why. Every key connect for a service that takes a value when its auth
    config is made (a client secret, a per-person token) mints a config
    holding that value — and Disconnect used to remove only the accounts, so
    the value stayed at Composio, under Alfie's name, after the person had been
    told it was forgotten.

    Which. Only a config whose id is in this Mac's ledger (AUTH_CONFIG_LEDGER,
    written by ensure_auth_config the moment Composio answers), that is still
    named `moe-<slug>` and is not Composio-managed. The name alone proves
    nothing: anyone on the project can make a config called `moe-<slug>` in
    the dashboard. Composio's auth config does carry `created_by`, "the
    identifier of the user who created the auth config" (AC_LIST_DOC) — but
    that is the project member behind the API key, the same for a config
    Alfie made and one a person made with that key, so it cannot tell them
    apart either.

    When. `DELETE /api/v3/auth_configs/<id>` (AC_DELETE_DOC, read 2026-09-14)
    is permanent ("This operation cannot be undone"), answers 200
    `{success}` or 400/401/404/500, and takes `revoke_on_delete=true` to
    also revoke the upstream credentials of every connection using the
    config. It documents no refusal to delete a config that is in use, and
    does not say what becomes of an account on one deleted without
    revoking. So this assumes the worst and never deletes a config in use: a
    config goes only when two readings agree it is unused — no account in
    the project's list (every page) names it, AND Composio's own
    `no_of_connections`, less the accounts this run just deleted, is not
    above zero (the count is what catches an account the list did not
    return). It never passes `revoke_on_delete`: nothing it deletes has a
    connection to revoke. Either reading unreadable or unfinished → nothing
    is deleted.

    Not under a paste. A key connect on this Mac holds its toolkit's connect
    lock (_connect_lock) from choosing its config until its account exists; a
    prune of that toolkit that cannot take it at once deletes nothing and
    leaves the toolkit pending. And a config marked in flight within
    IN_FLIGHT_GRACE_S is kept whatever the lock says. Without both, a refresh
    landing between a paste's config and its account deleted the config, and
    the paste failed "no such auth config".

    Again. A delete that failed, or a read that could not finish, leaves
    `retry` set for the toolkit in the ledger; `list` — which the app runs
    whenever it refreshes the connections screen — tries again
    (sweep_pending_prunes) until Composio has REFUSED PRUNE_MAX_MISSES tries
    in a row (no answer never counts: _retry_later), as do Disconnect on a
    service that is no longer connected, and every key connect for it.
    `attempt_at` is when this try counts as made (0 = let the next sweep try
    at once).
    """
    mine = _ledger_ids(slug)
    if not mine:
        # Nothing of Moe's recorded for it, so nothing left to retry either.
        _retry_clear(slug)
        return 0, 0, False
    with _file_lock(_connect_lock(slug), wait=0) as free:
        if not free:
            _retry_later(slug, attempt_at, "a key connect on this Mac was in progress", miss=False)
            return 0, 0, True
        return _prune(slug, mine, keep, just_deleted, attempt_at)


def _prune(slug, mine, keep, just_deleted, attempt_at):
    listed, why, status = _moe_auth_configs(slug, mine)
    uses = None
    if listed is not None:
        uses, why, status = _auth_config_uses(slug)
    if listed is None or uses is None:
        _retry_later(slug, attempt_at, why, miss=bool(status))
        return 0, 0, True
    configs, seen = listed
    recorded = _read_ledger()["configs"]
    now = time.time()
    gone = set(just_deleted)
    # A recorded id that a complete list no longer has is gone already.
    dropped = mine - seen
    deleted = failed = held = 0
    refused = []
    for ac in configs:
        ac_id = str(ac["id"])
        if ac_id in keep or (uses.get(ac_id) or set()) - gone:
            continue
        count = ac.get("no_of_connections")
        if isinstance(count, int) and count - len((uses.get(ac_id) or set()) & gone) > 0:
            continue
        if _in_flight(recorded.get(ac_id), now):
            held += 1
            continue
        status, _ = call("DELETE", "/api/v3/auth_configs/" + urllib.parse.quote(ac_id, safe=""))
        if status in (200, 204):
            deleted += 1
            dropped.add(ac_id)
        elif status == 404:
            dropped.add(ac_id)
        else:
            failed += 1
            refused.append(status)
    with _ledger_edit() as blob:
        for ac_id in dropped:
            blob["configs"].pop(ac_id, None)
        if not failed and not held:
            blob["retry"].pop(slug, None)
    if failed:
        _retry_later(slug, attempt_at, "Composio did not delete %d config%s (%s)" % (
            failed, "" if failed == 1 else "s",
            ", ".join(sorted({("HTTP %s" % s) if s else "no answer" for s in refused}))
            + ("; %s" % OUT_OF_TIME if _DEADLINE is not None and _DEADLINE - time.monotonic() <= 0.1 else "")),
            miss=any(refused))
    elif held:
        _retry_later(slug, attempt_at, "a key connect was using a config", miss=False)
    return deleted, failed, held > 0


def sweep_pending_prunes(now=None, budget=SWEEP_BUDGET_S):
    """Try again, at most every PRUNE_RETRY_S per toolkit, the prunes that
    could not finish. Returns the toolkits it reached Composio for. Costs
    nothing — no request, no lock, no write — when none is pending, which is
    almost always.

    Stamped first, one toolkit at a time. A toolkit's "last tried" is written
    just BEFORE its own requests: a `list` its caller killed mid-sweep used
    to leave no stamp, so every later refresh swept again. And bounded: every
    request shares `budget` seconds (call()'s _DEADLINE), so the sweep cannot
    eat the timeout `list` runs under. A toolkit the budget never reached is
    not stamped, and one whose try sent nothing before the budget ran out has
    its stamp put back: neither was tried, so both stay due for the next
    refresh. (They used to be stamped all at once, up front, so five pending
    toolkits and a slow Composio pushed the last three ten minutes out
    without a request — and counted each as a failed try.)

    Never beside a paste: a toolkit whose connect lock a key connect holds is
    skipped — nothing sent, nothing stamped. Other toolkits go on.

    A stamp in the future — the clock went back — counts as tried now, and is
    brought back to now; `0 < now - last` read it as never tried, and a sweep
    ran on every refresh.

    Composio refusing PRUNE_MAX_MISSES tries in a row, and it stops (see
    _retry_later for what counts).
    """
    now = time.time() if now is None else now
    pending = _read_ledger()["retry"]
    if not pending:
        return []
    tried = []
    with _budget(budget) as deadline:
        for slug in sorted(pending):
            if time.monotonic() >= deadline - 0.05:
                break
            seen = _retry_entry(pending[slug])
            if seen["misses"] >= PRUNE_MAX_MISSES or (
                    0 < seen["at"] <= now and now - seen["at"] < PRUNE_RETRY_S):
                continue
            with _file_lock(_connect_lock(slug), wait=0) as free:
                if not free:
                    continue
                due, before = False, 0.0
                with _ledger_edit() as blob:
                    if slug in blob["retry"]:
                        entry = _retry_entry(blob["retry"][slug])
                        if entry["misses"] >= PRUNE_MAX_MISSES:
                            pass
                        elif entry["at"] > now:
                            entry["at"] = now
                            blob["retry"][slug] = entry
                        elif entry["at"] > 0 and now - entry["at"] < PRUNE_RETRY_S:
                            pass
                        else:
                            before, entry["at"], due = entry["at"], now, True
                            blob["retry"][slug] = entry
                if not due:
                    continue
                sent = _SENT[0]
                prune_auth_configs(slug, attempt_at=now)
                if _SENT[0] != sent:
                    tried.append(slug)
                    continue
                with _ledger_edit() as blob:
                    if slug in blob["retry"]:
                        entry = _retry_entry(blob["retry"][slug])
                        if entry["at"] == now:
                            entry["at"] = before
                            blob["retry"][slug] = entry
    return tried


def connect_with_key(slug, another=False):
    """Create the connected account from what is on stdin. Prints
    "connected" and exits 0; never prints, logs or argv-passes a value.

    `POST /api/v3/connected_accounts` with
    `connection.state = {authScheme, val: {status: ACTIVE, <fields>}}` is the
    documented shape for a credential the person supplies (Composio's
    reference for that route, read 2026-09-11; not yet exercised against the
    live API from this repo — scripts/fake-composio.py serves the same shape).
    The account is ACTIVE on creation: there is no redirect and nothing to
    wait for, which is why the app's flow for these rows ends when this
    exits rather than polling for a sign-in.
    """
    if not another and live_accounts(connected_accounts().get(slug) or []):
        print("already connected")
        return 0
    info = toolkit_key_fields(slug)
    if info.get("error"):
        print("✗ %s" % info["error"], file=sys.stderr)
        return 1
    if not info["scheme"]:
        print("✗ %s takes no key — %s" % (
            slug, "it signs in through a link; use connect without --key" if info["managed"]
            else "Composio lists no way to authenticate it that a person can paste"),
            file=sys.stderr)
        return 1
    pasted = _read_pasted(sys.stdin)
    values = {"auth_config": {}, "account": {}}
    missing = []
    for f in info["fields"]:
        v = pasted.get(f["name"].lower(), "")
        if not v:
            missing.append(f["label"])
            continue
        values[f["stage"]][f["name"]] = v
    if missing:
        # Names only. The values that WERE given are not mentioned, in any form.
        print("✗ %s is required." % ", ".join(missing), file=sys.stderr)
        return 2
    try:
        who = user_id(create=True)
    except NoIdentity as exc:
        print("✗ %s" % exc, file=sys.stderr)
        return 1
    # From choosing its auth config until its account exists, a paste holds
    # this toolkit's connect lock and its config carries an in-flight mark. A
    # refresh that swept a pending prune in that window deleted the config
    # the paste had just made, and the account post failed "no such auth
    # config". The lock keeps a sweep or Disconnect of THIS service on this
    # Mac off it while this process lives (other services are not held up);
    # the mark (IN_FLIGHT_GRACE_S) holds even for a prune that did not ask
    # for the lock. Not getting the lock in CONNECT_LOCK_WAIT_S (a slow
    # Disconnect of the same service holding it) goes ahead on the mark alone.
    status, body = 0, None
    with _file_lock(_connect_lock(slug), wait=CONNECT_LOCK_WAIT_S):
        ac_id, why = ensure_auth_config(slug, info["scheme"], values["auth_config"])
        if ac_id:
            val = {"status": "ACTIVE"}
            val.update(values["account"])
            try:
                status, body = call("POST", "/api/v3/connected_accounts", {
                    "auth_config": {"id": ac_id},
                    "connection": {
                        "user_id": who,
                        "state": {"authScheme": info["scheme"], "val": val},
                    },
                })
            finally:
                _ledger_in_flight(ac_id, False)
    if not ac_id:
        print("✗ %s" % why, file=sys.stderr)
        # Nothing was made for this paste; an earlier one may have left a
        # config of Moe's behind (a Disconnect whose cleanup failed), and
        # every key connect for the service is a chance to clear it.
        prune_auth_configs(slug)
        return 1
    if status not in (200, 201) or not isinstance(body, dict) or not body.get("id"):
        # Composio's error text can quote the request back: every value
        # given is taken out before the text is cut, never after.
        why = _refusal(body, status, list(values["account"].items()) + list(values["auth_config"].items()))
        print("✗ Composio did not accept the key for %s: %s" % (slug, why), file=sys.stderr)
        # A config made for this paste holds its creation values (if any)
        # and now has no account: a refused paste must not leave it behind.
        # One this Mac's other account still uses is kept.
        prune_auth_configs(slug)
        return 1
    state = str(((body.get("connectionData") or {}).get("val") or {}).get("status")
                or body.get("status") or "ACTIVE").upper()
    # A service that takes values at auth-config creation gets a fresh
    # config per paste (they are this person's values, and Composio may hide
    # them on read, so an old config cannot be checked for a match). The one
    # it superseded — a replaced paste, a disconnect that failed half-way —
    # is deleted once nothing uses it; one a second account (--another)
    # still uses is kept, and so is the one this paste is on.
    prune_auth_configs(slug, keep=(ac_id,))
    if state == LIVE:
        # Without this the account exists and no tool can use it: the
        # session reads Composio's own config for the service, not Moe's.
        sync_session_auth_configs()
        print("connected")
        return 0
    print("sign-in started but not finished (%s)" % state.lower(), file=sys.stderr)
    return 1


def cmd_disconnect(argv):
    if not argv:
        print("disconnect needs a service", file=sys.stderr)
        return 2
    slug = argv[0].split("/")[-1].lower()
    # One budget for all of it, inside the app's 60 s: a Composio that hangs
    # leaves the cleanup pending and says so, rather than the app killing
    # Disconnect with nothing said.
    with _budget(DISCONNECT_BUDGET_S):
        return _disconnect(slug, argv)


#: Said when Composio refuses this Mac's key the account list (401/403): a
#: legacy scoped key is write-only on accounts (docs/COMPOSIO.md, "scoped
#: key"), so no "try again" will ever work, and nothing in the app hands the
#: Mac a different key.
KEY_CANNOT_MANAGE = ("Alfie's key for Composio on this Mac isn't allowed to manage your accounts there "
                     "(HTTP %s), so nothing was disconnected — remove %s at composio.dev under "
                     "Connected accounts, or tell Alfie this is broken so it can be fixed")


def _disconnect_refused_list(slug, argv, status):
    """Disconnect when Composio refused the account list (401/403). The
    session's own toolkit view still names the account it uses for `slug`,
    with its user id, and deleting by that id needs no list — so that one
    account goes when it is this Mac's (and the one asked for, if one was).
    Otherwise, or when the delete is refused too, KEY_CANNOT_MANAGE: saying
    "try again" here promised something no retry could do."""
    info = session_toolkit_view().get(slug) or {}
    acct = info.get("account") if isinstance(info.get("account"), dict) else {}
    ca_id = str(acct.get("id") or "")
    try:
        mine = user_id() if ca_id else ""
    except NoIdentity:
        mine = ""
    if ca_id and mine and str(acct.get("user_id") or "") == mine and (len(argv) < 2 or argv[1] == ca_id):
        st, _ = call("DELETE", "/api/v3/connected_accounts/" + urllib.parse.quote(ca_id, safe=""))
        if st in (200, 204):
            _, ac_failed, incomplete = prune_auth_configs(slug, just_deleted=[ca_id])
            if ac_failed or (incomplete and _ledger_ids(slug)):
                print("disconnected %s (1 account), but could not remove %s of Alfie's settings for %s at "
                      "Composio yet (%s)" % (slug, ac_failed or "some", slug, _retry_words(slug)),
                      file=sys.stderr)
                return 1
            print("disconnected %s (1 account)" % slug)
            return 0
        if st not in (401, 403):
            print("couldn't remove your %s account at Composio just now (%s) — nothing was "
                  "disconnected; try again" % (slug, ("HTTP %s" % st) if st else "no answer"),
                  file=sys.stderr)
            return 1
        status = st
    print(KEY_CANNOT_MANAGE % (status, slug), file=sys.stderr)
    return 1


def _disconnect(slug, argv):
    try:
        accts = connected_accounts(strict=True).get(slug) or []
    except AccountsUnreadable as exc:
        if exc.status in (401, 403):
            return _disconnect_refused_list(slug, argv, exc.status)
        # Not "not connected": nothing is known. This used to say "not
        # connected" about a live service, then prune — which on a key that
        # may not read accounts can never finish, so it retried for ever.
        print("couldn't read your Composio accounts just now (%s) — nothing was disconnected; "
              "try again" % exc, file=sys.stderr)
        return 1
    # An explicit account id disconnects exactly that one; without it every
    # account for the service goes, including the dead ones — leaving those
    # behind is what made the screen say "expired" forever after someone had
    # already reconnected.
    wanted = [a for a in accts if a["id"] == argv[1]] if len(argv) > 1 else accts
    if not wanted:
        # Two different situations, and saying the wrong one during a
        # destructive action is the worst place to be vague: "not connected"
        # about a service that plainly IS connected reads as a bug in the
        # connection rather than in the id.
        if len(argv) > 1 and accts:
            print("no account %s on %s — nothing was removed" % (argv[1], slug),
                  file=sys.stderr)
            return 1
        # Not connected — but a Disconnect whose config delete failed ends
        # exactly here: the accounts went, so the row reads "not connected",
        # and Moe's config (with what was pasted into it) is still at
        # Composio. Disconnecting again is how a person retries, so it must
        # not stop at "not connected".
        deleted, ac_failed, incomplete = prune_auth_configs(slug)
        if ac_failed or (incomplete and _ledger_ids(slug)):
            print("%s is not connected, but %s of Alfie's settings for it are still at Composio and "
                  "could not be removed yet — %s" % (
                      slug, ac_failed or "some", _retry_words(slug)), file=sys.stderr)
            return 1
        if deleted:
            print("%s is not connected — removed %d leftover setting%s of Alfie's for it at Composio"
                  % (slug, deleted, "" if deleted == 1 else "s"))
            return 0
        print("%s is not connected" % slug)
        return 0
    gone, failed = 0, 0
    deleted_ids = []
    for a in wanted:
        status, _ = call("DELETE", "/api/v3/connected_accounts/" + urllib.parse.quote(str(a["id"]), safe=""))
        if status in (200, 204):
            gone += 1
            deleted_ids.append(a["id"])
        else:
            failed += 1
    # "Disconnect forgets it there": the accounts are half of what a pasted
    # key left at Composio. The auth configs Moe made for the service can
    # hold a creation value too (a client secret, a token) — those go as
    # well, once no account left anywhere in the project uses them.
    _, ac_failed, incomplete = prune_auth_configs(slug, just_deleted=deleted_ids)
    # Both, when both: an account that could not be removed is the more
    # important half, and used to vanish behind the settings message.
    problems = []
    if failed:
        problems.append("could not remove %d account%s" % (failed, "" if failed == 1 else "s"))
    if ac_failed or (incomplete and len(wanted) == len(accts) and _ledger_ids(slug)):
        problems.append("could not remove %s of Alfie's settings for %s at Composio yet "
                        "(%s)" % (ac_failed or "some", slug, _retry_words(slug)))
    if problems:
        print("disconnected %d, but %s" % (gone, "; and ".join(problems)), file=sys.stderr)
        return 1
    print("disconnected %s (%d account%s)" % (slug, gone, "" if gone == 1 else "s"))
    return 0


def cmd_wait(argv):
    """Block until the service goes ACTIVE, or the deadline passes.

    The app's connect flow keeps a script running while it shows "approve
    this in the page that opened", and treats the exit as the answer. A
    connector that printed a URL and exited immediately would look like it
    had finished before the person had even switched to the browser.
    """
    if not argv:
        print("wait needs a service", file=sys.stderr)
        return 2
    slug = argv[0].split("/")[-1].lower()
    try:
        deadline = float(argv[1]) if len(argv) > 1 else 300.0
    except ValueError:
        deadline = 300.0
    import time
    end = time.time() + deadline
    while time.time() < end:
        accts = connected_accounts().get(slug) or []
        live = live_accounts(accts)
        if live:
            # The moment it is live, ask the service who it is. This is the
            # only point where the answer is unambiguous: the account that
            # just went ACTIVE is the one the person was signing in to.
            target = live[0]
            if not target["who"]:
                who = name_account_from_service(slug, target["id"])
                print("connected as %s" % who if who else "connected")
            else:
                print("connected as %s" % target["who"])
            return 0
        time.sleep(3)
    print("timed out waiting for %s" % slug, file=sys.stderr)
    return 1


def cmd_name(argv):
    """Give an account a name, so two of the same service can be told apart.

    Composio records no identity of its own — no email, and the OIDC token
    comes back empty — so the name has to come from the person. It is stored
    as Composio's `alias`, which is writable and reads back, so the name
    lives with the account rather than in a file on one Mac that a second
    device would never see.
    """
    # `name <service> <label>` names the live account; `--account <id>` names
    # exactly one, which is what the app passes when a service has several and
    # the person picked one. Without the id there is nothing to distinguish
    # two accounts by, and naming the wrong one is worse than not naming it.
    argv = list(argv)
    account_id = ""
    if "--account" in argv:
        i = argv.index("--account")
        if i + 1 >= len(argv):
            print("--account needs an id", file=sys.stderr)
            return 2
        account_id = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) < 2:
        print("name needs a service and a name", file=sys.stderr)
        return 2
    slug = argv[0].split("/")[-1].lower()
    label = " ".join(argv[1:]).strip()
    accts = connected_accounts().get(slug) or []
    if not accts:
        print("%s is not connected" % slug, file=sys.stderr)
        return 1
    if account_id:
        hit = [a for a in accts if a["id"] == account_id]
        if not hit:
            print("no account %s on %s — nothing was renamed" % (account_id, slug),
                  file=sys.stderr)
            return 1
        target = hit[0]
    else:
        # Without an explicit id, name the live one — naming a dead account is
        # almost never what someone means. Refuse when that is ambiguous
        # rather than picking: the caller has to say which.
        live = live_accounts(accts)
        if len(live) > 1:
            print("%s has %d accounts — say which with --account <id>"
                  % (slug, len(live)), file=sys.stderr)
            return 2
        target = (live or accts)[0]
    status, _ = call("PATCH", "/api/v3/connected_accounts/" + urllib.parse.quote(str(target["id"]), safe=""),
                     {"alias": label})
    if status != 200:
        print("could not name it (HTTP %s)" % status, file=sys.stderr)
        return 1
    print("named %s account: %s" % (slug, label))
    return 0


def cmd_identify(argv):
    """Fill in the names of accounts that do not have one yet.

    With one account per service this is exact. With several signed in to the
    same service the proxy answers for whichever Composio resolves, so this
    names only services that have exactly ONE unnamed account — guessing
    which of two accounts an address belongs to would put the wrong name on a
    row, which is worse than no name at all.
    """
    slugs = [a.split("/")[-1].lower() for a in argv] or list(connected_accounts().keys())
    named = 0
    for slug in slugs:
        live = live_accounts(connected_accounts().get(slug) or [])
        unnamed = [a for a in live if not a["who"]]
        if len(live) != 1 or not unnamed:
            if len(live) > 1 and unnamed:
                print("%-16s %d accounts — name these yourself, the service "
                      "cannot say which is which" % (slug, len(live)))
            continue
        who = name_account_from_service(slug, unnamed[0]["id"])
        if who:
            print("%-16s %s" % (slug, who))
            named += 1
        else:
            print("%-16s the service did not say" % slug)
    return 0 if named or not slugs else 1


def cmd_manifest(argv):
    slug = (argv[0].split("/")[-1].lower() if argv else "")
    meta = toolkit_meta([slug]).get(slug) or {}
    print("name=composio/%s" % slug)
    print("label=%s" % (meta.get("label") or slug))
    print("verbs=status connect disconnect")
    print("auth=broker")
    print("runs_in=both")
    print("cost=cheap")
    return 0


def cmd_session_url(argv):
    """Print the MCP URL of this Mac's Tool Router session; create it first
    if there is none. `configure-hermes.py` calls this once, when `.env` has a
    Composio key and no URL, and writes what it prints as COMPOSIO_MCP_URL.

    Why the session is made HERE and not by hand or by the edge. A session
    is Composio's per-user handle: it carries `config.user_id`, and every
    connection the person makes through it belongs to that user. The user id
    is this Mac's `composio-identity.json`, minted once and never re-derived
    (see `local_identity`), so the session has to be created by the thing
    that holds that id. The edge never sees it; the project key it minted is
    what authorises the call.

    Idempotent from the outside: a URL already in `.env` is printed as-is and
    nothing is created. A second session for one user would be harmless to
    Composio and confusing to the person (two URLs, one of them stale), which
    is why this reads before it writes.

    Measured on 2026-09-06 against the live API (a GET of the existing
    session, keys only): a session object carries `session_id`, `mcp: {type,
    url}` and `config: {user_id, toolkits, preload, …}`, and `mcp.url` is
    `https://backend.composio.dev/tool_router/<session_id>/mcp` — the shape
    SESSION_RE already expects. The CREATE call's response is assumed to be the
    same object (Composio's reference lists POST /api/v3.1/tool_router/session
    and shows no separate schema); if it is not, the fallback composes the URL
    from `session_id`, and if neither is there this fails loudly rather than
    writing a URL nothing can dial.

    Exit 0 and the URL on stdout; 3 when this Mac has no Composio key at all;
    1 when Composio refused or answered in a shape this does not know.
    """
    existing = (_env_file().get("COMPOSIO_MCP_URL")
                or os.environ.get("COMPOSIO_MCP_URL") or "").strip()
    m = SESSION_RE.search(existing)
    if m and "--multi-account" in argv and api_key():
        # Once per Mac (configure-hermes.py records the answer): a session
        # made before 2026-09-24 preloads, and cannot hold two accounts of a
        # service. Connections belong to the USER, not the session, so a new
        # one keeps every connection; the old one is left alive, unused.
        multi = session_is_multi_account(m.group(1))
        if multi is None:
            print("could not read the Composio session to check it; left as it is", file=sys.stderr)
            return 1
        if multi:
            print(existing)
            return 0
        existing = ""
    if SESSION_RE.search(existing):
        print(existing)
        return 0
    if not api_key():
        print("no Composio key on this Mac — nothing to make a session with", file=sys.stderr)
        return 3
    try:
        who = local_identity(create=True)
    except NoIdentity as exc:
        print(str(exc), file=sys.stderr)
        return 1
    # `workbench.enable: false`, always. The default is TRUE, and what it
    # turns on is a sudo Linux sandbox with open outbound network, billed to
    # us and creatable by anyone holding the key (CLOUD-PLAN §18.23c; the
    # rule is CLOUD-REMAINING D3). Moe never uses it: the brain's hands are
    # its own tools, on the Mac or on the away machine. The key is `enable`,
    # not `enabled` — checked against Composio's reference on 2026-09-11 —
    # and scripts/fake-composio.py refuses a create that lacks it, so a
    # session-creation path added later that forgets this goes red in
    # scripts/test-composio-session.sh rather than quietly renting sandboxes.
    status, body = call("POST", "/api/v3.1/tool_router/session",
                        {"user_id": who, "multi_account": {"enable": True},
                         "workbench": {"enable": False}})
    if status not in (200, 201) or not isinstance(body, dict):
        why = body.get("error") if isinstance(body, dict) else str(body)[:200]
        print("could not create a Composio session: %s" % (why or "HTTP %s" % status),
              file=sys.stderr)
        return 1
    mcp = body.get("mcp") if isinstance(body.get("mcp"), dict) else {}
    url = str(mcp.get("url") or "").strip()
    sid = str(body.get("session_id") or body.get("id") or "").strip()
    if not SESSION_RE.search(url) and sid.startswith("trs_"):
        url = BASE + "/tool_router/" + sid + "/mcp"
    # Through the edge (2026-10-19), the session is dialled at the proxy, not
    # at whatever host Composio names: the token in .env is no key there.
    m_sid = SESSION_RE.search(url)
    if BASE != DIRECT_BASE and m_sid:
        url = BASE + "/tool_router/" + m_sid.group(1) + "/mcp"
    if not SESSION_RE.search(url):
        print("Composio created a session but answered with no MCP URL this Mac recognises "
              "(keys: %s)" % ",".join(sorted(body.keys())), file=sys.stderr)
        return 1
    print(url)
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    verb, rest = argv[0], argv[1:]
    table = {
        "list": cmd_list, "search": cmd_search, "status": cmd_status,
        "connect": cmd_connect, "disconnect": cmd_disconnect, "wait": cmd_wait,
        "name": cmd_name, "identify": cmd_identify, "preload": cmd_preload,
        "fields": cmd_fields, "tools": cmd_tools,
        "remove": cmd_disconnect, "manifest": cmd_manifest,
        "session-url": cmd_session_url, "sweep": cmd_sweep,
        "sync-session": cmd_sync_session,
    }
    fn = table.get(verb)
    if not fn:
        print("unknown verb %r" % verb, file=sys.stderr)
        return 2
    return fn(rest)


if __name__ == "__main__":
    import urllib.parse  # noqa: E402  (only cmd_search needs it)
    sys.exit(main(sys.argv[1:]))

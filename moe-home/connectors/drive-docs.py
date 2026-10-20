#!/usr/bin/env python3
"""Google Docs, Sheets and Slides — the contents, for the documents the user
picked themselves.

Why this exists: Drive for Desktop syncs a native Google file as a `.gdoc` /
`.gsheet` / `.gslides` stub — a few hundred bytes of JSON holding a URL. The
`drive` connector surfaces the name and the link and says plainly that it
never read the document, because it cannot. This connector closes that one
gap, and only that one.

Why it does not reintroduce the problem that killed OAuth here (see
docs/GOOGLE-WITHOUT-OAUTH.md): the scope is
`https://www.googleapis.com/auth/drive.file` and nothing else. Google
classifies it non-sensitive — no unverified-app warning screen, no
verification review, no CASA assessment, no 100-user cap. It grants access
to files the user chose in Google's own picker (or that the app created),
never to the Drive. So the reach of this connector is exactly the list in
`~/.moe/connectors/drive-docs-files.json`, which the user built by clicking.

  drive-docs.py status
  drive-docs.py pull
  drive-docs.py crawl [--since DAYS] [--max-bytes N]

The refresh token lives in the macOS Keychain (`moe-google-docs`), never in
a file. An access token is fetched fresh on every run and kept only in
memory: refreshing *is* the status check, so "ok" cannot mean "we still have
a token that Google revoked last week".

Python 3.9, stdlib only — no google client libraries anywhere. HTTP is
spoken directly, which is a few dozen lines and no dependency.
"""
import calendar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MOE = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
FILES_PATH = os.path.join(MOE, "connectors", "drive-docs-files.json")
KEYCHAIN_SERVICE = "moe-google-docs"
# drive.file gives no identity scope (it cannot be combined with one), so
# there is no email to key the Keychain item on. One item, one label.
KEYCHAIN_ACCOUNT = "refresh-token"

# Overridable so the tests can point every network call at a fake server on
# localhost; nothing else in here is a URL.
DRIVE_API = os.environ.get("MOE_GOOGLE_DRIVE_API", "https://www.googleapis.com/drive/v3")
TOKEN_URI_OVERRIDE = os.environ.get("MOE_GOOGLE_TOKEN_URI", "")

HTTP_TIMEOUT = 30
MAX_FILES = 200             # a picked list is small by construction
EXPORT_LIMIT = 10 * 1024 * 1024   # Google's documented files.export ceiling
MEDIA_LIMIT = 2 * 1024 * 1024     # an uploaded file we will read via alt=media


# ── Foreign text ──────────────────────────────────────────────────────────
# A document's name and its contents are written by whoever shared it, and
# both end up in a markdown file the model reads. Same rules as
# connectors/hermeslib.py one_line() and drive.sh: no control characters, no
# markdown structure, no clickable links.
_MD_LEADING = re.compile(r"^(?=[#>\-+*|`]|\d+[.)]\s)")
_MD_LINK = re.compile(r"\[([^\]]*)\]\(([^)]*)\)")


def one_line(text, limit=120):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    text = re.sub(r"\s+", " ", text).strip()
    text = _MD_LINK.sub(r"\1 (\2)", text)
    text = _MD_LEADING.sub("\\\\", text, count=1)
    return text[:limit]


def block(text, max_lines=400, limit=400):
    """A document's text, line by line, each one neutralised. This is the
    whole reason the connector exists — the contents *are* the payload — so
    a '### heading' or a code fence inside someone's Doc must not become
    structure in the file Moe reads."""
    out = []
    for raw in str(text or "").splitlines():
        line = one_line(raw, limit)
        if not line:
            continue
        out.append(line)
        if len(out) >= max_lines:
            out.append("…")
            break
    return "\n".join(out)


# ── Configuration ─────────────────────────────────────────────────────────

def client_json_path():
    """The OAuth client shipped with the product. Same lookup order as
    scripts/connect-drive-docs.sh, plus the checkout's copy so this works
    from a git clone. None when the product was built without one — then the
    answer is "not configured", not a traceback. (build.sh does not copy the
    file into Memoe.app yet, so that is what a shipped build reports.)"""
    explicit = os.environ.get("MOE_GOOGLE_CLIENT_JSON")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    here = os.path.dirname(os.path.abspath(__file__))
    for path in (os.path.join(MOE, "google-client.json"),
                 "/Applications/Memoe.app/Contents/Resources/google-client.json",
                 os.path.join(here, "..", "..", "Resources", "google-client.json")):
        if os.path.isfile(path):
            return os.path.normpath(path)
    return None


def client_config():
    """(client_id, client_secret, token_uri) or None. The secret is a
    non-confidential installed-app secret (Google's own native-app guidance
    says a desktop client cannot keep one), but it is still never printed,
    never logged and never put on argv."""
    path = client_json_path()
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    section = data.get("installed") or data.get("web") or {}
    client_id = section.get("client_id") or ""
    if not client_id or client_id.startswith("REPLACE-ME"):
        return None
    token_uri = TOKEN_URI_OVERRIDE or section.get("token_uri") or "https://oauth2.googleapis.com/token"
    return client_id, section.get("client_secret") or "", token_uri


def load_files():
    """The picked ids, in the order they were picked. Anything that is not a
    plausible Drive file id is dropped: this list becomes a URL path."""
    try:
        with open(FILES_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    entries = data.get("files") if isinstance(data, dict) else data
    if not isinstance(entries, list):
        return []
    out, seen = [], set()
    for item in entries:
        fid = item.get("id") if isinstance(item, dict) else item
        fid = str(fid or "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{6,128}", fid) or fid in seen:
            continue
        seen.add(fid)
        out.append(fid)
        if len(out) >= MAX_FILES:
            break
    return out


def keychain_refresh_token():
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
             "-a", KEYCHAIN_ACCOUNT, "-w"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
    except (subprocess.SubprocessError, OSError):
        return None
    token = r.stdout.strip() if r.returncode == 0 else ""
    return token or None


# ── HTTP ──────────────────────────────────────────────────────────────────

class Unreachable(Exception):
    """The network, DNS or Google itself failed — exit 3, not needs-setup."""


class NeedsSetup(Exception):
    """The grant is gone; only the user can fix it — exit 1."""


def http(url, data=None, headers=None, limit=None):
    """(status, body bytes). Raises Unreachable for anything that is not an
    HTTP answer. `limit` caps how much of the body is read, so a document
    larger than the cap cannot be pulled into memory whole."""
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, resp.read(limit) if limit else resp.read()
    except urllib.error.HTTPError as e:
        try:
            body = e.read(65536)
        except Exception:
            body = b""
        return e.code, body
    except Exception as e:
        # urllib raises URLError, socket.timeout, ssl.SSLError, OSError…
        raise Unreachable("%s: %s" % (type(e).__name__, e))


def access_token():
    """A fresh access token, from the refresh token in the Keychain.

    This doubles as the connection check: Google is asked, every run, whether
    the grant is still alive. `security find-generic-password` returning a
    string proves only that a string is stored."""
    cfg = client_config()
    if not cfg:
        raise NeedsSetup("not configured")
    client_id, client_secret, token_uri = cfg
    refresh = keychain_refresh_token()
    if not refresh:
        raise NeedsSetup("not connected")
    form = {"client_id": client_id, "refresh_token": refresh, "grant_type": "refresh_token"}
    if client_secret:
        form["client_secret"] = client_secret
    status, body = http(token_uri, data=urllib.parse.urlencode(form).encode("ascii"),
                        headers={"Content-Type": "application/x-www-form-urlencoded"})
    if status == 200:
        try:
            token = json.loads(body.decode("utf-8", "replace")).get("access_token")
        except ValueError:
            token = None
        if token:
            return str(token)
        raise Unreachable("the token endpoint answered without an access token")
    if status in (400, 401):
        # invalid_grant: revoked at myaccount.google.com, password changed,
        # or six months unused. Nothing here can recover it.
        raise NeedsSetup("reconnect needed")
    raise Unreachable("the token endpoint answered %d" % status)


class Session:
    """One access token, refreshed at most once more on a 401. Past that a
    401 is a real answer — the grant is gone — not a transient."""

    def __init__(self):
        self.token = access_token()
        self.retried = False

    def get(self, url, limit=None):
        for _ in range(2):
            status, body = http(url, headers={"Authorization": "Bearer " + self.token}, limit=limit)
            if status == 401 and not self.retried:
                self.retried = True
                self.token = access_token()      # raises NeedsSetup if dead
                continue
            return status, body
        return 401, b""

    def json(self, url):
        status, body = self.get(url)
        if status == 200:
            try:
                return json.loads(body.decode("utf-8", "replace"))
            except ValueError:
                return None
        if status == 401:
            raise NeedsSetup("reconnect needed")
        return None


# ── Drive ─────────────────────────────────────────────────────────────────

SPREADSHEET = "application/vnd.google-apps.spreadsheet"

NATIVE = {
    "application/vnd.google-apps.document": ("Google Doc", "text/markdown"),
    "application/vnd.google-apps.spreadsheet": ("Google Sheet", "text/csv"),
    "application/vnd.google-apps.presentation": ("Google Slides", "text/plain"),
}
# Native types with no useful text export. Named rather than lumped into
# "unknown" so the output says what the file is instead of going quiet.
NATIVE_OTHER = {
    "application/vnd.google-apps.drawing": "Google Drawing",
    "application/vnd.google-apps.form": "Google Form",
    "application/vnd.google-apps.site": "Google Site",
    "application/vnd.google-apps.jam": "Google Jamboard",
    "application/vnd.google-apps.script": "Apps Script",
    "application/vnd.google-apps.map": "Google My Map",
    "application/vnd.google-apps.folder": "folder",
    "application/vnd.google-apps.shortcut": "shortcut",
}
# Uploaded files we will read through alt=media: text, and cheap.
MEDIA_TEXT = re.compile(r"^text/|^application/(json|xml|x-yaml|yaml|csv|javascript)$")

META_FIELDS = "id,name,mimeType,modifiedTime,size,trashed"


def meta(session, fid):
    """One file's metadata, or None when it is gone. A picked file can be
    deleted, or the share withdrawn, long after it was picked."""
    url = "%s/files/%s?%s" % (DRIVE_API, urllib.parse.quote(fid, safe=""),
                              urllib.parse.urlencode({"fields": META_FIELDS,
                                                      "supportsAllDrives": "true"}))
    data = session.json(url)
    return data if isinstance(data, dict) else None


def kind_of(mime):
    if mime in NATIVE:
        return NATIVE[mime][0]
    if mime in NATIVE_OTHER:
        return NATIVE_OTHER[mime]
    return one_line(mime or "file", 60)


def modified_epoch(iso):
    """Drive's modifiedTime (RFC 3339, always UTC with a Z) as an epoch.
    timegm, not mktime: mktime would read the UTC fields as local time and
    shift every date by the machine's offset. 0.0 for anything unparseable —
    it sorts last and falls outside --since, which is the safe way to be
    wrong about a date."""
    try:
        return calendar.timegm(time.strptime(str(iso)[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError, OverflowError):
        return 0.0


def when(iso, fmt="%Y-%m-%d %H:%M"):
    """The same instant shown in the user's own timezone, or the raw string
    when it is not the shape we expect (never a traceback over a date)."""
    secs = modified_epoch(iso)
    if not secs:
        return one_line(iso, 30)
    try:
        return time.strftime(fmt, time.localtime(secs))
    except (ValueError, OSError, OverflowError):
        return one_line(iso, 30)


def contents(session, info):
    """(text, why-not) for one file. Exactly one of the two is set."""
    mime = info.get("mimeType") or ""
    fid = urllib.parse.quote(str(info.get("id") or ""), safe="")
    if mime in NATIVE:
        export_as = NATIVE[mime][1]
        url = "%s/files/%s/export?%s" % (DRIVE_API, fid,
                                          urllib.parse.urlencode({"mimeType": export_as}))
        # One byte over the ceiling is enough to know we went past it.
        status, body = session.get(url, limit=EXPORT_LIMIT + 1)
        if status == 200:
            if len(body) > EXPORT_LIMIT:
                return None, "larger than Google's 10 MB export limit — skipped"
            return body.decode("utf-8", "replace"), None
        if status == 403:
            # exportSizeLimitExceeded is the documented 403 here; any other
            # 403 is a permission problem, and both are the user's to fix.
            if b"exportSizeLimitExceeded" in body:
                return None, "larger than Google's 10 MB export limit — skipped"
            return None, "Google refused the export (403)"
        if status == 404:
            return None, "no longer available to Moe"
        return None, "export failed (%d)" % status
    if mime in NATIVE_OTHER:
        return None, "%s — no text to export" % NATIVE_OTHER[mime]
    try:
        size = int(info.get("size") or 0)
    except (TypeError, ValueError):
        size = 0
    if not MEDIA_TEXT.match(mime):
        return None, "not a text format"
    if size > MEDIA_LIMIT:
        return None, "too large to read (%d bytes)" % size
    status, body = session.get("%s/files/%s?alt=media" % (DRIVE_API, fid), limit=MEDIA_LIMIT + 1)
    if status == 200:
        return body[:MEDIA_LIMIT].decode("utf-8", "replace"), None
    if status == 404:
        return None, "no longer available to Moe"
    return None, "could not be read (%d)" % status


# ── Arguments ─────────────────────────────────────────────────────────────

def crawl_args(argv):
    """[--since DAYS] [--max-bytes N] → (days, max_bytes); exits 2 on junk.
    Same shape and the same strictness as drive.sh and calendar.sh."""
    # The environment default is validated too: "no traceback ever" has to
    # survive a MOE_CRAWL_MAX_BYTES somebody typed by hand.
    env = os.environ.get("MOE_CRAWL_MAX_BYTES", "")
    days, max_bytes = 90, (int(env) if env.isdigit() else 400000)
    i = 0
    while i < len(argv):
        opt = argv[i]
        val = argv[i + 1] if i + 1 < len(argv) else ""
        if opt not in ("--since", "--max-bytes") or not val.isdigit():
            print("crawl: usage: crawl [--since DAYS] [--max-bytes N]", file=sys.stderr)
            sys.exit(2)
        if opt == "--since":
            days = int(val)
        else:
            max_bytes = int(val)
        i += 2
    return days, max_bytes


# ── The three verbs ───────────────────────────────────────────────────────

# House shape for a needs-setup line: what is wrong, then " — run <script>".
# The app cuts the line at that dash and shows only the first half, because
# on screen the button *is* the command (ConnectionsCatalog.humanDetail); a
# line that names the script anywhere else arrives on screen in pieces.
NOT_CONFIGURED = ("needs-setup: this build of Moe has no Google sign-in client, "
                  "so Docs and Sheets contents are unavailable")
NOT_CONNECTED = ("needs-setup: no Google documents are shared with Moe yet — run "
                 "~/.moe/scripts/connect-drive-docs.sh")
NOTHING_PICKED = ("needs-setup: signed in, but no documents are picked yet — run "
                  "~/.moe/scripts/connect-drive-docs.sh pick")
RECONNECT = ("needs-setup: reconnect needed, Google no longer accepts the saved "
             "sign-in — run ~/.moe/scripts/connect-drive-docs.sh")


def cmd_status():
    if not client_config():
        print(NOT_CONFIGURED)
        return 1
    if not keychain_refresh_token():
        print(NOT_CONNECTED)
        return 1
    ids = load_files()
    try:
        # Ask Google, do not merely find a string in the Keychain. A stored
        # refresh token whose grant was revoked reads exactly the same.
        access_token()
    except NeedsSetup:
        print(RECONNECT)
        return 1
    except Unreachable as e:
        print("unavailable: could not reach Google (%s)" % one_line(e, 60))
        return 3
    if not ids:
        print(NOTHING_PICKED)
        return 1
    print("ok: %d document%s" % (len(ids), "" if len(ids) == 1 else "s"))
    return 0


def open_session():
    """A Session, or (rc, message) to print and exit with."""
    try:
        return Session(), None
    except NeedsSetup as e:
        text = str(e)
        return None, (1, NOT_CONFIGURED if text == "not configured"
                      else NOT_CONNECTED if text == "not connected" else RECONNECT)
    except Unreachable as e:
        return None, (3, "unavailable: could not reach Google (%s)" % one_line(e, 60))


def cmd_pull():
    """One line per picked document: when it changed, what it is, its name.
    No contents — that is what crawl is for, the same split as drive.sh."""
    ids = load_files()
    if not ids:
        return 1
    session, problem = open_session()
    if session is None:
        rc, message = problem
        print(message, file=sys.stderr)
        return rc
    lines = []
    try:
        for fid in ids:
            info = meta(session, fid)
            if not info:
                continue
            if info.get("trashed"):
                continue
            lines.append("%s | %s | %s" % (when(info.get("modifiedTime")),
                                           kind_of(info.get("mimeType")),
                                           one_line(info.get("name"), 120)))
    except NeedsSetup:
        print(RECONNECT, file=sys.stderr)
        return 1
    except Unreachable as e:
        print("unavailable: %s" % one_line(e, 80), file=sys.stderr)
        return 3
    if not lines:
        return 1
    print("\n".join(lines))
    return 0


def cmd_crawl(argv):
    """The contents of every picked document, newest first, until the byte
    budget is spent. Newest first because when the cap bites, this quarter's
    strategy doc is worth more than a spreadsheet from two years ago."""
    days, budget = crawl_args(argv)
    ids = load_files()
    if not ids:
        return 1
    session, problem = open_session()
    if session is None:
        rc, message = problem
        print(message, file=sys.stderr)
        return rc
    try:
        items = []
        for fid in ids:
            info = meta(session, fid)
            if info and not info.get("trashed"):
                items.append(info)
        items.sort(key=lambda i: modified_epoch(i.get("modifiedTime")), reverse=True)
        cutoff = time.time() - days * 86400
        spent, wrote = 0, False
        for info in items:
            if spent >= budget:
                break
            if modified_epoch(info.get("modifiedTime")) < cutoff:
                continue
            text, why = contents(session, info)
            head = "### %s (%s, %s)" % (one_line(info.get("name"), 120),
                                        kind_of(info.get("mimeType")),
                                        when(info.get("modifiedTime"), "%Y-%m-%d"))
            # Google's CSV export is the first sheet of a workbook and
            # nothing else (docs/GOOGLE-WITHOUT-OAUTH.md). Said in the text
            # itself, not only in the docs: a reader given tab one of a
            # twelve-tab budget must not take it for the whole book.
            if text and info.get("mimeType") == SPREADSHEET:
                head += " — first sheet only"
            body = block(text) if text else "(%s)" % one_line(why, 100)
            # Truncated to the byte the budget ends on, the way `head -c`
            # finishes drive.sh's crawl — the cap is a cap, not a target the
            # last document is allowed to overshoot.
            raw = (head + "\n" + body + "\n\n").encode("utf-8", "replace")[:budget - spent]
            spent += len(raw)
            sys.stdout.buffer.write(raw)
            wrote = True
        sys.stdout.buffer.flush()
    except NeedsSetup:
        print(RECONNECT, file=sys.stderr)
        return 1
    except Unreachable as e:
        print("unavailable: %s" % one_line(e, 80), file=sys.stderr)
        return 3
    return 0 if wrote else 1


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        sys.exit(cmd_status())
    if cmd == "pull":
        sys.exit(cmd_pull())
    if cmd == "crawl":
        sys.exit(cmd_crawl(sys.argv[2:]))
    print("usage: drive-docs.py [status|pull|crawl [--since DAYS] [--max-bytes N]]", file=sys.stderr)
    sys.exit(2)

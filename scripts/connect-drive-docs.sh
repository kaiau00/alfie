#!/bin/bash
# Let Moe read the contents of Google Docs, Sheets and Slides you pick.
#
# This is the one Google scope Moe uses, and the only one it can use without
# reintroducing everything that killed OAuth here (docs/GOOGLE-WITHOUT-OAUTH.md):
#
#   https://www.googleapis.com/auth/drive.file
#
# Google classifies it NON-SENSITIVE. No unverified-app warning screen, no
# verification review, no CASA assessment, no 100-user cap. It reaches only
# the files you choose in Google's own picker — never your Drive.
#
# Google's picker is no longer JavaScript-only. For desktop apps you add
# `trigger_onepick=true` to a plain OAuth authorization URL and the redirect
# comes back carrying `picked_file_ids` alongside the auth `code`
# (developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker).
# So one browser round trip does sign-in and file-choosing at once, and the
# same page documents the hard constraint this script is built around:
# "Only the drive.file scope is permitted for these apps and it can't be
# combined with any other scope." Nothing else is ever requested here.
#
#   connect-drive-docs.sh [connect] [--timeout SECONDS]   sign in and pick (default 180)
#   connect-drive-docs.sh pick [--timeout SECONDS]        pick more, same account
#   connect-drive-docs.sh --list                          what Moe may read
#   connect-drive-docs.sh --revoke                        hand the grant back
#
# Nothing is opened for you: the URL is printed, and printed once as the
# machine line the app watches for —
#
#   SIGN_IN_URL=<url>        the app opens it after the user clicks
#
# Exit: 0 done · 1 not configured / wrong usage / nothing picked · 2 bad
# option · 3 Google unreachable · 4 nobody finished the picker before the
# timeout.
#
# Where things go: the refresh token into the macOS Keychain (service
# `moe-google-docs`, the same style as `moe-gmail`) and never into a file;
# the picked file ids into ~/.moe/connectors/drive-docs-files.json at 0600.
# No secret is ever printed, logged, or put on this script's argv — the
# client JSON travels to the Python step as a path, and the Python step
# reads it itself.
#
# Redirection for tests: MOE_HOME, MOE_GOOGLE_CLIENT_JSON, and
# MOE_GOOGLE_AUTH_URI / MOE_GOOGLE_TOKEN_URI / MOE_GOOGLE_REVOKE_URI to point
# every network call at a fake server on localhost. `security` is whatever is
# first on PATH, so the tests put a stub there. Bash 3.2 and `set -u` clean.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
MOE="${MOE_HOME:-$HOME/.moe}"
FILES="$MOE/connectors/drive-docs-files.json"
TIMEOUT=180
MODE="connect"

while [ $# -gt 0 ]; do
  case "$1" in
    connect|pick) MODE="$1" ;;
    --revoke)     MODE="revoke" ;;
    --list)       MODE="list" ;;
    --timeout)    [ $# -ge 2 ] || { echo "✗ --timeout needs a whole number of seconds"; exit 2; }
                  TIMEOUT="$2"; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown option $1"; exit 2 ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "✗ --timeout needs a whole number of seconds"; exit 2 ;; esac

mkdir -p "$MOE/connectors"

# The OAuth client the product ships. Same lookup order as
# connectors/drive-docs.py, plus the checkout's copy so this works from a
# clone. The file is gitignored and its contents never leave this function.
# NOTE: build.sh does not copy it into Memoe.app yet, so a shipped build finds
# nothing here and says "not configured" — see CONNECTORS.md.
find_client() {
  local c
  if [ -n "${MOE_GOOGLE_CLIENT_JSON:-}" ]; then
    [ -f "$MOE_GOOGLE_CLIENT_JSON" ] && { printf '%s\n' "$MOE_GOOGLE_CLIENT_JSON"; return 0; }
    return 1
  fi
  for c in "$MOE/google-client.json" \
           "/Applications/Memoe.app/Contents/Resources/google-client.json" \
           "$HERE/../Resources/google-client.json"; do
    [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

CLIENT="$(find_client || true)"
# --list and --revoke work without one. Revoking is the user taking something
# back; refusing to do it because the sign-in client is missing would leave a
# live grant at Google and a list of file ids on disk with no way to clear
# either. The revoke step below never reads the client file.
if [ -z "$CLIENT" ] && [ "$MODE" != list ] && [ "$MODE" != revoke ]; then
  echo "✗ Not configured: this copy of Memoe has no Google sign-in client, so Docs"
  echo "  and Sheets contents are unavailable. Everything else Google keeps working."
  exit 1
fi

# ── --list ────────────────────────────────────────────────────────────────
if [ "$MODE" = list ]; then
  python3 - "$FILES" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    print("No documents picked yet.")
    raise SystemExit(1)
files = data.get("files") if isinstance(data, dict) else data
if not isinstance(files, list) or not files:
    print("No documents picked yet.")
    raise SystemExit(1)
def one_line(text, limit=100):
    # Names come from whoever shared the document; this one goes to a terminal.
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    return re.sub(r"\s+", " ", text).strip()[:limit] or "(unnamed)"
for f in files:
    if not isinstance(f, dict):
        continue
    print("  %-14s %s" % (one_line(f.get("kind") or "file", 14), one_line(f.get("name"))))
print("\n%d document(s). Moe can read these and nothing else in your Drive." % len(files))
PY
  exit $?
fi

# ── --revoke ──────────────────────────────────────────────────────────────
# Hand the grant back to Google, forget the token, forget the list. The
# revoke call is best-effort: if it cannot be reached the local state still
# goes, because the user asked for it to.
if [ "$MODE" = revoke ]; then
  python3 - <<'PY' || true
import json, os, subprocess, sys, urllib.parse, urllib.request
REVOKE = os.environ.get("MOE_GOOGLE_REVOKE_URI", "https://oauth2.googleapis.com/revoke")
try:
    r = subprocess.run(["security", "find-generic-password", "-s", "moe-google-docs",
                        "-a", "refresh-token", "-w"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
    token = r.stdout.strip() if r.returncode == 0 else ""
except (OSError, subprocess.SubprocessError):
    token = ""
if token:
    try:
        req = urllib.request.Request(
            REVOKE, data=urllib.parse.urlencode({"token": token}).encode("ascii"),
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        urllib.request.urlopen(req, timeout=20).read()
    except Exception:
        print("(couldn't reach Google to revoke; removing the local copy anyway)")
PY
  security delete-generic-password -s "moe-google-docs" -a "refresh-token" >/dev/null 2>&1 || true
  rm -f "$FILES"
  echo "✓ Disconnected. Moe can no longer read any Google document."
  exit 0
fi

# ── connect / pick ────────────────────────────────────────────────────────
if [ "$MODE" = pick ]; then
cat <<'EOF'
Pick more Google documents
──────────────────────────
Google's picker opens in your browser. Whatever you choose is added to the
list Moe may read; everything already on the list stays.

EOF
else
cat <<'EOF'
Let Moe read Google Docs, Sheets and Slides
───────────────────────────────────────────
Google Drive syncs a Doc to this Mac as a link, not a document — so Moe can
see the name of every file in your Drive but not what any of them say.

This fixes that for the documents YOU choose. You will see Google's own file
picker; the ones you tick are the ones Moe can read, and Moe gets no access
of any kind to the rest of your Drive. You can take it back at any time with
  ~/.moe/scripts/connect-drive-docs.sh --revoke

EOF
fi

set +e
python3 - "$CLIENT" "$FILES" "$TIMEOUT" <<'PY'
import base64, hashlib, http.server, json, os, re, secrets, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request

CLIENT_JSON, FILES, TIMEOUT = sys.argv[1], sys.argv[2], int(sys.argv[3])

# The picker flow is documented against the v2 authorization endpoint, and the
# client JSON Google hands out still names the v1 one — so this is pinned here
# rather than read out of the file. Overridable for the offline tests only.
AUTH_URI = os.environ.get("MOE_GOOGLE_AUTH_URI", "https://accounts.google.com/o/oauth2/v2/auth")
TOKEN_OVERRIDE = os.environ.get("MOE_GOOGLE_TOKEN_URI", "")
DRIVE_API = os.environ.get("MOE_GOOGLE_DRIVE_API", "https://www.googleapis.com/drive/v3")
# The one scope. Google: "Only the drive.file scope is permitted for these
# apps and it can't be combined with any other scope." Adding a second one
# here does not degrade the flow, it breaks it — and it is also what would
# drag Moe back into verification.
SCOPE = "https://www.googleapis.com/auth/drive.file"

try:
    with open(CLIENT_JSON, encoding="utf-8") as fh:
        cfg = json.load(fh)
except (OSError, ValueError):
    print("✗ The Google sign-in client that ships with Moe could not be read.")
    raise SystemExit(1)
section = cfg.get("installed") or cfg.get("web") or {}
CLIENT_ID = str(section.get("client_id") or "")
CLIENT_SECRET = str(section.get("client_secret") or "")
TOKEN_URI = TOKEN_OVERRIDE or str(section.get("token_uri") or "https://oauth2.googleapis.com/token")
if not CLIENT_ID or CLIENT_ID.startswith("REPLACE-ME"):
    print("✗ The Google sign-in client that ships with Moe is a placeholder, not a real client.")
    raise SystemExit(1)

# ── PKCE ──────────────────────────────────────────────────────────────────
# Google's native-app guidance: a desktop client's secret is not confidential
# (it ships inside the app), so PKCE — not the secret — is what stops a local
# process racing us for the authorization code. S256, 43–128 unreserved
# characters, per RFC 7636 and Google's own wording.
verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).decode("ascii").rstrip("=")
challenge = base64.urlsafe_b64encode(
    hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
state = secrets.token_urlsafe(24)

# ── The loopback listener ─────────────────────────────────────────────────
# Google accepts http://127.0.0.1:<port> for installed apps and tells you to
# take a random free port. 127.0.0.1, not localhost: Google's own note says
# localhost "may cause issues with client firewalls".
result = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if not (q.get("code") or q.get("error") or q.get("picked_file_ids")):
            self.send_response(404)          # a favicon probe, not the redirect
            self.end_headers()
            return
        result.update({k: v[0] for k, v in q.items() if v})
        body = (b"<!doctype html><meta charset=utf-8><title>Moe</title>"
                b"<body style='font:16px -apple-system;padding:3em'>"
                b"<p>Done \xe2\x80\x94 you can close this tab and go back to Moe.</p>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        # The request line carries the auth code. It never goes to a log.
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
redirect_uri = "http://127.0.0.1:%d/" % srv.server_address[1]

params = [
    ("client_id", CLIENT_ID),
    ("redirect_uri", redirect_uri),
    ("response_type", "code"),
    ("scope", SCOPE),
    ("access_type", "offline"),         # …so there is a refresh token at all
    ("prompt", "consent"),              # documented as required by the picker flow
    ("trigger_onepick", "true"),        # this is what turns the consent page into a picker
    ("allow_multiple", "true"),         # pick a whole project's worth in one go
    ("state", state),
    ("code_challenge", challenge),
    ("code_challenge_method", "S256"),
]
auth_url = AUTH_URI + "?" + urllib.parse.urlencode(params)

print("Open this in your browser (copy it — nothing is opened for you):")
print()
print("  " + auth_url)
print()
print("Sign in, then tick the documents Moe may read.")
print()
# The machine line, exactly once, and only for a URL the app will actually
# open (https, or a loopback for the tests) — the same rule as connect.sh.
if re.match(r"^(https://|http://(127\.0\.0\.1|localhost)[:/])", auth_url):
    print("SIGN_IN_URL=%s" % auth_url)
print("Waiting for you to finish in the browser (up to %d s)…" % TIMEOUT)
sys.stdout.flush()

srv.timeout = 1
# …and a cap on one connection, not only on the wait between them. Without
# this a socket that opens and never sends a request line leaves the handler
# blocked in readline() forever, deadline or no deadline.
Handler.timeout = 10
deadline = time.monotonic() + TIMEOUT
stopped = False
try:
    while not result and time.monotonic() < deadline:
        srv.handle_request()
except KeyboardInterrupt:
    result.clear()
    stopped = True
finally:
    # Every path gives the port back: finished, timed out, or Ctrl-C.
    srv.server_close()

if stopped:
    print()
    print("✗ Stopped. Nothing was changed.")
    raise SystemExit(4)
if not result:
    print("✗ Timed out waiting for the browser. Nothing was changed — run this again.")
    # The one failure that looks exactly like this and is not the user being
    # slow: Google refusing the loopback redirect, so the browser showed an
    # error page and nothing ever came back to this port. Named, because a
    # silent 180-second wait teaches the user nothing.
    print("  If the browser showed an error from Google rather than a file picker,")
    print("  this copy of Memoe's sign-in needs updating — nothing you can fix here.")
    raise SystemExit(4)
if result.get("error"):
    print("✗ Google returned no documents (you may have cancelled). Nothing was changed.")
    raise SystemExit(1)
if result.get("state") != state:
    # Somebody else's redirect reached our port. Never exchange that code.
    print("✗ The reply from the browser did not match this sign-in. Nothing was changed.")
    raise SystemExit(1)
code = result.get("code") or ""
if not code:
    print("✗ Google did not return a sign-in code. Nothing was changed.")
    raise SystemExit(1)


def post_form(url, form):
    """(status, parsed json or None). Never raises for an HTTP answer;
    returns (0, None) when the network itself failed."""
    req = urllib.request.Request(
        url, data=urllib.parse.urlencode(form).encode("ascii"),
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read(1 << 20)
            status = resp.status
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None
    try:
        return status, json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return status, None


form = {"client_id": CLIENT_ID, "code": code, "code_verifier": verifier,
        "grant_type": "authorization_code", "redirect_uri": redirect_uri}
# Google marks client_secret optional and excludes only Android/iOS/Chrome
# clients; a Desktop client is issued one and is not excluded, so it is sent.
if CLIENT_SECRET:
    form["client_secret"] = CLIENT_SECRET
status, tokens = post_form(TOKEN_URI, form)
if status == 0:
    print("✗ Couldn't reach Google to finish signing in. Check your connection and try again.")
    raise SystemExit(3)
if status != 200 or not isinstance(tokens, dict):
    # The body can echo the client id; it is never printed.
    print("✗ Google refused to complete the sign-in (%d). Try again." % status)
    raise SystemExit(1)

refresh = str(tokens.get("refresh_token") or "")
access = str(tokens.get("access_token") or "")
if refresh:
    # argv, because Apple's `security` has no way to take a value on stdin —
    # the same exposure its own -w prompt has, and gone the moment it returns.
    # -U replaces the item from a previous run rather than erroring.
    try:
        r = subprocess.run(["security", "add-generic-password", "-U",  # erase-allowlist: moe-google-docs
                            "-s", "moe-google-docs", "-a", "refresh-token",
                            "-w", refresh, "-T", "/usr/bin/security"],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        saved = r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        saved = False
    refresh = ""
    if not saved:
        print("✗ Couldn't save the sign-in to your Keychain. Nothing was changed.")
        raise SystemExit(1)
    print("✓ sign-in saved to Keychain")
elif not os.path.exists(FILES):
    # No refresh token and no earlier one: without access_type=offline being
    # honoured there is nothing to sync with tomorrow.
    print("✗ Google did not return a lasting sign-in. Try again.")
    raise SystemExit(1)

# ── The picked ids ────────────────────────────────────────────────────────
# Documented as a comma-separated list on the redirect. parse_qs has already
# percent-decoded it; splitting on the comma covers both spellings.
raw_ids = result.get("picked_file_ids") or ""
picked = [i for i in re.split(r"[,\s]+", raw_ids) if re.fullmatch(r"[A-Za-z0-9_-]{6,128}", i)]

KIND = {
    "application/vnd.google-apps.document": "Google Doc",
    "application/vnd.google-apps.spreadsheet": "Google Sheet",
    "application/vnd.google-apps.presentation": "Google Slides",
}


def one_line(text, limit=120):
    """Document names are written by whoever shared them and end up in a
    terminal and in a JSON file. Same rules as connectors/hermeslib.py."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\[([^\]]*)\]\(([^)]*)\)", r"\1 (\2)", text)
    text = re.sub(r"^(?=[#>\-+*|`]|\d+[.)]\s)", "\\\\", text, count=1)
    return text[:limit]


def describe(fid):
    """Name and kind for a just-picked file, so --list and the confirmation
    below can say something a person recognises. Best effort: a failure here
    costs a label, never the connection."""
    if not access:
        return {}
    url = "%s/files/%s?%s" % (DRIVE_API, urllib.parse.quote(fid, safe=""),
                              urllib.parse.urlencode({"fields": "id,name,mimeType",
                                                      "supportsAllDrives": "true"}))
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + access})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read(1 << 18).decode("utf-8", "replace"))
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    mime = str(data.get("mimeType") or "")
    return {"name": one_line(data.get("name")), "kind": KIND.get(mime, one_line(mime, 60))}


try:
    with open(FILES, encoding="utf-8") as fh:
        existing = json.load(fh)
    existing = existing.get("files") if isinstance(existing, dict) else existing
    existing = [f for f in existing if isinstance(f, dict) and f.get("id")] if isinstance(existing, list) else []
except (OSError, ValueError):
    existing = []

known = {f["id"] for f in existing}
added = 0
today = time.strftime("%Y-%m-%d")
for fid in picked:
    if fid in known:
        continue
    entry = {"id": fid, "picked": today}
    entry.update(describe(fid))
    existing.append(entry)
    known.add(fid)
    added += 1

tmp = FILES + ".tmp"
os.makedirs(os.path.dirname(FILES) or ".", mode=0o700, exist_ok=True)
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump({"files": existing}, fh, indent=1)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, FILES)

if not picked:
    print()
    print("Signed in, but you did not pick a document — so Moe still cannot read any.")
    print("Run  connect-drive-docs.sh pick  and tick the ones you want.")
    raise SystemExit(1)

print()
print("✓ %d document(s) added; Moe may now read %d in total:" % (added, len(existing)))
for f in existing[-10:]:
    print("    %s  %s" % (f.get("kind") or "file", f.get("name") or f["id"]))
print()
print("Moe can read these and nothing else in your Drive.")
raise SystemExit(0)
PY
rc=$?
set -e
[ "$rc" -eq 0 ] || exit "$rc"

# Prove it with the connector, the same check doctor.sh makes.
CONNECTOR="$MOE/connectors/drive-docs.py"
[ -x "$CONNECTOR" ] || CONNECTOR="$HERE/../moe-home/connectors/drive-docs.py"
echo "Checking…"
if [ -x "$CONNECTOR" ] && "$CONNECTOR" status; then
  echo
  echo "✓ Connected. Moe will read them on the next sync, or run ~/.moe/sync.sh now."
else
  echo "✗ The sign-in was saved but the check failed — see the message above."
  exit 1
fi

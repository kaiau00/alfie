#!/bin/bash
# Adds a Gmail account to Moe using an app password. Run once per mailbox
# (personal, work, …). Nothing is written to disk except the address.
#
# Driven by the app: MOE_CONNECT_NONINTERACTIVE=1 and nothing is asked —
# the answers arrive as lines on stdin, the same protocol as connect.sh:
#
#   EMAIL=you@gmail.com
#   LABEL=personal            optional; defaults to the part before @
#   PASSWORD=abcd efgh ijkl mnop
#
# read up front, in any order. A missing EMAIL/PASSWORD is a plain
# "✗ … is required." exit 1. On any failure the LAST line on stdout is the
# sentence to show the user. The password goes to the Keychain through
# `security` (the one on PATH — tests put a stub first) and is never printed.
set -euo pipefail
umask 077

MOE="${MOE_HOME:-$HOME/.moe}"
ACCOUNTS="$MOE/connectors/gmail-accounts.json"
SERVICE="moe-gmail"
NONINTERACTIVE="${MOE_CONNECT_NONINTERACTIVE:-}"
mkdir -p "$MOE/connectors"

if [ -z "$NONINTERACTIVE" ]; then
cat <<'EOF'
Connect a Gmail account
───────────────────────
An app password is a 16-letter key Google makes for one app and one app only.
It is safer than giving Moe your real password: it reaches your mail and
nothing else, it cannot get into your Google account, you can delete it from
Google at any moment, and Moe never sees your actual password.

  1. Switch on 2-Step Verification for this account, if it isn't on already.
     Google only offers app passwords to accounts that have it — without it
     the page in step 2 does not exist.
     https://myaccount.google.com/signinoptions/twosv
  2. Open  https://myaccount.google.com/apppasswords
  3. Give it any name ("Moe" is fine) and press Create
  4. Copy the 16 letters it shows you, and paste them below

No app passwords page at all? Two kinds of account cannot have one: a work or
school account whose administrator has switched them off, and any account on
Google's Advanced Protection Program. That costs you mail only — your
calendar, contacts, Notes and Google Drive folder all still work.

The password is kept in your Mac's own password store, not in any file.

EOF
fi

EMAIL=""; LABEL=""; PASSWORD=""
if [ -n "$NONINTERACTIVE" ]; then
  # Everything up front, then stdin is closed for good: no child (security,
  # gmail.py) ever inherits a pipe with a password on it.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      EMAIL=*)    EMAIL="${line#EMAIL=}" ;;
      LABEL=*)    LABEL="${line#LABEL=}" ;;
      PASSWORD=*) PASSWORD="${line#PASSWORD=}" ;;
    esac
  done
  exec </dev/null
  [ -n "$EMAIL" ]    || { echo "✗ EMAIL is required."; exit 1; }
  [ -n "$PASSWORD" ] || { echo "✗ PASSWORD is required."; exit 1; }
else
  # `read` on a closed stdin fails silently under set -e; say what was needed.
  read -r -p "Gmail address: " EMAIL || { echo; echo "✗ No input (not a terminal?)"; exit 1; }
  [ -n "$EMAIL" ] || { echo "✗ No address given."; exit 1; }
  read -r -p "Label for it (e.g. personal, work): " LABEL || LABEL=""
  read -r -s -p "App password (hidden): " PASSWORD || { echo; echo "✗ No input (not a terminal?)"; exit 1; }
  echo
  [ -n "$PASSWORD" ] || { echo "✗ No password given."; exit 1; }
fi
LABEL="${LABEL:-${EMAIL%%@*}}"
case "$EMAIL" in
  *@*.*) ;;
  *) echo "✗ That does not look like an email address."; exit 1 ;;
esac

# Strip the spaces Google displays them with.
PASSWORD="${PASSWORD// /}"

# -U: replace an existing item for the same address (a rotated password).
# The value travels on argv to `security` — Apple's tool has no stdin mode —
# which is the same exposure its own `-w` prompt has; it is gone as soon as
# the call returns.
# erase-allowlist: moe-gmail
if security add-generic-password -U -s "$SERVICE" -a "$EMAIL" -w "$PASSWORD" \
     -T /usr/bin/security >/dev/null 2>&1; then
  PASSWORD=""
  echo "✓ password saved to Keychain"
else
  PASSWORD=""
  echo "✗ Moe couldn't save the password on this Mac. If your Mac asked you to allow it, say yes and try again."
  exit 1
fi

python3 - "$ACCOUNTS" "$EMAIL" "$LABEL" <<'PY'
import json, sys, os
path, email, label = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f: accounts = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    accounts = []
accounts = [a for a in accounts if a.get("email") != email]
accounts.append({"label": label, "email": email, "host": "imap.gmail.com"})
with open(path, "w") as f: json.dump(accounts, f, indent=2)
os.chmod(path, 0o600)
print(f"✓ {label} <{email}> added ({len(accounts)} mailbox(es) total)")
PY

echo
echo "Testing the connection…"
GMAIL_PY="$MOE/connectors/gmail.py"
[ -x "$GMAIL_PY" ] || GMAIL_PY="$(cd "$(dirname "$0")" && pwd)/../moe-home/connectors/gmail.py"
if "$GMAIL_PY" status; then
  if [ -z "$NONINTERACTIVE" ]; then
    echo
    "$GMAIL_PY" pull | head -8 || true
  fi
  echo
  echo "✓ Gmail connected. Moe will pick it up on the next sync."
else
  # The address stays listed (a re-run with the right password fixes it);
  # this last line is what the app shows.
  echo "✗ Google wouldn't let Moe in to $EMAIL with that password. Check all 16 letters came across; if they did, delete that app password at https://myaccount.google.com/apppasswords, create a fresh one, and paste that."
  exit 1
fi

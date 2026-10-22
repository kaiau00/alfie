#!/bin/bash
# Connect Signal: scan one QR code in the app, then talk to Moe in Signal's
# Note to Self.
#
#   connect-signal.sh [--timeout SECONDS]   (default 180)
#   connect-signal.sh --status               is this Mac linked?
#   connect-signal.sh --forget               unlink on this Mac: the keys and the account go
#
# Signal has no bot platform and no API for a personal account, so Moe links
# as a **secondary device of the person's own account** — the same thing
# Signal Desktop is — using signal-cli (GPL-3.0, run unmodified as a separate
# program; docs/SIGNAL.md). The phone scans; the person writes to themselves
# in Note to Self; Moe answers there.
#
# What happens, in order:
#   1. Signal support is fetched if this Mac does not have it yet
#      (fetch-signal-cli.sh: pinned, checksummed, signature-checked, ~180 MB
#      once). Its progress lines pass straight through.
#      **Already linked, but Signal support is missing or out of date** (a
#      Moe release that moves the signal-cli pin makes the old copy "not
#      ready"): it is fetched again and the link is KEPT — no new code, no
#      second "Moe" on the phone's Linked devices. Before 2026-09-14 that case
#      fell into the link branch and asked for a fresh scan.
#   2. `signal-cli link -n Moe` prints a sgnl://linkdevice URI; this emits it
#      as QR=<uri> for the app to draw, then waits for the scan, when
#      signal-cli prints "Associated with: <number>".
#   3. The number is written to <Moe home>/signal/account (what
#      signal-daemon.sh starts from), and to ~/.hermes/.env as SIGNAL_ACCOUNT,
#      SIGNAL_HTTP_URL=http://127.0.0.1:<port> and SIGNAL_ALLOWED_USERS=<the
#      same number> — so Moe answers the account owner and nobody else.
#   4. config.yaml: platforms.signal.enabled true, and
#      platforms.signal.extra.unauthorized_dm_behavior ignore. That second one
#      matters more than it looks: the default is "pair", which answers a
#      stranger's DM with a pairing code — and on a linked device a stranger
#      is anyone who messages the person, and the answer would go out from
#      the person's own account. (Hermes already defaults to "ignore" once an
#      allowlist is set, authz_mixin._get_unauthorized_dm_behavior step 5;
#      this is the second lock.) Groups stay off: SIGNAL_GROUP_ALLOWED_USERS
#      is never written.
#
# Machine lines on stdout, for the app (never a secret, never the number):
#   QR=<sgnl://linkdevice?…>   the code to draw
#   NEEDS_RESTART=gateway      the gateway reads .env/config.yaml only at start
#
# Exit: 0 linked · 1 wrong usage / no Hermes · 3 could not start (no Signal
# support, signal-cli refused, Signal said no) · 4 nobody scanned in time.
#
# **The trust ask is stated, not buried.** A linked device receives the
# whole account: every chat, contact and group. Moe acts only on Note to Self
# (the allowlist above, and the adapter drops the person's messages to other
# people — signal.py _unwrap_sync_message), but it holds the rest. On a
# terminal this says so and asks first; in the app, the row's description
# says it before Connect is clicked (ConnectionsModel's Signal blurb) — a
# prompt nothing can answer is not consent, it is a hang.
#
# Redirection for tests: HERMES_HOME, HERMES_AGENT_DIR (its .venv/bin/python
# runs the Python step), HERMES_BIN, MOE_HOME, MOE_SIGNAL_CLI_BIN (a
# signal-cli to run instead of the downloaded one — the suite's fake prints a
# URI and "Associated with:" with no Signal and no network), MOE_SIGNAL_PORT.
# Bash 3.2 and `set -u` clean.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME
AGENT_DIR="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
MOE="${MOE_HOME:-$HOME/.moe}"
CONN="$MOE/connectors"
[ -f "$CONN/hermeslib.py" ] || CONN="$HERE/../moe-home/connectors"
[ -f "$CONN/hermeslib.py" ] || { echo "✗ hermeslib.py not found under $CONN — re-run the installer"; exit 1; }
SIG="$MOE/signal"
ACCOUNT_FILE="$SIG/account"
# Linked is the account file AND the keys beside it — the test signal-daemon.sh
# starts from. With either gone the daemon never starts, so it is not linked
# here either, and connecting again is a new scan.
linked() { [ -s "$ACCOUNT_FILE" ] && [ -d "$SIG/data" ]; }

TIMEOUT=180
MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-}"; shift ;;
    --status) MODE=status ;;
    --forget) MODE=forget ;;
    -h|--help) sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown option $1"; exit 1 ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "✗ --timeout needs a number of seconds"; exit 1 ;; esac

runtime_ready() { [ -n "${MOE_SIGNAL_CLI_BIN:-}" ] || "$HERE/fetch-signal-cli.sh" --check; }

if [ "$MODE" = status ]; then
  if ! linked; then echo "needs-setup: not linked — connect.sh signal"; exit 1; fi
  if ! runtime_ready; then echo "needs-setup: linked, but Signal support has to be downloaded again (no new scan) — connect.sh signal"; exit 1; fi
  echo "ok: this Mac is linked to Signal"; exit 0
fi

if [ "$MODE" = forget ]; then
  # The account's keys live in data/; without them this Mac is no longer the
  # device the phone linked, whatever the phone still lists.
  if [ -e "$ACCOUNT_FILE" ] || [ -e "$SIG/data" ]; then
    rm -rf "$SIG/data" "$ACCOUNT_FILE"
    echo "✓ Signal unlinked on this Mac. Remove “Alfie” in Signal › Settings › Linked devices on your phone too."
  else
    echo "✓ Signal was not linked on this Mac."
  fi
  exit 0
fi

PY="$AGENT_DIR/.venv/bin/python"
if [ ! -x "$PY" ]; then
  echo "✗ Alfie's brain is not installed yet — run scripts/install.sh first."
  exit 1
fi
HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
[ -n "$HERMES_BIN" ] || HERMES_BIN="$AGENT_DIR/.venv/bin/hermes"
export PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

PORT="${MOE_SIGNAL_PORT:-}"
[ -n "$PORT" ] || { [ -s "$SIG/port" ] && PORT="$(head -n 1 "$SIG/port" | tr -d '[:space:]')"; } || true
[ -n "$PORT" ] || PORT=18649
case "$PORT" in ''|*[!0-9]*) echo "✗ the Signal port is not a number"; exit 1 ;; esac

mkdir -p "$SIG"; chmod 700 "$SIG"

if linked; then
  # Relinking throws away a working link and makes the person scan again —
  # and leaves a dead "Moe" on their phone. A link with no runtime (a pin
  # bump, a deleted runtime) needs the runtime, never a scan.
  if runtime_ready; then
    echo "✓ Signal is already linked on this Mac."
  else
    echo "Signal is linked on this Mac; getting the Signal support it needs (no new scan)…"
    "$HERE/fetch-signal-cli.sh" || exit 3
    runtime_ready || { echo "✗ Signal support did not install."; exit 3; }
    echo "✓ Signal support is up to date, and this Mac is still linked."
  fi
else
  if [ -t 0 ] && [ -z "${MOE_CONNECT_NONINTERACTIVE:-}" ]; then
    cat <<'EOF'
Connect Signal
──────────────
Signal has no bot accounts, so Alfie links to your own Signal as a device —
the same as Signal Desktop. That means:

  • this Mac receives your whole Signal account: every chat, contact and
    group — Alfie answers only what you write in Note to Self, but it holds
    the rest;
  • Alfie's replies appear in Note to Self;
  • you can unlink it any time: Signal › Settings › Linked devices.

EOF
    read -r -p "Continue? [y/N] " yn
    case "${yn:-n}" in [Yy]*) ;; *) echo "Skipped."; exit 0 ;; esac
  fi

  if [ -n "${MOE_SIGNAL_CLI_BIN:-}" ]; then
    CLI="$MOE_SIGNAL_CLI_BIN"; JH="${JAVA_HOME:-}"
  else
    "$HERE/fetch-signal-cli.sh" || exit 3
    paths="$("$HERE/fetch-signal-cli.sh" --paths)" || { echo "✗ Signal support did not install."; exit 3; }
    JH="$(printf '%s\n' "$paths" | sed -n 's/^JAVA_HOME=//p')"
    CLI="$(printf '%s\n' "$paths" | sed -n 's/^SIGNAL_CLI=//p')"
  fi

  echo "Open Signal on your phone › Settings › Linked devices › + , then scan the code."
  rc=0
  JAVA_HOME="$JH" "$PY" - "$CONN" "$TIMEOUT" "$CLI" "$SIG" <<'PY' || rc=$?
import os, re, subprocess, sys, threading
conn_dir, timeout, cli, sig = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
sys.path.insert(0, conn_dir)
import hermeslib as H

data = os.path.join(sig, "data")
os.makedirs(data, exist_ok=True)
os.chmod(data, 0o700)
env = dict(os.environ)
if not env.get("JAVA_HOME"):
    env.pop("JAVA_HOME", None)
try:
    # "Moe" is the name the phone lists the device under; it learns it at the scan.
    proc = subprocess.Popen([cli, "--config", data, "link", "-n", "Alfie"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace", start_new_session=True, env=env)
except OSError as e:
    print("✗ Could not start Signal support (%s)." % type(e).__name__)
    sys.exit(3)

def stop():
    if proc.poll() is not None:
        return
    try:
        proc.terminate(); proc.wait(timeout=5)
    except Exception:
        try: proc.kill()
        except Exception: pass

# The timeout ends the child, so the read loop ends because stdout closed —
# one clock, not a second tighter one on each read ("a backstop must be
# looser than what it backs").
timer = threading.Timer(max(1, timeout), stop)
timer.daemon = True
timer.start()

URI = re.compile(r"^sgnl://linkdevice\?\S+$")
ASSOC = re.compile(r"^Associated with:\s*(\+[0-9]{6,15})\s*$")
number, seen_uri, last = None, False, ""
try:
    for raw in (proc.stdout or []):
        line = raw.strip()
        if not line:
            continue
        if URI.match(line):
            seen_uri = True
            print("QR=%s" % line)
            sys.stdout.flush()
            continue
        m = ASSOC.match(line)
        if m:
            number = m.group(1)
            break
        # Everything else is signal-cli's own logging. Kept for the error
        # message, never echoed: it names the account.
        last = line
finally:
    timer.cancel()
    # After "Associated with" signal-cli is saving the account it just
    # linked; stopping it mid-write would lose the link the person just
    # scanned. So it gets a bounded minute to finish, and only then is ended.
    if number:
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
    stop()

if not number:
    if not seen_uri:
        print("✗ Signal never sent a code to scan. Check the network and try again.%s"
              % ((" (%s)" % H.one_line(re.sub(r"\+[0-9]{6,15}", "…", last), 100)) if last else ""))
        sys.exit(3)
    print("✗ Nobody scanned the code in time. Try again — Signal › Settings › Linked devices › +.")
    sys.exit(4)

tmp = os.path.join(sig, ".account.tmp")
with open(tmp, "w") as f:
    f.write(number + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, os.path.join(sig, "account"))
print("✓ Linked.")
PY
  [ "$rc" -eq 0 ] || exit "$rc"
fi

printf '%s\n' "$PORT" > "$SIG/port"

# .env: the address the gateway reaches the daemon at, whose account it is,
# and who may talk to Moe there — the person, and nobody else by default.
"$PY" - "$CONN" "$ACCOUNT_FILE" "$PORT" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import hermeslib as H
number = open(sys.argv[2]).read().strip()
env_path = os.path.join(H.hermes_home(), ".env")
H.dotenv_set(env_path, "SIGNAL_HTTP_URL", "http://127.0.0.1:%s" % sys.argv[3])
H.dotenv_set(env_path, "SIGNAL_ACCOUNT", number)
keys = H.env_keys(env_path)
if "SIGNAL_ALLOWED_USERS" not in keys:
    H.dotenv_set(env_path, "SIGNAL_ALLOWED_USERS", number)
PY

cfg() { # key value → non-fatal: the .env keys are what start the platform
  local out
  if out="$(HERMES_HOME="$HERMES_HOME" SSH_TTY="${SSH_TTY:-moe}" "$HERMES_BIN" config set "$1" "$2" 2>&1)"; then
    echo "✓ config.yaml: $1: $2"
  else
    echo "… could not set $1 in config.yaml ($(printf '%s' "$out" | tail -n 1))"
  fi
}
cfg platforms.signal.enabled true
cfg platforms.signal.extra.unauthorized_dm_behavior ignore
echo "✓ Signal connected. Once Alfie restarts, write to yourself in Note to Self."
echo "NEEDS_RESTART=gateway"

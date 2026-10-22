#!/bin/bash
# Connect WhatsApp: scan one QR code in the app. No Terminal, no Go, no clone.
#
#   connect-whatsapp.sh [--timeout SECONDS]   (default 180)
#   connect-whatsapp.sh --status              is a device already linked?
#
# **What this used to do, and why none of it was needed.** It printed a
# warning, asked `read -r -p "Continue anyway?"` — which no app can answer —
# then required the person to install the Go toolchain by hand, cloned
# `lharries/whatsapp-mcp` from GitHub, built it, and left a foreground
# process printing a QR code into a terminal window. Hermes has shipped its
# own WhatsApp bridge the whole time: `scripts/whatsapp-bridge/bridge.js`,
# Node bundled at ~/.hermes/node, a `--pair-only --pair-json` mode that emits
# `{"event":"qr","qr":…}` then `{"event":"connected","user":…}` on stdout,
# and a session under $HERMES_HOME/whatsapp/session that the gateway adapter
# picks up. Hermes's own dashboard drives exactly this
# (`/api/messaging/whatsapp/onboarding/*`); Moe drove a stranger's Go program
# instead, and sent the person to a terminal to do it.
#
# So this drives the bundled bridge, and speaks the app's machine lines on
# stdout:
#
#   QR=<payload>          the code to render. Sent again each time WhatsApp
#                         rotates it (~every 20 s) — the app re-renders
#   LINKED=1              the phone scanned and WhatsApp said yes. Sent the
#                         moment the bridge reports `connected` — seconds
#                         after the scan, and up to three minutes before this
#                         script exits, because it waits for the phone's
#                         history first. Without it the app sat on a dead QR
#                         code for those minutes, saying nothing, which is
#                         exactly what the owner reported on 2026-09-20
#   NEEDS_RESTART=gateway on success: the session is linked, .env says
#                         WHATSAPP_ENABLED=true and config.yaml says
#                         platforms.whatsapp.enabled: true; the gateway reads
#                         those only at start, and restarting it is the
#                         app's job
#
# Exit: 0 linked · 1 wrong usage / no Hermes · 3 the bridge could not start
# (no Node, dependencies would not install, WhatsApp refused) · 4 nobody
# scanned in time.
#
# **The one device keeps your history.** Since 2026-09-11 the bridge mirrors
# every chat, contact and message it sees into a SQLite store
# ($HERMES_HOME/whatsapp/store/messages.db, history_store.js beside the
# bridge) that connectors/whatsapp.sh reads — the archive the old second
# device (lharries/whatsapp-mcp, a Go toolchain and a clone) used to keep.
# Two .env lines switch it on, WHATSAPP_HISTORY_DB and
# WHATSAPP_SYNC_FULL_HISTORY, written here whether the link was just made
# or already there: a link made before the store existed is turned on by
# running this again, with no second scan. The pairing process gets the
# same two, because the phone sends its history in the seconds after the
# scan and the bridge now waits for those chunks before exiting (it says
# `history` as they land and `history_done` with the counts; an older
# bridge exits two seconds after `connected` and says neither).
#
# **The warning is still true and is still shown.** Linking a device is
# against WhatsApp's terms, accounts have been banned for it, and the link
# drops every few weeks. On a terminal this asks before doing anything. In
# the app the question cannot be asked down a pipe, so the warning lives in
# the row's own description (hermes-catalog.py PLATFORM_HELP["whatsapp"]),
# read before Connect is clicked — a prompt nothing can answer is not
# consent, it is a hang.
#
# Redirection for tests: HERMES_HOME, HERMES_AGENT_DIR (its .venv/bin/python
# runs the Python step), HERMES_BIN, MOE_HOME, and MOE_WHATSAPP_BRIDGE_CMD —
# a command to run instead of `node bridge.js`, so the suite can drive a fake
# bridge that emits the same JSON lines with no WhatsApp and no network.
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

TIMEOUT=180
STATUS_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-}"; shift ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown option $1"; exit 1 ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "✗ --timeout needs a number of seconds"; exit 1 ;; esac

SESSION="$HERMES_HOME/whatsapp/session"

if [ -n "$STATUS_ONLY" ]; then
  if [ -f "$SESSION/creds.json" ]; then echo "ok: a device is linked"; exit 0; fi
  echo "needs-setup: no device linked — connect.sh whatsapp"; exit 1
fi

PY="$AGENT_DIR/.venv/bin/python"
if [ ! -x "$PY" ]; then
  echo "✗ Alfie's brain is not installed yet — run scripts/install.sh first."
  exit 1
fi
HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
[ -n "$HERMES_BIN" ] || HERMES_BIN="$AGENT_DIR/.venv/bin/hermes"
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$AGENT_DIR"
export PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# Already linked: relinking throws away a working session and makes the
# person scan again for nothing.
ALREADY_LINKED=0
if [ -f "$SESSION/creds.json" ]; then
  ALREADY_LINKED=1
  echo "✓ WhatsApp is already linked on this Mac."
else
  # The warning, when there is a person on the other end who can answer it.
  if [ -t 0 ] && [ -z "${MOE_CONNECT_NONINTERACTIVE:-}" ]; then
    cat <<'EOF'
Connect WhatsApp
────────────────
WhatsApp has no personal API. Alfie links as a device, the same as WhatsApp
Web, which means:

  • it is against WhatsApp's terms of service;
  • accounts using tools like this have been warned and banned — including
    quiet, read-only ones;
  • the link drops every few weeks and you scan again.

If your WhatsApp number matters to you, skip this and let Alfie cover
everything else.

EOF
    read -r -p "Continue anyway? [y/N] " yn
    case "${yn:-n}" in
      [Yy]*) ;;
      *) echo "Skipped. Good call."; exit 0 ;;
    esac
  fi

  echo "Open WhatsApp › Settings › Linked Devices › Link a Device, then scan the code."

  rc=0
  "$PY" - "$CONN" "$TIMEOUT" "$SESSION" <<'PY' || rc=$?
import json, os, subprocess, sys, threading
conn_dir, timeout, session = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sys.path.insert(0, conn_dir)
import hermeslib as H

# Hermes's own resolvers, never a copy of where the bridge lives: Moe keeping
# a second, worse answer to a question Hermes had already answered is the
# whole of the defect being fixed here.
override = os.environ.get("MOE_WHATSAPP_BRIDGE_CMD")
store = os.environ.get("WHATSAPP_HISTORY_DB") or os.path.join(H.hermes_home(), "whatsapp", "store", "messages.db")
if override:
    import shlex
    cmd, cwd, env = shlex.split(override), None, dict(os.environ)
else:
    try:
        from gateway.platforms.whatsapp_common import resolve_whatsapp_bridge_dir
        from hermes_constants import find_node_executable, with_hermes_node_path
    except ImportError as e:
        print("✗ This version of Alfie cannot link WhatsApp (%s)." % e)
        sys.exit(3)
    bridge_dir = resolve_whatsapp_bridge_dir()
    script = bridge_dir / "bridge.js"
    if not script.exists():
        print("✗ Alfie's WhatsApp bridge is missing — reinstall Alfie.")
        sys.exit(3)
    node = find_node_executable("node")
    if not node:
        print("✗ Alfie's copy of Node is missing — reinstall Alfie.")
        sys.exit(3)
    env = with_hermes_node_path()
    # The bridge's dependencies, installed once, from the npm that ships
    # beside Node. The only slow step, so it says so rather than looking hung.
    if not (bridge_dir / "node_modules").exists():
        npm = find_node_executable("npm")
        if not npm:
            print("✗ Alfie's copy of npm is missing — reinstall Alfie.")
            sys.exit(3)
        print("Setting up WhatsApp for the first time (about a minute)…")
        sys.stdout.flush()
        try:
            r = subprocess.run([npm, "install", "--silent"], cwd=str(bridge_dir),
                               capture_output=True, text=True, timeout=600, env=env)
        except (OSError, subprocess.TimeoutExpired) as e:
            print("✗ Could not set up WhatsApp (%s)." % type(e).__name__)
            sys.exit(3)
        if r.returncode != 0:
            print("✗ Could not set up WhatsApp: %s" % H.one_line(r.stderr or r.stdout, 120))
            sys.exit(3)
    # WHATSAPP_DM_POLICY=pairing is what Hermes's own dashboard passes: a
    # stranger who messages the linked number is asked to pair rather than
    # answered. Anything else makes linking a phone mean "answer everyone
    # in it".
    env["WHATSAPP_MODE"] = os.environ.get("WHATSAPP_MODE") or "bot"
    env["WHATSAPP_DM_POLICY"] = "pairing"
    cmd = [node, str(script), "--pair-only", "--pair-json", "--session", session]
    cwd = str(bridge_dir)

# The name the phone lists the link under (WhatsApp > Linked Devices). The
# bridge's default is the engine's name, and the phone learns the name at
# the scan — so it has to be right for THIS process, not only in .env for
# the next one. Outside the branch above on purpose: the test's stand-in
# bridge (MOE_WHATSAPP_BRIDGE_CMD) measures what it was handed.
env["WHATSAPP_DEVICE_NAME"] = os.environ.get("WHATSAPP_DEVICE_NAME") or "Alfie"
# The history the one device keeps, to the pairing process too: the phone
# sends its recent chats right after the scan, and without a store to put
# them in they land on the floor. A person's own "false" is respected.
env["WHATSAPP_HISTORY_DB"] = store
env.setdefault("WHATSAPP_SYNC_FULL_HISTORY", "true")

os.makedirs(session, exist_ok=True)
try:
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace",
                            start_new_session=True, env=env)
except OSError as e:
    print("✗ Could not start the WhatsApp bridge (%s)." % type(e).__name__)
    sys.exit(3)


def stop():
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


# The timeout is enforced by ending the child, so the read loop finishes
# because stdout closed. A second, tighter clock on the readline itself is
# the trap CLAUDE.md names — "a backstop must be looser than what it backs" —
# and it would report "nobody scanned" over a scan that was in flight.
timer = threading.Timer(max(1, timeout), stop)
timer.daemon = True
timer.start()

user = None
seen_qr = False
error = ""
history = None          # the last counts the bridge reported
saving_said = False
# Once linked, how long to wait for the phone's history before moving on.
# Looser than the bridge's own 180 s ceiling on purpose — a backstop must
# be looser than what it backs, or it is the thing that cuts it off.
history_wait = int(os.environ.get("MOE_WHATSAPP_HISTORY_WAIT") or "200")
try:
    for raw in (proc.stdout or []):
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue            # the bridge logs prose too; ignore it
        if not isinstance(ev, dict):
            continue
        kind = str(ev.get("event") or "")
        if kind == "qr":
            qr = str(ev.get("qr") or "").strip()
            # One line and no whitespace: the app reads these line by line.
            if qr and not any(c.isspace() for c in qr):
                seen_qr = True
                print("QR=%s" % qr)
                sys.stdout.flush()
        elif kind == "connected":
            u = ev.get("user")
            user = u if isinstance(u, dict) else {}
            # Say so NOW. Everything below this line — the phone's history,
            # the .env writes, the gateway restart — happens with a person
            # watching a code they have already scanned, and that wait is
            # minutes, not seconds.
            print("LINKED=1")
            sys.stdout.flush()
            # Linked. The scan clock is done; the bridge now waits for the
            # phone's history and exits by itself when it stops arriving
            # (an older bridge exits two seconds from now). This clock backs
            # that one and ends the read loop by ending the child, as above.
            timer.cancel()
            timer = threading.Timer(max(1, history_wait), stop)
            timer.daemon = True
            timer.start()
        elif kind == "history":
            history = ev
            if not saving_said:
                print("Linked. Saving your recent chats…")
                sys.stdout.flush()
                saving_said = True
        elif kind == "history_done":
            history = ev
            break
        elif kind == "error":
            error = H.one_line(str(ev.get("error") or ""), 120)
            break
finally:
    timer.cancel()
    stop()

if user is None:
    if error:
        print("✗ WhatsApp said: %s" % error)
        sys.exit(3)
    if not seen_qr:
        print("✗ WhatsApp never sent a code to scan. Check the network and try again.")
        sys.exit(3)
    print("✗ Nobody scanned the code in time. Try again — WhatsApp › Settings › "
          "Linked Devices › Link a Device.")
    sys.exit(4)

# Linked. WHATSAPP_ENABLED is what actually turns the platform on; the
# session on disk is what it links with.
env_path = os.path.join(H.hermes_home(), ".env")
H.dotenv_set(env_path, "WHATSAPP_ENABLED", "true")

# The account that just scanned is the owner, exactly as Telegram's
# owner_user_id is. Without it Hermes answers nobody until a pairing is
# approved, and the person who linked their own phone is the last one who
# should have to ask permission to use it.
me = str(user.get("id") or "").split(":")[0].split("@")[0].strip()
keys = H.env_keys(env_path)
if me and "WHATSAPP_ALLOWED_USERS" not in keys and "WHATSAPP_ALLOW_ALL_USERS" not in keys:
    H.dotenv_set(env_path, "WHATSAPP_ALLOWED_USERS", me)

# Every reply the bridge sends opens with "⚕ *Hermes Agent*" and a rule
# unless WHATSAPP_REPLY_PREFIX is set — set to anything, including nothing
# (bridge.js: `=== undefined` is the only test). The person messaged Moe, and
# the engine's name on every line was the first thing the owner saw. Left
# alone if someone has chosen a prefix of their own.
if "WHATSAPP_REPLY_PREFIX" not in keys:
    H.dotenv_set(env_path, "WHATSAPP_REPLY_PREFIX", "")

# The same for the name on the phone. The bridge the gateway spawns after
# this gets an explicit env built from .env (the adapter's passthrough list),
# so the value has to be in .env for every reconnect, not only the scan above.
# Reaches a bridge that reads WHATSAPP_DEVICE_NAME (the fork, from a95583fd7f);
# an older bridge ignores it and keeps its default. Left alone if chosen.
if "WHATSAPP_DEVICE_NAME" not in keys:
    H.dotenv_set(env_path, "WHATSAPP_DEVICE_NAME", "Alfie")

name = H.one_line(str(user.get("name") or ""), 40)
print("✓ Linked%s." % ((" to %s" % name) if name else ""))
if isinstance(history, dict):
    m, c = history.get("messages"), history.get("chats")
    if isinstance(m, int) and isinstance(c, int) and not isinstance(m, bool):
        print("✓ Saved %d chat%s and %d message%s so far; the rest arrive while Alfie runs."
              % (c, "" if c == 1 else "s", m, "" if m == 1 else "s"))
PY
  [ "$rc" -eq 0 ] || exit "$rc"
fi

# The history store the one device keeps, switched on in .env whether the
# link was just made or was already there: a link made before 2026-09-11
# has a session and no store, and running Connect again is how it gets
# one — no second scan, and the gateway restart the app does on
# NEEDS_RESTART starts the bridge with it. Lines somebody set are left.
HAD_SESSION="$ALREADY_LINKED" "$PY" - "$CONN" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import hermeslib as H
had_session = os.environ.get("HAD_SESSION") == "1"
env_path = os.path.join(H.hermes_home(), ".env")
keys = H.env_keys(env_path)
store = os.environ.get("WHATSAPP_HISTORY_DB") or os.path.join(H.hermes_home(), "whatsapp", "store", "messages.db")
if "WHATSAPP_HISTORY_DB" not in keys:
    H.dotenv_set(env_path, "WHATSAPP_HISTORY_DB", store)
if "WHATSAPP_SYNC_FULL_HISTORY" not in keys:
    H.dotenv_set(env_path, "WHATSAPP_SYNC_FULL_HISTORY", "true")
print("✓ Alfie keeps your chats to read, in %s" % store)
# The phone sends its history only at the moment of a scan, and nothing can
# ask for it later. So a session that predates the store gets everything
# from now on and none of the past, and the only way to the past is a fresh
# scan. Said here, where the person has just been told the store is on.
if had_session:
    print("  Your phone sends its chats over when you scan, so this keeps everything from now on.")
    print("  To have the older ones too, unlink Alfie on your phone (Settings › Linked Devices) and connect again.")
PY

# The explicit flag in config.yaml (see connect.sh platform_enabled for why);
# non-fatal, WHATSAPP_ENABLED already makes the gateway start it.
if out="$(HERMES_HOME="$HERMES_HOME" SSH_TTY="${SSH_TTY:-moe}" "$HERMES_BIN" config set platforms.whatsapp.enabled true 2>&1)"; then
  echo "✓ config.yaml: platforms.whatsapp.enabled: true"
else
  echo "… could not set platforms.whatsapp.enabled in config.yaml ($(printf '%s' "$out" | tail -n 1))"
fi
echo "✓ WhatsApp connected. Message yourself once Alfie restarts."
echo "NEEDS_RESTART=gateway"

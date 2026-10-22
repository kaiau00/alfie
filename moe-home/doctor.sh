#!/bin/bash
# What's connected, what isn't, and exactly what to do about it.
set -uo pipefail

MOE="$HOME/.moe"
CONN="$MOE/connectors"

# The list of sources comes from the manifests in connectors/, so a newly
# installed connector shows up here without anyone editing this file.
. "$MOE/lib/connectors.sh" || {
  echo "missing $MOE/lib/connectors.sh — re-run scripts/install.sh" >&2; exit 1; }

green() { printf '\033[32m%s\033[0m\n' "$1"; }
amber() { printf '\033[33m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

echo "Alfie — connection check"
echo "═════════════════════════"
echo

# ── The one hard requirement ───────────────────────────────────────────────
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
if [ -x "$CLAUDE_BIN" ]; then
  green "✓ claude CLI            $($CLAUDE_BIN --version 2>/dev/null | head -1)"
else
  red   "✗ claude CLI            not found — Alfie cannot think without it"
fi

if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  green "✓ subscription login    credentials in Keychain (no API key needed)"
else
  amber "! subscription login    run 'claude' once and log in"
fi

# Calendar and Reminders are read through the Moe binary (EventKit). The
# permission sheet is raised here — someone is watching — and never from the
# sync timer (sync.sh sets MOE_EVENTKIT_NO_PROMPT). Two minutes to answer it.
MOE_BIN="${MOE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
if [ -x "$MOE_BIN" ]; then
  echo
  echo "Permissions"
  echo "───────────"
  /usr/bin/perl -e 'alarm 120; exec @ARGV' "$MOE_BIN" --eventkit-request 2>&1 | while IFS= read -r line; do
    case "$line" in
      ok:*)          green "  ✓ ${line#ok: }" ;;
      needs-setup:*) amber "  … ${line#needs-setup: }" ;;
      *)             red   "  ✗ $line" ;;
    esac
  done
fi

echo
echo "Sources"
echo "───────"

check() { # label, connector name
  local label out
  # Pad so the dashes line up; the longest stock label is 25 characters.
  label="$(printf '%-25s' "$1")"
  if ! connector_script "$2" >/dev/null; then
    amber "  ? $label — connector missing"
    return
  fi
  out="$(connector_status "$2")"
  case "$out" in
    ok:*)          green "  ✓ $label — ${out#ok: }" ;;
    needs-setup:*) amber "  … $label — ${out#needs-setup: }" ;;
    *)             red   "  ✗ $label — ${out#unavailable: }" ;;
  esac
}

# `label` is the one optional manifest field; fall back to the name. The
# Mac-native connectors first; the Hermes provider's virtual ones
# (lib/connectors.sh) get their own heading below.
HERMES_CONNS=""
for name in $(connectors_list); do
  case "$name" in
    hermes:*) HERMES_CONNS="$HERMES_CONNS $name"; continue ;;
  esac
  label="$(connector_field "$name" label)"
  check "${label:-$name}" "$name"
done

echo
echo "Through Hermes (MCP servers, skills, chat platforms)"
echo "────────────────────────────────────────────────────"
if [ -z "$HERMES_CONNS" ]; then
  amber "  … nothing connected yet — ~/.moe/scripts/connect.sh lists what Hermes offers"
fi
for name in $HERMES_CONNS; do
  kind="${name#hermes:}"; kind="${kind%%:*}"
  label="$(connector_field "$name" label)"
  check "$(printf '%-9s' "$kind") ${label:-${name##*:}}" "$name"
done

# Composio's key is the one credential here whose WRONGNESS is invisible: a
# scoped key and a full project key are both `ak_`-prefixed and identical to
# the eye, and the difference is "acts as one person" versus "reads every
# user's Google refresh token in plaintext". So this asks Composio what the
# key may DO rather than looking at it.
#
# Called, not copied. moe-47 owns scripts/check-composio-key.sh and holds its
# exit contract (0 scoped / 1 full / 2 could-not-ask); one implementation is
# the point, so that if it ever learns a new way to tell them apart it learns
# it once. A missing script is not a failure here — a checkout without it is
# older, not broken.
if grep -q '^  composio:' "${HERMES_HOME:-$HOME/.hermes}/config.yaml" 2>/dev/null; then
  echo
  echo "Composio"
  echo "────────"
  KEYCHECK=""
  for candidate in "$MOE/scripts/check-composio-key.sh" \
                   "$(dirname "$0")/../scripts/check-composio-key.sh"; do
    [ -x "$candidate" ] && { KEYCHECK="$candidate"; break; }
  done
  if [ -z "$KEYCHECK" ]; then
    amber "  … cannot check which kind of key is in use (no check-composio-key.sh)"
  else
    "$KEYCHECK" >/dev/null 2>&1
    case $? in
      0) green "  the key in use is scoped — it cannot read anyone's stored tokens" ;;
      1) red   "  the key in use is a FULL project key. It can read every connected
     account's access and refresh tokens in plaintext. Replace it with a
     scoped one before this ships anywhere." ;;
      *) amber "  could not ask Composio which kind of key this is" ;;
    esac
  fi
fi

echo
echo "Toolsets"
echo "────────"
# What the *running* gateway loaded, not what configure-hermes.py wrote.
# An explicit platform_toolsets list is the only thing Hermes honours, and a
# name on it can still arrive disabled (a plugin that failed to import) or
# unconfigured (a tool whose credential is missing) — neither of which is
# visible in config.yaml. Silent when the gateway is down; the claude CLI
# check above is the place that complains about a brain that isn't there.
TS="$(python3 "$CONN/hermes-connections.py" toolsets 2>/dev/null)"
if [ -n "$TS" ]; then
  printf '%s\n' "$TS" | while IFS=$'\t' read -r state name; do
    case "$state" in
      ok)          green "  ✓ $name" ;;
      needs-setup) amber "  … $name — loaded, but not configured" ;;
      *)           red   "  ✗ $name — listed but disabled" ;;
    esac
  done
else
  amber "  … gateway not answering — start Alfie, or run 'hermes serve'"
fi

echo
echo "Background jobs"
echo "───────────────"
# com.moe.jobs replaced com.moe.sync and com.moe.digest. Checking the old two
# meant a healthy, migrated Mac reported both of its background jobs broken —
# and the agent that actually runs was invisible to the one diagnostic the
# product ships.
for job in com.moe.jobs; do
  if launchctl list 2>/dev/null | grep -q "$job"; then
    green "  ✓ $job running"
  else
    amber "  … $job not loaded"
  fi
done

echo
echo "The send gate"
echo "─────────────"
# The one check worth running before trusting anything else here: does the
# confirmation actually stand in front of a send, right now, on this Mac?
#
# It is asked rather than assumed because every part of it can be true
# separately and still not work together. The hook has to be registered in
# the process that dispatches the tool call, the dialog has to be somewhere
# it can be found, and confirm.sh has to reach it. Hermes registers the hook
# per process and logs a failure at a level nobody sees, so "configured" and
# "running" are different questions.
#
# Nothing is sent: the hook is fed a synthetic Gmail send, and $MOE_CONFIRM_BIN
# answers it with "cancelled" instead of a dialog.
GATE_HOOK="$MOE/hermes/hooks/confirm-send.sh"
if [ ! -x "$GATE_HOOK" ]; then
  red "  ✗ confirm-send.sh missing — re-run scripts/install.sh"
else
  # $MOE_HOME points at the scratch dir for both probes below: the hook logs
  # every decision, and a check that writes two rows into the real audit trail
  # and then prints `tail -1` of it as "last time Moe asked you" can only ever
  # report itself.
  GATE_TMP="$(mktemp -d)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$2" > "%s/asked"\nexit 1\n' "$GATE_TMP" > "$GATE_TMP/stub"
  chmod +x "$GATE_TMP/stub"
  # A foreign server's send, not our own gmail_send: the hook defers that one
  # to gmail.py's dialog at the socket, so it would never write "asked".
  printf '{"tool_name":"mcp__other__gmail_send","tool_input":{"to":"nobody@example.invalid","subject":"gate check","body":"nothing is sent by this"}}' \
    | MOE_HOME="$GATE_TMP" MOE_HOOK_TEST=1 MOE_CONFIRM_BIN="$GATE_TMP/stub" \
      bash "$GATE_HOOK" >/dev/null 2>&1
  if [ -s "$GATE_TMP/asked" ]; then
    green "  ✓ a send is stopped and shown to you ($(tr -d '\n' < "$GATE_TMP/asked"))"
  else
    red   "  ✗ a send was NOT stopped — the confirmation would not appear"
  fi
  rm -rf "$GATE_TMP"

  # And whether the gate on this Mac is the one that was fixed. An installed
  # copy older than the repo is not hypothetical: the hook lives in
  # ~/.moe/hermes/hooks, install.sh is what puts it there, and a fix that
  # never reaches the machine is a fix nobody has. There are no version
  # numbers to compare, so this asks the gate to refuse something a current
  # one refuses — replacing the dialog it runs.
  GATE_TMP2="$(mktemp -d)"
  printf '#!/bin/bash\nexit 1\n' > "$GATE_TMP2/stub"; chmod +x "$GATE_TMP2/stub"
  printf '%s' '{"tool_name":"terminal","tool_input":{"command":"cp /bin/true ~/.moe/tools/moe-confirm"}}' \
    | MOE_HOME="$GATE_TMP2" MOE_HOOK_TEST=1 MOE_CONFIRM_BIN="$GATE_TMP2/stub" \
      bash "$GATE_HOOK" >/dev/null 2>&1
  if [ "$?" = "2" ]; then
    green "  ✓ nothing may replace the dialog itself"
  else
    amber "  ! this gate is older than the current one — run scripts/install.sh"
  fi
  rm -rf "$GATE_TMP2"
fi

# And the dialog itself: the one Moe draws, or the AppleScript one.
if [ -x "/Applications/Memoe.app/Contents/MacOS/moe-confirm" ]; then
  green "  ✓ Alfie's own confirmation dialog is installed"
elif [ -x "$MOE/tools/confirm.sh" ]; then
  amber "  … Alfie's dialog is missing; sends fall back to the plain macOS one"
else
  red   "  ✗ no confirmation dialog at all — nothing may be sent"
fi

# Whether Hermes is currently running the hook is a different question again,
# and the log is the only honest answer to it.
GATE_LOG="$MOE/logs/confirm-hook.log"
if [ -f "$GATE_LOG" ]; then
  LAST="$(tail -1 "$GATE_LOG" | cut -f1)"
  echo "  · last time Alfie asked you: $LAST"
fi

# What the gate does with each tool — decided by declaration, not by wording.
# `tools/gate.sh list` is the full table; this is the shape of it.
if [ -x "$GATE_HOOK" ]; then
  GATE_INV="$(MOE_HOME="$MOE" bash "$GATE_HOOK" --inventory 2>/dev/null)"
  if [ -n "$GATE_INV" ]; then
    # Own connector verbs appear twice (bare, and through the moe bridge);
    # count them once.
    GATE_INV="$(printf '%s\n' "$GATE_INV" | grep -v '^mcp__moe__')"
    G_RUN="$(printf '%s\n' "$GATE_INV" | awk -F'\t' '$3 ~ /^runs/' | wc -l | tr -d ' ')"
    G_ASK="$(printf '%s\n' "$GATE_INV" | awk -F'\t' '$3 ~ /^asks/' | wc -l | tr -d ' ')"
    G_YOU="$(printf '%s\n' "$GATE_INV" | awk -F'\t' '$4 ~ /^you / || $4 ~ /^your /' | wc -l | tr -d ' ')"
    G_UNL="$(printf '%s\n' "$GATE_INV" | awk -F'\t' '$2 == "unlabelled"' | cut -d'	' -f1 | sed 's/^mcp__//; s/__.*//' | sort -u | tr '\n' ' ')"
    echo "  · $G_RUN tools run without asking (declared reads and local work), $G_ASK ask first, $G_YOU decided by you"
    if [ -n "$G_UNL" ]; then
      amber "  ! servers whose labels say nothing (every tool asks until you decide): $G_UNL"
      echo "    → ~/.moe/tools/gate.sh list <server>, then allow/trust what you are happy with"
    fi
  else
    amber "  ! the gate's inventory is empty — python3 missing, or the hook is older than this doctor"
  fi
fi
if [ -f "$MOE/gate/policy.json" ]; then
  G_MODE="$(stat -f '%Lp' "$MOE/gate/policy.json" 2>/dev/null)"
  if [ "$G_MODE" = "600" ]; then
    green "  ✓ your gate decisions are in ~/.moe/gate/policy.json (owner-only)"
  else
    amber "  ! ~/.moe/gate/policy.json is mode $G_MODE — should be 600"
  fi
fi

echo
echo "Freshness"
echo "─────────"
BRIEF="$MOE/context/_brief.md"
if [ -f "$BRIEF" ]; then
  AGE=$(( ($(date +%s) - $(stat -f %m "$BRIEF")) / 60 ))
  if [ "$AGE" -lt 30 ]; then
    green "  ✓ context refreshed ${AGE}m ago"
  else
    amber "  … context is ${AGE}m old — run ~/.moe/sync.sh"
  fi
else
  amber "  … no context yet — run ~/.moe/sync.sh"
fi

MEM=$(ls -1 "$MOE/memory"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "  · $MEM memory file(s) in ~/.moe/memory"

echo
echo "To connect what's missing:"
echo "  Anything         ~/.moe/scripts/connect.sh          — lists it all; connect.sh <name>"
echo "  Gmail            ~/.moe/scripts/connect-gmail.sh    — read and send, with an app password"
echo "  Google Drive     install Google Drive for Desktop     — no sign-in; the synced folder is read"
echo "  Chrome browsing  ~/.moe/learn/consent.sh grant chrome — opt-in, off until you say so"
echo "  Telegram chats   ~/.moe/scripts/connect-telegram.sh"
echo "  WhatsApp         ~/.moe/scripts/connect-whatsapp.sh"
echo "  Messages/Calls   grant Full Disk Access to Memoe.app in System Settings"

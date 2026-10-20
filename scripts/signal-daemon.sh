#!/bin/bash
# signal-cli's daemon, kept running beside Moe's gateway — and only beside it.
#
# Hermes's Signal platform does not speak Signal itself; it talks to a
# signal-cli daemon over HTTP (gateway/platforms/signal.py: SSE on
# /api/v1/events, JSON-RPC on /api/v1/rpc, SIGNAL_HTTP_URL + SIGNAL_ACCOUNT).
# Something has to keep that daemon alive exactly as long as the gateway is.
#
# **Who starts this, and why there.** HermesSupervisor's wrapper
# (Sources/Moe/Brain/HermesSupervisor.swift, `wrapperScript`) starts it in the
# gateway's own process group, from the same job that then `exec`s the
# gateway. So:
#   - Moe quits, crashes or is `kill -9`ed → the wrapper's lifeline closes and
#     it TERMs the whole group: the gateway and this, together;
#   - the gateway exits on its own (a restart) → this notices its parent is
#     gone (it polls $PPID, which *is* the gateway, because the job exec'd into
#     it) and stops signal-cli before the next gateway starts another;
#   - signal-cli dies on its own → restarted here, with a backoff.
# Not a LaunchAgent: that would run a 150 MB JVM (measured 153 MB RSS) while
# Moe is not running, receiving messages nobody is listening for. With the
# daemon down, Signal's server keeps them for this device until it is back.
#
# Nothing to do — and no JVM — unless Signal was linked on this Mac:
# connect-signal.sh writes <Moe home>/signal/account after a successful scan.
# **And it stops when the link goes.** Disconnect (connect.sh --remove signal
# → connect-signal.sh --forget) deletes signal/account and signal/data while
# this is running. Before 2026-09-14 nothing here looked again: signal-cli
# kept serving the account from memory, and each time it died this started a
# fresh JVM (153 MB) against keys that were no longer on disk, backing off to
# once a minute, for as long as the gateway lived. Now the link is checked
# every poll and before every start; gone means signal-cli is stopped and
# this exits.
#
# Output goes to <Moe home>/logs/signal-daemon.log, never to the gateway's
# pipes (Moe reads the gateway's first stdout line as its PID). The daemon is
# started with --no-receive-stdout, so message contents are never written to
# that log.
#
# Redirection for tests: MOE_HOME; MOE_SIGNAL_CLI_BIN (a signal-cli to run
# instead of the downloaded one); MOE_SIGNAL_PARENT (the pid to outlive-check
# instead of $PPID); MOE_SIGNAL_POLL (seconds between checks, default 2).
# Bash 3.2 and `set -u` clean.
set -u
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
MOE="${MOE_HOME:-$(cd "$HERE/.." && pwd)}"
SIG="$MOE/signal"
ACCOUNT_FILE="$SIG/account"

# The link is the account file AND the keys beside it; either gone is unlinked.
linked() { [ -s "$ACCOUNT_FILE" ] && [ -d "$SIG/data" ]; }
linked || exit 0

mkdir -p "$MOE/logs"
exec >>"$MOE/logs/signal-daemon.log" 2>&1 </dev/null
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') signal-daemon: $*"; }

account="$(head -n 1 "$ACCOUNT_FILE" | tr -d '[:space:]')"
case "$account" in
  +[0-9]*) ;;
  *) say "the saved account is not a phone number; not starting"; exit 0 ;;
esac
port="18649"
[ -s "$SIG/port" ] && port="$(head -n 1 "$SIG/port" | tr -d '[:space:]')"
case "$port" in ''|*[!0-9]*) say "the saved port is not a number; not starting"; exit 0 ;; esac

if [ -n "${MOE_SIGNAL_CLI_BIN:-}" ]; then
  CLI="$MOE_SIGNAL_CLI_BIN"; JH="${JAVA_HOME:-}"
else
  paths="$("$HERE/fetch-signal-cli.sh" --paths 2>/dev/null)" || {
    say "Signal support is not downloaded on this Mac; reconnect Signal to fetch it"; exit 0; }
  JH="$(printf '%s\n' "$paths" | sed -n 's/^JAVA_HOME=//p')"
  CLI="$(printf '%s\n' "$paths" | sed -n 's/^SIGNAL_CLI=//p')"
fi

parent="${MOE_SIGNAL_PARENT:-$PPID}"
poll="${MOE_SIGNAL_POLL:-2}"
jp=""
stop() { [ -n "$jp" ] && kill -TERM "$jp" 2>/dev/null && wait "$jp" 2>/dev/null; exit 0; }
trap stop TERM INT HUP

backoff=2
while :; do
  kill -0 "$parent" 2>/dev/null || { say "the gateway is gone; not starting signal-cli"; exit 0; }
  linked || { say "Signal is no longer linked on this Mac; not starting signal-cli"; exit 0; }
  say "starting signal-cli on 127.0.0.1:$port"
  started="$(date +%s)"
  JAVA_HOME="$JH" "$CLI" --config "$SIG/data" -a "$account" daemon \
      --http "127.0.0.1:$port" --no-receive-stdout --ignore-stories &
  jp=$!
  while kill -0 "$jp" 2>/dev/null; do
    if ! kill -0 "$parent" 2>/dev/null; then
      say "the gateway is gone; stopping signal-cli"
      stop
    fi
    if ! linked; then
      say "Signal was unlinked on this Mac; stopping signal-cli"
      stop
    fi
    sleep "$poll"
  done
  wait "$jp"; rc=$?
  jp=""
  linked || { say "Signal was unlinked on this Mac; not starting signal-cli again"; exit 0; }
  [ $(( $(date +%s) - started )) -gt 60 ] && backoff=2
  say "signal-cli stopped (exit $rc); starting it again in ${backoff}s"
  waited=0
  while [ "$waited" -lt "$backoff" ]; do
    kill -0 "$parent" 2>/dev/null || exit 0
    sleep 1; waited=$((waited+1))
  done
  backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60
done

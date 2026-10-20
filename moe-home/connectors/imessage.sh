#!/bin/bash
# iMessage + SMS, straight from the local database. Read-only.
# Needs Full Disk Access for whatever launches it (Memoe.app).
set -uo pipefail
DB="$HOME/Library/Messages/chat.db"
SINCE_HOURS="${MOE_SINCE_HOURS:-24}"

# crawl [--since DAYS] [--max-bytes N]: the learn-me pass (learn.sh). Same
# read path as pull, wider window, and a hard byte cap so one chatty source
# cannot swamp the rest. Both values are validated as plain integers before
# they go anywhere near a query.
crawl_args() {
  SINCE_DAYS=90; MAX_BYTES="${MOE_CRAWL_MAX_BYTES:-400000}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)     SINCE_DAYS="${2:-}"; shift ;;
      --max-bytes) MAX_BYTES="${2:-}"; shift ;;
      *) echo "crawl: unknown option $1" >&2; exit 2 ;;
    esac
    shift
  done
  # Each on its own: concatenated, an empty --since would hide behind a
  # valid --max-bytes and reach the query as "-  days".
  case "$SINCE_DAYS" in ''|*[!0-9]*) echo "crawl: --since takes a whole number of days" >&2; exit 2 ;; esac
  case "$MAX_BYTES"  in ''|*[!0-9]*) echo "crawl: --max-bytes takes a whole number" >&2; exit 2 ;; esac
}

# newest_cap <bytes>: the crawl's byte cap, applied to the NEWEST end.
# The query hands rows newest first; this keeps the first <bytes> of them
# and turns them back into time order for distil. Until 2026-09-22 every
# crawl here was `ORDER BY … ASC | head -c`, which keeps the OLDEST bytes:
# a year of WhatsApp is ~1 MB against a 400 KB cap, so the owner's re-learn
# stopped at 2026-01-27 and nothing from the eight months since — his whole
# current life — was ever read. A line the cap cuts in half is the oldest
# one, and stays (as it did before), at the top.
# The rest is drained, not cut off, so nothing upstream dies on a closed
# pipe and fails the crawl under pipefail (whatsapp.sh says why: ticket #21).
newest_cap() {
  { head -c "$1"; cat >/dev/null; } | /usr/bin/env python3 -c '
import sys
data = sys.stdin.buffer.read()
lines = [l for l in data.split(b"\n") if l]
sys.stdout.buffer.write(b"".join(l + b"\n" for l in reversed(lines)))'
}

# The window's cut-off is CAST to INTEGER: strftime() returns TEXT, and SQLite
# sorts every number below every TEXT, so an uncast comparison matched no row
# and pull/crawl printed nothing (scripts/test-connectors-sql-dates.sh).
# `send-offer`: the Memoe app's "Use draft" on an offer — the chat's own id
# and the words, as JSON on stdin. `exec`, so the check in offer_send.py sees
# the app as its parent; it shows the confirmation card before anything goes.
if [ "${1:-}" = "send-offer" ]; then
  exec /usr/bin/python3 "$(dirname "$0")/offer_send.py" imessage
fi

case "${1:-status}" in
status)
  [ -f "$DB" ] || { echo "unavailable: no Messages database on this Mac"; exit 1; }
  if sqlite3 "file:$DB?mode=ro" "select 1;" >/dev/null 2>&1; then
    echo "ok: reading iMessage and SMS"
  else
    echo "needs-setup: grant Full Disk Access to Memoe.app in System Settings › Privacy & Security"
    exit 1
  fi
  ;;
pull)
  # Decoded as `items` is (imessage-items.py): most messages on recent macOS
  # keep their text only in attributedBody, which a query of m.text misses.
  /usr/bin/python3 "$(dirname "$0")/imessage-items.py" "$DB" pull "$SINCE_HOURS"
  ;;
items)
  # The situations engine's feed (moe-home/lib/situations.py): new messages
  # since a ROWID cursor, whole text, as JSON items, then {"cursor": …}.
  shift
  [ -f "$DB" ] || { echo "unavailable: no Messages database on this Mac" >&2; exit 1; }
  exec /usr/bin/python3 "$(dirname "$0")/imessage-items.py" "$DB" "$@"
  ;;
crawl)
  shift; crawl_args "$@"
  # Full text this time (pull truncates to 220 chars), read newest first so
  # the byte cap cuts off the far past rather than last week, and handed on
  # oldest first (newest_cap). Group chats carry the chat name so the digest
  # can tell a family thread from a work one. Decoded as pull is.
  /usr/bin/python3 "$(dirname "$0")/imessage-items.py" "$DB" crawl "$SINCE_DAYS" | newest_cap "$MAX_BYTES"
  ;;
*) echo "usage: imessage.sh [status|pull|items --since CURSOR|crawl [--since DAYS] [--max-bytes N]]"; exit 2 ;;
esac

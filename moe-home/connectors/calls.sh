#!/bin/bash
# Phone calls (iPhone calls relayed through this Mac), read-only.
# Needs Full Disk Access.
set -uo pipefail
DB="$HOME/Library/Application Support/CallHistoryDB/CallHistory.storedata"
SINCE_HOURS="${MOE_SINCE_HOURS:-48}"

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
case "${1:-status}" in
status)
  [ -f "$DB" ] || { echo "unavailable: no call history on this Mac (needs iPhone call relay enabled)"; exit 1; }
  if sqlite3 "file:$DB?mode=ro" "select 1;" >/dev/null 2>&1; then
    echo "ok: reading call history"
  else
    echo "needs-setup: grant Full Disk Access to Memoe.app"
    exit 1
  fi
  ;;
pull)
  # ZDATE is Core Data seconds since 2001-01-01.
  sqlite3 "file:$DB?mode=ro" <<SQL 2>/dev/null
.mode list
.separator " | "
SELECT
  datetime(ZDATE + 978307200,'unixepoch','localtime'),
  CASE ZORIGINATED WHEN 1 THEN 'outgoing' ELSE 'incoming' END,
  CASE WHEN ZANSWERED = 1 THEN 'answered' ELSE 'missed' END,
  COALESCE(ZADDRESS,'unknown'),
  CAST(ZDURATION AS INT) || 's'
FROM ZCALLRECORD
WHERE ZDATE + 978307200 > CAST(strftime('%s','now','-$SINCE_HOURS hours') AS INTEGER)
ORDER BY ZDATE DESC
LIMIT 40;
SQL
  ;;
crawl)
  shift; crawl_args "$@"
  # Who they call, how often and how long: the pattern is the fact, so no
  # per-row limit — just the window and the byte cap, which keeps the newest
  # calls (newest_cap).
  sqlite3 "file:$DB?mode=ro" <<SQL 2>/dev/null | newest_cap "$MAX_BYTES"
.mode list
.separator " | "
SELECT
  datetime(ZDATE + 978307200,'unixepoch','localtime'),
  CASE ZORIGINATED WHEN 1 THEN 'outgoing' ELSE 'incoming' END,
  CASE WHEN ZANSWERED = 1 THEN 'answered' ELSE 'missed' END,
  COALESCE(ZADDRESS,'unknown'),
  CAST(ZDURATION AS INT) || 's'
FROM ZCALLRECORD
WHERE ZDATE + 978307200 > CAST(strftime('%s','now','-$SINCE_DAYS days') AS INTEGER)
ORDER BY ZDATE DESC;
SQL
  ;;
*) echo "usage: calls.sh [status|pull|crawl [--since DAYS] [--max-bytes N]]"; exit 2 ;;
esac

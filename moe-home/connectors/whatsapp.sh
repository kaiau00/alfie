#!/bin/bash
# WhatsApp, read from the history the one linked device keeps.
#
# WhatsApp has no official personal API. Moe links this Mac as a device —
# the same mechanism as WhatsApp Web — through the bridge that ships inside
# Moe (scripts/whatsapp-bridge/bridge.js, run by Moe's brain), and that ONE
# device does two jobs: it is the number you can message Moe on, and it
# mirrors every chat, contact and message it sees into a SQLite file
# (`$HERMES_HOME/whatsapp/store/messages.db`, written by history_store.js
# beside the bridge) that this reads. Set it up with
# ~/.moe/scripts/connect-whatsapp.sh, and read the ban-risk note there first.
#
# **What this used to read, and why it read nothing.** Until 2026-09-11 this
# connector read a store only lharries/whatsapp-mcp's Go bridge wrote
# (~/.moe/whatsapp-mcp/…/messages.db) and sent through that bridge's HTTP on
# :8080 — a SECOND linked device, cloned and built with a Go toolchain the
# person had to install by hand. Linking moved to the bundled bridge on
# 2026-09-09 and nothing wrote that store any more, so every read here said
# "your phone has not linked this Mac yet" over a link that was working.
# One device now: the bridge keeps the history, `send` posts to the bridge
# (`POST /send` on its port, 3000), and `voice` asks it to fetch one stored
# voice note (`POST /history/download`).
#
# Redirection for tests: HERMES_HOME (the session and the store live under
# it), MOE_WHATSAPP_DB (the store file, else the path the bridge reports in
# /health, else the default), MOE_WHATSAPP_BRIDGE_URL (default
# http://127.0.0.1:3000), MOE_TRANSCRIBE_BIN (the binary `voice` transcribes
# with, default the installed Moe), MOE_WHATSAPP_SETTLING_SECONDS (how long a
# link that is not connected yet reads as coming up rather than as dropped).
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
# The session, where the gateway's adapter looks for it
# (hermes_constants.get_hermes_dir): the legacy whatsapp/session when it has
# content — connect-whatsapp.sh pairs there — else platforms/whatsapp/session,
# where a link made by Hermes itself on a fresh home lands.
SESSION="$HERMES_HOME/whatsapp/session"
[ -f "$SESSION/creds.json" ] || SESSION="$HERMES_HOME/platforms/whatsapp/session"
BRIDGE="${MOE_WHATSAPP_BRIDGE_URL:-http://127.0.0.1:3000}"
DB="${MOE_WHATSAPP_DB:-$HERMES_HOME/whatsapp/store/messages.db}"
SINCE_HOURS="${MOE_SINCE_HOURS:-24}"
CONNECT_HINT="run ~/.moe/scripts/connect-whatsapp.sh"

# How long a link that is not connected *yet* reads as coming up rather than
# as a link that has dropped.
#
# Measured on this Mac on 2026-09-20, from ~/.hermes/logs/gateway.log: the
# gateway's "Connecting to whatsapp…" to its "✓ whatsapp connected" took
# 2.81 s and 3.23 s — the whole of starting the bridge and reaching WhatsApp.
# Ninety seconds is close to thirty times the slower of those: long enough
# that no healthy start is ever called a dropped link, short enough that a
# link that really has dropped says so within a minute and a half.
SETTLING_SECONDS="${MOE_WHATSAPP_SETTLING_SECONDS:-90}"

# Who a chat is, for a row: its stored name, else — for a one-to-one chat —
# the bare number, so tools/name-numbers.py can put a Contacts name on it.
# The jid itself would not do: name-numbers.py leaves anything with an "@"
# alone on purpose (a jid is what a send is addressed to), and the old Go
# store only ever resolved names because it stored the number AS the name.
# A group keeps its jid when it has no subject; there is no contact to ask.
WHO="COALESCE(NULLIF(replace(replace(c.name, char(10), ' '), char(13), ' '),''), CASE WHEN c.jid LIKE '%@s.whatsapp.net' THEN substr(c.jid, 1, instr(c.jid, '@') - 1) ELSE c.jid END)"

# GET /health from the bridge, as one JSON object on stdout; exit 1 when the
# bridge does not answer. The bridge binds loopback and checks the Host
# header, so the URL is spelled with 127.0.0.1 or localhost, never else.
bridge_health() {
  curl -s --max-time 4 "$BRIDGE/health" 2>/dev/null
}

# One field of /health, read with a Python one-liner so a half-written or
# non-JSON answer is "" rather than a shell error. Prints "null" for a key
# that is present and null, "" for one that is absent — the difference
# between a bridge started without a store and one that predates stores.
health_field() { # <json> <dotted.key>
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if not isinstance(d, dict) or k not in d:
        sys.exit(0)
    d = d[k]
print("null" if d is None else d)' "$2" 2>/dev/null
}

# Seconds since a file was last written, on stdout; nothing, and non-zero,
# when it is not there or cannot be read. Used on the session's creds.json,
# which only the bridge writes: Baileys rewrites it every time WhatsApp hands
# it a new key, so a young creds.json means the bridge was alive moments ago
# — whether it is answering now or being started again by a gateway that is
# restarting. That is the difference between a link coming up and one that
# has dropped, and nothing else on this Mac carries it.
age_seconds() { # <path>
  [ -e "$1" ] || return 1
  python3 -c '
import os, sys, time
try:
    print(max(0, int(time.time() - os.path.getmtime(sys.argv[1]))))
except OSError:
    sys.exit(1)' "$1" 2>/dev/null
}

# 0 when <seconds> is a number below SETTLING_SECONDS. Anything that is not a
# number — an absent file, a bridge whose /health predates `uptime` — is NOT
# young: an unknown answer must never be the one that says "give it a moment"
# forever.
is_young() { # <seconds-or-anything>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -lt "$SETTLING_SECONDS" ]
}

# The store to read. MOE_WHATSAPP_DB wins; else the default path; else,
# when that is not there, the path the running bridge says it writes —
# reading the file the writer names is what keeps the two from drifting.
find_db() {
  [ -f "$DB" ] && return 0
  [ -n "${MOE_WHATSAPP_DB:-}" ] && return 1
  local h p
  h="$(bridge_health)" || return 1
  p="$(health_field "$h" history.path)"
  case "$p" in ''|null) return 1 ;; esac
  [ -f "$p" ] && DB="$p"
  [ -f "$DB" ]
}

# sqlite3 on the store, with a busy timeout, and a sentence when it fails.
# The bridge writes this file while Moe runs; a read that lands inside one
# of its transactions used to get "database is locked" at once, and every
# read here sent sqlite3's stderr to /dev/null — so a busy store came back
# as rc=1 and no words, which callers turned into "WhatsApp failed" or, in
# send's name lookup, "no chat called Dad". Three seconds is longer than
# any write the bridge makes (a history chunk is one transaction); what
# still fails says why, on stderr, and keeps its non-zero status.
wa_sql() {
  local err rc
  err="$(mktemp "${TMPDIR:-/tmp}/wa-sql.XXXXXX")" || err=/dev/null
  sqlite3 -cmd ".timeout 3000" "$@" 2>"$err"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$err" ]; then rc=1; fi
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'locked|busy' "$err" 2>/dev/null; then
      echo "your WhatsApp chats on this Mac are busy being saved — try again in a moment (the store was locked for more than 3 seconds)" >&2
    else
      echo "could not read your WhatsApp chats on this Mac: $(head -1 "$err" 2>/dev/null)" >&2
    fi
  fi
  [ "$err" = /dev/null ] || rm -f "$err"
  return "$rc"
}

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
#
# The rest of the stream is DRAINED after the cap, not cut off. A bare
# `head -c` closes the pipe as soon as it has its bytes, everything upstream
# dies writing into it (name-numbers.py with a BrokenPipeError, sqlite3 with
# SIGPIPE), and `set -o pipefail` turns a crawl that had its answer into a
# failed one: ticket #21, `whatsapp crawl` over 30 days, exit 120, nothing
# learned. Reading the remainder costs a scan the query already paid for.
newest_cap() {
  { head -c "$1"; cat >/dev/null; } | /usr/bin/env python3 -c '
import sys
data = sys.stdin.buffer.read()
lines = [l for l in data.split(b"\n") if l]
sys.stdout.buffer.write(b"".join(l + b"\n" for l in reversed(lines)))'
}

# who_rows: the pull and crawl rows, with who sent each message said in words.
# In:  "<g|d>|<when>|<chat>|<me|sender>|<text>" (g = a group chat), after
#      tools/name-numbers.py has put Contacts names on the numbers.
# Out: "<when>|<chat>|from <who> → <whom>|<text>":
#        from me → Ada Lovelace (4477…)        you sent it, one-to-one
#        from Ada Lovelace (4477…) → me        you received it
#        from me → Family (group)              you wrote in a group
#        from Bob (4477…) → Family (group)     someone in the group wrote
# Until 2026-10-07 the third field was a bare "me" or a number, and nothing
# said it was the sender: Moe read the chat's name (the other person, in a
# one-to-one chat) as the sender and told the owner that someone had sent
# HIM the invite he had sent them (ticket #21). Still four "|" fields, the
# text last, so tools/recipients.py and moe-screen read it as before.
who_rows() {
  /usr/bin/env python3 -c '
import sys
out = sys.stdout
try:
    for line in sys.stdin:
        kind, _, rest = line.rstrip("\n").partition("|")
        parts = rest.split("|", 3)
        if kind not in ("g", "d") or len(parts) != 4:
            out.write(line if line.endswith("\n") else line + "\n")
            continue
        when, chat, who, text = parts
        mine = who == "me"
        if kind == "g":
            whom = "%s (group)" % chat
            frm = "me" if mine else (who or "someone in the group")
        elif mine:
            frm, whom = "me", chat
        else:
            # The sender as stored (a Contacts name and the number), else
            # the chat, which in a one-to-one chat is the same person.
            frm, whom = who or chat, "me"
        out.write("%s|%s|from %s → %s|%s\n" % (when, chat, frm, whom, text))
    out.flush()
except BrokenPipeError:
    sys.exit(0)'
}

# `send-offer`: the Memoe app's "Use draft" on an offer. The app hands over
# the exact chat and the exact words the person chose, as JSON on stdin, from
# its own memory, with no model choosing either. It is sent only when this script's parent
# process IS the signed Memoe app (a model's shell never is) and the offer is
# minutes old (tools/recipients.py `offer`). The dialog below still shows it
# and waits for the click; what it does not need is a send ticket, because no
# model chose this recipient.
OFFER_SEND=""
if [ "${1:-}" = "send-offer" ]; then
  HERE_OFFER="$(cd "$(dirname "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")")" && pwd)"
  offer="$(/usr/bin/python3 "$HERE_OFFER/../tools/recipients.py" offer --ppid "$PPID")"
  case "$offer" in
    ok$'\n'*) ;;
    *) printf '%s\n' "$offer" | sed -n 2p | grep . || echo "not sent — that offer could not be checked."; exit 1 ;;
  esac
  offer="${offer#ok$'\n'}"
  set -- send "${offer%%$'\n'*}" "${offer#*$'\n'}"
  OFFER_SEND=1
fi

case "${1:-status}" in
status)
  # The truth of the single device, asked of the artefacts in order: is
  # there a session, is the bridge that holds it running, is it connected,
  # does it keep a history, and has anything arrived. Everything after
  # " — run " is cut before the app shows a line (ConnectionsCatalog.
  # humanDetail): a sentence on screen, the command here.
  if [ ! -f "$SESSION/creds.json" ]; then
    echo "needs-setup: your phone has not linked this Mac yet — $CONNECT_HINT"
    exit 1
  fi
  # How long ago the bridge last wrote the session. Read once, before the
  # bridge is asked anything, because both answers below turn on it.
  link_age="$(age_seconds "$SESSION/creds.json")" || link_age=""
  if ! health="$(bridge_health)" || [ -z "$health" ]; then
    # Linked, and nothing is holding the link: the bridge runs inside Moe's
    # brain and starts with it. Not "needs-setup" — there is nothing to set
    # up — and not a dropped link, which the bridge would report itself.
    if is_young "$link_age"; then
      # The session was written seconds ago and nothing is answering yet:
      # the scan has just finished and the brain is restarting to start the
      # bridge with it (connect-whatsapp.sh ends on NEEDS_RESTART=gateway).
      # Telling that person to quit Moe would interrupt the very restart
      # they are waiting for.
      echo "unavailable: linked — Moe is starting your WhatsApp link now, which takes a few seconds"
      exit 1
    fi
    echo "unavailable: your phone is linked, but Moe's WhatsApp link is not running right now — it starts with Memoe, so give it a moment; if it does not come back, quit Memoe and open it again"
    exit 1
  fi
  state="$(health_field "$health" status)"
  if [ "$state" != "connected" ]; then
    # The bridge is up and WhatsApp is not. bridge.js starts every run on
    # connectionState 'disconnected' and only reaches 'connected' when the
    # socket opens, so THIS is what a link made seconds ago looks like as
    # well as one that has dropped — and until 2026-09-20 both were told
    # "the link to your phone has dropped — link it again", over a link the
    # person had just made and that was working. Two clocks separate them:
    # how long this bridge has been running (its own /health) and how long
    # ago it last wrote the session.
    bridge_age="$(health_field "$health" uptime)"
    bridge_age="${bridge_age%%.*}"        # process.uptime() is a float
    if is_young "$bridge_age" || is_young "$link_age"; then
      echo "unavailable: linked — Moe is connecting to your phone, which takes a few seconds"
      exit 1
    fi
    echo "needs-setup: the link to your phone has dropped (WhatsApp does that every few weeks) — link it again — $CONNECT_HINT"
    exit 1
  fi
  hist="$(health_field "$health" history)"
  case "$hist" in
    '')
      # A bridge with no `history` key at all predates the store: it answers
      # as Moe but keeps nothing for anyone to read.
      echo "needs-setup: Moe answers on WhatsApp, but this version keeps none of your chats to read — update Memoe"
      exit 1 ;;
    null)
      # The bridge knows about a store and was started without one: the
      # link was made before the store existed, and connecting again writes
      # the setting that turns it on (no second scan is asked for).
      echo "needs-setup: Moe answers on WhatsApp but is not keeping your chats — connect WhatsApp again to turn that on — $CONNECT_HINT"
      exit 1 ;;
  esac
  if ! find_db; then
    echo "unavailable: linked — the store your chats go into is not where Moe expected ($DB)"
    exit 1
  fi
  messages="$(health_field "$health" history.messages)"
  chats="$(health_field "$health" history.chats)"
  case "$messages" in ''|null|*[!0-9]*) messages=0 ;; esac
  case "$chats" in ''|null|*[!0-9]*) chats=0 ;; esac
  if [ "$messages" -eq 0 ]; then
    # Linked and connected, and nothing has landed yet: the phone sends its
    # history in the minutes after linking. Nothing for a person to do, so
    # ok — with the words, because an empty read is not a broken one.
    # True at a fresh link: the phone sends its history in the minutes
    # after the scan. For a link made before the store existed nothing old
    # is coming — the phone is only ever asked at the moment of the scan —
    # so the same line says what that person has to do to get it.
    echo "ok: linked — waiting for your chats to arrive from your phone (if you linked before Moe kept them, only new messages arrive from now on — link again to bring the past in)"
    exit 0
  fi
  echo "ok: reading WhatsApp — $chats chats, $messages messages"
  ;;
items)
  # The situations engine's feed (moe-home/lib/situations.py): new messages
  # since a rowid cursor, as JSON items, then {"cursor": …}.
  shift
  find_db || exit 1
  exec python3 "$(dirname "$0")/whatsapp-items.py" "$DB" "$@"
  ;;

pull)
  find_db || exit 1
  # Names come from your Contacts, because WhatsApp only gives us the number
  # for one-to-one chats. Group chats already carry a real name.
  wa_sql -separator '|' "file:$DB?mode=ro" <<SQL | python3 "$HOME/.moe/tools/name-numbers.py" | who_rows
SELECT
  CASE WHEN m.chat_jid LIKE '%@g.us' THEN 'g' ELSE 'd' END,
  datetime(m.timestamp,'localtime'),
  replace(COALESCE($WHO, CASE WHEN m.chat_jid LIKE '%@s.whatsapp.net' THEN substr(m.chat_jid, 1, instr(m.chat_jid, '@') - 1) ELSE m.chat_jid END), '|', '/'),
  CASE m.is_from_me WHEN 1 THEN 'me' ELSE replace(COALESCE(m.sender,''), '|', '/') END,
  replace(substr(m.content,1,200), char(10), ' ')
FROM messages m
LEFT JOIN chats c ON c.jid = m.chat_jid
WHERE m.content IS NOT NULL AND m.content != ''
  AND m.timestamp > datetime('now','-$SINCE_HOURS hours')
ORDER BY m.timestamp DESC
LIMIT 50;
SQL
  ;;

crawl)
  shift; crawl_args "$@"
  find_db || exit 1
  # Full messages, names resolved the same way pull does. Read newest first
  # so the byte cap drops the far past, never last week (newest_cap), and
  # handed on in time order.
  wa_sql -separator '|' "file:$DB?mode=ro" <<SQL | python3 "$HOME/.moe/tools/name-numbers.py" | who_rows | newest_cap "$MAX_BYTES"
SELECT
  CASE WHEN m.chat_jid LIKE '%@g.us' THEN 'g' ELSE 'd' END,
  datetime(m.timestamp,'localtime'),
  replace(COALESCE($WHO, CASE WHEN m.chat_jid LIKE '%@s.whatsapp.net' THEN substr(m.chat_jid, 1, instr(m.chat_jid, '@') - 1) ELSE m.chat_jid END), '|', '/'),
  CASE m.is_from_me WHEN 1 THEN 'me' ELSE replace(COALESCE(m.sender,''), '|', '/') END,
  replace(replace(m.content, char(10), ' '), char(13), ' ')
FROM messages m
LEFT JOIN chats c ON c.jid = m.chat_jid
WHERE m.content IS NOT NULL AND m.content != ''
  AND m.timestamp > datetime('now','-$SINCE_DAYS days')
ORDER BY m.timestamp DESC;
SQL
  ;;

chats)
  # Who you actually talk to, by name.
  find_db || exit 1
  limit="${2:-30}"
  case "$limit" in (*[!0-9]*) echo "expected a number"; exit 2;; esac
  wa_sql -separator '|' "file:$DB?mode=ro" \
    "select $WHO, c.jid, datetime(c.last_message_time,'localtime')
     from chats c order by c.last_message_time desc limit $limit;" \
    | python3 "$HOME/.moe/tools/name-numbers.py"
  ;;

find)
  who="${2:?name required}"
  find_db || exit 1
  wa_sql -separator '|' "file:$DB?mode=ro" \
    "select $WHO, c.jid from chats c;" \
    | python3 "$HOME/.moe/tools/name-numbers.py" \
    | { grep -iF -- "$who" || true; } | head -10
  # `|| true` because grep exits 1 when it matches nothing, `set -o pipefail`
  # at the top of this file propagates that, and the caller turns any non-zero
  # into "the connector failed". "There is no chat called Izzy" would have
  # reached the model as "I could not reach WhatsApp" — and this is the lookup
  # done immediately before choosing who to message, so a wrong answer here
  # pushes it towards guessing a number.
  ;;

send)
  # Every send goes through a real confirmation dialog. Moe cannot approve on
  # your behalf: the dialog is shown by the OS and needs a human click. That
  # matters because Moe reads text written by other people, and an instruction
  # buried in an incoming message must never be able to turn into an outgoing
  # one.
  to="${2:?recipient jid or phone number required}"
  msg="${3:?message text required}"

  # The recipient must be something WhatsApp can actually address: a jid, or
  # a phone number we turn into one. The bridge does NOT check — it hands
  # any string to WhatsApp as a chat id, so a contact's name would go out as
  # "Ada Lovelace" and come back as an error that reads like a broken link
  # and is not one. Resolve it here, or refuse.
  # Refuse text that can make the dialog show one thing and send another:
  # control characters, DEL, the Unicode line/paragraph separators and the
  # bidi overrides and isolates. gmail.py and telegram.py both do this and
  # say why — "a gate whose display can be steered is not a gate". Newline
  # and tab are ordinary message text and stay.
  # In a function, because the message is checked twice: as asked, and
  # again as the person rewrote it in the dialog, below.
  showable() { # to, msg → 0 when both can be shown and sent
    # Invisible text too: C1 controls, every format character (zero-width
    # spaces and joiners, word joiners, BOM) and the Unicode tag block — a
    # person cannot see them in the dialog, and a model can read them.
    printf '%s%s' "$1" "$2" | LC_ALL=C python3 -c 'import sys, re, unicodedata
raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
bad = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069\U000e0000-\U000e007f]")
text = raw.replace("\n", "").replace("\t", "")
sys.exit(1 if bad.search(text) or any(unicodedata.category(c) == "Cf" for c in text) else 0)'
  }
  if showable "$to" "$msg"; then :; else
    echo "not sent — that message contains a character that cannot be shown in the confirmation. Use ordinary text."; exit 1
  fi
  # WhatsApp's own limit is 65536, but a dialog nobody can read is not a gate.
  if [ "${#msg}" -gt 4096 ]; then
    echo "not sent — that message is too long to show you before sending (${#msg} characters, limit 4096)."; exit 1
  fi

  name=""
  jid=""
  case "$to" in
    *@*) jid="$to" ;;                       # already a jid
  esac
  # A PHONE NUMBER, and only that.
  #
  # This used to be the glob `[0-9]*`, which matches anything merely STARTING
  # with a digit: a chat named "2 Doors Down" became 2@s.whatsapp.net and a
  # message went to a number nobody chose, because the name lookup below
  # never ran. Test the WHOLE string instead — digits and the punctuation
  # people write numbers with, nothing else — and then require a length a
  # real number can have (E.164 allows fifteen; the short end is loose
  # because country plans vary).
  if [ -z "$jid" ] && [ -z "$(printf '%s' "$to" | tr -d '0-9 ()+.-')" ]; then
    digits="$(printf '%s' "$to" | tr -cd '0-9')"
    if [ "${#digits}" -ge 6 ] && [ "${#digits}" -le 15 ]; then
      jid="${digits}@s.whatsapp.net"
    else
      echo "not sent — \"$to\" is not a phone number Moe can dial (${#digits} digits)."; exit 1
    fi
  fi
  # A name: look it up in the chats we already know about. One match only —
  # sending "to Dan" when there are two Dans is not a thing to guess at.
  if [ -z "$jid" ] && find_db; then
    # `find` prints the name through tools/name-numbers.py, so a chat whose
    # stored name is a bare number comes back as "Mom (18485551234)" — and
    # the schema tells the model to pass exactly what `find` returned. Match
    # that shape too, by taking the number out of the trailing brackets;
    # otherwise the one identifier a person is given is the one that fails.
    lookup="$to"
    case "$to" in
      *\ \(*\)) bracketed="$(printf '%s' "$to" | sed -E 's/.*\(([0-9+ .()-]+)\)$/\1/')"
                digits="$(printf '%s' "$bracketed" | tr -cd '0-9')"
                if [ "${#digits}" -ge 6 ] && [ "${#digits}" -le 15 ]; then
                  jid="${digits}@s.whatsapp.net"
                fi ;;
    esac
    # A failed lookup is not "no chat by that name": say so and stop.
    matches="$(wa_sql "file:$DB?mode=ro" \
      "select jid from chats where lower(name) = lower('${lookup//\'/\'\'}') limit 2;")" || {
      echo "not sent — could not look \"$to\" up in your WhatsApp chats just now"; exit 1; }
    if [ -n "$jid" ]; then :
    elif [ "$(printf '%s\n' "$matches" | grep -c .)" = 1 ]; then
      jid="$matches"
    elif [ -n "$matches" ]; then
      echo "more than one WhatsApp chat is called \"$to\" — say which number to use"; exit 1
    fi
  fi
  [ -n "$jid" ] || {
    echo "no WhatsApp chat called \"$to\" — give a phone number with its country code, or the exact chat name"; exit 1; }

  # The dialog names who this really goes to, resolved. Approving a name that
  # was never resolved is approving something nobody checked.
  name="$jid"
  if [ -f "$DB" ]; then
    # Only the label: a store busy past the timeout leaves the dialog
    # showing the jid itself, which is still who it goes to.
    n="$(sqlite3 -cmd ".timeout 3000" "file:$DB?mode=ro" "select name from chats where jid = '${jid//\'/\'\'}' and name != '' limit 1;" 2>/dev/null)"
    [ -n "$n" ] && name="$n ($jid)"
  fi
  # And a bare number is shown with the contact's name, when Contacts has one.
  case "$name" in
    *@s.whatsapp.net)
      resolved="$(printf '%s' "${name%%@*}" | python3 "$HOME/.moe/tools/name-numbers.py" 2>/dev/null)"
      [ -n "$resolved" ] && [ "$resolved" != "${name%%@*}" ] && name="$resolved" ;;
  esac

  # The dialog is the one beside THIS file, found through a fixed
  # interpreter that does the resolving. A python3 earlier on $PATH answered
  # the realpath probe with a directory of its choosing and the send went
  # through a confirm.sh somebody else wrote.
  HERE_REAL="$(cd "$(dirname "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")")" && pwd)"
  CONFIRM="$HERE_REAL/../tools/confirm.sh"
  [ -x "$CONFIRM" ] || { echo "not sent — the confirmation dialog is missing, so nothing was sent."; exit 1; }
  # Who this is, and who named them (tools/recipients.py): never the owner
  # through a contact tool, never somebody nobody named. The resolved jid is
  # checked for the owner too — "Jordan" can resolve to the owner's own chat.
  # A check that cannot run is a refusal, the same as a dialog that cannot.
  #
  # The send gate's ticket: the hook judged this exact send (these recipients,
  # these words) and wrote a one-time ticket where no tool call can write.
  # Without it nothing goes, however this script was started — the model has
  # a shell, so nothing in this script's environment can be what decides.
  if [ -n "$OFFER_SEND" ]; then
    MOE_CONFIRM_PROVENANCE=""
  else
    gate_out="$(printf '%s' "$msg" | /usr/bin/python3 "$HERE_REAL/../tools/recipients.py" take \
                  --channel whatsapp --to "$to" --resolved "$jid" 2>/dev/null)"
    gate_rc=$?
    if [ "$gate_rc" -eq 3 ]; then
      printf '%s\n' "$gate_out" | sed -n 2p; exit 1
    elif [ "$gate_rc" -ne 0 ]; then
      echo "not sent — Moe could not check who this is going to, so nothing was sent."; exit 1
    fi
    MOE_CONFIRM_PROVENANCE="$(printf '%s\n' "$gate_out" | sed -n 3p)"
  fi
  export MOE_CONFIRM_PROVENANCE
  # The dialog's answer goes through a file: on exit 5 the person rewrote
  # the message, and the new words come back as NUL-separated records —
  # which a bash variable cannot hold. mktemp makes it 0600; it is removed
  # on every way out.
  ANSWER_FILE="$(mktemp "${TMPDIR:-/tmp}/moe-whatsapp-answer.XXXXXX")" || {
    echo "not sent — could not make room for the dialog's answer."; exit 1; }
  trap 'rm -f "$ANSWER_FILE"' EXIT
  "$CONFIRM" "WhatsApp" "$name" "$msg" >"$ANSWER_FILE"
  answer=$?
  case "$answer" in
    0) ;;
    5)
      edited="$(python3 -c 'import sys
for rec in open(sys.argv[1], "rb").read().split(b"\0"):
    key, sep, value = rec.partition(b"=")
    if sep and key == b"body":
        sys.stdout.buffer.write(value); break' "$ANSWER_FILE")"
      [ -n "$edited" ] || { echo "not sent — you cancelled"; exit 1; }
      msg="$edited"
      # The same two checks the request passed, on what they typed.
      if showable "$to" "$msg"; then :; else
        echo "not sent — the rewritten message contains a character that cannot be sent."; exit 1
      fi
      if [ "${#msg}" -gt 4096 ]; then
        echo "not sent — the rewritten message is too long (${#msg} characters, limit 4096)."; exit 1
      fi
      ;;
    # 7: the card withdrew — whoever asked went away, or nobody answered in
    # time (confirm.sh). Not "you cancelled": nobody did.
    7) echo "not sent — the confirmation expired before anyone answered, so nothing was sent."; exit 1 ;;
    *) echo "not sent — you cancelled"; exit 1 ;;
  esac

  # POST /send on the bridge: {chatId, message} → {success: true, messageId}
  # on 200; {error} on 503 (not connected to WhatsApp) or 500 (WhatsApp
  # refused). Read what came back, and believe it: plain `curl -s` exits 0
  # on a 500, so this used to print "sent to …" for a message that never
  # left. 70 s, because the bridge itself gives one send 60.
  resp="$(curl -sS --max-time 70 -X POST "$BRIDGE/send" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"chatId": sys.argv[1], "message": sys.argv[2]}))' "$jid" "$msg")" 2>&1)" || {
    echo "not sent — Moe's WhatsApp link is not running right now. Quit Memoe and open it again."; exit 1; }
  if printf '%s' "$resp" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
sys.exit(0 if d.get("success") else 1)'; then
    echo "sent to $name"
  else
    why="$(printf '%s' "$resp" | python3 -c 'import json,sys
try:
    print((json.load(sys.stdin).get("error") or "")[:200])
except Exception:
    pass' 2>/dev/null)"
    case "$why" in
      "Not connected to WhatsApp") why="the link to your phone is down right now (WhatsApp drops it every few weeks) — reconnect it in Settings › Connections" ;;
    esac
    echo "not sent${why:+ — $why}"
    exit 1
  fi
  ;;

voice)
  # Voice notes: ask the bridge to fetch one from the store's reference, then
  # transcribe the file it wrote. POST /history/download {messageId, chatId}
  # answers {success, path} — it does not stream the audio — so the reply
  # is parsed, not saved as a sound file.
  limit="${2:-5}"
  case "$limit" in (*[!0-9]*) echo "expected a number"; exit 2;; esac
  find_db || { echo "no WhatsApp store"; exit 1; }

  MOE_BIN="${MOE_TRANSCRIBE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
  [ -x "$MOE_BIN" ] || MOE_BIN="$HOME/moe/.build/debug/Moe"

  wa_sql -separator '|' "file:$DB?mode=ro" \
    "select m.id, m.chat_jid, COALESCE($WHO, m.chat_jid),
            datetime(m.timestamp,'localtime')
     from messages m left join chats c on c.jid = m.chat_jid
     where m.media_type = 'audio'
     order by m.timestamp desc limit $limit;" |
  while IFS='|' read -r id jid who when; do
    [ -z "$id" ] && continue
    label=$(printf '%s' "$who" | python3 "$HOME/.moe/tools/name-numbers.py" 2>/dev/null || echo "$who")
    echo "── $when — $label"

    reply=$(curl -s --max-time 90 -X POST "$BRIDGE/history/download" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"messageId": sys.argv[1], "chatId": sys.argv[2]}))' "$id" "$jid")" 2>/dev/null)

    path=$(printf '%s' "$reply" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
print(d.get('path','') if d.get('success') else '')
" 2>/dev/null)

    if [ -n "$path" ] && [ -f "$path" ]; then
      text=$("$MOE_BIN" --transcribe "$path" 2>/dev/null)
      echo "   ${text:-(downloaded but could not transcribe)}"
    else
      reason=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('error','')[:120])
except Exception: print('')
" 2>/dev/null)
      case "$reason" in
        *403*|*404*|*410*|*incomplete*) echo "   (WhatsApp no longer has this one — media it holds expires)" ;;
        "")    echo "   (no response — Moe's WhatsApp link is not running)" ;;
        *)     echo "   ($reason)" ;;
      esac
    fi
  done
  ;;

*) echo "usage: whatsapp.sh [status|pull|crawl [--since DAYS] [--max-bytes N]|chats|find <name>|send <to> <text>|voice [n]]"; exit 2 ;;
esac

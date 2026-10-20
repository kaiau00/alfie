#!/bin/bash
# Moe's hands on macOS.
#
# Everything here goes through AppleScript/EventKit, which needs no OAuth, no
# API key, no MCP server and no network. The first call to each app raises a
# one-time "Moe wants to control Notes" prompt; say yes once.
#
# SECURITY — read before editing.
#
# Every argument here can originate from content Moe *read*: a note, an email,
# an incoming message. So arguments are untrusted input, and this file must
# never build a script or a query by string concatenation.
#
#   - AppleScript takes arguments via `on run argv`, passed after `--`. A note
#     titled  x" & (do shell script "…") & "  would otherwise close the string
#     literal and run as code. That is a real, reachable path from anyone who
#     can put text in front of Moe.
#   - SQLite gets read-only URIs and single-quote-escaped values, and every
#     numeric limit is validated as an integer.
#
# Usage:  apple.sh <command> [args…]
set -uo pipefail

usage() {
  cat <<'EOF'
notes-list [limit]              recent note titles
notes-search <query>            notes matching a query (titles + snippet)
notes-read <title>              full text of the first note matching title
notes-create <title> <body>     new note in the default folder

reminders-today                 reminders due today, incomplete
reminders-list [list]           incomplete reminders, optionally in one list
reminders-add <text> [due] [list]  add a reminder; due like "2026-09-01 09:00"

cal-today                       today's events
cal-next [days]                 events over the next N days (default 7)
cal-add <title> <start> [end] [calendar]   new event; start/end like "2026-09-01 09:00"

contacts-find <name>            phone + email for a person

messages-recent [limit]         recent iMessage/SMS (needs Full Disk Access)
messages-from <name> [limit]    recent messages with one person

mail-unread [limit]             unread mail in Apple Mail
EOF
}

die() { echo "$1" >&2; exit 2; }

# Integer or nothing.
num() {
  local v="${1:-}" d="$2"
  [ -z "$v" ] && { echo "$d"; return; }
  case "$v" in (*[!0-9]*|'') die "expected a number, got: $v";; esac
  echo "$v"
}

# Escape a value for embedding in a single-quoted SQL literal.
sqlq() { printf '%s' "${1//\'/\'\'}"; }

MSGDB="file:$HOME/Library/Messages/chat.db?mode=ro"

# Reminders and Calendar go through the Moe binary (EventKit) when the app is
# installed. The AppleScript fallbacks below LAUNCH Reminders.app/Calendar.app
# visibly; they exist only for a checkout without /Applications/Memoe.app.
# MOE_BIN overrides the location.
MOE_BIN="${MOE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
have_moe() { [ -x "$MOE_BIN" ]; }

case "${1:-}" in

# ---------- Notes ----------
notes-list)
  n="$(num "${2:-}" 15)"
  osascript - "$n" <<'AS'
on run argv
  set lim to (item 1 of argv) as integer
  set out to ""
  tell application "Notes"
    set c to count of notes
    if c > lim then set c to lim
    repeat with i from 1 to c
      try
        set out to out & (name of note i) & linefeed
      end try
    end repeat
  end tell
  return out
end run
AS
  ;;

notes-search)
  [ -n "${2:-}" ] || die "query required"
  osascript - "$2" <<'AS'
on run argv
  set q to item 1 of argv
  set out to ""
  tell application "Notes"
    repeat with n in (notes whose name contains q or plaintext contains q)
      try
        set b to plaintext of n
        if (length of b) > 160 then set b to text 1 thru 160 of b
        set out to out & (name of n) & " :: " & my flatten(b) & linefeed
      end try
    end repeat
  end tell
  return out
end run

on flatten(s)
  set AppleScript's text item delimiters to {linefeed, return, tab}
  set p to text items of s
  set AppleScript's text item delimiters to " "
  set r to p as text
  set AppleScript's text item delimiters to ""
  return r
end flatten
AS
  ;;

notes-read)
  [ -n "${2:-}" ] || die "title required"
  osascript - "$2" <<'AS'
on run argv
  tell application "Notes" to return plaintext of (first note whose name contains (item 1 of argv))
end run
AS
  ;;

notes-create)
  [ -n "${2:-}" ] || die "title required"
  osascript - "$2" "${3:-}" <<'AS'
on run argv
  set t to item 1 of argv
  set b to item 2 of argv
  tell application "Notes"
    make new note at folder "Notes" of account "iCloud" with properties {name:t, body:b}
  end tell
  return "created: " & t
end run
AS
  ;;

# ---------- Reminders ----------
reminders-today)
  if have_moe; then exec "$MOE_BIN" --reminders --today; fi
  osascript <<'AS'
set out to ""
set d to (current date)
set time of d to 0
set d2 to d + 1 * days
tell application "Reminders"
  repeat with r in (reminders whose completed is false and due date ≥ d and due date < d2)
    set out to out & (name of r) & " (" & ((due date of r) as string) & ")" & linefeed
  end repeat
end tell
return out
AS
  ;;

reminders-list)
  if have_moe; then
    if [ -n "${2:-}" ]; then exec "$MOE_BIN" --reminders --titles --list "$2"; fi
    exec "$MOE_BIN" --reminders --titles
  fi
  if [ -n "${2:-}" ]; then
    osascript - "$2" <<'AS'
on run argv
  set out to ""
  tell application "Reminders"
    repeat with r in (reminders of list (item 1 of argv) whose completed is false)
      set out to out & (name of r) & linefeed
    end repeat
  end tell
  return out
end run
AS
  else
    osascript <<'AS'
set out to ""
tell application "Reminders"
  repeat with r in (reminders whose completed is false)
    set out to out & (name of r) & linefeed
  end repeat
end tell
return out
AS
  fi
  ;;

reminders-add)
  [ -n "${2:-}" ] || die "text required"
  if have_moe; then exec "$MOE_BIN" --add-reminder "$2" "${3:-}" "${4:-}"; fi
  osascript - "$2" "${3:-}" <<'AS'
on run argv
  set t to item 1 of argv
  set dueStr to item 2 of argv
  tell application "Reminders"
    if dueStr is "" then
      make new reminder with properties {name:t}
    else
      make new reminder with properties {name:t, due date:(date dueStr)}
    end if
  end tell
  return "added: " & t
end run
AS
  ;;

# ---------- Calendar ----------
cal-today)
  if have_moe; then exec "$MOE_BIN" --calendar 1 --dash; fi
  osascript <<'AS'
set out to ""
set d to (current date)
set time of d to 0
set d2 to d + 1 * days
tell application "Calendar"
  repeat with c in calendars
    try
      repeat with e in (events of c whose start date ≥ d and start date < d2)
        set out to out & ((start date of e) as string) & " — " & (summary of e) & linefeed
      end repeat
    end try
  end repeat
end tell
return out
AS
  ;;

cal-next)
  n="$(num "${2:-}" 7)"
  if have_moe; then exec "$MOE_BIN" --calendar "$n" --from-now --dash; fi
  osascript - "$n" <<'AS'
on run argv
  set days_ to (item 1 of argv) as integer
  set out to ""
  set d to (current date)
  set d2 to d + days_ * days
  tell application "Calendar"
    repeat with c in calendars
      try
        repeat with e in (events of c whose start date ≥ d and start date < d2)
          set out to out & ((start date of e) as string) & " — " & (summary of e) & linefeed
        end repeat
      end try
    end repeat
  end tell
  return out
end run
AS
  ;;

cal-add)
  [ -n "${2:-}" ] || die "title required"
  [ -n "${3:-}" ] || die "start required"
  have_moe || die "cal-add needs /Applications/Memoe.app (or MOE_BIN)"
  exec "$MOE_BIN" --add-event "$2" "$3" "${4:-}" "${5:-}"
  ;;

# ---------- Contacts ----------
contacts-find)
  [ -n "${2:-}" ] || die "name required"
  # In-process through the app when it is installed (the Contacts grant,
  # nothing launched); the AppleScript below is the fallback for a checkout
  # without one, and answers for the Automation grant instead.
  if have_moe; then exec "$MOE_BIN" --contacts find "$2"; fi
  osascript - "$2" <<'AS'
on run argv
  set q to item 1 of argv
  set out to ""
  tell application "Contacts"
    repeat with p in (people whose name contains q)
      set out to out & (name of p)
      try
        repeat with e in emails of p
          set out to out & "  " & (value of e)
        end repeat
      end try
      try
        repeat with ph in phones of p
          set out to out & "  " & (value of ph)
        end repeat
      end try
      set out to out & linefeed
    end repeat
  end tell
  return out
end run
AS
  ;;

# ---------- Messages (read-only) ----------
messages-recent)
  lim="$(num "${2:-}" 20)"
  sqlite3 "$MSGDB" \
    "SELECT datetime(m.date/1000000000 + 978307200,'unixepoch','localtime'),
            COALESCE(h.id,'me'), substr(m.text,1,200)
     FROM message m LEFT JOIN handle h ON m.handle_id=h.ROWID
     WHERE m.text IS NOT NULL ORDER BY m.date DESC LIMIT $lim;"
  ;;

messages-from)
  [ -n "${2:-}" ] || die "name or number required"
  who="$(sqlq "$2")"
  lim="$(num "${3:-}" 20)"
  sqlite3 "$MSGDB" \
    "SELECT datetime(m.date/1000000000 + 978307200,'unixepoch','localtime'),
            CASE m.is_from_me WHEN 1 THEN 'me' ELSE h.id END, substr(m.text,1,200)
     FROM message m JOIN handle h ON m.handle_id=h.ROWID
     WHERE h.id LIKE '%$who%' AND m.text IS NOT NULL
     ORDER BY m.date DESC LIMIT $lim;"
  ;;

# ---------- Mail ----------
mail-unread)
  lim="$(num "${2:-}" 10)"
  osascript - "$lim" <<'AS'
on run argv
  set lim to (item 1 of argv) as integer
  set out to ""
  tell application "Mail"
    set msgs to (messages of inbox whose read status is false)
    set n to count of msgs
    if n > lim then set n to lim
    repeat with i from 1 to n
      try
        set m to item i of msgs
        set out to out & (sender of m) & " — " & (subject of m) & linefeed
      end try
    end repeat
  end tell
  return out
end run
AS
  ;;

*) usage; exit 1 ;;
esac

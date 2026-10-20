#!/bin/bash
# Recorded phone calls and their transcripts.
#
# When you record a call on iPhone, iOS saves the audio *and* a written
# transcript into a Notes folder called "Call Recordings", which syncs to this
# Mac over iCloud. So the transcripts are already here — no extra permission,
# no audio processing, nothing to install. This reads them.
#
# If you've never recorded a call, or the folder is named differently in your
# language, this reports as not-connected and everything else carries on.
set -uo pipefail

FOLDER="${MOE_CALL_FOLDER:-Call Recordings}"
LIMIT="${MOE_CALLREC_LIMIT:-8}"
CHARS="${MOE_CALLREC_CHARS:-700}"

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

probe() {
  /usr/bin/perl -e 'alarm 12; exec @ARGV' \
    osascript -e "tell application \"Notes\" to return count of notes of folder \"$FOLDER\"" 2>/dev/null
}

# On the sync timer, read through Notes.app only when it is already open:
# `tell application "Notes"` LAUNCHES it, visibly, and sync runs every ten
# minutes. A person asking (tools/apple.sh, learn.sh) gets the old behaviour.
# "skipped:" with exit 0 tells sync.sh to keep the last context file.
# TODO: read ~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite
# directly (ZICNOTEDATA.ZDATA is gzip + protobuf) and drop AppleScript here.
notes_open() { [ -z "${MOE_SYNC:-}" ] || /usr/bin/pgrep -xq Notes; }

case "${1:-status}" in
items)
  # The situations engine's read (moe-home/lib/situations.py): notes changed
  # since a cursor, whole text, as JSON items, then {"cursor": …}. Only while
  # Notes is open; see notes-items.py.
  shift
  exec /usr/bin/python3 "$(dirname "$0")/notes-items.py" calls "$@"
  ;;
status)
  notes_open || { echo "ok: reading call transcripts from Notes (when it is open)"; exit 0; }
  n="$(probe)"
  if [ -z "$n" ]; then
    echo "unavailable: no \"$FOLDER\" folder in Notes (record a call on iPhone, or set MOE_CALL_FOLDER)"
    exit 1
  fi
  echo "ok: $n recorded call(s) with transcripts"
  ;;
pull)
  notes_open || { echo "skipped: Notes not running"; exit 0; }
  [ -n "$(probe)" ] || exit 1
  # Transcripts are long, so take the most recent few and truncate hard —
  # this file is read on every turn.
  osascript <<APPLESCRIPT 2>/dev/null
set out to ""
tell application "Notes"
  try
    set theNotes to notes of folder "$FOLDER"
  on error
    return ""
  end try
  set n to count of theNotes
  if n > $LIMIT then set n to $LIMIT
  repeat with i from 1 to n
    try
      set aNote to item i of theNotes
      set t to name of aNote
      set d to modification date of aNote
      set b to plaintext of aNote
      if (length of b) > $CHARS then set b to (text 1 thru $CHARS of b) & "…"
      set out to out & "### " & t & " (" & (short date string of d) & " " & (time string of d) & ")" & linefeed
      set out to out & my clean(b) & linefeed & linefeed
    end try
  end repeat
end tell
return out

on clean(s)
  set AppleScript's text item delimiters to {linefeed, return, tab}
  set parts to text items of s
  set AppleScript's text item delimiters to " "
  set r to parts as text
  set AppleScript's text item delimiters to ""
  return r
end clean
APPLESCRIPT
  ;;
crawl)
  shift; crawl_args "$@"
  [ -n "$(probe)" ] || exit 1
  # Whole transcripts this time, capped per call so one long meeting does not
  # use the whole byte budget.
  osascript <<APPLESCRIPT 2>/dev/null | { head -c "$MAX_BYTES"; cat >/dev/null; }
set out to ""
set cutoff to (current date) - $SINCE_DAYS * days
tell application "Notes"
  try
    set theNotes to notes of folder "$FOLDER"
  on error
    return ""
  end try
  repeat with aNote in theNotes
    try
      set d to modification date of aNote
      if d > cutoff then
        set b to plaintext of aNote
        if (length of b) > 12000 then set b to (text 1 thru 12000 of b) & "…"
        set out to out & "### " & (name of aNote) & " (" & (short date string of d) & ")" & linefeed
        set out to out & my clean(b) & linefeed & linefeed
      end if
    end try
  end repeat
end tell
return out

on clean(s)
  set AppleScript's text item delimiters to {return, tab}
  set parts to text items of s
  set AppleScript's text item delimiters to " "
  set r to parts as text
  set AppleScript's text item delimiters to ""
  return r
end clean
APPLESCRIPT
  ;;
*) echo "usage: call-recordings.sh [status|pull|items --since CURSOR|crawl [--since DAYS] [--max-bytes N]]"; exit 2 ;;
esac

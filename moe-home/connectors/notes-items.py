#!/usr/bin/env python3
"""`notes.sh items` and `call-recordings.sh items`: notes changed since a
cursor, as the situations engine's items (moe-home/lib/situations.py).

    notes-items.py notes --since <cursor>   every note but recorded calls
    notes-items.py calls --since <cursor>   the "Call Recordings" folder only

A note is the owner writing — "call Dan about the invoice by Thursday",
"Dana will send the contract Monday" — so every item is theirs (`me`) and
of kind "note"; a recorded call's transcript is both sides of a
conversation the owner had, kind "call". Each change to a note is one item
(its id carries the modification time), so an edited note is read again and
the engine keeps what it read before (`append_feed`).

Through Notes.app and ONLY while it is open: `tell application "Notes"`
launches it, visibly, and the engine asks every five minutes. While it is
closed nothing is read and the cursor stays where it was, so the next read
while it is open picks up everything changed since — including what synced
from a phone meanwhile — within the engine's 48 hours: a change older than
that when Notes is next opened is old news, not read. (NoteStore.sqlite would need Full Disk Access and a
protobuf decoder; see the TODO in notes.sh.)

The cursor is unix seconds of the newest change read. An empty cursor is
the first look: it prints only now, so the engine starts from the moment it
was switched on (MOE_ITEMS_BACKFILL_HOURS reads that many hours back
instead, for a measurement run). Password-protected notes are never read.
"""
import json
import os
import subprocess
import sys
import time

LIMIT = 50
TEXT_CAP = 4000
FOLDER = os.environ.get("MOE_CALL_FOLDER") or "Call Recordings"
#: A note in these folders is not news (English names; a localised
#: "Recently Deleted" is read, and its notes were already read when written).
SKIP_FOLDERS = ("Recently Deleted",)
FIELD, RECORD = "\x1f", "\x1e"

SCRIPT = r'''
on run argv
  set secsBack to (item 1 of argv) as integer
  set nowD to current date
  set cutoff to nowD - secsBack
  set out to ""
  tell application "Notes"
    set hits to (notes whose modification date ≥ cutoff)
    repeat with i from 1 to (count of hits)
      try
        set theNote to item i of hits
        if not (password protected of theNote) then
          set f to ""
          try
            set f to name of (container of theNote)
          end try
          set d to modification date of theNote
          set out to out & (id of theNote) & (character id 31) & ((d - nowD) as integer) & (character id 31) & f & (character id 31) & (name of theNote) & (character id 31) & (plaintext of theNote) & (character id 30)
        end if
      end try
    end repeat
  end tell
  return out
end run
'''


def notes_running():
    return subprocess.run(["/usr/bin/pgrep", "-xq", "Notes"]).returncode == 0


def read(back_s, timeout=90):
    """[(id, unix time, folder, title, text)] changed in the last `back_s`."""
    started = time.time()
    p = subprocess.run(["/usr/bin/osascript", "-", str(int(max(1, back_s)))], input=SCRIPT,
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        err = (p.stderr or "").strip()
        if "-1743" in err or "not allowed" in err.lower() or "not authorized" in err.lower():
            raise PermissionError("allow Alfie to control Notes (System Settings › Privacy & Security › Automation)")
        raise RuntimeError("Notes refused: %s" % (err[:200] or "no reason given"))
    out = []
    for rec in (p.stdout or "").rstrip("\n").split(RECORD):
        parts = rec.split(FIELD)
        if len(parts) < 5:
            continue
        nid, rel, folder, title, text = parts[0].strip(), parts[1], parts[2], parts[3], FIELD.join(parts[4:])
        try:
            at = started + int(rel)
        except ValueError:
            continue
        if nid:
            out.append((nid, float(at), folder.strip(), title.strip(), text))
    return out


def items(kind, since, now=None, reader=read, running=notes_running):
    """(item dicts, new cursor)."""
    now = time.time() if now is None else now
    if not since:
        hours = os.environ.get("MOE_ITEMS_BACKFILL_HOURS", "")
        if not hours.isdigit():
            return [], str(int(now))
        since = str(int(now - int(hours) * 3600))
    try:
        cursor = float(since)
    except ValueError:
        cursor = now
    if not running():
        return [], since
    rows = reader(now - cursor + 1)
    wanted = []
    for nid, at, folder, title, text in rows:
        if at < cursor - 1 or folder in SKIP_FOLDERS:
            continue
        is_call = folder == FOLDER
        if (kind == "calls") != is_call:
            continue
        wanted.append((at, nid, title, text))
    wanted.sort()
    wanted = wanted[:LIMIT]
    out = []
    for at, nid, title, text in wanted:
        body = text.strip()
        if not body:
            continue
        out.append({"id": "%s@%d" % (nid, int(at)), "thread": nid, "thread_name": title[:120],
                    "at": at, "from": {"id": "me", "name": "", "me": True}, "to_me": True,
                    "group": False, "kind": "call" if kind == "calls" else "note",
                    "text": body[:TEXT_CAP]})
    new_cursor = str(int(wanted[-1][0])) if wanted else str(int(max(cursor, now - 1)))
    return out, new_cursor


def main(argv):
    kind = argv[1] if len(argv) > 1 else ""
    if kind not in ("notes", "calls") or "--since" not in argv:
        print("usage: notes-items.py notes|calls --since CURSOR", file=sys.stderr)
        return 2
    since = argv[argv.index("--since") + 1] if argv.index("--since") + 1 < len(argv) else ""
    try:
        found, cursor = items(kind, since)
    except PermissionError as e:
        print("needs-setup: %s" % e, file=sys.stderr)
        return 1
    except (RuntimeError, subprocess.SubprocessError, OSError) as e:
        print("notes: %s" % e, file=sys.stderr)
        return 1
    for it in found:
        print(json.dumps(it, ensure_ascii=False))
    print(json.dumps({"cursor": cursor}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

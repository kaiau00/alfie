#!/bin/bash
# Decides whether anything that just happened is worth interrupting you for.
#
# Runs at the end of every sync (sync.sh calls it). Writes ~/.moe/nudge.json
# when it finds something; the app then glows amber until you tap it, and only
# then speaks. It never talks unprompted — being startled by your laptop is
# worse than missing an email.
#
# Off switch: Settings › Background. `"nudges": false` in ~/.moe/config.json
# and this script returns before reading anything at all.
#
# The rules are deliberately deterministic and cheap. Asking a model "is this
# important?" every ten minutes would cost real usage and be less predictable
# than "your meeting starts in eight minutes".
set -uo pipefail

MOE="${MOE_HOME:-$HOME/.moe}"
CTX="$MOE/context"
STATE="$MOE/.nudge-state"
OUT="$MOE/nudge.json"
mkdir -p "$STATE"

# The off switch, checked before anything is read.
#
# Settings › Background writes `"nudges": false` into config.json. The check
# lives here, not only in the caller, so that however this script is reached
# — sync.sh, a launchd tick, a hand run — a person who switched nudges off
# gets nothing looked at on their behalf: no calendar read, no call log, no
# messages. A missing or unreadable config.json means the default, which is
# on. python3 rather than grep so a reformatted config still parses.
if ! python3 - "$MOE/config.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        cfg = json.load(f)
except (OSError, ValueError):
    cfg = {}
sys.exit(0 if cfg.get("nudges", True) is not False else 1)
PY
then
  exit 0
fi

# Don't stack nudges: if one is already waiting, leave it alone.
[ -f "$OUT" ] && exit 0

reasons=()

# ── A meeting about to start ───────────────────────────────────────────────
# Through the Moe binary (EventKit) when the app is installed; the AppleScript
# below launches Calendar.app visibly (same fix as connectors/calendar.sh).
#
# This rule is the OLD one: a fixed twenty minutes, on the ten-minute sync
# clock, and not configurable. `moe-calendar-heads-up` does the same job
# properly — the person's own number of minutes, on a two-minute clock, so
# "five minutes before" means five. The moment they set that, this stands
# down: two heads-ups for one meeting is worse than either alone, and the
# one that stays is the one they asked for. Nobody who has not set it sees
# any change.
heads_up_minutes() {
  python3 - "$MOE/config.json" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get("calendarHeadsUpMinutes")
    print(int(v) if isinstance(v, (int, float)) and v > 0 else 0)
except Exception:
    print(0)
PY
}
MOE_BIN="${MOE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
if [ "$(heads_up_minutes)" != 0 ]; then
  : # the heads-up job owns this now
elif [ -s "$CTX/calendar.md" ] && [ -x "$MOE_BIN" ]; then
  soon=$(MOE_EVENTKIT_NO_PROMPT=1 /usr/bin/perl -e 'alarm 12; exec @ARGV' "$MOE_BIN" --calendar 1 --from-now --json 2>/dev/null \
    | python3 -c '
import json, sys, time
from datetime import datetime
now = time.time()
for e in json.load(sys.stdin):
    t = datetime.fromisoformat(e["start"]).timestamp()
    if now < t < now + 20 * 60:
        print(e["title"], "at", datetime.fromtimestamp(t).strftime("%-I:%M:%S %p"))
' 2>/dev/null)
  if [ -n "$soon" ]; then
    first=$(echo "$soon" | head -1)
    if [ ! -f "$STATE/last-event" ] || [ "$(cat "$STATE/last-event")" != "$first" ]; then
      echo "$first" > "$STATE/last-event"
      reasons+=("You've got $first — starting shortly.")
    fi
  fi
elif [ -s "$CTX/calendar.md" ]; then
  soon=$(/usr/bin/perl -e 'alarm 12; exec @ARGV' osascript <<'AS' 2>/dev/null
set out to ""
set now to current date
set cutoff to now + (20 * minutes)
tell application "Calendar"
  repeat with c in calendars
    try
      repeat with e in (events of c whose start date > now and start date < cutoff)
        set out to out & (summary of e) & " at " & (time string of (start date of e)) & linefeed
      end repeat
    end try
  end repeat
end tell
return out
AS
)
  if [ -n "$soon" ]; then
    first=$(echo "$soon" | head -1)
    if [ ! -f "$STATE/last-event" ] || [ "$(cat "$STATE/last-event")" != "$first" ]; then
      echo "$first" > "$STATE/last-event"
      reasons+=("You've got $first — starting shortly.")
    fi
  fi
fi

# ── Missed calls ───────────────────────────────────────────────────────────
if [ -s "$CTX/calls.md" ]; then
  missed=$(grep -ci "missed" "$CTX/calls.md" 2>/dev/null || echo 0)
  prev=$(cat "$STATE/missed-count" 2>/dev/null || echo 0)
  if [ "$missed" -gt "$prev" ]; then
    echo "$missed" > "$STATE/missed-count"
    who=$(grep -i "missed" "$CTX/calls.md" | head -1 | awk -F'|' '{print $4}' | xargs)
    reasons+=("You missed a call${who:+ from $who}.")
  fi
fi

# ── Messages from people who matter ────────────────────────────────────────
# "Matters" = named in memory/people.md OR in memory/profile/people.md. Two
# files, one format: the first is what the user (or Moe) wrote by hand, the
# second is what the learn-me crawl distilled from mail and chats, in the same
# `**Name** — …` shape with a provenance tag the regex below simply ignores.
# Reading only the hand-written one meant a machine that had learned who
# matters still nudged about nobody. No name list, no nudge — better silent
# than crying wolf over every group chat.
PEOPLE="$MOE/memory/people.md"
PROFILE_PEOPLE="$MOE/memory/profile/people.md"
if [ -f "$PEOPLE" ] || [ -f "$PROFILE_PEOPLE" ]; then
  # Strict on purpose. The first version matched a name anywhere in the file —
  # including messages the user sent themselves, group mentions and week-old
  # lines — and announced "X messaged you" when they had not. Now: the name must
  # be the SENDER, the message must not be from the user, and it must be newer
  # than anything already reported.
  found=$(python3 - "$CTX" "$STATE" "$PEOPLE" "$PROFILE_PEOPLE" <<'PYEOF'
import os, re, sys, json
ctx, state = sys.argv[1], sys.argv[2]
people_paths = sys.argv[3:]

# Both files, concatenated: a name in either one counts, and a name in both
# is de-duplicated below. A path that does not exist is simply nothing.
text = ""
for p in people_paths:
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            text += f.read() + "\n"
    except OSError:
        pass
names = []
for raw in re.findall(r"\*\*([^*]{2,40})\*\*", text):
    name = raw.strip().strip(".,;:")
    words = name.split()
    if not words or len(words) > 3: continue
    if words[0] in {"His", "Her", "Their", "My", "The", "A", "An"}: continue
    if not all(w[:1].isupper() and w[:1].isalpha() for w in words): continue
    if len(words[0]) < 3: continue
    names.append(words[0])
names = list(dict.fromkeys(names))
if not names:
    raise SystemExit

seen_path = os.path.join(state, "seen.json")
try: seen = json.load(open(seen_path))
except Exception: seen = {}

hits = []
for src in ("messages", "whatsapp", "telegram"):
    path = os.path.join(ctx, f"{src}.md")
    if not os.path.exists(path): continue
    last = seen.get(src, "")
    newest = last
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3: continue
        stamp, sender = parts[0], parts[-2]
        body = parts[-1]
        if not stamp or not stamp[0].isdigit(): continue
        if stamp > newest: newest = stamp
        if stamp <= last: continue           # already accounted for
        low = sender.lower()
        if low in ("me", "you") or "-> me" not in line.lower() and low == "me":
            continue
        if sender.lower().startswith("me"): continue
        for n in names:
            # The NAME must be the sender, not merely mentioned.
            if re.search(rf"(^|[^A-Za-z]){re.escape(n)}([^A-Za-z]|$)", sender, re.I):
                hits.append(f"{n} messaged you on {src}: {body[:80]}")
                break
    seen[src] = newest

os.makedirs(state, exist_ok=True)
json.dump(seen, open(seen_path, "w"))
if hits:
    print(hits[0])
PYEOF
)
  [ -n "$found" ] && reasons+=("$found")
fi

# ── Nothing worth saying ───────────────────────────────────────────────────
[ ${#reasons[@]} -eq 0 ] && exit 0

# Keep it to one thing. A pile of notifications is noise.
text="${reasons[0]}"
if [ ${#reasons[@]} -gt 1 ]; then
  text="$text (and ${#reasons[@]} other things)"
fi

python3 - "$OUT" "$text" <<'PY'
import json, os, sys, time
path, text = sys.argv[1], sys.argv[2]
json.dump({"text": text, "at": time.time()}, open(path, "w"))
os.chmod(path, 0o600)
print("nudge:", text)
PY

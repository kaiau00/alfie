#!/bin/bash
# The consent gate for the learn-me crawl. Per source, explicit, revocable.
#
#   consent.sh check <source>     rc 0 if granted, 1 if not — no output
#   consent.sh state <source>     one word: granted | refused | unset. The
#                                 app asks this to tell "said no" apart from
#                                 "never been asked", which `check` cannot.
#   consent.sh ask <source>       print what will be read, ask, record the answer
#   consent.sh grant <source>     record consent without asking (the app's
#                                 own consent sheet calls this after its click)
#   consent.sh revoke <source>
#   consent.sh show               the table
#   consent.sh profile <source>   how the source is read and how often — the
#                                 resolved learning profile, as JSON
#   consent.sh mode <source> <key> <value>
#                                 set one of sync|speak|seed|update|watch|
#                                 seed_days for a source — `speak` is "tell me
#                                 when something happens here", the answer the
#                                 proactive pass and every watch read
#                                 (learn/source_profile.py does
#                                 the work; the answer lands in consent.json
#                                 beside the source's yes/no, under "modes")
#
# Consent lives in $MOE_HOME/memory/profile/consent.json as
# {"<source>": {"granted": true|false, "date": "YYYY-MM-DD"}} — one file,
# readable by a human, the same shape whether the answer came from this
# prompt or from the app. Nothing here reads any data; it only asks.
#
# Refusing is per source and breaks nothing else: learn.sh skips a source
# without consent and carries on with the ones that have it.
set -uo pipefail

MOE="${MOE_HOME:-$HOME/.moe}"
CONN="${CONN:-$MOE/connectors}"
PROFILE="${MOE_PROFILE_DIR:-$MOE/memory/profile}"
FILE="$PROFILE/consent.json"

. "$MOE/lib/connectors.sh" 2>/dev/null || {
  echo "missing $MOE/lib/connectors.sh — re-run scripts/install.sh" >&2; exit 1; }

usage() { echo "usage: consent.sh check|state|ask|grant|revoke <source> | show | profile <source> | mode <source> <key> <value>"; exit 2; }

# One name in this file is not a connector: the daily background pass itself.
#
# Every other entry answers "may Moe read this source at all". This one
# answers the separate question "may Moe go back over the sources you have
# already said yes to, once a day, on its own" — which a person can want to
# answer differently, and has to be able to withdraw on its own. It lives in
# the same consent.json, in the same shape, so there is one file to read and
# one file to delete rather than a second store nobody knows about.
BACKGROUND_SOURCE=background-learning

# A second non-connector name: permission to WRITE what the crawl learns into
# Hermes's own long-term memory — the USER.md/MEMORY.md the agent injects into
# every turn — as opposed to merely reading a source or keeping Moe's own
# reviewable archive. Held apart because promoting crawled facts into the
# engine's core memory is a heavier, distinct decision: it is made once,
# revocable, and until it is made the daily background pass never touches that
# memory on its own.
SEED_SOURCE=memory-seeding

# A third kind of name: `watch:<connection>` — permission for Moe to keep an
# eye on ONE connection on its own and speak up when something there needs
# the user. It is not the crawl (which reads history to learn) and not the
# per-source read consent (which is about reading at all): "tell me when
# something happens there" is its own promise, off by default. Any
# connection Hermes has can be named; what a watch READS is a recipe the
# person keeps in ~/.moe/watch/<connection>.json — their own configuration
# for their own connection, never shipped, never named in code.
WATCH_DIR="${MOE_WATCH_DIR:-$MOE/watch}"
watch_recipe() { printf '%s\n' "$WATCH_DIR/${1#watch:}.json"; }

# The GATHER counterpart of a watch: bare `<connection>` names permission to
# LEARN from a connection on the daily crawl — its own read consent, same as a
# native source. What it reads is the person's own recipe at
# ~/.moe/gather/<connection>.json (parallel to ~/.moe/watch/, never shipped);
# unlike a watch, a connection with no gather recipe is not a switch at all.
GATHER_DIR="${MOE_GATHER_DIR:-$MOE/gather}"
gather_recipe() { printf '%s\n' "$GATHER_DIR/$1.json"; }

# The Hermes connections the learn pass can read back, "<kind>/<name>" per
# line, from the same probe the Connections pane uses. Files only, under an
# alarm, empty when the provider is missing.
#
# `gatherable`, not `names`: which connections can be learned from is the
# provider's rule (its GATHERABLE), and it covers two kinds — an MCP server
# of its own, and a CONNECTED service that Composio brokers. Asking `names`
# and keeping the mcp/ lines is what this used to do, and on a Mac whose
# every service comes through Composio that list is empty.
hermes_gatherable() {
  [ -x "$CONN/hermes-connections.py" ] || return 0
  /usr/bin/perl -e 'alarm 10; exec @ARGV' "$CONN/hermes-connections.py" gatherable 2>/dev/null
}

# The kind of one bare connection name ("github" → "composio"), empty when
# Hermes has no gatherable connection by that name. A dedicated server wins
# over a brokered service of the same name, as it does everywhere else.
hermes_kind() {
  local kinds
  kinds="$(hermes_gatherable | sed -n "s|^\([a-z][a-z]*\)/$1\$|\1|p")"
  if printf '%s\n' "$kinds" | grep -qx mcp; then printf 'mcp\n'
  else printf '%s\n' "$kinds" | grep -m1 .; fi
}

valid_source() {
  case "${1:-}" in ''|*[!A-Za-z0-9_:-]*) return 1 ;; esac
  case "$1" in "$BACKGROUND_SOURCE"|"$SEED_SOURCE") return 0 ;; esac
  case "$1" in
    watch:*) local c="${1#watch:}"
             case "$c" in ''|*[!A-Za-z0-9_-]*|*:*) return 1 ;; esac
             [ -f "$(watch_recipe "$1")" ] && return 0
             [ -n "$(hermes_kind "$c")" ]; return ;;
    *:*)     return 1 ;;
  esac
  [ -f "$(connector_manifest "$1")" ] && return 0
  # A bare connection name is a valid GATHER source when it is a connection
  # the learn pass can read — auto-read discovers what to read, so no recipe
  # is needed. A hand-pinned ~/.moe/gather/<c>.json still counts, for a
  # connection Hermes may no longer list.
  [ -f "$(gather_recipe "$1")" ] && return 0
  [ -n "$(hermes_kind "$1")" ]
}

# One field out of a watch recipe, for describe and list. python3 rather
# than grep: the values are prose with quotes and colons in them.
watch_field() { # watch:<c> <field>
  python3 - "$(watch_recipe "$1")" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]) or "")
except (OSError, ValueError):
    pass
PY
}

gather_field() { # <c> <field> — same, out of the gather recipe
  python3 - "$(gather_recipe "$1")" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]) or "")
except (OSError, ValueError):
    pass
PY
}

# What each source hands over. Said in plain words, once, before anything is
# read — this is the sentence the user is agreeing to, so it must not oversell
# or undersell. Falls back to the manifest label for a connector we do not
# know by name.
describe() {
  # One table, in learn/consent_list.py (DESCRIBE), so the sentence the
  # terminal prompt asks with and the one Settings shows can never drift.
  local py="$MOE/learn/consent_list.py"
  [ -f "$py" ] || py="$(dirname "$0")/consent_list.py"
  MOE_HOME="$MOE" CONN="$CONN" MOE_WATCH_DIR="$WATCH_DIR" MOE_GATHER_DIR="$GATHER_DIR" \
    python3 "$py" describe "$1" 2>/dev/null || echo "$1"
}

# How far back the question is actually asking about, in words. The number
# is the source's own `seed_days` — a year for most, ninety days for
# browsing, whatever the person has set — so the sentence someone agrees to
# is the window that is really read, not a constant that used to be true.
window_words() { # <source>
  local py="$MOE/learn/profile.py" days=""
  [ -f "$py" ] || py="$(dirname "$0")/profile.py"
  if [ -f "$py" ]; then
    days="$(MOE_HOME="$MOE" CONN="$CONN" MOE_PROFILE_DIR="$PROFILE" \
      MOE_WATCH_DIR="$WATCH_DIR" MOE_GATHER_DIR="$GATHER_DIR" \
      python3 "$py" get "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("seed_days")
    print(int(v) if v else "")
except Exception:
    print("")' 2>/dev/null)"
  fi
  case "$days" in
    ''|*[!0-9]*) echo "up to a year" ;;
    365)         echo "up to a year" ;;
    1095)        echo "up to three years" ;;
    *) if [ "$days" -ge 365 ]; then echo "up to $((days / 365)) year(s)"; else echo "up to $days days"; fi ;;
  esac
}

record() { # source, granted(true|false)
  mkdir -p "$PROFILE"
  python3 - "$FILE" "$1" "$2" "${MOE_TODAY:-$(date '+%Y-%m-%d')}" <<'PY'
import json, os, sys
path, source, granted, today = sys.argv[1:5]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    data = {}
entry = data.get(source) if isinstance(data.get(source), dict) else {}
# A yes or no is a new answer; the modes the person set beside it (how
# the source is read, `consent.sh mode`) are not, and stay.
entry.update({"granted": granted == "true", "date": today})
data[source] = entry
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=1, sort_keys=True); f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

granted() { # rc 0 if consent.json says granted
  [ -f "$FILE" ] || return 1
  python3 - "$FILE" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(1)
# Only the exact recorded shape counts: an object per source with
# "granted": true. Any other shape (a bare true, a string, a list, a
# hand-edited file) is "no" — quietly, not with a traceback.
entry = d.get(sys.argv[2]) if isinstance(d, dict) else None
sys.exit(0 if isinstance(entry, dict) and entry.get("granted") is True else 1)
PY
}

cmd="${1:-}"
case "$cmd" in
  # Machine-readable, for Settings › Background: every source the crawl could
  # read, one per line, tab-separated —
  #   name  state(granted|refused|unset)  connected(yes|no)  label  what it hands over
  # — then the two non-connector answers. "Connected" is the connector's own
  # status verb (ok: …), so a source that is not set up shows as such rather
  # than as a switch that does nothing. Native connectors only: the
  # provider's virtual ones have no crawl verb, and asking each of them is a
  # live call. Learn-me is the only reader of deep_crawl, so the list here is
  # exactly what learn.sh all would visit.
  list)
    # One process, not eighty: learn/consent_list.py builds every row —
    # native sources, the two standing answers, a watch row per Hermes
    # connection, a gather row per connection — and prints the same
    # tab-separated shape. `list --quick` makes no probe ("connected" from
    # $MOE/status.json, the last answers anyone got; unknown reads as yes);
    # a plain `list` probes everything in parallel and refreshes the cache.
    # Settings shows the quick list at once and runs the full one behind it.
    LIST_PY="$MOE/learn/consent_list.py"
    [ -f "$LIST_PY" ] || LIST_PY="$(dirname "$0")/consent_list.py"
    [ -f "$LIST_PY" ] || { echo "consent.sh: consent_list.py is missing — re-run scripts/install.sh" >&2; exit 1; }
    MOE_HOME="$MOE" CONN="$CONN" MOE_PROFILE_DIR="$PROFILE" MOE_WATCH_DIR="$WATCH_DIR" MOE_GATHER_DIR="$GATHER_DIR" \
      exec python3 "$LIST_PY" list "${2:-}"
    ;;
  show)
    if [ -f "$FILE" ]; then
      python3 - "$FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k in sorted(d):
    v = d[k]
    # An entry holding only "modes" (consent.sh mode, before any answer) is
    # a setting, not an answer: no row.
    if not isinstance(v, dict) or "granted" not in v:
        continue
    print("%-16s %-8s %s" % (k, "granted" if v.get("granted") else "refused", v.get("date", "")))
PY
    else
      echo "no consent recorded yet"
    fi
    exit 0 ;;
  # The learning profile: how a source is read and how often. Both verbs
  # are learn/profile.py's (which forwards to source_profile.py), with the
  # same directories this script resolves, so a scratch home in a test and
  # the real one are the same to both. A bare name is a native connector
  # to profile.py; here, as everywhere in this file, a bare name with no
  # manifest but a recipe (or a Hermes connection) is that connection,
  # so `mode notion update weekly` means mcp/notion — and `mode github
  # update weekly`, on a Mac where GitHub comes through Composio, means
  # composio/github. The kind comes from the provider, never from a guess
  # here: a well-formed `mcp/github` that resolves to nothing would take the
  # answer and apply it to no source at all. A name that is BOTH a Mac
  # connector and a connection — calendar.manifest beside
  # gather/calendar.json — is refused rather than guessed: the two have
  # separate settings, and `mode calendar sync no` meant for the recipe
  # would switch the Mac connector off. Say native/x or mcp/x. profile.py
  # validates the key, the value and the source, and exits 2 writing nothing.
  profile|mode)
    PROFILE_PY="$MOE/learn/profile.py"
    [ -f "$PROFILE_PY" ] || PROFILE_PY="$(dirname "$0")/profile.py"
    [ -f "$PROFILE_PY" ] || { echo "consent.sh: profile.py is missing — re-run scripts/install.sh" >&2; exit 1; }
    src="${2:-}"
    case "$src" in
      ''|*[!A-Za-z0-9_:/-]*) echo "consent.sh: '$src' is not a connector" >&2; exit 2 ;;
      */*|hermes:*) ;;
      *) kind="$(hermes_kind "$src")"
         if [ -n "$kind" ] || [ -f "$(gather_recipe "$src")" ] || [ -f "$(watch_recipe "watch:$src")" ]; then
           if [ -f "$(connector_manifest "$src")" ]; then
             echo "consent.sh: '$src' is both a Mac connector and a Hermes connection — say native/$src or ${kind:-mcp}/$src" >&2; exit 2
           fi
           src="${kind:-mcp}/$src"
         fi ;;
    esac
    export MOE_HOME="$MOE" CONN="$CONN" MOE_PROFILE_DIR="$PROFILE" MOE_WATCH_DIR="$WATCH_DIR" MOE_GATHER_DIR="$GATHER_DIR"
    if [ "$cmd" = profile ]; then
      [ $# -eq 2 ] || usage
      exec python3 "$PROFILE_PY" get "$src"
    fi
    [ $# -eq 4 ] || usage
    exec python3 "$PROFILE_PY" set "$src" "$3" "$4"
    ;;
  check|state|ask|grant|revoke) ;;
  *) usage ;;
esac

src="${2:-}"
valid_source "$src" || { echo "consent.sh: '$src' is not a connector" >&2; exit 2; }

case "$cmd" in
  check)  granted "$src" ;;
  # "refused" and "unset" are different answers and the app has to tell them
  # apart: it may ask once, and must not ask again after someone has said no.
  # Always exit 0 — the word is the answer, not the exit code.
  state)
    python3 - "$FILE" "$src" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    d = {}
entry = d.get(sys.argv[2]) if isinstance(d, dict) else None
# "modes" alone (consent.sh mode, before any answer) is not an answer.
if not isinstance(entry, dict) or "granted" not in entry:
    print("unset")
else:
    print("granted" if entry.get("granted") is True else "refused")
PY
    exit 0 ;;
  grant)  record "$src" true;  echo "consent recorded for $src" ;;
  revoke) record "$src" false; echo "consent withdrawn for $src — learn.sh will skip it" ;;
  ask)
    if granted "$src"; then exit 0; fi
    # The background pass is not a source, so the sentence about what would
    # be read does not fit it. Its own words, then the same prompt.
    if [ "$src" = "$BACKGROUND_SOURCE" ]; then
      cat <<EOF

Once a day, Moe would go back over the sources you have already said yes to
and write down a short list of things about you. It reads nothing you have
not already agreed to, and no new source is added by saying yes here.

It all stays on this Mac. What is kept is the list, with where each line came
from and when, in ~/.moe/memory/profile/. Stop it later with:
  ~/.moe/learn/consent.sh revoke $src

EOF
    elif [ "$src" = "$SEED_SOURCE" ]; then
      cat <<EOF

Moe would save what it has learned about you into its long-term memory, so it
remembers you from one chat to the next. Only a few durable, high-signal facts
are kept, and Moe never overwrites or deletes what is already there.

It all stays on this Mac. The facts go to the local Hermes agent, which
decides what to keep; the raw list, with a source and date on each, stays in
~/.moe/memory/profile/ for you to see and correct. Withdraw this later with:
  ~/.moe/learn/consent.sh revoke $src

EOF
    else
    cat <<EOF

To learn about you from ${src}, Moe would read
  $(describe "$src")
going back $(window_words "$src"), once — after that it only catches up.

It all stays on this Mac. The text goes to the local Hermes agent on this
machine in small pieces, and what comes back is a short list of facts with
a source and date on each, in ~/.moe/memory/profile/. You can see, correct
and delete every one of them, and withdraw this later with:
  ~/.moe/learn/consent.sh revoke $src

EOF
    fi
    if [ ! -t 0 ] && [ -z "${MOE_CONSENT_STDIN:-}" ]; then
      # Not a terminal and nobody said stdin is an answer: a background job
      # cannot consent on the user's behalf.
      echo "no terminal to ask on — run this yourself, or the app will ask"
      exit 1
    fi
    case "$src" in
      "$BACKGROUND_SOURCE"|"$SEED_SOURCE") printf 'Turn this on? [y/N] ' ;;
      *) printf 'Read %s? [y/N] ' "$src" ;;
    esac
    read -r yn || yn=n
    case "$yn" in
      [Yy]|[Yy][Ee][Ss]) record "$src" true;  echo "Thanks — recorded."; exit 0 ;;
      *)                 record "$src" false
                         case "$src" in
                           "$BACKGROUND_SOURCE"|"$SEED_SOURCE") echo "Left alone. Nothing changes." ;;
                           *) echo "Left alone. Nothing from $src will be read." ;;
                         esac
                         exit 1 ;;
    esac ;;
esac

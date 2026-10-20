#!/bin/bash
# The gate in front of anything another person will receive.
#
# This exists because "Moe promises to ask first" is not a control — it is an
# instruction, and instructions can be talked around by text Moe reads in your
# mail or messages. This puts a real dialog in the path: the send cannot
# happen unless a human clicks Send, and the dialog shows the exact recipients
# and the exact words that will go out. Every recipient, always — a list too
# long to show is refused rather than shortened.
#
#   confirm.sh "WhatsApp" "Dad" "Running 10 minutes late" [tool-id] [icon-key] [kind] [edit] [detail] [headline]
#
# The arguments after the message are optional. The raw tool id to print
# quietly under the buttons, which service mark to draw, "send", "act" or
# "session", whether the caller can send a message the person REWROTE in the
# dialog ("yes", the default, or "no"), and a detail — code the dialog draws
# under the sentence, as code, so the message can stay a sentence — and a
# headline: one line saying what is being asked and where ("Create an account
# on fazier.com?"), which the card draws in place of the service's name.
# Callers that predate them lose a subtitle, nothing else.
#
# Who named the recipient arrives as data, in MOE_CONFIRM_PROVENANCE: one line
# of JSON from tools/recipients.py — {"state": "named"|"partial"|"found"|"shown"|"owner",
# "recipient", "quote", "said", "source", "requested", "mismatch", "query",
# "query_unasked"}. The dialog says "You named this person: …" or, in amber,
# "You said 'Walter' — Moe picked …" / "Moe chose this person — found in …", and
# warns when the request named somebody else or the search was Moe's own idea.
# Absent (a Hermes that keeps no record), it says nothing about it.
#
# Exit 0 = approved, send exactly what was shown.
# Exit 6 = approved, and "Allow everything this session" was pressed. Only a
#          `session` kind can answer this; the hook writes the grant. Any
#          other kind reads 6 as "not 0" and does not send.
# Exit 5 = approved AS EDITED: the person changed the words, and the changed
#          fields are on stdout as NUL-separated `key=value` records —
#          `body=…`, `subject=…`, only what changed. A caller that reads 5
#          must send those words and not the ones it asked about; a caller
#          that predates 5 reads it as "not 0" and does not send, which is
#          the safe way for an old caller to be wrong.
# Exit 7 = withdrawn: whoever asked went away, or nobody answered before the
#          deadline. Nothing was sent, and the card left a sentence saying
#          so in the person's inbox. (Any caller reading "not 0" is right.)
# Anything else = do not send.
#
# Two dialogs, in this order
# --------------------------
# 1. `moe-confirm`, Moe's own (Sources/MoeConfirm) — the message scrolls, so
#    nothing is truncated, the recipient is the largest thing on screen, and
#    it is recognisably the app you were just talking to rather than a system
#    alert with a caution triangle. Which matters for more than looks: a
#    person who has learnt what Moe's approval prompt looks like has some
#    chance of noticing one that is not.
# 2. `display dialog`, the AppleScript one, if there is no moe-confirm on this
#    Mac or it could not put a window up. It cannot scroll, so this is also
#    the only path that still has to cut a long message short — and it says
#    in numbers how much it is not showing, because approving words you were
#    never shown is the one thing this script exists to prevent.
#
# Only exit 0 from the dialog is a send. "I could not ask" (anything but 0 or
# 1 out of moe-confirm) falls through to the second dialog rather than being
# read as an answer, and if that fails too, nothing is sent.
#
# There is deliberately NO environment variable pointing at the dialog. A
# gate you can aim at /bin/true with an exported variable is not a gate, so
# the path is derived from this script's own location and the fixed places
# Memoe.app lives — the same rule connectors/gmail.py applies to finding this
# file.
set -uo pipefail

CHANNEL="${1:?channel required}"
TO="${2:?recipient required}"
BODY="${3:?message required}"
TOOL="${4:-}"
SERVICE="${5:-}"
# What kind of thing is being confirmed. "send": a message leaves — Send /
# Cancel, and nothing is ever remembered. "act": a tool that changes things,
# or one nobody has vouched for — Do it / Always allow / Cancel, and "Always
# allow" (exit 4) is written to ~/.moe/gate/policy.json by the hook, never here.
# "session": a send that, approved, covers the rest of the conversation —
# Send / Allow everything this session / Cancel, and the hook remembers.
KIND="${6:-send}"
case "$KIND" in send|act|session) ;; *) KIND=send ;; esac
# Whether the caller can put a rewritten message into what it sends. The
# hook says "no" for a call whose message it found nowhere it can write
# back to; every connector of Moe's own can, and says nothing.
EDIT="${7:-yes}"
case "$EDIT" in yes|no) ;; *) EDIT=yes ;; esac
# What the dialog draws as code under the sentence, if anything.
DETAIL="${8:-}"
# One line: what is being asked, and where. Never more than one line — a
# break is how a heading grows a second, forged one.
HEADLINE="$(printf '%s' "${9:-}" | /usr/bin/tr '\n\r' '  ')"
# One line of JSON, or nothing. A newline or a NUL would split the record the
# dialog reads, so anything carrying one is dropped rather than repaired.
PROVENANCE="${MOE_CONFIRM_PROVENANCE:-}"
case "$PROVENANCE" in *$'\n'*|*$'\r'*) PROVENANCE="" ;; esac

# A gate that cannot show what it is approving must refuse. A recipient list
# longer than a dialog can hold would push the message off the bottom of the
# screen, and the person would be clicking Send on words they cannot see.
if [ ${#TO} -gt 900 ]; then
  echo "not sent — that recipient list is too long to show in one dialog" >&2
  exit 1
fi

# `pwd -P` rather than $MOE_HOME or an argument: the dialog this runs has to
# be the one shipped beside this file, not one somebody pointed it at. And
# every external binary below is absolute — `osascript` off $PATH is a
# dialog somebody else wrote, which is the same hole as a movable gate
# wearing different clothes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# In order: inside the app wherever it was put, then a repo checkout's build.
# First one that exists and is executable wins.
#
# `$HERE/moe-confirm` used to be first, and was the worst line in this file.
# $HERE is ~/.moe/tools — the toolbelt, which the model writes to as a matter
# of course, and which Layer 0 deliberately does not protect as a directory
# because apple.sh and mac.sh live there. `moe-confirm` was not a protected
# basename either. So `cp /bin/true ~/.moe/tools/moe-confirm` passed the hook
# silently and every send afterwards was approved by /bin/true, for ever,
# with no dialog. Nothing ever installed a dialog there; the line existed to
# make a test convenient. The test now points $MOE_CONFIRM_UI_FOR_TESTS at
# its stub, which is honoured only alongside $MOE_HOOK_TEST=1 — the same
# two-key arrangement the hook uses, for the same reason.
# "Pretend this is not a Mac", for the tests, under the same three conditions
# as the two seams below and with the same reasoning: two exported variables
# is a longer string rather than a key, so this script must ALSO be running
# from a temporary directory, which a test copy is and the installed gate
# never is.
#
# It has to be answerable BEFORE find_ui runs, and that is not a style
# preference — it is a bug this file already had for one afternoon. Written
# as a test on `$UI` *after* the search, the first away test on a developer's
# Mac found `/Applications/Memoe.app/Contents/MacOS/moe-confirm`, put a real
# approval dialog on the owner's screen, and sat there waiting for them to
# click it. A seam that says "there is no dialog here" must be consulted
# before anything goes looking for one.
#
# Note what it can and cannot do. It ROUTES; it does not approve. Forced on,
# it reaches confirm-away.py, which refuses without a $MOE_ASK_DIR a caller
# minted and refuses again without the exact word `approved` inside it. There
# is no arrangement of these variables that sends a message.
seam_away() {
  [ "${MOE_HOOK_TEST:-}" = "1" ] || return 1
  [ "${MOE_NOT_A_MAC_FOR_TESTS:-}" = "1" ] || return 1
  case "$HERE" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
  esac
  return 1
}

find_ui() {
  local candidate
  # Before the search, not after it. See seam_away.
  seam_away && return 1
  # A test seam, and only in a place a test can be.
  #
  # Two exported variables is not a key, it is a longer string: with just
  # that, `MOE_HOOK_TEST=1 MOE_CONFIRM_UI_FOR_TESTS=/usr/bin/true` opened
  # this gate from a shell — and on the shell route into gmail.py and
  # whatsapp.sh, this dialog is the ONLY gate, because the Hermes hook
  # deliberately does not double up on connectors that confirm themselves.
  # So the seam now also requires that THIS SCRIPT is running from a
  # temporary directory, which is what a test copy is and what the installed
  # gate never is. The connectors resolve confirm.sh through their own
  # realpath, so the file they reach is always the installed one, where the
  # seam is dead however the environment is set.
  if [ "${MOE_HOOK_TEST:-}" = "1" ] && [ -x "${MOE_CONFIRM_UI_FOR_TESTS:-}" ]; then
    case "$HERE" in
      /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
        printf '%s' "$MOE_CONFIRM_UI_FOR_TESTS"; return 0 ;;
    esac
  fi
  for candidate in \
    "/Applications/Memoe.app/Contents/MacOS/moe-confirm" \
    "$HOME/Applications/Memoe.app/Contents/MacOS/moe-confirm" \
    "$HERE/../../dist/Memoe.app/Contents/MacOS/moe-confirm" \
    "$HERE/../../.build/release/MoeConfirm"
  do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

# Who is waiting on this card, and until when (Sources/MoeDesign/
# ConfirmLifecycle.swift). The card withdraws — exit 7, never a send — when
# any of these processes is gone, when this script is, or at the deadline.
#   * $PPID: whatever ran this script — a connector, or the send hook.
#   * $MOE_CONFIRM_REQUESTER: the process that ran THAT (the connectors
#     plugin sets it), for when a connector outlives the job that asked.
#   * $MOE_CONFIRM_DEADLINE: an absolute time, seconds since 1970, from the
#     caller's own timeout; else half an hour. The card caps it at an hour.
# These can only make a card give up sooner. None of them can approve.
LIFE_REQUESTER="$PPID ${MOE_CONFIRM_REQUESTER:-}"
case "${MOE_CONFIRM_DEADLINE:-}" in
  ''|*[!0-9]*) LIFE_DEADLINE=$(( $(/bin/date +%s) + 1800 )) ;;
  *) LIFE_DEADLINE="$MOE_CONFIRM_DEADLINE" ;;
esac
LIFE_HOME="$(cd "$HERE/.." && pwd -P)"
# Who asked, when it was not the person's own turn (a scheduled job,
# background work, and the owner is at the Mac): a label on the card, one
# line, never a way to approve anything.
LIFE_ORIGIN="$(printf '%s' "${MOE_CONFIRM_ORIGIN:-}" | /usr/bin/tr '\n\r' '  ')"
UI_PID=""
# The card goes when this script goes, however it goes. A SIGKILL runs no
# trap; the card sees its parent vanish and withdraws on its own.
# A hang-up is passed on as one — the card reads it as "the task that asked
# stopped" — and anything else as TERM ("closed").
stop_card() { [ -n "$UI_PID" ] && kill -"${1:-TERM}" "$UI_PID" 2>/dev/null; UI_PID=""; }
# A person has given a FINAL answer — Send, Always, Session or Cancel, on the
# card or on the AppleScript dialog: say so to the plugin that watches this
# send's turn (moe-connectors ConnectorGroup), which from then on lets it
# finish instead of withdrawing it. Never on a withdrawal, and never on a
# card that could not ask and falls through to the other dialog — that one is
# still waiting on a person. Only a path of the shape the plugin makes is
# touched, so nothing else can be aimed at with this.
mark_answered() {
  case "${MOE_CONFIRM_ANSWERED:-}" in
    */moe-card-*/answered) [ -d "${MOE_CONFIRM_ANSWERED%/answered}" ] && /usr/bin/touch "$MOE_CONFIRM_ANSWERED" ;;
  esac
  return 0
}
OSA_OUT=""
cleanup() { stop_card; [ -n "${UI_OUT:-}" ] && rm -f "$UI_OUT"; [ -n "$OSA_OUT" ] && rm -f "$OSA_OUT"; return 0; }
trap cleanup EXIT
trap 'stop_card; exit 143' TERM
trap 'stop_card HUP; exit 129' HUP
trap 'stop_card; exit 130' INT

UI="$(find_ui)"
if [ -n "$UI" ]; then
  # What the dialog says back — the rewritten fields, when there are any —
  # goes through a file, not a variable: bash drops NUL from a command
  # substitution, and NUL is what separates the records. mktemp makes it
  # 0600, and it is gone on every way out of this script.
  UI_OUT="$(mktemp "${TMPDIR:-/tmp}/moe-confirm-answer.XXXXXX")" || UI_OUT=""
  # NUL-separated key=value records on stdin. Not argv: `ps` shows argv to
  # every process on this Mac, and this is somebody's private message.
  # In the background and waited for, so the traps above know its pid and
  # a signal to this script reaches `wait` instead of queuing behind it.
  "$UI" >"${UI_OUT:-/dev/null}" < <(
    printf 'channel=%s\0to=%s\0body=%s\0tool=%s\0service=%s\0kind=%s\0edit=%s\0detail=%s\0' \
      "$CHANNEL" "$TO" "$BODY" "$TOOL" "$SERVICE" "$KIND" "$EDIT" "$DETAIL"
    [ -n "$HEADLINE" ] && printf 'headline=%s\0' "$HEADLINE"
    printf 'requester=%s\0deadline=%s\0home=%s\0' "$LIFE_REQUESTER" "$LIFE_DEADLINE" "$LIFE_HOME"
    [ -n "$LIFE_ORIGIN" ] && printf 'origin=%s\0' "$LIFE_ORIGIN"
    printf 'provenance=%s\0' "$PROVENANCE"
  ) &
  UI_PID=$!
  wait "$UI_PID"
  UI_STATUS=$?
  UI_PID=""
  case "$UI_STATUS" in
    0)
      mark_answered
      echo "approved"
      exit 0
      ;;
    5)
      # Send, as rewritten. Only a message can be rewritten, only when the
      # caller said it could take one, and only when the dialog actually
      # handed something back that a person could have typed: a 5 with no
      # records, or with a record carrying a character that can steer what
      # a screen shows, is not an answer, and the other dialog asks — with
      # the original words, which is the safe side to be wrong on.
      if [ "$KIND" = "send" ] && [ "$EDIT" = "yes" ] && [ -n "$UI_OUT" ] \
         && command -v python3 >/dev/null 2>&1 \
         && python3 - "$UI_OUT" <<'PY'
import re, sys
bad = re.compile("[\x00-\x08\x0b-\x1f\x7f\u2028\u2029\u202a-\u202e\u2066-\u2069]")
try:
    raw = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(1)
kept = []
for rec in raw.split(b"\0"):
    key, sep, value = rec.partition(b"=")
    if not sep or key not in (b"body", b"subject"):
        continue
    text = value.decode("utf-8", "replace")
    if bad.search(text.replace("\n", "").replace("\t", "")):
        sys.exit(1)
    if key == b"subject" and "\n" in text:
        sys.exit(1)
    kept.append(key + b"=" + text.encode("utf-8") + b"\0")
if not kept:
    sys.exit(1)
sys.stdout.buffer.write(b"".join(kept))
sys.stdout.flush()
PY
      then
        mark_answered
        exit 5
      fi
      # Not an answer: fall through and ask the other way.
      ;;
    1)
      mark_answered
      echo "cancelled by user — nothing was sent" >&2
      exit 1
      ;;
    7)
      # Withdrawn. Never the other dialog: whoever asked has gone, and a
      # second card for nobody is the orphan this exit exists to prevent.
      echo "not sent — the confirmation expired before anyone answered" >&2
      exit 7
      ;;
    4)
      # Only an act can be allowed for good. A send dialog never exits 4; if
      # one does, that is not an answer, and the fallback asks again.
      if [ "$KIND" = "act" ]; then
        mark_answered
        echo "approved, and always allowed from now on"
        exit 4
      fi
      ;;
    6)
      # Only a session can be allowed whole. Anything else exiting 6 is not
      # an answer, and the fallback asks again.
      if [ "$KIND" = "session" ]; then
        mark_answered
        echo "approved, and everything allowed for this session"
        exit 6
      fi
      ;;
    *)
      # Could not ask: no window server, a crash, a build that predates this
      # protocol. Ask the other way rather than deciding on its behalf.
      ;;
  esac
fi

# Past this point nothing can draw a headline apart from the message: the
# phone prompt and `display dialog` take one text. So it goes first, where a
# person reads first.
if [ -n "$HEADLINE" ]; then
  BODY="$HEADLINE"$'\n\n'"$BODY"
fi

# Not a Mac at all: ask on the phone instead of failing silently.
#
# Everything below this point is `display dialog`, which needs a window
# server. The away machine has none — no `Memoe.app` for find_ui to find and no
# `/usr/bin/osascript` to run — so every send from there has ended the same
# way since the machine existed: `$OSA` is not a file, RESULT comes back
# empty, "cancelled by user" on stderr, exit 1. Nothing shown, nothing sent,
# and nobody asked.
#
# So this branch cannot weaken the gate, and that is structural rather than
# careful. It is reached only where BOTH of the Mac's dialogs are absent —
# which is to say only on a runtime where the code beneath it always refuses.
# The worst it can do is refuse the same sends. It is also worth saying what
# it does NOT do: it does not decide anything. confirm-away.py carries the
# question out and an answer back, and only the exact word `approved` is a
# send.
#
# The two tests are facts about this machine, not settings on it: no dialog
# binary anywhere find_ui looks, and no /usr/bin/osascript. The second is the
# sharper one — osascript is on every Mac and on nothing else, and a Mac that
# has lost it has lost more than this script. No environment variable selects
# this path in production; find_ui already explains at length why a gate you
# can aim with an exported variable is not a gate, and the same rule binds
# here.
not_a_mac() {
  # The seam is checked first and has already made find_ui return nothing, so
  # the two clauses agree rather than race. In production only the second
  # runs, and it is two facts about this machine: no dialog binary anywhere
  # find_ui looks, and no /usr/bin/osascript. The second is the sharper one —
  # osascript is on every Mac and on nothing else.
  seam_away && return 0
  [ -z "$UI" ] && [ ! -x /usr/bin/osascript ]
}

# confirm-away.py is resolved from $HERE, beside this file, exactly as find_ui
# resolves the dialog and as gmail.py resolves this script. It is handed the
# same NUL-separated records the Swift dialog is handed, on stdin and never
# argv, for the same reason: `ps` shows argv to every process on this machine
# and this is somebody's private message.
if not_a_mac; then
  if [ ! -x "$HERE/confirm-away.py" ]; then
    # Missing rather than silent. This is the shape the image gets wrong —
    # one of two files arrives — and "nothing was sent" with no reason is
    # what made a withheld connector read as a broken one.
    echo "not sent — there is no way to ask you about this from here (no dialog, and no $HERE/confirm-away.py)" >&2
    exit 1
  fi
  set +o pipefail
  printf 'channel=%s\0to=%s\0body=%s\0tool=%s\0service=%s\0kind=%s\0' \
    "$CHANNEL" "$TO" "$BODY" "$TOOL" "$SERVICE" "$KIND" \
    | "$HERE/confirm-away.py"
  AWAY_STATUS=$?
  set -o pipefail
  # 0 is the only approval. Every other exit — a denial, nobody answering, no
  # place to ask, a crash — is a refusal, and confirm-away.py has already
  # written the sentence saying which. It never exits 5: there is no text
  # field on a phone prompt, so nothing can come back rewritten, and a caller
  # reading 5 would send words the person never typed.
  if [ "$AWAY_STATUS" -eq 0 ]; then
    echo "approved"
    exit 0
  fi
  exit 1
fi

# `display dialog` has no scroll bar, and a dialog taller than the screen is
# clipped with nothing to say so. So the body is cut at a length that fits —
# and the dialog says, in numbers, how much it is not showing. What gets sent
# is unchanged: this is display only.
# The AppleScript dialog cannot style a real field apart from a forged one,
# and the recipient reaching it is not always checked by whoever passed it:
# telegram.py builds it from the contact's own name off the wire, and
# whatsapp.sh reads it out of a chats table the other party writes to. A
# newline in there draws a complete, correctly-labelled forgery — a second
# "TO (checked):" line, or a second message — under the real one. Moe's own
# dialog names these characters; this one has no way to, so they are replaced
# before it ever sees them. No legitimate recipient contains a newline.
# This weaker dialog cannot style a forged recipient apart from a real one, so
# it must not be handed one that can lie about itself. C0 controls go to
# spaces; the Unicode bidi and format overrides (which can visually reverse a
# recipient) are stripped too, via python3 when it is here — the Swift dialog
# names these, this one can only remove them. NUL never reaches here (bash
# drops it on read), so what is shown is what moe-confirm would have sent.
strip_steering() { # stdin -> stdout, bidi/format controls removed
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,unicodedata
t=sys.stdin.read()
bad=set(range(0x202A,0x202F))|set(range(0x2066,0x206A))|{0x200E,0x200F,0x061C,0xFEFF,0x2028,0x2029}
sys.stdout.write("".join(" " if (ord(c)<0x20 or ord(c) in bad or unicodedata.category(c) in ("Cf","Cc")) else c for c in t))'
  else
    LC_ALL=C tr '\000-\037' ' '
  fi
}
TO="$(printf '%s' "$TO" | strip_steering)"
CHANNEL="$(printf '%s' "$CHANNEL" | strip_steering)"

# `display dialog` has no scroll bar and no height clamp, so a body that is
# short in characters and tall in lines pushes its own buttons off the
# screen: 1,799 characters of newlines passed the character limit with
# nothing hidden and nothing said. Both are capped.
LIMIT=1800
MAX_LINES=24
SHOWN="$BODY"
HIDDEN=0
LINES="$(printf '%s' "$SHOWN" | grep -c '' || true)"
if [ "${LINES:-0}" -gt "$MAX_LINES" ]; then
  SHOWN="$(printf '%s' "$SHOWN" | head -n "$MAX_LINES")"
  HIDDEN=$(( ${#BODY} - ${#SHOWN} ))
fi
if [ ${#SHOWN} -gt "$LIMIT" ]; then
  HIDDEN=$(( ${#SHOWN} - LIMIT ))
  SHOWN="${SHOWN:0:$LIMIT}"
fi

# Absolute, for the same reason the dialog path is: `osascript` off $PATH is
# a dialog somebody else wrote. The test seam beside it obeys the same rule
# as the one above — this script must itself be running from a temporary
# directory, which the installed gate never is.
OSA=/usr/bin/osascript
if [ "${MOE_HOOK_TEST:-}" = "1" ] && [ -x "${MOE_OSASCRIPT_FOR_TESTS:-}" ]; then
  case "$HERE" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
      OSA="$MOE_OSASCRIPT_FOR_TESTS" ;;
  esac
fi

# Who named the recipient, as one line this dialog can show. Written by the
# same rules as Moe's own dialog (Sources/MoeConfirm/ConfirmProvenance.swift).
WHO=""
if [ -n "$PROVENANCE" ] && command -v python3 >/dev/null 2>&1; then
  WHO="$(printf '%s' "$PROVENANCE" | python3 -c 'import json, sys
try:
    p = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(p, dict):
    sys.exit(0)
state = p.get("state")
g = lambda k: str(p.get(k) or "").strip()
if state == "named":
    line = "WHO: you named this person: \u201c%s\u201d" % g("quote") if g("quote") else "WHO: you named this person"
elif state == "partial":
    line = "WHO: \u26a0\ufe0f you said \u201c%s\u201d \u2014 Moe picked %s" % (g("said"), g("recipient"))
elif state == "found":
    line = "WHO: \u26a0\ufe0f Moe chose this person \u2014 found in %s" % (g("source") or "a lookup")
elif state == "shown":
    line = "WHO: \u26a0\ufe0f Moe found this address on %s and showed it to you" % (g("source") or "a page")
    if g("said"):
        line += " \u2014 you said \u201c%s\u201d" % g("said")
elif state == "owner":
    line = "WHO: this is you \u2014 you asked for it"
elif state == "legacy":
    line = "WHO: \u26a0\ufe0f this job was made before Moe checked recipients"
else:
    line = ""
if line and p.get("mismatch") and g("requested"):
    line += "  \u26a0\ufe0f You asked for \u201c%s\u201d, not this person." % g("requested")
if line and p.get("query_unasked"):
    line += ("  \u26a0\ufe0f Moe searched for \u201c%s\u201d on its own." % g("query") if g("query")
             else "  \u26a0\ufe0f Moe picked them from a list it pulled up on its own.")
sys.stdout.write(line)' 2>/dev/null | strip_steering)"
fi

# Bounded by the same deadline as the card (`giving up after`), and run in the
# background like the card, so the traps above take it down with its turn.
GIVE_UP=$(( LIFE_DEADLINE - $(/bin/date +%s) ))
[ "$GIVE_UP" -lt 1 ] && GIVE_UP=1
OSA_OUT="$(mktemp "${TMPDIR:-/tmp}/moe-confirm-osa.XXXXXX")" || OSA_OUT=""
"$OSA" - "$CHANNEL" "$TO" "$SHOWN" "$HIDDEN" "$KIND" "$GIVE_UP" "$WHO" >"${OSA_OUT:-/dev/null}" 2>/dev/null <<'AS' &
on run argv
  set channelName to item 1 of argv
  set recipient to item 2 of argv
  set bodyText to item 3 of argv
  set hiddenCount to item 4 of argv
  set kindName to item 5 of argv
  set giveUp to (item 6 of argv) as integer
  set whoLine to item 7 of argv
  if whoLine is not "" then set recipient to recipient & return & whoLine
  if hiddenCount is not "0" then
    set bodyText to bodyText & "…" & return & return & ¬
        "⚠️ " & hiddenCount & " more characters follow that are NOT shown here. " & ¬
        "They will be sent. Cancel if you have not read them."
  end if
  -- The message is fenced. The Swift dialog stopped reading To:/Cc:/Bcc: out
  -- of a body precisely because a message beginning "To: dad@example.com"
  -- drew a second recipient row that nothing had checked; this dialog is one
  -- pkill away and had none of that. It cannot style the two apart, so it
  -- says which is which instead.
  --
  -- No apostrophes or backticks in this block: bash 3.2 scans a quoted
  -- heredoc for quotes when it sits inside a command substitution, and one
  -- "Moe" + "s" cost an hour.
  if kindName is "act" then
    set prompt to "Let Moe run this " & channelName & " tool?" & return & return & ¬
        "TARGET: " & recipient & return & return & bodyText
    set dialogTitle to "Moe wants to do something"
    set yesButton to "Do it"
  else
    set prompt to "Send this " & channelName & " message?" & return & return & ¬
        "TO (checked): " & recipient & return & return & ¬
        "MESSAGE (as written, not checked):" & return & bodyText
    set dialogTitle to "Moe wants to send a message"
    set yesButton to "Send"
  end if
  try
    set answer to display dialog prompt ¬
      with title dialogTitle ¬
      buttons {"Cancel", yesButton} ¬
      default button "Cancel" ¬
      with icon caution ¬
      giving up after giveUp
    if gave up of answer then return "GaveUp"
    return button returned of answer
  on error number errorNumber
    -- -128 is the person pressing Cancel; anything else is not an answer.
    if errorNumber is -128 then return "Cancel"
    return "Error"
  end try
end run
AS
UI_PID=$!
wait "$UI_PID"
UI_PID=""
RESULT="$( [ -n "$OSA_OUT" ] && cat "$OSA_OUT")"

if [ "$RESULT" = "Send" ] || [ "$RESULT" = "Do it" ]; then
  mark_answered
  echo "approved"
  exit 0
fi
if [ "$RESULT" = "GaveUp" ]; then
  echo "not sent — the confirmation expired before anyone answered" >&2
  exit 7
fi
if [ "$RESULT" = "Cancel" ]; then
  mark_answered
  echo "cancelled by user — nothing was sent" >&2
  exit 1
fi
# Not an answer at all — the dialog errored, or never ran. Said as that: no
# person cancelled anything.
echo "not sent — the confirmation could not be shown, so nothing was sent" >&2
exit 1

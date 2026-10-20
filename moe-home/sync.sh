#!/bin/bash
# Pulls every connected source into ~/.moe/context/ so Moe already knows
# what's going on before you ask.
#
# Runs from a LaunchAgent every few minutes. Designed to be boring: one broken
# source never takes down the rest, nothing here calls a model, and the whole
# pass is plain files you can read.
#
#   sync.sh          — pull everything the profiles say to keep up to date
#
# Which sources that is comes from learn/profile.py ("sync" in Settings ›
# Background): a native switched off is left alone and its old context file
# removed; a Hermes connection is read only with a gather recipe, sync on
# and consent, and at most hourly (see gather_one). Without a usable
# profile.py nothing is gated and nothing is removed.
#
# The hourly "digest" this file used to run (a `claude -p` call to distil
# the brief into memory/*.md) is gone: its prompt sat after `--add-dir`,
# which swallows it, so every run since it was installed failed with "Input
# must be provided either through stdin or as a prompt argument" and wrote
# nothing — and it went around Hermes, so what it might have learned would
# have landed in files the model never reads. Hermes's `moe-proactive` cron
# job (hermes-jobs/moe-proactive.json) does that work now, in Hermes's own
# memory, and only when the brief has actually changed.
set -uo pipefail

# MOE_HOME, the way learn.sh takes it, so a test can point this at a scratch
# home; the app runs it with nothing set and lands on ~/.moe as ever.
MOE="${MOE_HOME:-$HOME/.moe}"
CTX="$MOE/context"
CONN="${CONN:-$MOE/connectors}"
LOG="$MOE/logs/sync.log"
# Seconds a single source may take; then it is cut off and the last file
# kept. MOE_SYNC_TIMEOUT so a test can make "too long" a couple of seconds.
TIMEOUT="${MOE_SYNC_TIMEOUT:-45}"
# A Hermes connection with a gather recipe is read at most this often (an
# hour), not every tick: each read is a fresh Hermes process connecting to
# the server and making every read in the recipe — see gather_one.
GATHER_EVERY="${MOE_GATHER_EVERY:-3600}"

mkdir -p "$CTX" "$MOE/logs" "$MOE/memory"

# Tell the connectors this is the timer, not a person:
#   MOE_SYNC=1                the Notes connectors skip their AppleScript pull
#                             unless Notes.app is already open (it would launch
#                             it, visibly, every tick) and print "skipped: …"
#                             so the last context file is kept — see pull_one.
#   MOE_EVENTKIT_NO_PROMPT=1  the Calendar/Reminders reads (Moe --calendar,
#                             --reminders) never raise the permission sheet
#                             from here; doctor.sh raises it on purpose.
export MOE_SYNC=1 MOE_EVENTKIT_NO_PROMPT=1

# Which connectors exist is not this file's business. lib/connectors.sh finds
# every <name>.manifest in connectors/ and tells us what to run and where to
# write it; adding a source means dropping in a script and a manifest, not
# editing the sync loop.
#
# Fail loudly if it is missing. This file runs without `set -e`, so a failed
# source would otherwise leave connectors_list undefined, run the loop zero
# times, and publish an empty brief with a clean exit — the worst outcome.
. "$MOE/lib/connectors.sh" || {
  echo "missing $MOE/lib/connectors.sh — re-run scripts/install.sh" >&2; exit 1; }

# Only one sync at a time: the 10-minute agent and the Settings pane's
# "Refresh now" both run this file.
exec 9>"$MOE/.sync.lock"
if ! /usr/bin/perl -e 'use Fcntl ":flock"; open(F, "<&=9") or exit 1; flock(F, LOCK_EX|LOCK_NB) or exit 1' 9<&9; then
  echo "another sync is already running" >&2
  exit 0
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# macOS has no coreutils `timeout`; perl's alarm does the job — but not as
# `alarm; exec`: that kills the one process it exec'd and nothing else, and
# the real gather is a venv python holding stdio MCP servers (npx …) as
# children, which lived on past the alarm, orphaned, one set per tick. So:
# fork, put the child in a process group of its own (setpgrp — the same
# pattern the app uses in ConnectionsModel.run), and on the alarm signal
# the whole group, TERM then KILL. Exit 142 (128 + SIGALRM) is what the
# old form produced and what pull_one keys on; a child killed by any
# other signal exits 128 + it (141 for SIGPIPE). `exec { $ARGV[0] }`,
# never `exec @ARGV`: with one element perl would split it as a shell
# command, and Moe's home has a space in its path. Perl exiting normally
# (rather than dying of SIGALRM itself) is also what silences the
# "Alarm clock: 14" bash printed to stderr for every cut-off source.
run_limited() {
  /usr/bin/perl -e '
    my $limit = shift @ARGV;
    my $pid = fork;
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec: $!\n"; }
    my $group = sub { kill $_[0], -$pid };
    local $SIG{ALRM} = sub { $group->("TERM"); select(undef, undef, undef, 0.5); $group->("KILL"); exit 142 };
    local $SIG{TERM} = local $SIG{INT} = sub { $group->("TERM"); exit 143 };
    alarm $limit;
    waitpid($pid, 0);
    alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
  ' "$TIMEOUT" "$@"
}

declare -a OK=() QUIET=() SKIP=() OFF=() SLOW=() GATHERED=() NOYES=()

# ── Profiles ─────────────────────────────────────────────────────────────
# learn/profile.py resolves, per source, whether it is kept up to date at
# all — "sync", in Settings › Background. Every ten minutes is a lot of
# reading for a schema that changes monthly, and any reading is too much
# for a docs search that holds nothing of the person's; the profile is
# where that is decided, and this file only asks. A payload from before
# profiles has no usable profile.py: then nothing is gated, exactly as
# before, and the log says so once — an old profile.py fails the same way
# for every source, and one line beats a stack trace per source per tick.
PROFILE_PY="$MOE/learn/profile.py"
profiles=1
profiles_off() { # <why>
  [ "$profiles" = 1 ] || return 0
  profiles=0
  log "profiles: $PROFILE_PY $1 — nothing gated this tick (natives pulled as before, no Hermes connection read, no context file removed)"
}
# Decided ONCE, before the loop, with one probe — never per source, mid-loop:
# profiles are off only when profile.py is missing or answers the probe the
# way the claims-store profile.py of 0.3.7 did, a usage line and exit 2.
# Anything else that goes wrong later — one source's `get` tracing back —
# is that source's problem (see the callers) and never flips the whole tick
# into the ungated past, where a native the person switched off is pulled
# again and every Hermes context file is removed.
profile_probe() { # <source>
  [ -f "$PROFILE_PY" ] || { profiles_off "is missing"; return; }
  local err rc
  err="$(mktemp)"
  MOE_HOME="$MOE" CONN="$CONN" python3 "$PROFILE_PY" get "$1" >/dev/null 2>"$err"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q "usage:" "$err"; then
    profiles_off "answered 'get $1' with a usage line (exit 2)"
  elif [ "$rc" -ne 0 ]; then
    cat "$err" >> "$LOG"
    log "profiles: $PROFILE_PY get $1 exited $rc — not a usage error, so profiles stay on; a source it cannot answer for is pulled as before and nothing is removed"
  fi
  rm -f "$err"
}
# "on" | "off", or nothing (rc 1) when profiles cannot answer for this one
# source. The callers decide what nothing means: for a native it is on
# (what sync always did), for a Hermes connection it is off — and in both
# cases nothing on disk is removed, because a missing answer is not "no".
#
# Its stderr goes nowhere: the probe above already logged the one traceback
# worth having. Appending it here instead put ten lines per source into
# sync.log every ten minutes — a megabyte a day of the same stack, in the
# file someone opens to find out what went wrong.
profile_sync() { # <source>
  [ "$profiles" = 1 ] || return 1
  local out
  out="$(MOE_HOME="$MOE" CONN="$CONN" python3 "$PROFILE_PY" get "$1" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict) or "sync" not in d:
    sys.exit(1)
print("on" if d.get("sync") is True else "off")' 2>/dev/null)" || out=""
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# A source the person switched off. Its old context file goes too: the
# brief would otherwise keep answering "what's on" from the day it was
# switched off, dated as if fresh — worse than saying nothing. Off is not
# "not connected", so it joins neither SKIP nor status.json; the brief gets
# its own line so Moe does not imply it looked.
sync_off() { # <context name> <source>
  local out="$CTX/$1.md"
  if [ -f "$out" ]; then
    rm -f "$out"
    log "off: $2 — sync (profile); removed stale context/$1.md"
  else
    log "off: $2 — sync (profile)"
  fi
  OFF+=("$1")
}

# Three outcomes, and keeping them apart matters: a source with nothing to
# report is not a broken source. "No events today" must never show up in the
# same list as "Gmail isn't connected", or the brief teaches Moe to
# apologise for things that are working fine.
#
# The verb and an optional key: natives answer `pull`; a Hermes connection
# is read with `crawl <kind>/<name> --since 1` through its provider, which
# wants the key on `status` too. ${key:+"$key"} is the bash 3.2-safe way to
# pass an argument that may be nothing at all under set -u.
# A native that said "needs-setup:" (Telegram never signed in, Gmail with no
# mailbox) is not asked again every tick to say it again: its verdict is
# kept in state/sync-parked/<name> and reused for half an hour, or until
# something a sign-in writes has changed — connectors/ (telegram.session,
# gmail-accounts.json) or the consent answers. On the owner's Mac those two
# were re-asked, and re-logged, on every one of ~140 ticks a day.
PARKED="$MOE/state/sync-parked"
PARK_MINUTES="${MOE_SYNC_PARK_MINUTES:-30}"
CONSENT_FILE="$MOE/memory/profile/consent.json"
parked_verdict() { # <context name> → the verdict, while it still stands
  local f="$PARKED/$1"
  [ -f "$f" ] || return 1
  if [ -z "$(find "$f" -mmin -"$PARK_MINUTES" 2>/dev/null)" ] || [ "$CONN" -nt "$f" ] \
     || { [ -f "$CONSENT_FILE" ] && [ "$CONSENT_FILE" -nt "$f" ]; }; then
    rm -f "$f"
    return 1
  fi
  head -1 "$f"
}

pull_one() { # <context name> <script> <verb> [<key>] [<args…>]
  local name="$1" script="$2" verb="$3" key="${4:-}"
  shift 3; [ $# -gt 0 ] && shift
  [ -x "$script" ] || { SKIP+=("$name — not installed"); return; }

  local out="$CTX/$name.md" tmp status
  tmp="$(mktemp)"
  run_limited "$script" "$verb" ${key:+"$key"} "$@" > "$tmp" 2>>"$LOG"
  local rc=$?

  # "skipped: <why>" with exit 0 means the source chose not to read this
  # tick (Notes.app not open). Keep whatever it gave us last time rather
  # than publishing the excuse as data or deleting good context.
  if [ "$rc" -eq 0 ] && [ "$(head -c 8 "$tmp")" = "skipped:" ]; then
    status="$(head -1 "$tmp")"
    rm -f "$tmp"
    if [ -s "$out" ]; then
      OK+=("$name")
      log "kept $name — ${status#skipped: }"
    else
      SKIP+=("$name — ${status#skipped: }")
      log "skipped $name: ${status#skipped: }"
    fi
    return
  fi

  # rc matters: the 45s alarm kills sqlite3 and gmail.py mid-stream, and both
  # emit incrementally. Accepting any non-empty output would publish a silently
  # truncated file over good data and log it as a clean pull.
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" "$out"
    rm -f "$PARKED/$name"
    OK+=("$name")
    log "pulled $name ($(wc -l < "$out" | tr -d ' ') lines)"
    return
  fi

  rm -f "$tmp"
  # Cut off by the alarm. That is not a verdict on the source — its status
  # would say "ok" a second later and file it under "Not connected" as
  # "hermes-notion — ok: fake" — so no status call, the last file stays for
  # the brief, and the brief says it was slow. status.json is not touched:
  # this tick learned nothing about whether it is connected.
  if [ "$rc" -eq 142 ]; then
    SLOW+=("$name")
    if [ -s "$out" ]; then
      log "took too long $name (>${TIMEOUT}s) — kept the last context/$name.md"
    else
      log "took too long $name (>${TIMEOUT}s) — nothing kept yet"
    fi
    return
  fi
  status="$(run_limited "$script" status ${key:+"$key"} 2>/dev/null | head -1)"
  # Exit 3 means "I am configured but could not reach the service" — a Gmail
  # outage must not read as "checked it, nothing there".
  if [ "$rc" -eq 3 ]; then
    rm -f "$out"
    SKIP+=("$name — ${status:-could not be reached just now}")
    log "unreachable $name"
  elif [ "$rc" -eq 0 ] && [[ "$status" == ok:* ]]; then
    : > "$out"                     # connected, simply nothing to say
    rm -f "$PARKED/$name"
    QUIET+=("$name")
    log "$name connected, nothing new"
  else
    rm -f "$out"
    # A read that failed on a source whose status is fine (a gather whose
    # server said no) is "could not be read", not "ok: connected" pasted
    # under Not connected.
    case "$status" in ok:*) status="could not be read (exit $rc)" ;; esac
    SKIP+=("$name — ${status:-unavailable (exit $rc)}")
    log "unavailable $name: ${status:-exit $rc}"
    case "$status" in
      needs-setup:*)
        mkdir -p "$PARKED" && printf '%s\n' "$status" > "$PARKED/$name"
        log "not asking $name again until its connection changes (or ${PARK_MINUTES} min)" ;;
    esac
  fi
}

# ── Hermes connections with a gather recipe ─────────────────────────────
# A Hermes connection — an MCP server of its own, or one of the services
# Composio brokers — is live and is never pulled, except one the
# person has written a gather recipe for (~/.moe/gather/<name>.json: the
# same declared, read-only reads the learn pass makes), whose profile says
# sync (off unless they switch it on: every MCP row ships sync=false), and
# whose reading they have said yes to. The consent is the bare connection
# name, the one the learn crawl checks: both are reads of the same recipe,
# so one yes covers both. Then today's slice of it is kept under
# context/hermes-<name>.md with the same accounting as any native, and the
# brief gets a section for it, so "what's on" there is instant too.
#
# "Today's slice" is `--since 1`, and what that reads is the recipe's to
# say: a read with a "{since_days}"/"{since_date}" placeholder in its args
# gets today; one without is the same read whatever the number (a metric
# catalog has no "since"). Either way each read is a fresh Hermes process
# — venv, connect, every read in the recipe — and for a remote OAuth server
# a fresh process is a fresh copy of the token racing the gateway's. So at
# most once an HOUR, not every ten-minute tick: context/.gather-<name>
# is touched after every attempt and the next tick keeps the last file
# until it is an hour old.
gather_one() { # <hermes:mcp:name> | <hermes:composio:slug>
  local name="$1" bare="${1##*:}" ctx label state stamp age
  ctx="$(connector_field "$name" context_file)"; ctx="${ctx:-hermes-$bare}"
  # Without profiles nothing from Hermes is read, and nothing is removed
  # either: a file left by a tick that had profiles is not stale, it is
  # the last thing known, and the fallback must not delete it.
  [ "$profiles" = 1 ] || return
  # No answer for this one source is "off" — nothing from Hermes was read
  # on this tick before profiles existed, and a guess must not start it —
  # but not "switched off": the file stays, the log says what happened.
  if ! state="$(profile_sync "$name")"; then
    log "skipped $bare — profile.py could not answer for it (see above); left context/$ctx.md alone"
    return
  fi
  if [ "$state" != on ]; then
    [ -f "$CTX/$ctx.md" ] && rm -f "$CTX/$ctx.md" && log "off: $bare — sync (profile); removed stale context/$ctx.md"
    return
  fi
  # Consent withdrawn is not "stop reading it from now on", it is "you
  # should not have what you read". The cached copy goes with the answer,
  # the way switching sync off takes it — otherwise Moe keeps answering
  # from a file the person has just revoked.
  if ! "$MOE/learn/consent.sh" check "$bare" 2>>"$LOG"; then
    if [ -f "$CTX/$ctx.md" ]; then
      rm -f "$CTX/$ctx.md" "$CTX/.gather-$bare"
      log "skipped $bare — no consent to read it; removed context/$ctx.md"
    else
      log "skipped $bare — no consent to read it"
    fi
    return
  fi
  label="$(connector_field "$name" label)"; label="${label:-$bare}"
  stamp="$CTX/.gather-$bare"
  if [ -f "$stamp" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$stamp" 2>/dev/null || echo 0) ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$GATHER_EVERY" ]; then
      # Read within the hour: it counts as looked at either way. With
      # something in it that is OK, with nothing it is quiet — not absent,
      # which is what it was before, so status.json went stale for the five
      # ticks in between and Settings never mentioned it again.
      if [ -s "$CTX/$ctx.md" ]; then OK+=("$ctx"); else QUIET+=("$ctx"); fi
      log "kept $ctx — read ${age}s ago, next in $((GATHER_EVERY - age))s"
      GATHERED+=("$ctx	$label")
      return
    fi
  fi
  touch "$stamp"
  pull_one "$ctx" "$(connector_script "$name")" crawl "$(_hermes_key "$name")" --since 1
  # Remember it for the brief whether it had something to say or not; an
  # empty file makes section() a no-op, the same as any other quiet source.
  GATHERED+=("$ctx	$label")
}

log "sync starting"

# The output name comes from the manifest, not the connector name: imessage
# writes context/messages.md and reminders writes context/tasks.md, and the
# brief below (and everything that reads it) is built around those names.
# Only connectors with a `pull` verb. The Hermes provider's virtual
# connectors (hermes:mcp:linear, hermes:platform:telegram, …) have none on
# purpose: Hermes's tools are live — Moe calls Notion when you ask about
# Notion — and a cached copy in context/ would only be stale and large.
# doctor.sh still shows their real status. The one exception is gather_one
# below, and it takes three yeses.
all_names="$(connectors_list)"
# The one probe that decides whether profiles gate this tick (see
# profile_probe): the first native, the source every payload has.
probe=""
for name in $all_names; do
  case "$name" in hermes:*) continue ;; esac
  probe="$name"; break
done
profile_probe "${probe:-calendar}"
for name in $all_names; do
  case "$name" in
    hermes:mcp:*|hermes:composio:*)
      connector_has_verb "$name" crawl; rc=$?
      if [ "$rc" -eq 0 ]; then
        gather_one "$name"
      elif [ "$rc" -eq 2 ]; then
        # Too slow to say what it is (lib/connectors.sh) is not "nothing to
        # gather": until 2026-10-07 the two were one silent skip.
        SLOW+=("${name##*:}")
        log "too slow: ${name##*:} — Moe could not tell what it is in time; left its last copy"
      fi
      continue ;;
    hermes:*)     continue ;;
  esac
  connector_has_verb "$name" pull || continue
  ctx="$(connector_field "$name" context_file)"; ctx="${ctx:-$name}"
  # No answer for this one native is "on": what sync always did, and the
  # only answer that removes nothing.
  if ! state="$(profile_sync "$name")"; then
    [ "$profiles" = 1 ] && log "profile.py could not answer for $name (see above) — pulled as before"
    state=on
  fi
  if [ "$state" = off ]; then
    sync_off "$ctx" "$name"
    continue
  fi
  # One switch per source, "Learn and watch" (owner, 2026-09-29): a Mac
  # source the person has not said yes to is not kept ready either — Moe
  # reaches it only when asked. A copy kept before the answer goes with it.
  if ! "$MOE/learn/consent.sh" check "$name" 2>>"$LOG"; then
    if [ -f "$CTX/$ctx.md" ]; then
      rm -f "$CTX/$ctx.md"
      log "skipped $name — no yes to learn from and watch it; removed context/$ctx.md"
    else
      log "skipped $name — no yes to learn from and watch it"
    fi
    # Said no (Settings, or Not now twice…) is "switched off"; never
    # answered is "waiting for a yes": the brief must not tell Moe the
    # person switched off something they were never asked about.
    if [ "$("$MOE/learn/consent.sh" state "$name" 2>/dev/null)" = refused ]; then
      OFF+=("$ctx")
    else
      NOYES+=("$ctx")
    fi
    continue
  fi
  if parked="$(parked_verdict "$ctx")"; then
    SKIP+=("$ctx — $parked")
    continue
  fi
  pull_one "$ctx" "$(connector_script "$name")" pull
done

# ── The brief Moe reads first ────────────────────────────────────────────
BRIEF="$CTX/_brief.md"
# What is connected, beside the brief and refreshed with it. The model cannot
# read a file to find out — the claude-code child runs with Read disallowed —
# so this is written here and injected into the prompt. Best-effort: a brief
# that cannot say what is connected is still worth writing. `refresh` writes
# the prose (`_connections.md`, this Mac's prompt) AND the facts as JSON
# (`_connections.json`), which travels to the person's cloud computer as the
# `context/connections` document — the one thing that tells a machine with no
# Mac that Cloudflare lives behind COMPOSIO_SEARCH_TOOLS (2026-09-20).
MOE_HOME="$MOE" "$CONN/hermes-connections.py" refresh >/dev/null 2>&1 || true
# The person's own background jobs, with how each is doing (lib/jobs_brief.py).
MOE_HOME="$MOE" /usr/bin/python3 "$MOE/lib/jobs_brief.py" > "$CTX/jobs.md.tmp" 2>/dev/null && mv "$CTX/jobs.md.tmp" "$CTX/jobs.md" \
  || rm -f "$CTX/jobs.md.tmp"
BRIEF_TMP="$(mktemp "$CTX/.brief.XXXXXX")"
# One instant for the whole brief: the stamp at the top and every "ended 3 h
# ago" / "in 20 min" in the calendar are relative to it (ticket #9). MOE_NOW
# (ISO 8601) pins it for tests; the turn that carries the brief says how old
# it is, and the Now line on every turn is the model's clock.
if [ -n "${MOE_NOW:-}" ] && BRIEF_AT="$(/bin/date -j -f '%Y-%m-%dT%H:%M:%S%z' "$(printf '%s' "$MOE_NOW" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/Z$/+0000/')" +%s 2>/dev/null)"; then :; else
  BRIEF_AT="$(date +%s)"
fi
BRIEF_NOW="$(date -r "$BRIEF_AT" +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})$/:\1/')"
{
  echo "# Right now"
  echo
  echo "_Refreshed $(date -r "$BRIEF_AT" '+%A %-d %B, %-I:%M %p')._"
  echo

  section() { # heading, file
    [ -s "$CTX/$2.md" ] || return 0
    echo "## $1"; echo; cat "$CTX/$2.md"; echo
  }

  # ${#arr[@]} is safe on an empty array in bash 3.2 (what macOS ships);
  # "${arr[*]}" is NOT — it aborts with "unbound variable" under set -u and
  # would truncate this whole file mid-write. Guard on the count first.
  if [ -s "$CTX/calendar.md" ]; then
    # Split by the clock when the app can do it: "Earlier today (over)",
    # "Now", "Coming up", each line with its end and a label. At 18:08 on
    # 2026-09-23 the unsplit list read a 2 PM call as still ahead (ticket #9).
    # Any failure — an older app without --brief, no EventKit access — falls
    # back to the pulled lines, which is what this always printed.
    cal_script="$(connector_script calendar 2>/dev/null)"
    if [ -n "$cal_script" ] \
       && cal_split="$(MOE_NOW="$BRIEF_NOW" "$cal_script" brief 2>/dev/null)" \
       && [ -n "$cal_split" ]; then
      echo "## Calendar (next few days)"; echo
      echo "_As of $(date -r "$BRIEF_AT" '+%-I:%M %p') — the Now line on each message is the clock._"; echo
      printf '%s\n' "$cal_split"; echo
    else
      section "Calendar (next few days)" calendar
    fi
  elif [ ${#QUIET[@]} -gt 0 ] && [[ " ${QUIET[*]} " == *" calendar "* ]]; then
    echo "## Calendar (next few days)"; echo; echo "Nothing scheduled."; echo
  fi

  section "Tasks" tasks
  # Every job the person has set up, as THIS Mac runs it, with its real
  # health — in the brief because the brief is what both brains read, and
  # the cloud computer's own job list holds only what travels there. On
  # 2026-09-30 the cloud Moe saw 2 of 20 and called a job that had failed
  # five times in a row "healthy" (its own copy never ran).
  section "Background jobs" jobs

  local_inbound=0
  for f in messages whatsapp telegram gmail; do
    [ -s "$CTX/$f.md" ] && local_inbound=1
  done
  if [ "$local_inbound" = 1 ]; then
    echo "## Inbound (recent)"; echo
    for f in messages whatsapp telegram gmail; do
      if [ -s "$CTX/$f.md" ]; then
        echo "### $f"; echo; cat "$CTX/$f.md"; echo
      fi
    done
  fi

  section "Calls" calls
  section "Recorded calls (transcripts)" callrecs
  section "Recent notes" notes
  # Both of these sync into context/ and, until this was here, were read by
  # nothing: a connector that writes a file no section names is dead weight.
  section "Drive (recently changed)" drive
  section "Browsing (recent)" chrome
  # The Hermes connections gather_one kept up to date, one section each,
  # headed the way Connections names them. Same guard: the array may be empty.
  if [ ${#GATHERED[@]} -gt 0 ]; then
    for entry in "${GATHERED[@]}"; do
      section "${entry#*	} (today)" "${entry%%	*}"
    done
  fi

  if [ ${#QUIET[@]} -gt 0 ]; then
    echo "_Connected and quiet: ${QUIET[*]}._"
    echo
  fi

  # Cut off by the alarm this tick. Not "not connected" — its status would
  # say ok — and not fresh either: what is shown above for it, if anything,
  # is the last copy that came through.
  if [ ${#SLOW[@]} -gt 0 ]; then
    echo "_Took too long to read this time (showing the last copy, where there is one): ${SLOW[*]}._"
    echo
  fi

  # Switched off in Settings › Background: not looked at, on purpose. Named
  # so Moe neither answers from memory of it nor calls it unavailable.
  if [ ${#NOYES[@]} -gt 0 ]; then
    echo "_Not kept up to date (no yes to learn from and watch it yet): ${NOYES[*]}._"
  fi
  if [ ${#OFF[@]} -gt 0 ]; then
    echo "_Not kept up to date (switched off): ${OFF[*]}._"
    echo
  fi

  # Which of their channels reach them right now, and the one tool that does
  # (connectors/reach-brief.py says why). Before "Not connected", so the
  # personal-account Telegram reader being unset up can never be read as
  # "cannot reach them on Telegram" — the 2026-09-25 incident, where that
  # line was all the brain knew and a job it wrote messaged a contact.
  if [ -x "$CONN/reach-brief.py" ]; then
    MOE_HOME="$MOE" "$CONN/reach-brief.py" section 2>/dev/null || true
  fi

  if [ ${#SKIP[@]} -gt 0 ]; then
    # A LOCAL connector being unset up does not mean the service is
    # unreachable. Gmail was signed in through the broker and this section
    # still read "gmail — needs-setup: no mailbox added yet — run
    # connect-gmail.sh", so the model repeated that back to someone whose
    # mail was working: a specific instruction beats a general list, every
    # time. Say which ROUTE is missing, and name the one that is not.
    BROKERED="$("$CONN/composio.py" list --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)["connections"]
except Exception:
    sys.exit(0)
print(" ".join(r["slug"] for r in rows if r.get("connected")))
' 2>/dev/null)"
    echo "## Not connected"
    echo
    echo "These are genuinely unavailable — do not imply you checked them."
    echo
    for line in "${SKIP[@]}"; do
      name="${line%% *}"
      # A chat app first: named connected via Memoe when the cloud carries it,
      # and the personal-account reader labelled optional either way.
      relabelled=""
      [ -x "$CONN/reach-brief.py" ] \
        && relabelled="$(MOE_HOME="$MOE" "$CONN/reach-brief.py" line "$line" 2>/dev/null)"
      if [ -n "$relabelled" ]; then
        printf '%s\n' "$relabelled"
        continue
      fi
      matched=""
      for slug in $BROKERED; do
        # gmail matches gmail; drive matches googledrive; calendar matches
        # googlecalendar. Substring either way, because the two naming
        # schemes are ours and Composio's and neither is going to change.
        case "$slug" in *"$name"*) matched="$slug" ;; esac
        case "$name" in *"$slug"*) matched="$slug" ;; esac
      done
      if [ -n "$matched" ]; then
        # The correction goes FIRST. Trailing it after the original sentence
        # left "run connect-gmail.sh" as the first thing read, and that is
        # the sentence the model repeated to someone whose mail worked.
        echo "- ${name}: CONNECTED through the composio tools — use those."
        echo "  (Only the on-this-Mac copy is unset up: ${line#* })"
      else
        echo "- ${line}"
      fi
    done
    echo
  fi
} > "$BRIEF_TMP"

# Scrub obvious secrets before anything reads this.
#
# The brief is attached to essentially every request Moe makes, and personal
# notes are full of PINs, door codes and one-time passcodes. Masking them here
# costs nothing and means they aren't sitting in a file that gets read on every
# single turn. It is a coarse filter, not a guarantee.
if ! python3 - "$BRIEF_TMP" <<'PY' 2>>"$LOG"
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)

KEYWORD = (r"(?i)\b(?:pass\s?words?|passcode|pass\s?phrase|pin|otp|one[- ]time code|"
           r"security code|screen ?time|verification code|cvv|ssn|routing|account\s?number)\b")

# A meeting join URL carries its passcode in the query string — Zoom writes
# ?pwd=, Teams ?p=, Meet ?pli=/authuser. The keyword scrubber above never sees
# it, because "pwd" is not a word it knows and the value is glued to an "=".
# The brief is re-sent on every turn, so a link pasted there keeps the passcode
# in the prompt indefinitely. Strip the query off any URL in the brief: the
# link still works for a human clicking it in most cases, and where it does
# not, the agent has the full URL from the calendar tool at the moment it
# needs it rather than from a document that lives forever.
URL_SECRET = re.compile(r"(?i)\b(https?://[^\s|]+?)\?(?:[^\s|]*\b(?:pwd|passcode|password|token|key|secret)=)[^\s|]*")

# Skip label words ("password", "is", ":") and mask the first token that
# actually looks like a secret — one containing a digit. Masking the label
# instead of the value is the easy mistake here, and it protects nothing.
SECRET = re.compile(
    KEYWORD + r"(?P<sep>[^\n]{0,24}?)(?P<val>\b(?=[A-Za-z0-9\-]*\d)[A-Za-z0-9\-]{3,}\b)")

def mask(m):
    whole = m.group(0)
    start = m.start("val") - m.start(0)
    return whole[:start] + "•" * len(m.group("val"))

text = SECRET.sub(mask, text)
# A meeting passcode rides in the query string, where the keyword scrubber
# above cannot see it. Keep the link, drop the query.
text = URL_SECRET.sub(lambda m: m.group(1) + "?••••", text)
# Bare card-length digit runs.
text = re.sub(r"\b(?:\d[ -]?){13,16}\b", "•••• redacted ••••", text)
open(path, "w", encoding="utf-8").write(text)
PY

then
  # Fail closed. The brief is attached to every request Moe makes; publishing
  # it unredacted because a python invocation broke is the wrong direction to
  # fail in.
  log "REDACTION FAILED — brief not published"
  rm -f "$BRIEF_TMP"
  exit 1
fi

mv "$BRIEF_TMP" "$BRIEF"
chmod 600 "$BRIEF" 2>/dev/null || true

log "sync done — data: ${OK[*]:-none}; quiet: ${QUIET[*]:-none}; unavailable: ${#SKIP[@]}; too slow: ${SLOW[*]:-none}"

# What this tick learned about every source — pulled, quiet, or unavailable
# — is exactly the "is it connected" answer Settings and the Connections
# pane otherwise probe live, at a cost of seconds per source every time a
# page opens. Written to $MOE/status.json (merged, never replaced: the
# consent list writes the same file for Hermes connections) so those pages
# can show the last known answer at once and re-check behind it.
# A cut-off source (SLOW) is in none of these lists: this tick did not
# learn whether it is connected, and the last answer stands.
gathered_names=""
if [ ${#GATHERED[@]} -gt 0 ]; then
  for entry in "${GATHERED[@]}"; do gathered_names="$gathered_names ${entry%%	*}"; done
fi
python3 - "$MOE/status.json" "${OK[*]:-}" "${QUIET[*]:-}" "${SKIP[*]:-}" "$gathered_names" <<'PY' 2>>"$LOG" || true
import json, os, sys, time
path, ok, quiet, skip, gathered = sys.argv[1:6]
try:
    cache = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    cache = {}
if not isinstance(cache, dict):
    cache = {}
now = time.time()
for name in ok.split() + quiet.split():
    # A Hermes connection is filed under its bare name — the key the consent
    # list writes for it — not under the hermes-<name> its context file has.
    if name.startswith("hermes-"):
        name = name[len("hermes-"):]
    cache[name] = {"connected": True, "at": now, "by": "sync"}
# SKIP entries are "name — reason", space-separated as one string; the name
# is the first word of each and reasons never start a new entry with a bare
# connector name, so take every word that is a known connector.
known = {n[:-9] for n in os.listdir(os.path.dirname(path) + "/connectors") if n.endswith(".manifest")} if os.path.isdir(os.path.dirname(path) + "/connectors") else set()
# …and every Hermes connection gather_one read this tick, by its context
# name; a failed gather is filed connected=false under the bare name, the
# same key its success is filed under.
known |= set(gathered.split())
for word in skip.split():
    if word in known and word not in ok.split() and word not in quiet.split():
        if word.startswith("hermes-"):
            word = word[len("hermes-"):]
        cache[word] = {"connected": False, "at": now, "by": "sync"}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cache, f, indent=1, sort_keys=True)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

# ── Anything worth interrupting for ────────────────────────────────────────
# Here rather than in a launchd job of its own, for four reasons:
#
#   * nudge.sh reads context/*.md, which the loop above has just rewritten —
#     running it on a separate clock would judge yesterday's files;
#   * this is the 10-minute tick, so the rules are checked exactly as often as
#     the data they read changes, and there is one background schedule for a
#     person to understand and switch off rather than two;
#   * we still hold the sync lock, so two overlapping ticks cannot both decide
#     to write nudge.json;
#   * `Moe --sync` execs this file as a child of the app binary, which is what
#     gives nudge.sh's own `Moe --calendar` read the EventKit grant.
#
# A nudge is deterministic, costs nothing, and belongs on every tick; the
# pass that spends model usage is Hermes's moe-proactive job, on its own
# clock, and reads the brief this tick just wrote.
# Its exit status is deliberately ignored — a broken rule must not fail a sync
# that has already published a good brief. The off switch is inside nudge.sh
# itself (config.json's `nudges`), so it holds however the script is reached.
if [ -x "$MOE/nudge.sh" ]; then
  out="$("$MOE/nudge.sh" 2>>"$LOG")" || true
  [ -n "$out" ] && log "$out"
fi

# The nudge test above is the last thing here; without this a tick with
# nothing to say would exit 1 and launchd would log a failure for it.
exit 0

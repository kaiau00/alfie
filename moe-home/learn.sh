#!/bin/bash
# The learn-me crawl: consent → crawl → distil → merge, one source at a time,
# then hand the fresh digests to Hermes so the agent can seed its own memory.
#
#   learn.sh <source|all> [--stage seed|update|recent|deep] [--dry-run] [--no-ask]
#
#   seed     read back once over the source's whole window — its profile's
#            seed_days: a year for most things, 90 for browsing — and
#            stamp it seeded. What the app runs after you say yes.
#   update   catch up: only the sources whose profile says they are due,
#            reading just what is new since the last stamp (or the whole
#            recipe again, for a source that cannot be asked "since when").
#            The daily background job (hermes-jobs/moe-learn-deep.sh) runs it.
#   recent   the last 90 days, no stamp — the terminal interview, and the
#            default: seconds to crawl, a few minutes to distil
#   deep     the old name for update, kept so an installed job keeps working
#   --dry-run   crawl and print the estimate, then stop; nothing is distilled
#   --no-ask    never prompt for consent; a source without it is skipped
#               (what the background job passes — it cannot consent for you)
#
# Every source is independent. One that is not connected, has no consent, or
# whose crawl fails is reported and skipped; the others carry on. The raw
# crawl text is the most sensitive thing this writes, so it lives under
# context/crawl/ mode 600 only for as long as distil needs it and is
# deleted afterwards; what persists is the digest (facts with provenance)
# and the profile files in memory/profile/.
#
# Logs to ~/.moe/logs/learn.log, like sync.sh and the rest.
set -uo pipefail

MOE="${MOE_HOME:-$HOME/.moe}"
CONN="${CONN:-$MOE/connectors}"
LEARN="$MOE/learn"
PROFILE="${MOE_PROFILE_DIR:-$MOE/memory/profile}"
CRAWL="$MOE/context/crawl"
FEED_READ="$MOE/learn/feed-read.json"   # how far the message pass has read each service
DIGESTS="$PROFILE/digests"
LOG="$MOE/logs/learn.log"
# Ten minutes per crawl, then it is cut off (rc 142: what came through is
# used, nothing is stamped). MOE_CRAWL_TIMEOUT so a test can make it seconds.
CRAWL_TIMEOUT="${MOE_CRAWL_TIMEOUT:-600}"
RECENT_DAYS=90
# The window when no profile can say better: what "deep" always read.
DEEP_DAYS=365

mkdir -p "$CRAWL" "$DIGESTS" "$MOE/logs"
# The files inside are 0600 already; closing the directories too keeps
# even the list of sources and stages out of another account's sight.
chmod 700 "$CRAWL" "$PROFILE" "$DIGESTS" 2>/dev/null || true

. "$MOE/lib/connectors.sh" || {
  echo "missing $MOE/lib/connectors.sh — re-run scripts/install.sh" >&2; exit 1; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
say() { echo "$*"; log "$*"; }
# macOS has no coreutils `timeout`; perl's alarm does the job — the same
# wrapper as sync.sh's, and for the same reason: `alarm; exec` killed only
# the process it exec'd, and a gather crawl is a venv python holding stdio
# MCP servers as children, which outlived the alarm. The child goes in a
# process group of its own (setpgrp) and the alarm signals the group, TERM
# then KILL, exiting 142 — the code the old form produced. A child killed
# by another signal exits 128 + it (141: SIGPIPE from the byte cap). Ctrl-C
# and a kill of this file reach the group too, so a crawl never outlives
# the pass that started it. `exec { $ARGV[0] }`, never `exec @ARGV`: one
# element would be split as a shell line, and Moe's home has a space in it.
run_limited() { # <seconds> <cmd…>
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
  ' "$@"
}

usage() { echo "usage: learn.sh <source|all> [--stage seed|update|recent|deep] [--dry-run] [--no-ask]" >&2; exit 2; }

target="${1:-}"; [ -n "$target" ] || usage
shift
stage=recent; dry_run=0; no_ask=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   stage="${2:-}"; shift ;;
    --dry-run) dry_run=1 ;;
    --no-ask)  no_ask=1 ;;
    *) usage ;;
  esac
  shift
done
# `deep` is what the installed daily job still says; it means update now.
# `recent` keeps its own name (and digest file): a 90-day read with no
# stamp is not a seed, and must not make the app think one has happened.
case "$stage" in recent|seed|update) ;; deep) stage=update ;; *) usage ;; esac

# ── Profiles ──────────────────────────────────────────────────────────────
# learn/profile.py answers, per source, whether there is anything to learn
# from it at all, how far back the one-time seed looks, how often to catch
# up afterwards and when that last happened (the stamp). This file asks; it
# decides nothing about cadence itself. A payload from before profiles
# existed has no usable profile.py, and then every stage behaves exactly as
# before there were profiles — nothing gated, a DEEP_DAYS window, no stamps
# — and the log says so once rather than a source per line.
PROFILE_PY="$LEARN/profile.py"
profiles=1
profile_py() {
  MOE_HOME="$MOE" CONN="$CONN" MOE_PROFILE_DIR="$PROFILE" python3 "$PROFILE_PY" "$@"
}
# Whether this run has profiles is decided ONCE, before the loop, by one
# probe (profile_probe): off only when profile.py is missing or answers
# `get` the way the claims-store profile.py of 0.3.7 did — a usage line
# and exit 2 — and then the whole run is the old behaviour, consistently.
# It is never decided per source, mid-loop: a run that read three sources
# gated and stamped and the next four ungated, unstamped and a year
# deep is not a fallback, it is a mess. One source `get` or `due` cannot
# answer for while profiles are on (a traceback, say) is skipped, not
# read blind — a docs search must not be crawled because a loader bug
# stopped the profile that says never to.
profiles_off() { # <why>
  [ "$profiles" = 1 ] || return 0
  profiles=0
  log "profiles: $PROFILE_PY $1 — running without profiles: no gating, ${DEEP_DAYS}-day window, no stamps"
}
profile_probe() { # <source>
  [ -f "$PROFILE_PY" ] || { profiles_off "is missing"; return; }
  local err rc
  err="$(mktemp)"
  profile_py get "$1" >/dev/null 2>"$err"; rc=$?
  # 127 is the shell saying it could not run python3 at all — the cron job
  # has a sanitised PATH, and a Command Line Tools shim that no longer
  # resolves is exactly how that happens. Nothing downstream can work
  # (distil is python too), and the failure has to be loud: without this
  # every source was "skipped: its profile could not be read", learn.sh
  # exited 0, and Hermes recorded a clean run every night for ever.
  if [ "$rc" -eq 127 ] || grep -qi "command not found\|no such file or directory" "$err"; then
    say "· cannot run python3 ($PROFILE_PY exited $rc) — nothing can be read until that is fixed"
    cat "$err" >> "$LOG"
    rm -f "$err"
    exit 1
  fi
  if [ "$rc" -eq 2 ] && grep -q "usage:" "$err"; then
    profiles_off "answered 'get $1' with a usage line (exit 2)"
  elif [ "$rc" -ne 0 ]; then
    cat "$err" >> "$LOG"
    log "profiles: $PROFILE_PY get $1 exited $rc — not a usage error, so profiles stay on; a source it cannot answer for is skipped"
  fi
  rm -f "$err"
}
# "<seed> <seed_days> <update>" for one source; rc 1 and nothing when there
# is no usable answer. The JSON is read by python rather than grep: the
# fields are typed, and a hand-edited override that says "yes" instead of
# true must read as false, not as a match.
profile_fields() { # <source>
  [ "$profiles" = 1 ] || return 1
  local out
  out="$(profile_py get "$1" 2>>"$LOG" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict) or "seed" not in d:
    sys.exit(1)
print("%s %d %s" % ("true" if d.get("seed") is True else "false",
                    int(d.get("seed_days") or 365), d.get("update") or "daily"))' 2>/dev/null)" || out=""
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
# "seed" | "update <days>" | "no"; rc 1 and nothing otherwise.
profile_due() { # <source>
  [ "$profiles" = 1 ] || return 1
  local out
  out="$(profile_py due "$1" 2>>"$LOG" | head -1)" || out=""
  case "$out" in
    seed|no) ;;
    "update "*) case "${out#update }" in ''|*[!0-9]*) out="" ;; esac ;;
    *) out="" ;;
  esac
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
# One cadence's worth of days, for a source that is being caught up without
# ever having been read back (`seed: no`). The +1 is the same overlap
# `profile.py due` uses: a day read twice costs a little, a day missed is
# gone. Anything unrecognised falls to a day.
profile_update_days() { # daily|weekly|monthly
  case "${1:-daily}" in
    weekly)  echo 8 ;;
    monthly) echo 31 ;;
    never)   echo 2 ;;
    *)       echo 2 ;;
  esac
}
# Record a pass that got as far as merging, dated the day its crawl
# STARTED (`--today`): a seed that begins at 23:50 and merges after midnight
# read up to the earlier day, and a stamp saying tomorrow would make the
# next update skip the hours in between. A stamp that fails to write is
# logged, not fatal: the merge stands, and the worst case is one extra read
# next time.
profile_stamp() { # <source> <seed|update> <YYYY-MM-DD>
  [ "$profiles" = 1 ] || return 0
  profile_py stamp "$1" "$2" --today "$3" >/dev/null 2>>"$LOG" || log "$1: could not stamp $2 (see above)"
}

# One learn at a time: the deep job and a hand-run recent pass would
# otherwise both rewrite the same profile files.
exec 9>"$MOE/.learn.lock"
if ! /usr/bin/perl -e 'use Fcntl ":flock"; open(F, "<&=9") or exit 1; flock(F, LOCK_EX|LOCK_NB) or exit 1' 9<&9; then
  echo "another learn pass is already running" >&2
  exit 0
fi

# Which sources. `all` means every connector that opted into deep_crawl and
# knows the crawl verb — a source fine to poll every ten minutes is not
# necessarily one anyone wants a year of read.
sources=""
if [ "$target" = all ]; then
  for name in $(connectors_list); do
    deep="$(connector_field "$name" deep_crawl)"; rc=$?
    if [ "$rc" -eq 2 ]; then
      # Too slow to say what it is (lib/connectors.sh) is not "not a source".
      log "skipped $name — Alfie could not tell what it is in time; it is read next time"
      echo "learn.sh: skipped $name — too slow to say what it is" >&2
      continue
    fi
    [ "$deep" = yes ] || continue
    connector_has_verb "$name" crawl || continue
    sources="$sources $name"
  done
else
  case "$target" in *[!A-Za-z0-9_:-]*) usage ;; esac
  # One source, three spellings: a native connector; a Hermes connection in
  # this file's own hermes:<kind>:<name> form; or the bare name consent uses
  # for one ("notion"), which is what the app has in hand when it runs
  # `learn.sh <source> --stage seed` after the person says yes.
  if [ -f "$(connector_manifest "$target")" ]; then
    :
  elif [ "${target#hermes:}" != "$target" ] && [ -n "$(connector_field "$target" name)" ]; then
    :
  elif [ "${target#*:}" = "$target" ] && [ -n "$(connector_field "hermes:mcp:$target" name)" ]; then
    target="hermes:mcp:$target"
  # …and the same bare name for a service Composio brokers ("github"). The
  # app hands over exactly what consent recorded, which is the bare name for
  # every kind, so without this line a yes to GitHub reached no crawl at all.
  # MCP first: a dedicated server for a service is the more specific
  # connection, and that is the order consent_list.py resolves in too.
  elif [ "${target#*:}" = "$target" ] && [ -n "$(connector_field "hermes:composio:$target" name)" ]; then
    target="hermes:composio:$target"
  else
    echo "learn.sh: '$target' is not a connector" >&2; exit 2
  fi
  connector_has_verb "$target" crawl || { echo "learn.sh: $target has no crawl verb" >&2; exit 2; }
  sources="$target"
fi
[ -n "$sources" ] || {
  [ "$dry_run" = 0 ] && [ -f "$LEARN/last_pass.py" ] \
    && MOE_HOME="$MOE" python3 "$LEARN/last_pass.py" record ran "read nothing — no source on this Mac can be read back." 2>>"$LOG"
  echo "no sources with deep_crawl=yes and a crawl verb"; exit 0; }

# The probe, on the first source this run will visit (any well-formed name
# answers: the loader falls back to built-ins for one it does not know).
for name in $sources; do profile_probe "$name"; break; done

log "learn starting: stage=$stage profiles=$profiles dry_run=$dry_run sources:$sources"

# The raw crawl text must not outlive this run. rm on the normal paths
# below, and this trap for Ctrl-C, a kill, or an error in between.
current_raw=""
trap '[ -n "$current_raw" ] && rm -f "$current_raw"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

done_list=""; skipped=""; fresh_digests=""
# What a connected service's messages SAY, as its own pass (status #8; the
# owner, 2026-09-29: "everything in the inbox, and make it cheap"). A
# service's crawl is its structure only; its messages come from what the
# five-minute engine already fetched (lib/feed_crawl.py) — no second read of
# the service, automated mail dropped, one block per conversation, capped —
# and only what this pass has not read before (a read position per source,
# moved only once the pass has merged). Distilled with the PERSONAL prompt,
# which never takes another person's words as a fact about the owner — not
# the structure prompt, which forbids message content and files everything
# as identity (review 2026-09-29). Only for a service the engine watches (a
# read plan with a tool), the same test its consent sentence uses.
learn_messages() { # <name> <bare> <safe>
  local name="$1" bare="$2" safe="$3" fc plan rawf digestf rc summary
  fc="$MOE/lib/feed_crawl.py"
  plan="$MOE/gather/composio-$bare.items.json"
  [ -f "$fc" ] && [ -f "$plan" ] || return 0
  python3 -c 'import json,sys; sys.exit(0 if (json.load(open(sys.argv[1])) or {}).get("tool") else 1)' "$plan" 2>/dev/null || return 0
  rawf="$CRAWL/$safe.messages.txt"
  : > "$rawf"; chmod 600 "$rawf"
  current_raw="$rawf"
  run_limited "$CRAWL_TIMEOUT" python3 "$fc" "composio/$bare" --new "$FEED_READ" \
    --max-bytes "${MOE_FEED_CRAWL_MAX_BYTES:-200000}" > "$rawf" 2>>"$LOG"
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$rawf" ]; then
    rm -f "$rawf"; current_raw=""
    [ "$rc" -ne 0 ] && log "$name: reading its messages from the engine's feed failed (exit $rc)"
    return 0
  fi
  log "$name: $(wc -c < "$rawf" | tr -d ' ') bytes of what its messages say, new since the last pass, from the engine's feed"
  if [ "$dry_run" = 1 ]; then
    say "  its messages: $(python3 "$LEARN/distil.py" "$bare-messages" "$rawf" --estimate 2>>"$LOG")"
    rm -f "$rawf"; current_raw=""; return 0
  fi
  digestf="$DIGESTS/$safe.messages.json"
  # Its own source tag: merge.py treats one source's claims on one key as an
  # update, and a claim from the messages must corroborate the structure's
  # (or native Gmail's), not replace it.
  if ! python3 "$LEARN/distil.py" "$bare-messages" "$rawf" --out "$digestf" --window-days 30 2>>"$LOG"; then
    rm -f "$rawf"; current_raw=""
    say "· $name — its messages: distil failed; read again next time (see $LOG)"
    skipped="$skipped $name(messages: distil failed)"
    return 0
  fi
  rm -f "$rawf"; current_raw=""
  if ! summary="$(python3 "$LEARN/merge.py" "$digestf" 2>>"$LOG")"; then
    say "· $name — its messages: merge failed; read again next time (see $LOG)"
    skipped="$skipped $name(messages: merge failed)"
    return 0
  fi
  python3 "$fc" "composio/$bare" --commit "$FEED_READ" 2>>"$LOG"
  fresh_digests="$fresh_digests $digestf"
  done_list="$done_list $name(messages)"
  say "· $name — its messages: $(python3 -c '
import json, sys
s = json.loads(sys.argv[1])
print("%d new, %d refreshed, %d replaced" % (s["added"], s["refreshed"], s["replaced"]))' "$summary")"
}

learn_one() {
  local name="$1" script status raw digest est bare safe hkey today pflag
  local fields p_seed p_days p_update due days stamp_seed=0 stamp_update=0
  # A hermes:<kind>:<name> source (an MCP connection, gathered by auto-read —
  # or by the person's own ~/.moe/gather recipe when there is one) is driven
  # through the connections provider, which needs the key on status/crawl;
  # its consent is the bare connection name, its raw/digest files can't carry
  # the colons the name has, and its crawl is distilled with the general
  # "gather" prompt (a connected service, not mail/chat/notes).
  case "$name" in
    hermes:*) hkey="$(_hermes_key "$name")"; bare="${name##*:}"; safe="${name//:/_}"; pflag="--profile gather" ;;
    *)        hkey=""; bare="$name"; safe="$name"; pflag="" ;;
  esac
  script="$(connector_script "$name")"
  [ -x "$script" ] || { skipped="$skipped $name(not installed)"; return; }

  # The profile, before anything live is asked or anyone is prompted: a
  # docs search that holds nothing of the person's is not worth a status
  # call, let alone a consent question. Then the window for this stage.
  if [ "$profiles" != 1 ]; then
    fields=""; p_seed=true; p_days=$DEEP_DAYS; p_update=daily
  elif fields="$(profile_fields "$name")"; then
    set -- $fields; p_seed="$1"; p_days="$2"; p_update="$3"
    if [ "$p_seed" = false ] && [ "$p_update" = never ]; then
      say "· $name — nothing to learn from here (profile)"
      skipped="$skipped $name(profile)"
      return
    fi
  else
    say "· $name — skipped: its profile could not be read (see $LOG)"
    skipped="$skipped $name(profile unreadable)"
    return
  fi
  case "$stage" in
    recent) days=$RECENT_DAYS ;;
    # "Read this one back" — the stage the app runs the moment someone says
    # yes to a source. `seed: no` is the person's answer to exactly that
    # question ("keep up with it, but don't go back through it"), so it
    # wins over the caller: the source is caught up instead, and nothing is
    # stamped as seeded, or the switch would have been a label.
    seed)
      if [ "$p_seed" = false ]; then
        if [ -n "$fields" ] && ! due="$(profile_due "$name")"; then
          say "· $name — skipped: its profile could not say whether it is due (see $LOG)"
          skipped="$skipped $name(profile unreadable)"
          return
        fi
        case "${due:-}" in
          "update "*) days="${due#update }" ;;
          *)          days=$(profile_update_days "$p_update") ;;
        esac
        stamp_update=1
        say "· $name — reading it back once is off for this one; catching up instead"
      else
        days=$p_days; stamp_seed=1; stamp_update=1
      fi ;;
    update)
      if [ -n "$fields" ] && ! due="$(profile_due "$name")"; then
        say "· $name — skipped: its profile could not say whether it is due (see $LOG)"
        skipped="$skipped $name(profile unreadable)"
        return
      fi
      if [ -n "$fields" ]; then
        case "$due" in
          # Consented but never seeded — a yes given at the terminal, whose
          # recent pass stamps nothing. The whole window, here: unattended
          # is where a year-long read belongs, and it is exactly what the
          # daily job read for every consented source before profiles.
          seed)       days=$p_days; stamp_seed=1; stamp_update=1 ;;
          "update "*) days="${due#update }"; stamp_update=1 ;;
          no) say "· $name — up to date (profile: $p_update)"
              skipped="$skipped $name(not due)"
              # Its messages are not on the structure's clock: only what is
              # new is read, so they go every day — with the yes.
              case "$name" in hermes:composio:*)
                "$LEARN/consent.sh" check "$bare" && learn_messages "$name" "$bare" "$safe" ;;
              esac
              return ;;
        esac
      else
        days=$DEEP_DAYS
      fi ;;
  esac

  if [ -n "$hkey" ]; then
    status="$(run_limited 12 "$script" status "$hkey" 2>/dev/null | head -1)"
  else
    status="$(run_limited 12 "$script" status 2>/dev/null | head -1)"
  fi
  case "$status" in ok:*) ;; *) say "· $name — skipped: ${status:-not connected}"; skipped="$skipped $name(not connected)"; return ;; esac

  # The gate. Nothing is read without a recorded yes.
  if ! "$LEARN/consent.sh" check "$bare"; then
    if [ "$no_ask" = 1 ] || ! "$LEARN/consent.sh" ask "$bare"; then
      say "· $name — skipped: no consent"
      skipped="$skipped $name(no consent)"
      return
    fi
  fi
  # Its messages, as their own pass — after the gate: the feed can outlive
  # a revoke by a tick, and nothing is learned without the yes (review
  # 2026-09-29 round 2).
  case "$name" in hermes:composio:*) learn_messages "$name" "$bare" "$safe" ;; esac

  raw="$CRAWL/$safe.$stage.txt"
  current_raw="$raw"
  # The day this read is of — fixed now, before a crawl that can run for
  # ten minutes and a distil that can run for more, and what the stamp says.
  today="${MOE_TODAY:-$(date +%Y-%m-%d)}"
  say "· $name — reading the last $days days…"
  : > "$raw"; chmod 600 "$raw"
  if [ -n "$hkey" ]; then
    run_limited "$CRAWL_TIMEOUT" "$script" crawl "$hkey" --since "$days" > "$raw" 2>>"$LOG"
  else
    run_limited "$CRAWL_TIMEOUT" "$script" crawl --since "$days" > "$raw" 2>>"$LOG"
  fi
  local rc=$?
  # What the connector produced is what gets distilled, whatever its exit
  # code: every crawl verb ends in `head -c $MAX_BYTES`, and under pipefail
  # a source bigger than the cap makes sqlite3/osascript die of SIGPIPE (rc
  # 141) — the truncation working as designed. A crawl the alarm cut short
  # (142) is partial in the same honest way. Only an empty result is
  # "nothing".
  #
  # The STAMP is another matter. 142 is transient — the service was slow,
  # the network was down, ten minutes was not enough today — and a stamp
  # would tell the next update that the whole window was read when a
  # retry could well finish it; so no stamp at all, and the log says why.
  # 141 is not transient: the cap is a fixed number of bytes off the same
  # deterministic read, so a retry produces the same bytes and learns
  # nothing more, tomorrow or in a year. Not stamping a seed cut by the
  # cap would not make it more complete; it would make `due` say "seed"
  # every day, and the daily job re-crawl a year and re-distil the
  # same bytes — full model cost — forever, for exactly the sources big
  # enough to hit the cap (mail, messages). So 141 is stamped like 0, for
  # both stages, and the cut is in the log.
  if [ ! -s "$raw" ]; then
    rm -f "$raw"; current_raw=""
    # Nothing came back. Exit 0 is a quiet source; anything else is a
    # source that could not be read (every read failed, a crash) and must
    # not be filed as "nothing to read" — not stamped either way.
    if [ "$rc" -eq 0 ]; then
      say "· $name — nothing to read"
      skipped="$skipped $name(empty)"
    else
      say "· $name — could not be read (exit $rc); see $LOG"
      skipped="$skipped $name(failed)"
    fi
    return
  fi
  if [ "$rc" -eq 142 ]; then
    log "$name: crawl took longer than ${CRAWL_TIMEOUT}s and was cut off — using the $(wc -c < "$raw" | tr -d ' ') bytes it produced; NOT stamped, so it is read again next time"
    say "· $name — took too long; using what came through, will read it again next time"
    stamp_seed=0; stamp_update=0
  elif [ "$rc" -ne 0 ]; then
    log "$name: crawl exited $rc, using the $(wc -c < "$raw" | tr -d ' ') bytes it produced"
  fi

  est="$(python3 "$LEARN/distil.py" "$bare" "$raw" --estimate 2>>"$LOG")"
  say "  $(python3 -c '
import json, sys
e = json.loads(sys.argv[1])
m = max(1, (e["seconds"] + 59) // 60)
print("%d KB, %d chunk(s), %d model call(s), roughly %d minute(s)" % (e["bytes"] // 1024, e["chunks"], e["calls"], m))' "$est")"
  if [ "$dry_run" = 1 ]; then
    rm -f "$raw"; current_raw=""
    return
  fi

  digest="$DIGESTS/$safe.$stage.json"
  if ! python3 "$LEARN/distil.py" "$bare" "$raw" --out "$digest" --window-days "$days" $pflag 2>>"$LOG"; then
    rm -f "$raw"; current_raw=""
    say "· $name — distil failed (is Hermes running? see $LOG)"
    skipped="$skipped $name(distil failed)"
    return
  fi
  rm -f "$raw"; current_raw=""

  local summary
  summary="$(python3 "$LEARN/merge.py" "$digest" 2>>"$LOG")" || {
    say "· $name — merge failed (see $LOG)"; skipped="$skipped $name(merge failed)"; return; }
  say "· $name — $(python3 -c '
import json, sys
s = json.loads(sys.argv[1])
print("%d new, %d refreshed, %d replaced, %d question(s)" % (s["added"], s["refreshed"], s["replaced"], s["questions"]))' "$summary")"
  done_list="$done_list $name"
  fresh_digests="$fresh_digests $digest"
  # Stamped only now: a pass that crawled but could not distil or merge has
  # learned nothing, and must be read again next time, not marked done.
  [ "$stamp_seed" = 1 ] && profile_stamp "$name" seed "$today"
  [ "$stamp_update" = 1 ] && profile_stamp "$name" update "$today"
  return 0
}

for name in $sources; do
  learn_one "$name"
done

# The nightly consolidation (learn/consolidate.py): one line per topic,
# events that are over archived, each file held to its cap, sensitive lines
# removed, and summary.md + check.md rewritten. It runs on every pass that
# is not a dry run — also when nothing new was read, because an event goes
# stale whether or not anything was due today. A failure is logged, never
# fatal: the merged profile stands and tomorrow's pass tries again.
if [ "$dry_run" = 0 ] && [ -f "$LEARN/consolidate.py" ]; then
  if cout="$(MOE_PROFILE_DIR="$PROFILE" python3 "$LEARN/consolidate.py" 2>>"$LOG")"; then
    log "consolidate: $cout"
    [ -n "$done_list" ] && say "· tidied what Alfie knows: $(python3 -c '
import json, sys
s = json.loads(sys.argv[1])
print("%d merged, %d past events archived, %d over the limit, %d sensitive removed" % (s["merged"], s["past"], s["capped"], s["sensitive"]))' "$cout" 2>/dev/null || echo done)"
  else
    say "· could not tidy the profile (see $LOG) — what was learned is kept"
  fi
fi

# Hand what was learned to Hermes and let the agent decide what to keep — but
# only if seeding the engine's own memory is separately consented. The
# per-source consent above is permission to READ a source; this is the
# distinct permission to WRITE durable facts into the always-in-prompt core
# memory, which the user grants once and can revoke. Without it the crawl
# still fills the reviewable archive; it just never touches Hermes's memory —
# so the unattended daily pass cannot seed core memory on its own until the
# user has said yes. seed-memory.py itself is selective, scrubs the facts,
# only offers what is new (a ledger), and skips when memory is near full.
# A failure here is not fatal — the archive stands and the next run retries.
# Skipped entirely on a dry run. Run via python3, so gate on -f not +x.
if [ "$dry_run" = 0 ] && [ -n "$fresh_digests" ] && [ -f "$LEARN/seed-memory.py" ]; then
  if "$LEARN/consent.sh" check memory-seeding; then
    seed_args=()
    for d in $fresh_digests; do seed_args+=(--digest "$d"); done
    say "· handing what was learned to Hermes to remember…"
    if out="$(python3 "$LEARN/seed-memory.py" "${seed_args[@]}" 2>>"$LOG")"; then
      say "  ${out:-(seed-memory said nothing)}"
    else
      say "· could not seed Hermes memory (see $LOG) — the archive is updated; Hermes was not seeded this run"
    fi
  else
    say "· not seeding Hermes memory — not consented (grant: ~/.moe/learn/consent.sh grant memory-seeding)"
  fi
fi

log "learn done — merged:${done_list:- none}; skipped:${skipped:- none}"
# The record Settings › Background and the Memory page read (learn/last_pass.py):
# what this pass read and what it passed over, each with its reason. A dry
# run learned nothing and records nothing. The daily wrapper writes the same
# record for the days it never gets this far.
if [ "$dry_run" = 0 ] && [ -f "$LEARN/last_pass.py" ]; then
  if [ -n "$done_list" ]; then
    MOE_HOME="$MOE" python3 "$LEARN/last_pass.py" record ran "read $(echo $done_list | tr ' ' ',')." \
      --read "$done_list" --skipped "$skipped" 2>>"$LOG" || true
  else
    MOE_HOME="$MOE" python3 "$LEARN/last_pass.py" record ran "read nothing." \
      --skipped "$skipped" 2>>"$LOG" || true
  fi
fi
if [ "$dry_run" = 1 ]; then
  echo "Dry run: nothing was distilled or merged."
elif [ -n "$done_list" ]; then
  echo "Done. See what Alfie knows: ~/.moe/learn/profile.py list"
  [ -s "$PROFILE/questions.md" ] && echo "Some things Alfie could not tell — $PROFILE/questions.md"
fi
exit 0

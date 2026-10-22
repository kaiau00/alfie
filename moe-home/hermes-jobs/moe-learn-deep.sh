#!/bin/bash
# The daily catch-up of the learn-me crawl, as a Hermes no-agent cron job.
#
# `--stage update`: learn.sh asks each source's profile whether it is due —
# daily for mail, weekly for a wiki, monthly for a schema, never for a docs
# search — and reads only what is new since its last stamp. A source that
# was consented to but never seeded (a yes given at the terminal) gets its
# one full read here, unattended, which is where a year-long read belongs.
# The job keeps its old name, `moe-learn-deep`: renaming a registered cron
# job would leave the old one behind on every install that has it.
#
# Hermes runs this from $HERMES_HOME/scripts/ (cron only accepts scripts that
# live there), with a sanitised environment: no provider credentials, no
# API_SERVER_KEY. That is fine — learn.sh's distil step reads the key from
# ~/.hermes/.env itself, the way Memoe.app does, and everything stays local.
#
# No-agent semantics: empty stdout is a silent tick, any output is delivered
# as a message, non-zero exit is an error alert. So this prints only when
# something needs a person: a source that has no consent yet is not that
# (the app asks, in its own time), a failed pass is.
#
# --no-ask is the important flag. A background job cannot consent on the
# user's behalf; sources without a recorded yes are skipped, not prompted.
set -u
MOE="${MOE_HOME:-$HOME/.moe}"

# Every way out of this file that reads nothing is written down first —
# $MOE/logs/learn-last.json and a line in $MOE/logs/learn.log — by
# learn/last_pass.py, and learn.sh writes the same record when it does run.
# Measured 2026-09-14: after an erase this job ran three days running,
# Hermes recorded each as `ok · silent (empty output)`, and nothing on the
# Mac could say that the reason was a switch nobody had turned on. Settings
# › Background and the Memory page read this record; stdout stays empty,
# because stdout is a message to the person and "still off" is not news.
note() { # <outcome> <reason>
  [ -f "$MOE/learn/last_pass.py" ] && MOE_HOME="$MOE" python3 "$MOE/learn/last_pass.py" record "$1" "$2" 2>/dev/null
  return 0
}

# The gate on the whole pass, before anything else.
#
# `--no-ask` below means each source is checked for its own consent, so
# nothing unagreed is ever read. That is not the same question as "may Moe
# do this every day on its own, without saying so" — a person who connected
# their mail agreed to Moe reading mail when asked, not to a daily crawl
# nobody told them about. So this pass has its own recorded yes,
# `background-learning`, granted from the sheet the app shows and withdrawn
# from Settings › Background. Without it the job does nothing at all.
#
# Silent: a no-agent job delivers any output as a message, and "you have not
# switched this on" is not news, every day, forever. Exit 0 so it is a tick.
# And the switch for model spend, Settings › Background › "Background
# thinking" (docs/LOOPS.md §3). This pass's distil step runs on the person's
# MAIN brain, one call per 12 000-character chunk, invisible to Hermes's cron
# accounting — found 2026-09-10 to be the largest background bill Moe can
# run up. `backgroundThinking: false` in config.json is a silent tick.
if python3 - "$MOE" <<'PY'
import json, sys
try:
    with open(sys.argv[1] + "/config.json", encoding="utf-8") as f:
        cfg = json.load(f)
except (OSError, ValueError):
    cfg = {}
sys.exit(0 if (isinstance(cfg, dict) and cfg.get("backgroundThinking", True) is False) else 1)
PY
then
  note paused "didn't run — “Let Alfie think on its own” is off."
  exit 0
fi
if [ -x "$MOE/learn/consent.sh" ]; then
  if ! "$MOE/learn/consent.sh" check background-learning; then
    # `unset` and `refused` are different silences: one was never asked (the
    # app's sheet waits for a source to be allowed first), the other said no.
    case "$("$MOE/learn/consent.sh" state background-learning 2>/dev/null)" in
      refused) note off "didn't run — the daily pass is switched off." ;;
      *)       note not-asked "didn't run — the daily pass has never been switched on." ;;
    esac
    exit 0
  fi
else
  # No consent script means no way to check, and reading without checking is
  # the failure this gate exists to prevent.
  note no-gate "couldn't run — learn/consent.sh is missing."
  exit 0
fi

# The headroom gate (docs/LOOPS.md §3, docs/DEFAULTS.md row 23) — the same
# one the half-hourly pass keeps, lib/headroom.py, so the two never disagree
# about when a plan is nearly used up. The distil step above spends the MAIN
# brain on the person's own plan, and a daily pass must not eat a plan
# overnight: past half of the short window (Claude's five-hour, ChatGPT's
# session) or four fifths of the long one (seven-day, weekly) it waits for
# tomorrow's run. A stale, absent or unreadable gauge — and an API key, which
# has no windows — is "go". `check` exits 3 for "no headroom", so a gate
# that cannot run at all (no python, a crash: exit 1) never shuts the pass.
#
# Fail-open, but never silently (review 2026-09-15): a gate that crashed, or
# is missing, used to look exactly like a gate that said "go". Either is one
# line on stderr (Hermes keeps it against the run) and one in learn.log, next
# to the pass's other reasons. Not in learn-last.json: the pass that follows
# writes its own record there, and "ran" is the truth about this run.
gate_note() { # <what happened>
  echo "moe-learn-deep: $1" >&2
  mkdir -p "$MOE/logs" 2>/dev/null \
    && printf '[%s] moe-learn-deep: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$MOE/logs/learn.log" 2>/dev/null
  return 0
}
headroom="$MOE/lib/headroom.py"
[ -f "$headroom" ] || headroom="$(dirname "$0")/../lib/headroom.py"
if [ -f "$headroom" ]; then
  python3 "$headroom" check >/dev/null 2>&1
  gate=$?
  if [ "$gate" -eq 3 ]; then
    note paused "didn't run — your plan is nearly used up"
    exit 0
  elif [ "$gate" -ne 0 ]; then
    gate_note "headroom gate failed (exit $gate) — running anyway"
  fi
else
  gate_note "headroom gate missing (lib/headroom.py not found) — running anyway"
fi

# stdout is DELIVERED — this job is `deliver: moe`, so anything echoed here
# lands on the island with the amber pulse and is spoken on Play. A job name,
# a script name, an exit code and five lines of somebody else's stderr are
# none of them a message for a person, and they matched no filter: they do
# not begin "Cron '...'", so neither gate ever saw them. Diagnostics go to
# stderr, which Hermes records against the run and shows in
# Settings › Background as "needs a look" — the right place for them.
# Nothing that is not a sentence for the owner may be echoed in this file.
[ -x "$MOE/learn.sh" ] || { echo "moe-learn-deep: $MOE/learn.sh is missing" >&2; exit 1; }

out="$("$MOE/learn.sh" all --stage update --no-ask 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  note failed "ran and didn't finish — learn.sh exited $rc."
  echo "moe-learn-deep: learn.sh exited $rc" >&2
  echo "$out" | tail -5 >&2
  exit 1
fi
# learn.sh exits 0 on a partial crawl: a source that could not be distilled is
# reported in its own line and the run continues, which is right for the seven
# other sources. It is not right for the JOB. A no-agent cron job's exit code
# is the only signal Hermes has: on 0 it records last_status "ok", leaves
# failure_streak at 0, and mints no incident (cron/scheduler.py), so a broken
# crawl looked identical to a clean one. Measured: the 2026-08-31 16:52 run
# wrote "chrome — distil failed" into its output file while jobs.json said
# "last_status": "ok", "failure_streak": 0.
#
# Non-zero here is what turns that into a streak, an incident deduplicated by
# (job, error) so it is raised once rather than nightly, and a delivery. The
# stdout above is preserved either way — Hermes captures it for both outcomes.
case "$out" in
  *"distil failed"*|*"merge failed"*)
    note failed "ran and a source could not be distilled or merged."
    echo "$out" | grep -E "failed" >&2
    exit 1 ;;
esac
exit 0

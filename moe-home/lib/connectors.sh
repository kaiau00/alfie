#!/bin/bash
# Connector discovery. Sourced, not run.
#
# A connector is any executable in connectors/ that answers `status`, and it
# is *described* by a sidecar manifest beside it: gmail.py + gmail.manifest.
# The manifest is the thing that makes a connector exist as far as sync.sh
# and doctor.sh are concerned — no manifest, no connector. That is
# deliberate: a stray helper script in the directory must never get run with
# `pull` just because it happens to be executable.
#
# Manifest format is KEY=value, one per line, `#` comments allowed:
#
#   name          gmail                  must equal the file's basename
#   verbs         status pull            space-separated; every connector has status
#   cadence       10m                    how often the sync agent should pull it
#   deep_crawl    yes | no               is years of it worth reading? (the old
#                                        deep crawl's flag; kept for the manifest format)
#   auth          oauth | app-password | local | none
#   runs_in       mac | cloud | both     feeds the capability manifest (PRODUCT.md §5)
#   cost          cheap | expensive
#   context_file  gmail                  what sync.sh writes: context/<context_file>.md
#   label         Gmail                  optional; what doctor.sh prints
#
# Everything here has to work under macOS's bash 3.2 and `set -u`: no
# associative arrays, no ${arr[*]} on a possibly-empty array, no mapfile.
# Manifests are plain lines and we grep them; that is the whole parser.
#
#   connectors_list                  → one connector name per line, sorted
#   connector_field <name> <key>     → the value, or nothing (rc 1) if unset
#   connector_script <name>          → path to <name>.sh or <name>.py
#   connector_has_verb <name> <verb> → rc 0 if the manifest lists that verb,
#                                      2 if a provider was too slow to say
#   connector_status <name>          → runs the status verb (12 s alarm), one line
#
# Callers may set CONN before sourcing to point somewhere other than
# ~/.moe/connectors (validate.sh does, so it can check the repo copy).
#
# ── Providers: virtual connectors ────────────────────────────────────────
#
# Moe's connections are Hermes's connections (CONNECTORS.md). Nobody writes
# a manifest per Notion or Slack: a *provider* is a script that yields
# connectors at run time, and today there is one, connectors/
# hermes-connections.py, which lists every MCP server, credentialed skill
# and gateway platform configured under ~/.hermes. They appear here as
#
#   hermes:<kind>:<name>       e.g. hermes:mcp:linear, hermes:skill:notion,
#                              hermes:platform:telegram
#
# and the four functions above answer for them: connector_field asks the
# provider for a manifest-shaped answer, connector_script is the provider,
# connector_has_verb says `status` only. They are never pulled — Hermes's
# tools are live, not cached context (sync.sh checks the verb). validate.sh
# checks manifests only; a provider validates itself.
#
# Set MOE_NO_PROVIDERS=1 to list manifests alone (validate.sh does).

CONN="${CONN:-$HOME/.moe/connectors}"
PROVIDER_HERMES="$CONN/hermes-connections.py"

# hermes:<kind>:<name> → "<kind>/<name>", what the provider takes.
_hermes_key() { local n="${1#hermes:}"; printf '%s/%s\n' "${n%%:*}" "${n#*:}"; }

# How long the provider has to say what one connection is. Its answer comes
# from files (and Composio's last list), well under a second.
MOE_MANIFEST_SECONDS="${MOE_MANIFEST_SECONDS:-10}"

# _conn_limited <seconds> <command…>: run under a time limit, the way
# sync.sh's run_limited does — perl forks and waits, and on the deadline
# stops the command's whole process group and exits 142. It replaces
# `perl -e 'alarm N; exec @ARGV'`, where the ALARM killed the command itself
# and bash, seeing a child die of a signal, wrote "Alarm clock: 14" to
# stderr: 488 of the 533 lines in com.moe.jobs.err on 2026-10-07, every one
# of them a source sync.sh then skipped without a word of its own.
_conn_limited() {
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

# One name per line. The glob is sorted by the shell, so the order is stable
# and alphabetical — nothing downstream depends on order, and it means adding
# a connector never shuffles someone else's position in the logs.
connectors_list() {
  local m
  for m in "$CONN"/*.manifest; do
    [ -f "$m" ] || continue          # unmatched glob comes back literally
    m="${m##*/}"; m="${m%.manifest}"
    # Callers iterate this with `for name in $(connectors_list)`, which
    # word-splits — so a name with a space would come through as two
    # connectors that don't exist. Refuse anything outside [A-Za-z0-9_-].
    case "$m" in
      ''|*[!A-Za-z0-9_-]*)
        echo "connectors: ignoring '$m.manifest' — names may only use letters, digits, _ and -" >&2
        continue ;;
    esac
    printf '%s\n' "$m"
  done
  # Then the provider's connections. Files only, no live calls, so this is
  # as cheap as the glob above; a missing or broken provider yields nothing
  # rather than an error — the native connectors must never depend on it.
  [ -n "${MOE_NO_PROVIDERS:-}" ] && return 0
  [ -x "$PROVIDER_HERMES" ] || return 0
  # Under an alarm: doctor/sync must not hang on a Python that stalls (a
  # venv re-exec, a slow disk); with no ~/.hermes at all it answers at once.
  _conn_limited 10 "$PROVIDER_HERMES" names 2>/dev/null | while IFS= read -r m; do
    case "$m" in
      ''|*[!A-Za-z0-9_/-]*) continue ;;   # same alphabet, plus the one '/'
    esac
    printf 'hermes:%s:%s\n' "${m%%/*}" "${m#*/}"
  done
}

connector_manifest() { printf '%s\n' "$CONN/$1.manifest"; }

# Manifest text for a name: the file, or the provider's synthesised one.
# Returns 142 when the provider did not answer in time, and says so on
# stderr: "too slow to say" is not "has no such verb", and a caller that
# cannot tell the two apart skips a source and reports nothing.
_connector_manifest_text() {
  case "$1" in
    hermes:*)
      [ -x "$PROVIDER_HERMES" ] || return 1
      local text rc
      text="$(_conn_limited "$MOE_MANIFEST_SECONDS" "$PROVIDER_HERMES" manifest "$(_hermes_key "$1")" 2>/dev/null)"; rc=$?
      if [ "$rc" -eq 142 ]; then
        echo "connectors: $1 was too slow to say what it is (over ${MOE_MANIFEST_SECONDS}s) — not read this time" >&2
        return 142
      fi
      [ -n "$text" ] && printf '%s\n' "$text"
      return "$rc" ;;
    *) local f; f="$(connector_manifest "$1")"; [ -f "$f" ] && cat "$f" ;;
  esac
}

# Print one field. Last occurrence wins, whitespace around `=` and at the ends
# is ignored, and a missing key or manifest returns 1 with no output — so
# `"$(connector_field x cadence)"` is safely empty rather than an error.
# Returns 2 (also with no output) when the provider was too slow to answer.
connector_field() {
  local name="$1" key="$2" text line
  text="$(_connector_manifest_text "$name")"
  [ $? -eq 142 ] && return 2
  line="$(printf '%s\n' "$text" | grep "^[[:space:]]*$key[[:space:]]*=" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  line="${line#*=}"
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
  printf '%s\n' "$line"
}

# The executable for a connector: <name>.sh, else <name>.py. When neither
# exists we still print the .sh path and return 1, so a caller's `[ -x ]`
# check fails the same way it always has ("not installed") instead of
# tripping over an empty string.
connector_script() {
  local name="$1" s
  case "$name" in
    hermes:*) printf '%s\n' "$PROVIDER_HERMES"; [ -x "$PROVIDER_HERMES" ]; return ;;
  esac
  for s in "$CONN/$name.sh" "$CONN/$name.py"; do
    [ -f "$s" ] && { printf '%s\n' "$s"; return 0; }
  done
  printf '%s\n' "$CONN/$name.sh"
  return 1
}

# rc 0 yes, 1 no, 2 the provider was too slow to say — callers that skip
# on "no" must say something different on 2 (sync.sh, learn.sh).
connector_has_verb() {
  local verbs
  verbs="$(connector_field "$1" verbs)"
  [ $? -eq 2 ] && return 2
  case " $verbs " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# The status line for any connector, native or virtual, under the same 12 s
# alarm doctor.sh always used (a hung IMAP login must not hang the report).
# Prints exactly one line: "ok: …", "needs-setup: …" or "unavailable: …".
# Callers key off that prefix, not the exit code (head owns it). A virtual connector's status is a real
# check — `hermes mcp test`, the gateway's health endpoint — not a token on
# disk (see hermes-connections.py).
connector_status() {
  local name="$1" script
  script="$(connector_script "$name")"
  [ -x "$script" ] || { echo "unavailable: connector missing"; return 3; }
  case "$name" in
    hermes:*) _conn_limited 30 "$script" status "$(_hermes_key "$name")" 2>&1 | head -1 ;;
    *)        _conn_limited 12 "$script" status 2>&1 | head -1 ;;
  esac
}

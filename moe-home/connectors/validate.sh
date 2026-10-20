#!/bin/bash
# Checks every connector manifest in this directory — run it before shipping
# a new connector, and from CI. Exits non-zero if anything is wrong.
#
# What "wrong" means: a required field is missing or has a value outside the
# allowed set, the manifest's `name` disagrees with its filename, or the
# script it describes is missing or not executable. Format is documented at
# the top of lib/connectors.sh.
#
#   connectors/validate.sh              check the manifests beside this script
#   connectors/validate.sh <dir>        check another directory
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONN="${1:-$HERE}"
export CONN
# Manifests only. The Hermes provider's virtual connectors have no manifest
# file to check and answer for themselves (lib/connectors.sh).
export MOE_NO_PROVIDERS=1

# The library normally lives at ~/.moe/lib; when validating the repo copy it
# is one directory up from here. Try both, in that order.
for lib in "$HERE/../lib/connectors.sh" "$HOME/.moe/lib/connectors.sh"; do
  if [ -f "$lib" ]; then . "$lib"; break; fi
done
command -v connectors_list >/dev/null 2>&1 || {
  echo "validate.sh: cannot find lib/connectors.sh" >&2; exit 2; }

problems=0
fail() { echo "  ✗ $1: $2"; problems=$((problems + 1)); }

# One of a fixed set, or fail. The lists are the contract that sync.sh and the
# capability manifest rely on, so a typo here is a real bug, not a style nit.
one_of() { # name, key, allowed…
  local name="$1" key="$2" val; shift 2
  val="$(connector_field "$name" "$key")"
  local ok=0 a
  for a in "$@"; do [ "$val" = "$a" ] && ok=1; done
  [ "$ok" = 1 ] || fail "$name" "$key must be one of: $* (got '${val:-<unset>}')"
}

required() { # name, key
  local val
  val="$(connector_field "$1" "$2")"
  [ -n "$val" ] || fail "$1" "missing required field '$2'"
}

# One question to the plugin, once, rather than per connector.
PLUGIN_INIT="$HERE/../hermes-plugins/moe-connectors/__init__.py"
if [ -f "$PLUGIN_INIT" ] && command -v python3 >/dev/null 2>&1; then
  KNOWN_VERBS="$(python3 - "$PLUGIN_INIT" <<'PYVERBS' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(" ".join(sorted(set(m.VERB_HELP) | set(m.VERB_FLAGS) | set(m.TAKES_NOTHING)
                    | set(getattr(m, "ENGINE_VERBS", ())))))
PYVERBS
)"
fi
export KNOWN_VERBS

count=0
for name in $(connectors_list); do
  count=$((count + 1))

  # name must match the filename: everything else keys off the basename.
  [ "$(connector_field "$name" name)" = "$name" ] \
    || fail "$name" "name field must be '$name' (matching the filename)"

  for key in verbs cadence deep_crawl auth runs_in cost context_file; do
    required "$name" "$key"
  done

  # `status` is the one verb every connector must answer — it is how sync.sh
  # tells "nothing today" from "not connected", and what doctor.sh shows.
  connector_has_verb "$name" status || fail "$name" "verbs must include 'status'"

  one_of "$name" deep_crawl yes no
  one_of "$name" auth       oauth app-password local none
  one_of "$name" runs_in    mac cloud both
  one_of "$name" cost       cheap expensive

  # Digits then exactly one m or h: 10m, 1h. Not 1h30m, not 10, not m.
  cadence="$(connector_field "$name" cadence)"
  case "$cadence" in
    [0-9]*[mh]) case "${cadence%?}" in *[!0-9]*) fail "$name" "cadence should look like 10m or 1h (got '$cadence')" ;; esac ;;
    *) fail "$name" "cadence should look like 10m or 1h (got '$cadence')" ;;
  esac

  # context_file is a bare basename — it becomes context/<context_file>.md
  # and must not be able to escape that directory or word-split in a loop.
  # Letters, digits, underscore and hyphen only.
  ctxf="$(connector_field "$name" context_file)"
  case "$ctxf" in
    *[!A-Za-z0-9_-]*) fail "$name" "context_file may only contain [A-Za-z0-9_-] (got '$ctxf')" ;;
  esac

  # `<verb>_stdin` / `<verb>_args` declare what a verb takes — which keys, in
  # what shape — and the Hermes plugin builds the model's schema from them.
  # A typo is silent and expensive: `send_stdn=` leaves the send tool with no
  # fields at all, which is how `gmail_send` came to be called with `{}` and
  # the confirmation dialog came to show "(unknown recipient)" over an empty
  # message. So the verb must exist, and each field must parse.
  # A misspelled *key* declares nothing at all and looks like an ordinary
  # unknown field, so a verb's own prefix is what gives it away: anything
  # `send_…` on a connector with a `send` verb has to be one we understand.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    for verb in $(connector_field "$name" verbs); do
      case "$key" in
        "${verb}_stdin"|"${verb}_args") ;;
        "${verb}_"*) fail "$name" "'$key' is not a field this understands — did you mean ${verb}_stdin or ${verb}_args?" ;;
      esac
    done
  done <<EOF
$(grep -E '^[a-z_]+=' "$CONN/$name.manifest" 2>/dev/null)
EOF

  # `sends=` names the verbs that leave the machine — the confirm hook asks
  # before each of them. Every one must be a verb this connector has, or the
  # declaration gates nothing.
  for verb in $(connector_field "$name" sends); do
    connector_has_verb "$name" "$verb" \
      || fail "$name" "sends= names '$verb', which is not in verbs"
  done

  while IFS= read -r decl; do
    [ -n "$decl" ] || continue
    key="${decl%%=*}"
    verb="${key%_stdin}"; verb="${verb%_args}"
    connector_has_verb "$name" "$verb" \
      || fail "$name" "$key declares input for '$verb', which is not in verbs"
    for field in ${decl#*=}; do
      case "${field%\*}" in
        *[!A-Za-z0-9_]*) case "${field%\*}" in
            *"[]") case "${field%%[]*}" in *[!A-Za-z0-9_]*)
                     fail "$name" "$key: '$field' is not a field name" ;; esac ;;
            *) fail "$name" "$key: '$field' is not a field name" ;;
          esac ;;
      esac
    done
  done <<EOF
$(grep -E '^[a-z_]+_(stdin|args)=' "$CONN/$name.manifest" 2>/dev/null)
EOF

  # A verb the Hermes plugin has no words and no input shape for is published
  # to the model as "The connector's `reply` verb" with an empty argument
  # list — the exact shape that had gmail_send being called with `{}`. The
  # plugin knows `status pull crawl send find chats accounts voice` and
  # declares `crawl`'s flags itself; anything else has to say what it takes.
  # Asked of the plugin rather than copied from it. A hand-typed list here is
  # a third copy of one half of a two-file contract: add a verb to VERB_HELP
  # and this would reject it, delete one and this would wave it through.
  known_verbs="${KNOWN_VERBS:-}"
  # Empty means the plugin was not beside us to ask — a checkout of
  # connectors/ alone, which is how scripts/test-connections.sh runs. "I
  # cannot check" is not "nothing is valid": without this, every verb of
  # every connector was reported as undescribed.
  if [ -z "$known_verbs" ]; then
    known_verbs="__unavailable__"
  fi
  [ "$known_verbs" = "__unavailable__" ] || for verb in $(connector_field "$name" verbs); do
    case " $known_verbs " in
      *" $verb "*) continue ;;
    esac
    grep -qE "^${verb}_(stdin|args)=" "$CONN/$name.manifest" 2>/dev/null \
      || fail "$name" "verb '$verb' is not one the Hermes plugin describes — declare ${verb}_stdin= or ${verb}_args= saying what it takes"
  done

  script="$(connector_script "$name")" || fail "$name" "no $name.sh or $name.py beside the manifest"
  if [ -f "$script" ] && [ ! -x "$script" ]; then
    fail "$name" "$(basename "$script") is not executable (chmod +x it)"
  fi
done

if [ "$count" -eq 0 ]; then
  echo "no manifests found in $CONN" >&2
  exit 1
fi

# The manifests are one half of a contract; the Hermes plugin that turns them
# into tools is the other, and a manifest can be perfectly valid while the
# tool built from it is unusable — every connector tool was published to the
# model with no arguments at all, for months, and every manifest validated the
# whole time. That other half is checked by
# `moe-home/hermes-plugins/moe-connectors/tests/test_connectors_plugin.py`,
# and it is `scripts/test-plugins.sh` that runs it — not this script.
#
# This script used to run it too, as `python3 <the test file>`, and that was
# wrong for one reason that took a while to see. One of those tests,
# RealCatalogue::test_it_registers_the_catalogue_not_a_curated_list, reads the
# caller's live `~/.moe/connectors` on purpose and asserts more than ten tools
# come out of it. So validate.sh's verdict depended on $HOME — a thing a
# manifest validator has no business reading. From a terminal it passed; from
# scripts/test-drive-chrome.sh and scripts/test-drive-docs.sh, which point
# HOME at a scratch home holding two connectors, it failed every single time,
# for a reason with nothing to do with any manifest. Both suites were excused
# from scripts/test-all.sh over it.
#
# The invocation was also the reason a payload prune that dropped the plugin's
# tests broke validation an hour later (docs/BUNDLE.md), and it shipped to
# every user's ~/.moe/connectors, where a developer unittest suite has no
# audience. scripts/test-plugins.sh runs the same 49 tests with an interpreter
# it picks and the real home RealCatalogue needs, and it is in test-all.sh's
# OFFLINE list — so nothing is lost by this script keeping to manifests.

if [ "$problems" -gt 0 ]; then
  echo "$problems problem(s) across $count manifest(s) in $CONN"
  exit 1
fi
echo "✓ $count connector manifest(s) valid"

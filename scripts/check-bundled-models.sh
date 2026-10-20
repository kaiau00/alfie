#!/bin/bash
# Is the set of staged models the set the lists name — no more, no less?
#
# `Models/` is gitignored and per-checkout, so what ships is whatever is on
# disk rather than whatever the code says. `fetch-models.sh` sweeps models
# that have been de-listed, but nothing on the build path runs it:
# `catch-up.sh` only calls it when there is no `Models/` anywhere on the Mac,
# and `ship.sh` stages from wherever one already is. A stale directory is
# therefore reused indefinitely, and `build.sh` copies all of it.
#
# What that cost, measured on 2026-09-06: PocketTTS was removed from the
# lists on 2026-09-03 (e9a8a0c) and Supertonic the same day (fe96ca1, partly
# because its OpenRAIL-B use-based restrictions are a licence obligation on
# everyone who installs Moe). Three days later /Applications/Memoe.app — built
# from a commit that contained both removals — still carried 776 MB of one
# and 161 MB of the other, and was missing silero-vad and campplus, which
# the lists had since added. The bundle was 2.7 GB against a stated 1.9.
#
# build.sh's only models gate was `-lt 500 MB`, and it reported PASS every
# single time, correctly: 1.8 GB is not less than 500 MB. **A bound in one
# direction is a check that cannot fail in the other**, which is this repo's
# most expensive recurring mistake and the reason this asks both questions.
#
# It is a separate script rather than a block inside build.sh so that
# scripts/test-models.sh can run the real thing against scratch directories
# and watch it refuse — a guard tested by reading it is not tested.
#
#   check-bundled-models.sh <models-dir> [lists-file]
#
# Exit 0 when the set matches, 1 when it does not, 2 when the check itself
# could not run (which is also a failure: a guard that cannot run must never
# report a pass).
set -u

DIR=${1:-}
LISTS=${2:-"$(dirname "$0")/fetch-models.sh"}

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "✗ check-bundled-models: no such models directory: ${DIR:-<none>}" >&2
    exit 2
fi
if [ ! -f "$LISTS" ]; then
    echo "✗ check-bundled-models: cannot read the model lists at $LISTS" >&2
    exit 2
fi

# Read the lists out of fetch-models.sh rather than repeating them. A second
# copy is a second thing to update, and two halves drifting apart is the
# exact failure this exists to catch.
want=$(sed -n 's/^APP_SUPPORT_MODELS="\(.*\)"$/\1/p; s/^CACHE_MODELS="\(.*\)"$/\1/p' "$LISTS" \
       | tr ' ' '\n' | grep -v '^$' | sort -u)
if [ -z "$want" ]; then
    echo "✗ check-bundled-models: no model lists found in $LISTS" >&2
    echo "  APP_SUPPORT_MODELS / CACHE_MODELS may have been renamed. This check" >&2
    echo "  cannot run, so it fails rather than passing blind." >&2
    exit 2
fi

have=$(cd "$DIR" && ls -1 2>/dev/null | sort -u)

extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))

status=0

if [ -n "$extra" ]; then
    echo "✗ staged models the lists no longer name:" >&2
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        echo "    $m ($(du -sh "$DIR/$m" 2>/dev/null | cut -f1))" >&2
    done <<< "$extra"
    status=1
fi

if [ -n "$missing" ]; then
    echo "✗ models the lists name but nothing staged:" >&2
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        echo "    $m" >&2
    done <<< "$missing"
    status=1
fi

if [ "$status" != 0 ]; then
    echo "  $DIR is stale. Run ./scripts/fetch-models.sh in that checkout: it" >&2
    echo "  removes what the lists stopped naming and fetches what they added." >&2
    exit 1
fi

echo "  models: $(printf '%s\n' "$want" | wc -l | tr -d ' ') staged, none extra, none missing"
exit 0

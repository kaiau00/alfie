#!/bin/bash
# Runs the Swift unit tests. Use this instead of a bare `swift test`.
#
# This project builds with the Command Line Tools, not Xcode. The CLT ship
# Swift Testing (but not XCTest) under Library/Developer/, and SwiftPM does
# not add that directory to the search path on its own — a bare `swift test`
# fails with "no such module 'Testing'". Passing the paths on the command
# line rather than in Package.swift matters: SwiftPM's generated test runner
# is compiled outside any target, and only global flags reach it.
#
# The paths are derived from the active developer directory and only added
# when that is the CLT: with Xcode selected, `swift test` finds Testing on
# its own, and pointing it at the CLT copy could mix toolchain versions.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
FLAGS=()
if [[ "$DEV_DIR" == */CommandLineTools ]]; then
    CLT_DEV="$DEV_DIR/Library/Developer"
    if [[ -d "$CLT_DEV/Frameworks/Testing.framework" ]]; then
        FLAGS=(
            -Xswiftc -F"$CLT_DEV/Frameworks"
            -Xlinker -F"$CLT_DEV/Frameworks"
            -Xlinker -rpath -Xlinker "$CLT_DEV/Frameworks"
            -Xlinker -rpath -Xlinker "$CLT_DEV/usr/lib"
        )
    else
        echo "warning: $CLT_DEV/Frameworks/Testing.framework not found; a bare 'swift test' will likely fail" >&2
    fi
fi

# A scratch home for the whole run. Tests that drive the real Conductor
# (StallGuardConductorTests) write its log, history and conversation files,
# and those must never land in the Moe someone is using — `~/.moe` on this
# Mac is the owner's. `Config.homeDir` honours MOE_HOME in debug builds only,
# and reads it once per process, so it is set here, before the process
# starts, rather than by a test that may run after something else has
# already fixed the home. Those tests refuse to run on any other home.
if [[ -z "${MOE_HOME:-}" ]]; then
    MOE_HOME="$(mktemp -d -t moe-test-home)"
    export MOE_HOME
    MOE_TEST_HOME_MADE=1
fi

# MoeCloudTests needs a real PostgreSQL — row-level security is the thing
# under test and no other database has it (docs/ONE-AGENT.md §3.3, §15).
# scripts/pgtest.sh brings an ephemeral one up on a unix socket under .build,
# on no TCP port, touching nothing outside this checkout. Set MOE_SKIP_PG=1
# to run the rest of the suite without it — and understand that this turns
# the cross-tenant canary off, which is the one check the slice exists for.
# A tree without the closed targets (the public, local-only export) has no
# MoeCloudTests at all, so there is nothing for a database to serve.
if [[ ! -f cloud/targets.json ]]; then
    echo "note: no cloud/ in this tree — community build, no PostgreSQL suite." >&2
    MOE_SKIP_PG=1
    MOE_SKIP_PG_QUIET=1
fi
if [[ "${MOE_SKIP_PG_QUIET:-0}" == "1" ]]; then
    :
elif [[ "${MOE_SKIP_PG:-0}" == "1" ]]; then
    # Loud, because this removes every tenant-boundary test in the suite —
    # the cross-tenant canary included — and a green run that says nothing
    # about the boundary looks exactly like a green run that does.
    echo "warning: MOE_SKIP_PG=1 — the whole MoeCloud suite is off." >&2
    echo "warning: that is the cross-tenant canary, both slice-3 falsifiers," >&2
    echo "warning: the transport-security refusals and the BYPASSRLS mutation" >&2
    echo "warning: check. This run says nothing about the tenant boundary." >&2
else
    MOE_TEST_PG_SOCKET="$(scripts/pgtest.sh start)"
    export MOE_TEST_PG_SOCKET
    export MOE_TEST_PG_PORT="${MOE_TEST_PG_PORT:-55432}"
    trap 'scripts/pgtest.sh stop' EXIT
fi

# Run it through a tee so the trailing verdict below can count skips.
#
# **Why there is a trailing verdict at all.** swift-testing's own summary line
# counts a skipped test as a test: measured 2026-09-04, `--filter
# RowLevelSecurity` prints "Test run with 16 tests in 1 suite passed" whether
# all sixteen ran or all sixteen were skipped, and the whole-suite line reads
# "1529 tests in 162 suites passed" either way while 161 tests did not run.
# So the number every session in docs/CLOUD-PLAN.md has been quoting as
# evidence cannot tell "ran" from "stood down" — this repo's own rule that a
# check which cannot fail is worse than no check, arriving in the summary line
# that reports every other check.
#
# The warning above is printed BEFORE the run, and is then buried under a
# thousand lines of ✔. People read the last line. This is the last line.
set -o pipefail
RUN_LOG="$(mktemp -t moe-test-run)"
# NOT a second `trap … EXIT`: that would REPLACE the pgtest.sh stop above and
# leave a PostgreSQL running after every green run. Caught while writing it.
cleanup_run_log() {
    rm -f "$RUN_LOG"
    if [[ "${MOE_TEST_HOME_MADE:-0}" == "1" && "$MOE_HOME" == "${TMPDIR:-/tmp}"* ]]; then
        rm -rf "$MOE_HOME"
    fi
}
if [[ "${MOE_SKIP_PG:-0}" == "1" ]]; then
    trap cleanup_run_log EXIT
else
    trap 'scripts/pgtest.sh stop; cleanup_run_log' EXIT
fi
swift test "${FLAGS[@]}" "$@" 2>&1 | tee "$RUN_LOG"
STATUS=${PIPESTATUS[0]}
SKIPPED=$(grep -c '➜ Test .* skipped\.' "$RUN_LOG" || true)
if (( SKIPPED > 0 )); then
    echo "" >&2
    echo "NOT RUN: $SKIPPED test(s) were skipped in the run above." >&2
    if [[ "${MOE_SKIP_PG:-0}" == "1" ]]; then
        echo "         MOE_SKIP_PG=1 is why. The summary line counts them as" >&2
        echo "         passing tests; they did not run. Drop the variable and" >&2
        echo "         scripts/test.sh starts its own PostgreSQL — it needs no" >&2
        echo "         system install and touches nothing outside .build." >&2
    fi
fi
exit "$STATUS"

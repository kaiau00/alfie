#!/bin/bash
# Synthetic connector for the learn tests. `crawl` prints the fixture text
# beside it (invented people, no real data) and records the arguments it was
# given in $MOE_FIXTURE_ARGS so a test can check the window and the cap.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-status}" in
  status) echo "ok: fixture"; ;;
  pull)   echo "fixture | nothing" ;;
  crawl)
    shift
    [ -n "${MOE_FIXTURE_ARGS:-}" ] && echo "$*" > "$MOE_FIXTURE_ARGS"
    if [ "${MOE_FIXTURE_EMPTY:-}" = 1 ]; then exit "${MOE_FIXTURE_RC:-0}"; fi
    cat "$HERE/fixture-crawl.txt"
    # MOE_FIXTURE_HANG=1 mimics a crawl that has produced some text and then
    # waits on a child (an MCP server, an IMAP socket) that never answers:
    # the alarm's case. The child's pid goes to $MOE_FIXTURE_CHILD so a test
    # can check it died with the crawl.
    if [ "${MOE_FIXTURE_HANG:-}" = 1 ]; then
      sleep 300 &
      echo $! > "${MOE_FIXTURE_CHILD:-/dev/null}"
      wait
    fi
    # MOE_FIXTURE_RC=141 mimics a real connector whose output hit the byte
    # cap: `| head -c` closed the pipe and sqlite3/osascript died of SIGPIPE.
    exit "${MOE_FIXTURE_RC:-0}" ;;
  *) exit 2 ;;
esac

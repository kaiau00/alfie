#!/bin/bash
# Apple Mail — every account set up in Mail.app on this Mac, read from Mail's
# own index and message files. Read-only; needs Full Disk Access for
# Memoe.app. The work is mail-items.py (status, pull, items).
set -uo pipefail
# `send-offer`: the Memoe app's "Use draft" on an offer — the chat's own id
# and the words, as JSON on stdin. `exec`, so the check in offer_send.py sees
# the app as its parent; it shows the confirmation card before anything goes.
if [ "${1:-}" = "send-offer" ]; then
  exec /usr/bin/python3 "$(dirname "$0")/offer_send.py" mail
fi

exec /usr/bin/python3 "$(dirname "$0")/mail-items.py" "$@"

#!/bin/bash
# Puts the Telegram application pair where build.sh will find it.
#
# Telegram issues an api_id/api_hash per *application*, not per person
# (my.telegram.org/apps), so Moe is meant to carry its own — someone
# connecting their chats should never meet that page. It is gitignored for the
# same reason Resources/google-client.json is: a build input that identifies
# this application, not source.
#
# ── Why this script exists ──────────────────────────────────────────────────
#
# Until now the only way in was `MOE_TELEGRAM_API_ID` and
# `MOE_TELEGRAM_API_HASH` in the environment. Nobody's shell had them. So
# every release from 0.1.0 to 0.3.4 shipped with Telegram permanently dead,
# and nothing said so — the gate that would have refused only ran for a
# *signed* build, and no release has ever been signed. It was found the night
# 0.3.5 shipped, by a gate that had never fired before.
#
# The credentials were on the machine the whole time, in
# ~/.moe/connectors/telegram.json, written there by the connector. This copies
# them into the checkout so build.sh finds them without anyone remembering
# anything.
#
#   ./scripts/stage-telegram-client.sh          # from ~/.moe/connectors
#   ./scripts/stage-telegram-client.sh <path>   # from a specific json file
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Resources/telegram-client.json"
SRC="${1:-}"

if [ -z "$SRC" ]; then
  # The connector's own file first, then any sibling checkout that has already
  # been staged — the same search ship.sh does for google-client.json.
  for c in "$HOME/.moe/connectors/telegram.json" \
           "$HOME/Library/Application Support/Moe/connectors/telegram.json" \
           ../*/Resources/telegram-client.json \
           ../../../Resources/telegram-client.json; do
    [ -f "$c" ] || continue
    SRC="$c"
    break
  done
fi

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  cat >&2 <<MSG
✗ cannot find a Telegram application pair on this Mac.

  Looked in:
    ~/.moe/connectors/telegram.json
    ~/Library/Application Support/Moe/connectors/telegram.json
    a sibling checkout's Resources/telegram-client.json

  If Alfie has never connected Telegram here, get a pair from
  https://my.telegram.org/apps and write it as:

    { "api_id": "1234567", "api_hash": "..." }

  to Resources/telegram-client.json, or pass the path to this script.
MSG
  exit 1
fi

python3 - "$SRC" "$OUT" <<'PY'
import json, sys, os

src, out = sys.argv[1:3]
try:
    d = json.load(open(src))
except Exception as e:
    sys.exit("✗ %s is not readable JSON: %s" % (src, e))

api_id = str(d.get("api_id", "") or "").strip()
api_hash = str(d.get("api_hash", "") or "").strip()
if not api_id or not api_hash:
    sys.exit("✗ %s has no api_id/api_hash (keys: %s)" % (src, sorted(d)))

# Only the two fields. The source file is the *connector's* state and may also
# hold a phone number, a session reference or whatever it starts keeping next;
# none of that belongs in an app that ships to other people.
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    json.dump({"api_id": api_id, "api_hash": api_hash}, f, indent=2)
    f.write("\n")
os.chmod(out, 0o600)
print("  api_id:   %s (%d chars)" % ("present", len(api_id)))
print("  api_hash: present (%d chars)" % len(api_hash))
PY

echo "✓ staged $OUT from $SRC"
echo "  build.sh now bakes Telegram in; ./scripts/ship.sh will stop warning about it."

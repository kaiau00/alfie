#!/bin/bash
# Saves what Claude or ChatGPT told you about yourself, so the soul crawl reads
# it alongside your messages, notes and mail.
#
#   import-assistant-dump.sh claude          then paste, then Ctrl-D
#   import-assistant-dump.sh chatgpt < file.md
set -euo pipefail

MOE="$HOME/.moe"
DEEP="$MOE/context/deep"
SOURCE="${1:-}"

if [ -z "$SOURCE" ]; then
  cat <<'EOF'
usage: import-assistant-dump.sh <name>

  name    where it came from — e.g. claude, chatgpt, claude-work

The prompt to give them is in:
  ~/moe/moe-home/prompts/ask-your-assistants.md

Paste the reply, then press Ctrl-D on a blank line.
EOF
  exit 1
fi

# Keep it to a safe filename.
SAFE="$(printf '%s' "$SOURCE" | tr -cd '[:alnum:]-_' | tr '[:upper:]' '[:lower:]')"
[ -n "$SAFE" ] || { echo "That name has no usable characters."; exit 1; }

mkdir -p "$DEEP"
OUT="$DEEP/from-$SAFE.md"

if [ -t 0 ]; then
  echo "Paste what $SOURCE told you about you. Ctrl-D when you're done."
  echo
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP"

BYTES=$(wc -c < "$TMP" | tr -d ' ')
if [ "$BYTES" -lt 200 ]; then
  echo "✗ Only $BYTES bytes — that doesn't look like a real answer. Nothing saved."
  exit 1
fi

{
  echo "# What $SOURCE knows about me"
  echo
  echo "_Exported $(date '+%A %-d %B %Y'). Written by $SOURCE, not verified._"
  echo
  cat "$TMP"
} > "$OUT"
chmod 600 "$OUT"

echo "✓ saved $BYTES bytes to $OUT"
echo
echo "  Read it and delete anything wrong — Alfie reads it on every conversation:"
echo "    open -e \"$OUT\""
echo
echo "  Then hand it to Hermes too:  ~/.moe/hermes/migrate-memory.py"

#!/bin/bash
# One-time ChatGPT sign-in for Hermes (the "ChatGPT — your subscription"
# brain in Moe's Brain pane).
#
# Runs `hermes auth add openai-codex`: OpenAI's device-code flow, which
# prints a URL and a code, opens the browser, and waits for you to approve.
# Hermes keeps the resulting tokens in ~/.hermes/auth.json (0600) and
# refreshes them itself. Nothing is captured or stored by this script.
set -u

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "Run this in a terminal: the sign-in shows a code you need to see." >&2
  exit 1
fi

HERMES="${MOE_HERMES_BIN:-}"
for candidate in "$HERMES" "$HOME/.hermes/hermes-agent/.venv/bin/hermes" "$HOME/.local/bin/hermes" \
                 /opt/homebrew/bin/hermes /usr/local/bin/hermes "$(command -v hermes 2>/dev/null || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then HERMES="$candidate"; break; fi
done
if [ -z "$HERMES" ] || [ ! -x "$HERMES" ]; then
  echo "hermes is not installed (looked in ~/.hermes/hermes-agent/.venv/bin, ~/.local/bin, PATH)." >&2
  exit 1
fi

echo "Signing Hermes in to ChatGPT. Approve the code in your browser when it opens."
echo
"$HERMES" auth add openai-codex
status=$?
echo
if [ "$status" = 0 ]; then
  echo "signed in"
  echo "Back in Alfie, choose \"ChatGPT — your subscription\" and press Apply."
else
  echo "hermes auth add openai-codex exited $status — sign-in did not complete." >&2
fi
exit $status

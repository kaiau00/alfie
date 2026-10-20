#!/bin/bash
# Installs Claude Code, safely, for whoever needs it — scripts/install.sh on a
# developer's Mac, and Moe itself when someone picks "a Claude subscription"
# in onboarding. One implementation, because two would drift and this is the
# one that runs a script off the internet.
#
#   ./scripts/install-claude.sh          install it if it is not already here
#   ./scripts/install-claude.sh --check  say whether it is here; install nothing
#
# Prints ✓/✗ lines a person can read; everything the installer itself prints
# goes to ~/.moe/logs/install-claude.log.
#
# Why this is the safe form of `curl | bash`. Anthropic's own installer is the
# documented method (code.claude.com/docs, Quickstart, "Native Install"):
# `curl -fsSL https://claude.ai/install.sh | bash`. We do not pipe it into a
# shell. It is fetched to a file over https and TLS 1.2 or better, its sha256
# and its entire text are written to the log so that what ran can be read
# afterwards, its first two bytes are checked to be a script — a captive wifi
# portal's login page is a 200 with HTML in it — and only then is it run,
# with no sudo, under a ten-minute alarm, with stdin closed so its last step
# cannot sit waiting for an answer nobody is going to type.
#
# There is no checksum to pin, and that is worth saying plainly: unlike uv in
# install-hermes.sh, this URL is a rolling installer that always serves the
# newest, so a pinned hash would break on Anthropic's next release. What
# stands in for it: the script we run verifies the ~200 MB binary it downloads
# against a sha256 in Anthropic's own release manifest and deletes it on a
# mismatch (read 2026-08-30, checksum_matches() in claude.ai/install.sh), it
# installs under $HOME, and it refuses outright to run under sudo.
set -uo pipefail

MOE_HOME="${MOE_HOME:-$HOME/.moe}"
LOG="$MOE_HOME/logs/install-claude.log"
URL="${MOE_CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

CLAUDE_BIN=""
find_claude() {
  # Everywhere a Claude Code install can land, because a stranger may well
  # already have one and installing over it is rude, slow, and a good way to
  # break the one they were using: PATH first, then the native installer's
  # directory, both Homebrew prefixes, the older local install, bun, and npm's
  # global bin. A file that exists is not enough — it has to answer
  # --version, or it is a leftover from an install that went wrong.
  local c npm_bin=""
  if command -v npm >/dev/null 2>&1; then
    npm_bin="$(npm prefix -g 2>/dev/null || true)"
  fi
  for c in "$(command -v claude 2>/dev/null || true)" \
           "$HOME/.local/bin/claude" \
           /opt/homebrew/bin/claude \
           /usr/local/bin/claude \
           "$HOME/.claude/local/claude" \
           "$HOME/.bun/bin/claude" \
           "${npm_bin:+$npm_bin/bin/claude}"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    if "$c" --version >/dev/null 2>&1; then CLAUDE_BIN="$c"; return 0; fi
  done
  return 1
}

if find_claude; then
  echo "✓ Claude Code is already here: $("$CLAUDE_BIN" --version 2>/dev/null | head -1)"
  exit 0
fi
if [ "${1:-}" = "--check" ]; then
  echo "✗ Claude Code is not installed"
  exit 1
fi

mkdir -p "$MOE_HOME/logs"
dir="$(mktemp -d "${TMPDIR:-/tmp}/moe-claude.XXXXXX")"
script="$dir/install.sh"
{ echo; echo "=== claude install $(date '+%Y-%m-%d %H:%M:%S') from $URL ==="; } >>"$LOG"

echo "› fetching the installer from $URL"
if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 \
     -o "$script" "$URL" >>"$LOG" 2>&1; then
  rm -rf "$dir"
  echo "✗ couldn't reach $URL"
  exit 1
fi
if [ "$(head -c 2 "$script" 2>/dev/null)" != '#!' ]; then
  rm -rf "$dir"
  echo "✗ what came back from $URL isn't an installer — nothing was run"
  exit 1
fi
{ echo "sha256 $(shasum -a 256 "$script" | awk '{print $1}')"
  echo "--- the script that is about to run ---"; cat "$script"
  echo "--- end ---"; } >>"$LOG"

echo "› downloading Claude Code (about 200 MB — a minute or two)…"
if ! ( unset CLAUDE_INSTALL_ALLOW_SUDO
       /usr/bin/perl -e 'alarm 600; exec @ARGV or die "$!\n"' -- bash "$script" \
     ) </dev/null >>"$LOG" 2>&1; then
  rm -rf "$dir"
  echo "✗ the Claude Code installer stopped part-way (what it printed: $LOG)"
  exit 1
fi
rm -rf "$dir"
hash -r 2>/dev/null || true

if find_claude; then
  echo "✓ Claude Code installed: $("$CLAUDE_BIN" --version 2>/dev/null | head -1)"
  exit 0
fi
echo "✗ the installer finished but there's still no Claude Code that runs (details: $LOG)"
exit 1

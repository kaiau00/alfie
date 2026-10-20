#!/bin/bash
# Removes what install-hermes.sh put down: the hermes-agent checkout (with
# its venv) and the `hermes` wrapper. Nothing else — ~/.hermes/config.yaml,
# .env, memories, sessions, skills and the Keychain token all stay, so a
# later install-hermes.sh picks up exactly where you were. uv and the
# uv-managed Python stay too (other tools may use them; `uv python uninstall
# 3.11` and `rm ~/.local/bin/uv ~/.local/bin/uvx` if you want them gone).
#
# Overrides: HERMES_HOME (~/.hermes), MOE_BIN_DIR (~/.local/bin), MOE_HOME (~/.moe).
set -euo pipefail
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
MOE_BIN_DIR="${MOE_BIN_DIR:-$HOME/.local/bin}"
MOE_HOME="${MOE_HOME:-$HOME/.moe}"
AGENT_DIR="$HERMES_HOME/hermes-agent"
WRAPPER="$MOE_BIN_DIR/hermes"
LOG="$MOE_HOME/logs/install-hermes.log"
mkdir -p "$(dirname "$LOG")"
echo "=== uninstall-hermes $(date '+%Y-%m-%d %H:%M:%S') HERMES_HOME=$HERMES_HOME ===" >>"$LOG"
ok()   { printf '✓ %s\n' "$*"; echo "OK  $*" >>"$LOG"; }
fail() { printf '✗ %s\n' "$*"; echo "ERR $*" >>"$LOG"; exit 1; }

if pgrep -f "$AGENT_DIR/.venv/bin/python" >/dev/null 2>&1; then
  fail "a Hermes process from $AGENT_DIR is running (Moe's gateway?) — quit Moe first"
fi

if [ -d "$AGENT_DIR/.git" ]; then
  if [ -n "$(git -C "$AGENT_DIR" status --porcelain 2>/dev/null)" ] && [ "${FORCE:-0}" != 1 ]; then
    fail "$AGENT_DIR has local changes — FORCE=1 $0 to remove it anyway"
  fi
  rm -rf "$AGENT_DIR"
  ok "removed $AGENT_DIR (checkout + venv)"
elif [ -e "$AGENT_DIR" ]; then
  fail "$AGENT_DIR is not a git checkout; not touching it"
else
  ok "$AGENT_DIR already gone"
fi

# Hermes's pm tool store and its dependency state (since the 3.14 line):
# Node, the browser, uv, the interpreter — Hermes's runtime, not the person's
# data, and ~700 MB of it. Removed with the checkout they belong to.
if [ ! -e "$AGENT_DIR" ]; then
  for d in tools installs; do
    if [ -e "$HERMES_HOME/$d" ]; then
      rm -rf "${HERMES_HOME:?}/$d"
      ok "removed $HERMES_HOME/$d (Hermes's own $([ "$d" = tools ] && echo "tool store" || echo "dependency state"))"
    fi
  done
fi
if [ -f "$WRAPPER" ]; then
  if grep -q "hermes-agent/.venv/bin/python" "$WRAPPER"; then
    rm -f "$WRAPPER"; ok "removed $WRAPPER"
  else
    ok "left $WRAPPER alone (not the venv wrapper install-hermes.sh writes)"
  fi
else
  ok "$WRAPPER already gone"
fi
ok "kept $HERMES_HOME/config.yaml, .env, memories, sessions, skills and the Keychain token"

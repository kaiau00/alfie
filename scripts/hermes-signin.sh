#!/bin/bash
# One-time Claude sign-in for Hermes.
#
# The Hermes gateway that Moe runs starts its own Claude Code child, and that
# child signs in with a long-lived setup-token rather than your interactive
# login (HERMES-PLAN.md, "Revised after review"). This script runs
# `claude setup-token` in your terminal, captures the token it prints, and
# stores it in the login keychain where Moe reads it:
#
#     service  moe-child-oauth
#     account  moe
#     access   /usr/bin/security only (Moe reads it through that tool)
#
# The token is never echoed by this script, never written to a file that
# outlives the run, and the line claude prints it on is masked on screen.
set -u
umask 077

if ! command -v claude >/dev/null 2>&1; then
  echo "claude is not on your PATH. Install Claude Code first (https://claude.ai/code)." >&2
  exit 1
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "Run this in a terminal: claude setup-token needs to talk to you." >&2
  exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/moe-signin.XXXXXX") || exit 1
tokfile="$tmp/token"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Signing Hermes in to Claude. Follow the prompts from claude setup-token;"
echo "the token itself is captured and will not be shown."
echo

# Everything claude prints passes through awk: the token is diverted to a
# private file and masked on the terminal. stdin stays the terminal so the
# interactive prompts work.
claude setup-token 2>&1 | awk -v out="$tokfile" '
  {
    # The token may arrive mid-line, wrapped in ANSI styling and padded with
    # spaces; match on a copy with the escapes stripped.
    plain = $0
    gsub(/\033\[[0-9;]*[A-Za-z]/, "", plain)
    if (match(plain, /sk-ant-oat01-[A-Za-z0-9_-]+/)) {
      print substr(plain, RSTART, RLENGTH) > out
      close(out)
      sub(/sk-ant-oat01-[A-Za-z0-9_-]+/, "sk-ant-oat01-…(captured)")
    }
    print; fflush()
  }'
status=${PIPESTATUS[0]}

if [ ! -s "$tokfile" ]; then
  echo >&2
  if [ "$status" != 0 ]; then
    echo "claude setup-token did not complete (exit $status)." >&2
  else
    echo "claude setup-token did not produce a token." >&2
  fi
  echo "Sign in to Claude first — run \`claude\`, then \`/login\` — and run this script again." >&2
  exit 1
fi

token=$(head -n 1 "$tokfile" | tr -d '[:space:]')
rm -f "$tokfile"

# Replace by delete-then-add, never `-U`. Updating an existing item with
# `-U -T …` rewrites its access list, and a keychain ACL change always
# brings up "security wants to change access permissions… enter the login
# keychain password". A fresh item created with its final ACL never does.
# -T restricts access to the security tool, which is exactly how Moe reads
# it back (see HermesKey.childOAuthToken). Deliberately not -A: "any
# application" would hand the token to anything that asks. `-w` goes last.
security delete-generic-password -a moe -s moe-child-oauth >/dev/null 2>&1
if security add-generic-password -a moe -s moe-child-oauth -T /usr/bin/security -w "$token" >/dev/null 2>&1; then
  unset token
  echo
  echo "stored"
  echo "Alfie will pick it up the next time it starts Hermes."
else
  unset token
  echo "Couldn't store the token in the keychain (security add-generic-password failed)." >&2  # erase-allowlist: moe-child-oauth
  exit 1
fi

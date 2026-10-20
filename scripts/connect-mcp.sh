#!/bin/bash
# DEPRECATED — Hermes owns MCP now. Use scripts/connect.sh:
#
#   connect-mcp.sh linear npx -y @linear/mcp-server   →  connect.sh --command linear npx -y @linear/mcp-server
#   connect-mcp.sh notion --http https://…            →  connect.sh --url notion https://…
#   connect-mcp.sh                                    →  connect.sh   (lists everything; `connect.sh notion`
#                                                        installs the catalog server with one click)
#
# This shim translates the old arguments and hands over. What it used to do —
# write ~/.moe/.mcp.json for the Claude Code runtime and start a notes file
# under memory/tools/ — is gone: Hermes's Claude Code transport starts the
# child with `--strict-mcp-config` and its own config dir, so a .mcp.json in
# ~/.moe was never read by it, and nothing else in Moe reads that file
# either (checked 2026-08-30: only this script did). An existing
# ~/.moe/.mcp.json is left alone; delete it when you like.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "connect-mcp.sh is deprecated — MCP servers are Hermes connections now; using scripts/connect.sh." >&2

if [ $# -eq 0 ]; then
  exec "$HERE/connect.sh"
fi
NAME="$1"; shift
[ $# -gt 0 ] || { echo "Give the command to run, or --http <url>." >&2; exit 1; }
if [ "$1" = "--http" ]; then
  exec "$HERE/connect.sh" --url "$NAME" "${2:?url required}"
fi
exec "$HERE/connect.sh" --command "$NAME" "$@"

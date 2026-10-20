#!/bin/bash
# WhatsApp on this Mac. One QR code, in the app. Nothing to install.
#
# **Two rows, one WhatsApp, and now one linking.** Moe shows WhatsApp twice on
# purpose: "WhatsApp on this Mac" (Moe reads and writes as you) and "WhatsApp"
# under Ways to reach Moe (a number you message and Moe answers). Both mean
# linking this Mac as a device from your phone, and until 2026-09-09 they
# linked it TWICE, by two different mechanisms:
#
#   this script          cloned lharries/whatsapp-mcp, needed the Go toolchain
#                        installed by hand, built it, and left a foreground
#                        process printing a QR code into a Terminal window
#   connect.sh's platform  wrote WHATSAPP_ENABLED=true and said
#                        "run 'hermes whatsapp' in a terminal"
#
# Both are gone. Hermes ships its own bridge and its own Node
# (scripts/whatsapp-bridge/bridge.js, ~/.hermes/node) with a --pair-only
# --pair-json mode, and connect-whatsapp-bot.sh drives it and emits
# QR=<payload> for the app to draw. So this script is that script: one scan,
# one linked device, no Terminal, no Go, no clone, nothing fetched from a
# stranger at connect time.
#
# **What that trades away, said out loud.** whatsapp-mcp also shipped an MCP
# server with tools for searching your own chat history. Hermes's bridge gives
# Moe the conversation it is in, not a searchable archive of every chat. That
# is a real difference and the owner may want the archive back — the way to
# get it without a Terminal is a prebuilt binary in the app bundle, not a Go
# toolchain on the user's Mac. docs/CONNECTORS-AUDIT.md §2 carries it as an
# open item rather than pretending the two are the same thing.
#
# Two linked devices for one WhatsApp account was never right in any case:
# each carries its own expiry and its own share of the ban risk this connector
# warns about, for one person's one phone.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/connect-whatsapp-bot.sh" "$@"

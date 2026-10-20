#!/bin/bash
# From a fresh clone to a running community build of Memoe.
#
#   ./scripts/bootstrap.sh            build, then open it
#   ./scripts/bootstrap.sh --models   also bundle the speech and voice models
#                                     (~900 MB; otherwise they download the
#                                     first time each is needed)
#   ./scripts/bootstrap.sh --no-open  build only
#
# What it does, in order:
#   1. checks for the Command Line Tools and a Swift that can read Package.swift;
#   2. builds the COMMUNITY edition (MOE_EDITION=community), named Memoe OSS:
#      bundle id app.memoe.oss, its own home under ~/Library/Application
#      Support/Memoe OSS, no updater, no cloud, ad-hoc signed unless you have a
#      signing identity — so it can never take the place of an official Memoe
#      installed on the same Mac;
#   3. with --models, runs scripts/fetch-models.sh against that build (which is
#      why the build must work without Models/ first) and builds again;
#   4. opens dist/Memoe.app. Nothing is copied into /Applications.
#
# Hermes, the agent Memoe runs, is not in the clone either: on first launch the
# app installs the pinned commit of the public fork (scripts/install-hermes.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

MODELS=0; OPEN=1
for a in "$@"; do
  case "$a" in
    --models) MODELS=1 ;;
    --no-open) OPEN=0 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "✗ Memoe is a Mac app; this needs macOS" >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || {
  echo "✗ no Command Line Tools. Install them with:  xcode-select --install" >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "✗ no swift on PATH (Command Line Tools)" >&2; exit 1; }
need="$(sed -n '1s/.*swift-tools-version: *\([0-9.]*\).*/\1/p' Package.swift)"
echo "› $(swift --version 2>&1 | head -1)  (Package.swift needs tools ${need:-?})"

export MOE_EDITION=community
echo "› building the community edition (Memoe OSS) — this takes a few minutes the first time"
./build.sh
if [ "$MODELS" = 1 ]; then
  ./scripts/fetch-models.sh
  ./build.sh
fi
echo "✓ built dist/Memoe.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/Memoe.app/Contents/Info.plist))"
if [ "$OPEN" = 1 ]; then
  open dist/Memoe.app
  echo "✓ opened it. Its data lives in ~/Library/Application Support/Memoe OSS."
fi

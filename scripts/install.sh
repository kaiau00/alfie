#!/bin/bash
# Sets up ~/.moe, builds Memoe.app, installs it, and starts the background sync.
#
# MOE_DRY_RUN=1 stops after ~/.moe is populated: no Hermes download, no
# compiler, nothing copied into /Applications, no launchd job, no app opened.
# It exists so scripts/test-fresh-install.sh can point HOME at a scratch
# directory and check that every file the app and the shell scripts read is
# actually there — the one failure mode that turns a stranger's first run into
# a dead end, and the one that cannot be found by reading the copy list,
# because the bug is always the file that is not in it.
#
# The three questions this script can ask, and the switches that answer them
# without a person (a scripted install, and the tests). Each is documented
# again where it is used:
#
#   MOE_INSTALL_CLAUDE   ask (default) | yes | no    install Claude Code
#   MOE_SIGNING_CERT     auto (default) | yes | no   make the signing certificate
#   MOE_CLAUDE_INSTALLER_URL                         where the first one comes from
set -euo pipefail
DRY_RUN="${MOE_DRY_RUN:-0}"

cd "$(dirname "$0")/.."
REPO="$PWD"

# Alfie: this installer is Memoe's own. It installs over /Applications/Memoe.app
# under Memoe's bundle ids, which a fork must never do (AGENTS.md, TRADEMARK.md).
if [ ! -f cloud/release.env ]; then
  echo "✗ install.sh installs the official Memoe and is disabled in Alfie." >&2
  echo "  Build with ./scripts/bootstrap.sh and drag dist/Alfie.app into Applications." >&2
  exit 1
fi

# ── Which Moe this run is for ────────────────────────────────────────────
#
# MOE_DEV=1 builds and installs "Moe Dev": its own bundle identifier, its
# own name, its own home, no updater. See build.sh's header for why the
# identifier is the thing that matters — macOS treats two bundles sharing
# one as the same app, so a dev build with a different identifier cannot
# take the release app's place, its preferences, its privacy grants or its
# background jobs, whoever runs what.
#
# The guards below (staleness, ancestry, the launch check) still apply to a
# dev install. They are cheap and a broken dev build is still a broken app;
# what changes is only which app is at risk.
# The default is Moe Dev, and that is the whole guard.
#
# Every other protection written on 2026-09-03 asks "should this install be
# allowed?" — and each was answered correctly while the person's Moe was
# replaced anyway, because the question was never the problem. Nobody
# intended to touch their app; they ran the install command that has always
# meant "put my work on this Mac". So that command now means Moe Dev, and
# replacing the Moe someone actually uses takes a deliberate word.
#
# MOE_INSTALL_RELEASE=1 is that word (or `release` as the argument). It is
# for cutting a release, and for a person who means to update their own Moe.
# It is not for testing a change: that is what Moe Dev is.
MOE_DEV="${MOE_DEV:-1}"
case "${1:-}" in
  dev|--dev)         MOE_DEV=1 ;;
  release|--release) MOE_DEV=0 ;;
esac
[ "${MOE_INSTALL_RELEASE:-0}" = 1 ] && MOE_DEV=0
export MOE_DEV
if [ "$MOE_DEV" = 1 ]; then
  HOME_DIR="$HOME/Library/Application Support/Moe Dev"
  BUNDLE_ID="com.memoe.app.dev"
  APP="/Applications/Memoe Dev.app"
  BUILT="dist/Alfie Dev.app"
  WHICH="Alfie Dev"
else
  HOME_DIR="$HOME/.moe"
  BUNDLE_ID="com.memoe.app"
  APP="/Applications/Memoe.app"
  BUILT="dist/Alfie.app"
  WHICH="Alfie"
fi

echo "Alfie setup"
echo "───────────"

# 1. The hard dependencies. Hermes is the brain; its child Claude Code is
# what thinks. Neither is now a thing the user has to go and fetch: this
# script offers Claude Code and installs it, and install-hermes.sh puts Hermes
# down without asking (uv, Python 3.11, the fork, the venv, the `hermes`
# wrapper). Both are skipped when they are already there, and neither stops
# the install when it fails — DISTRIBUTION.md §2 rule 4, never block.
#
# Until 2026-08-30 a missing `claude` was `exit 1` and a sentence telling a
# stranger to go and install it themselves. That was the single hardest stop
# in a first run.
#
#   MOE_INSTALL_CLAUDE   ask (default) | yes | no
#     ask  prompt, when there is a terminal to prompt at; with no terminal,
#          or under MOE_DRY_RUN, report what would happen and move on
#     yes  install without asking (a scripted install, and the tests)
#     no   don't; say what to run by hand and carry on
INSTALL_CLAUDE="${MOE_INSTALL_CLAUDE:-ask}"

CLAUDE_BIN=""
find_claude() {
  # Everywhere a Claude Code install can land, because a stranger may well
  # already have one and installing over it is rude, slow, and a good way to
  # break the one they were using: PATH first, then the native installer's
  # directory, both Homebrew prefixes, the older local install, bun, and npm's
  # global bin. A file that exists is not enough — it has to answer
  # --version, or it is a leftover from an install that went wrong.
  local c npm_bin=""
  # Spelled out as an if rather than `cmd && var=…`: under `set -e` the second
  # form is only safe because of an exemption most readers have to look up.
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
    # Quoted whole, so a home directory with a space in it cannot split one
    # candidate into two; an empty one falls out at the -n test below.
    [ -n "$c" ] && [ -x "$c" ] || continue
    if "$c" --version >/dev/null 2>&1; then CLAUDE_BIN="$c"; return 0; fi
  done
  return 1
}

claude_version() { "$CLAUDE_BIN" --version 2>/dev/null | head -1; }

# The install command, and why it is the safe form of it.
#
# Anthropic's own installer is the documented method (code.claude.com/docs,
# Quickstart, "Native Install (Recommended)"): `curl -fsSL
# https://claude.ai/install.sh | bash`. We do not pipe it into a shell. It is
# fetched to a file, over https only and TLS 1.2 or better, its sha256 and its
# whole text are written to ~/.moe/logs/install-claude.log so what ran is
# readable afterwards, its first two bytes are checked to be a script, and only
# then is it run.
#
# There is no checksum to pin here, and that is worth saying plainly: unlike
# uv in install-hermes.sh — a fixed release asset with a fixed hash — this URL
# is a rolling installer that always serves the newest, so a pinned hash would
# break on Anthropic's next release. What stands in for it: the script we run
# verifies the ~200 MB binary it downloads against a sha256 in Anthropic's own
# release manifest and deletes it on a mismatch (read on 2026-08-30 —
# checksum_matches() in claude.ai/install.sh), it installs under $HOME, and it
# refuses outright to run under sudo. We never use sudo, never write outside
# $HOME, and never ask it for a particular version.
CLAUDE_INSTALLER_URL="${MOE_CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

# The installer moved to scripts/install-claude.sh so that Moe itself can run
# it — someone who picks "a Claude subscription" in onboarding needs exactly
# this, and a second implementation inside the app would be a second thing
# running a script off the internet. The safety reasoning lives there now.
install_claude() {
  local runner="$REPO/scripts/install-claude.sh"
  if [ ! -x "$runner" ]; then
    echo "✗ scripts/install-claude.sh is missing from the checkout"
    return 1
  fi
  MOE_HOME="$HOME_DIR" MOE_CLAUDE_INSTALLER_URL="$CLAUDE_INSTALLER_URL" "$runner" || return 1
  hash -r 2>/dev/null || true
  find_claude && return 0
  return 1
}

by_hand() {
  echo "  To do it yourself later, in a terminal:"
  echo "      curl -fsSL $CLAUDE_INSTALLER_URL | bash"
  echo "  Then run this installer again — it is safe to repeat."
}

CLAUDE_OK=0
if find_claude; then
  CLAUDE_OK=1
  echo "✓ Claude Code is already here — $(claude_version)"
elif [ "$INSTALL_CLAUDE" = no ]; then
  echo "› Claude Code isn't installed, and you said not to install it."
  by_hand
elif [ "$INSTALL_CLAUDE" != yes ] && [ "$DRY_RUN" = 1 ]; then
  # A run that is only checking the file layout downloads nothing.
  echo "› Claude Code isn't installed — a real run would offer to install it (skipped: MOE_DRY_RUN)"
elif [ "$INSTALL_CLAUDE" != yes ] && [ ! -t 0 ]; then
  # Nobody here to ask. Say what a real run would do rather than deciding a
  # 200 MB download on behalf of someone who isn't watching.
  echo "› Claude Code isn't installed — a real run would offer to install it (skipped: nothing here to ask at)"
else
  ask=y
  if [ "$INSTALL_CLAUDE" != yes ]; then
    echo
    echo "  Alfie needs Claude Code, Anthropic's command-line app — it's the part of Alfie"
    echo "  that thinks. It's about a 200 MB download, it installs in your home folder,"
    echo "  and it never asks for your admin password."
    echo
    read -r -p "  Install it now? [Y/n] " ask || ask=y
  fi
  if [[ "${ask:-y}" =~ ^[Nn] ]]; then
    echo "› Not installing it. Alfie will install and run; it just won't be able to think yet."
    by_hand
  elif install_claude; then
    CLAUDE_OK=1
    echo "✓ Claude Code installed — $(claude_version)"
  else
    echo "  Carrying on without it — everything else still installs."
    by_hand
  fi
fi

# Found, but your shell would not find it. Worth saying in words: the next
# thing this person does is type `claude` and get "command not found", and
# conclude the install failed.
if [ "$CLAUDE_OK" = 1 ] && ! command -v claude >/dev/null 2>&1; then
  # Shown with a ~ rather than the full path: /Users/<name>/.local/bin is a
  # mouthful, and the point of the sentence is which folder, not where home is.
  dir="$(dirname "$CLAUDE_BIN")"
  case "$dir" in "$HOME"/*) dir="~${dir#"$HOME"}" ;; esac
  echo "  It's at $dir/claude, and Alfie looks there. Your own terminal may not find"
  echo "  it until you open a new window — if it still can't, add $dir to your PATH."
fi

# A failed Hermes install does not stop the app install: Moe runs without
# Hermes (it says so when asked to think), and the fix is to run this
# installer again, which the closing message says.
HERMES_OK=1
if command -v hermes >/dev/null 2>&1 || [ -x "$HOME/.local/bin/hermes" ] \
   || [ -x "$HOME/.hermes/hermes-agent/.venv/bin/hermes" ]; then
  echo "✓ Alfie's core is already here"
elif [ "$DRY_RUN" = 1 ]; then
  # A dry run never downloads a gigabyte to prove a copy list is complete.
  echo "› Alfie's core isn't here yet — a real run would install it (skipped: MOE_DRY_RUN)"
else
  # Said before the wait, not after it: this is the longest step in the whole
  # install by a wide margin, and a minute and a half of silence with no idea
  # what is happening is how someone decides it has hung and kills it.
  echo
  echo "  Installing the rest of Alfie's core now. It's a big download — about 1.3 GB,"
  echo "  and usually a minute or two. Nothing to do; it prints as it goes."
  echo
  if ! "$REPO/scripts/install-hermes.sh"; then
    HERMES_OK=0
    echo "✗ That didn't finish (the ✗ line above says why). Carrying on with the app —"
    echo "  Alfie will install and run, but it won't be able to answer until this works."
  fi
fi

# 2. Home directory, tools, connectors.
mkdir -p "$HOME_DIR"/{tools,connectors,lib,context,memory,logs,prompts,learn}
# put_files <dir> <file>…: each file copied beside its destination under a
# temporary name, then renamed over it. Never `cp -f` straight onto it: that
# truncates the file in place and rewrites it, and anything reading it at
# that moment reads half of each. bash reads a script as it runs, so a sync
# tick that was mid-sync.sh during an install once died on
# "sync.sh: line 499: every: command not found". A rename swaps the whole
# file at once; a reader that already has it open keeps the old one.
put_files() {
  local dir="$1" src base tmp rc=0
  shift
  for src in "$@"; do
    [ -f "$src" ] || continue
    base="$(basename "$src")"
    tmp="$dir/.$base.installing.$$"
    if cp -f "$src" "$tmp" && mv -f "$tmp" "$dir/$base"; then :; else rm -f "$tmp"; rc=1; fi
  done
  return "$rc"
}
put_files "$HOME_DIR/tools"      "$REPO/moe-home/tools/"*.sh        2>/dev/null || true
# tools/ is not all shell. moe-home/connectors/whatsapp.sh calls
# $HOME/.moe/tools/name-numbers.py by absolute path in five places, so a
# *.sh-only glob leaves WhatsApp naming every contact by phone number on a
# fresh Mac. scripts/test-fresh-install.sh is what keeps this line here.
put_files "$HOME_DIR/tools"      "$REPO/moe-home/tools/"*.py        2>/dev/null || true
put_files "$HOME_DIR/lib"        "$REPO/moe-home/lib/"*.sh          2>/dev/null || true
# lib/mcp_read.py: the one deterministic read of a Hermes connection that
# both the watch monitor (Hermes's cron) and the learn crawl import.
put_files "$HOME_DIR/lib"        "$REPO/moe-home/lib/"*.py          2>/dev/null || true
# learn/consent.sh is not only the learn-me crawl's gate: Settings →
# Connections turns Chrome browsing on and off through it, so it has to be
# installed even on a machine that never runs the crawl.
put_files "$HOME_DIR/learn"      "$REPO/moe-home/learn/"*.sh        2>/dev/null || true
put_files "$HOME_DIR/learn"      "$REPO/moe-home/learn/"*.py        2>/dev/null || true
# learn/profiles.json: how each source is read and how often, researched per
# service. Without it every source falls to its manifest's built-in (three
# years of Chrome history instead of ninety days).
put_files "$HOME_DIR/learn"      "$REPO/moe-home/learn/"*.json      2>/dev/null || true
# Manifests and validate.sh ride along with the scripts — sync.sh and
# doctor.sh discover connectors from the *.manifest files. The glob is what
# installs drive-docs.py and drive-docs.manifest too; the chmod +x at the end
# of this step is what makes the .py runnable.
put_files "$HOME_DIR/connectors" "$REPO/moe-home/connectors/"*      2>/dev/null || true

# Retiring a connector has to reach the Macs that already have it.
#
# This step only ever copied, so a connector deleted from the repo stayed
# installed forever — and an installed manifest is a live tool. `google` was
# deleted in e38a775 ("The founder's decision, implemented: no Google sign-in
# anywhere") and was still on this machine months later, still publishing
# google_status and google_pull to the model, still named in the connector
# list a person reads. A deletion that does not reach the install is not a
# deletion.
#
# Moved aside rather than deleted: retired/ keeps the files where a person
# can see them and put them back, and the manifest is what makes a connector
# real, so moving it is enough to retire it. Anything a user put here by hand
# is preserved for the same reason.
retired="$HOME_DIR/connectors/retired"
for installed in "$HOME_DIR/connectors/"*.manifest; do
  [ -e "$installed" ] || continue
  base="$(basename "$installed" .manifest)"
  [ -f "$REPO/moe-home/connectors/$base.manifest" ] && continue
  mkdir -p "$retired"
  # `$base.*` alone leaves google-send-patterns.md behind, because the file
  # is named after the connector plus a word, not after the connector plus an
  # extension.
  for part in "$HOME_DIR/connectors/$base".* "$HOME_DIR/connectors/$base"-*; do
    [ -e "$part" ] && mv -f "$part" "$retired/" 2>/dev/null || true
  done
  echo "✓ retired the $base connector (moved to connectors/retired — it is no longer in Alfie)"
done

put_files "$HOME_DIR/prompts"    "$REPO/moe-home/prompts/"*.md      2>/dev/null || true
# The Connections pane launches these by path, so they must live beside the
# rest of Moe's home rather than only in the source checkout. Every script
# the app calls goes: connect.sh (the entry point — the old connect-*.sh
# glob missed it), the connect-* helpers it exec's, connect-telegram-bot.sh
# and pairing.sh (chat platforms), hermes-signin.sh ("Sign in to Claude for
# Hermes"), and the Hermes (un)installers. Named one by one so a missing
# file is a visible ✗ rather than a glob that silently matched nothing.
mkdir -p "$HOME_DIR/scripts"
# connect-drive-docs.sh is named here for a reason beyond the Connections
# pane: every "not connected" line connectors/drive-docs.py prints tells the
# user to run ~/.moe/scripts/connect-drive-docs.sh. Without this copy those
# sentences point at a file that is not there.
for f in connect.sh connect-gmail.sh connect-telegram.sh connect-drive-docs.sh \
         connect-telegram-bot.sh connect-whatsapp.sh connect-whatsapp-bot.sh \
         connect-signal.sh fetch-signal-cli.sh signal-daemon.sh \
         connect-mcp.sh pairing.sh \
         hermes-signin.sh hermes-codex-signin.sh install-hermes.sh install-claude.sh \
         refresh-hermes-seed.sh reseed-hermes.sh fetch-hermes-browser.sh \
         uninstall-hermes.sh import-assistant-dump.sh; do
  if [ -f "$REPO/scripts/$f" ]; then
    put_files "$HOME_DIR/scripts" "$REPO/scripts/$f"
  else
    echo "✗ scripts/$f is missing from the checkout — Settings › Connections will not find it"
  fi
done
chmod +x "$HOME_DIR/scripts/"*.sh 2>/dev/null || true
# learn.sh goes with learn/: the directory without its driver is a crawl
# that cannot be run from an installed Mac, only from a source checkout.
# nudge.sh goes with sync.sh for the same reason: sync.sh's last step runs
# ~/.moe/nudge.sh, and without this copy that step silently does nothing, so
# the amber glow in the notch could never happen on an installed Mac.
put_files "$HOME_DIR" "$REPO/moe-home/sync.sh" "$REPO/moe-home/doctor.sh" \
      "$REPO/moe-home/learn.sh" "$REPO/moe-home/nudge.sh"        2>/dev/null || true
# The starter vocabulary. Sources/MoeDictation/Vocabulary.swift reads
# ~/.moe/vocabulary.txt as its highest-priority source; a missing file is
# treated as empty, so leaving it out is silent — dictation just spells the
# words Moe ships knowing the way they sound. Never overwritten: this file is
# one the user edits.
[ -f "$HOME_DIR/vocabulary.txt" ] || cp "$REPO/moe-home/vocabulary.txt" "$HOME_DIR/" 2>/dev/null || true
# The Hermes glue: the confirm-before-send hook that ~/.hermes/config.yaml
# points at, the one-shot memory migrator, and configure-hermes.py, which
# merges config-fragment.yaml into ~/.hermes/config.yaml. Tests stay in the
# repo. The merge runs at the end of this script (step 7): what it changed
# goes to ~/.moe/logs/install.log and the user sees one line.
mkdir -p "$HOME_DIR/hermes/hooks"
# The gate can legitimately be root-owned and mode 555 — that is the one thing
# that turns confirm-before-send from a rule the agent might find a spelling
# past into a boundary it cannot cross, and `configure-hermes.py --check`
# offers exactly that. It also means this `cp -f` cannot write it. With
# `|| true` on the end, that failure was SILENT: the boundary would hold and
# the gate would quietly stop being updated, so a machine that hardened itself
# would go on running whatever version of the hook it hardened, forever, while
# every install said ✓.
#
# So: try, and if the copy fails only because the destination is not ours, say
# so and say what to do about it. Loud and specific beats silent and current.
for hook in "$REPO/moe-home/hermes/hooks/"*.sh; do
  [ -f "$hook" ] || continue
  dest="$HOME_DIR/hermes/hooks/$(basename "$hook")"
  if cmp -s "$hook" "$dest" 2>/dev/null; then
    continue
  fi
  if ! cp -f "$hook" "$dest" 2>/dev/null; then
    if [ -e "$dest" ] && [ ! -w "$dest" ]; then
      echo "✗ $dest is not writable (root-owned gate) and is OUT OF DATE."
      echo "  The send gate is hardened, which is good — but this update could not reach it."
      echo "  Run:  sudo cp -f '$hook' '$dest' && sudo chmod 555 '$dest'"
    else
      echo "✗ could not install $(basename "$hook") into $HOME_DIR/hermes/hooks/"
    fi
  fi
done
# *.json: model-tiers.json, which configure-hermes.py reads from beside itself.
put_files "$HOME_DIR/hermes" "$REPO/moe-home/hermes/"*.py "$REPO/moe-home/hermes/"*.yaml \
          "$REPO/moe-home/hermes/"*.json                               2>/dev/null || true
# What configure-hermes.py installs INTO Hermes, and where it looks for it:
# hermes-plugins/ (the moe-profile plugin — the learn-me profile in Hermes's
# system prompt — and the claimstore plugin, which makes Hermes's MEMORY.md
# and USER.md a digest of ~/.moe/ledger so a second writer is the normal case)
# and hermes-jobs/ (the nightly deep-crawl script and its cron spec). All are
# copied whole, tests and all, because the plugin's directory is what lands in
# ~/.hermes/plugins/. Without this step configure-hermes.py
# on a real Mac finds no payload beside itself and quietly installs neither —
# which is exactly how the learn-me pipeline came to be fully built and
# entirely inert.
# Replaced rather than merged, and to an explicit destination path: `cp -R a
# b` means two different things depending on whether b/a already exists, and
# a plugin directory carrying a file from an older version is a plugin that
# fails to load.
# hermes-gateway-hooks/ joins them: drop-in gateway hooks (HOOK.yaml +
# handler.py) that configure-hermes.py copies into ~/.hermes/hooks/. Different
# mechanism from the `hooks:` block in config.yaml — those are shell hooks on
# tool calls; these run in-process on gateway lifecycle events.
# hermes-skills/ joins them: skills Moe wrote, which the Skills Hub cannot
# install because they exist nowhere but this checkout. configure-hermes.py's
# install_moe_skills() copies them into ~/.hermes/skills/<category>/<name>/.
for d in hermes-plugins hermes-jobs hermes-gateway-hooks hermes-skills; do
  if [ -d "$REPO/moe-home/$d" ]; then
    rm -rf "${HOME_DIR:?}/$d"
    cp -R "$REPO/moe-home/$d" "$HOME_DIR/$d"
    # Compiled Python is generated, never written, and it embeds the absolute
    # path of the source it was built from — which is how Moe 0.3.5 shipped
    # two .pyc files naming the builder's home directory and worktree.
    # build.sh prunes them from the bundle; this keeps the two installs
    # identical, which scripts/test-payload.sh checks file by file. Python
    # rebuilds them on first import, so nothing is lost.
    find "$HOME_DIR/$d" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$HOME_DIR/$d" -name '*.pyc' -delete 2>/dev/null || true
  else
    echo "✗ moe-home/$d is missing from the checkout — whatever it carries (the learn-me profile plugin, the nightly crawl, the gateway hooks, Alfie's own skills) will not be installed"
  fi
done
# learn/*.py is here so profile.py — what Settings › Memory runs to show,
# correct and delete what Moe has learned — matches its own shebang.
chmod +x "$HOME_DIR"/tools/*.sh "$HOME_DIR"/connectors/* "$HOME_DIR"/*.sh \
         "$HOME_DIR"/learn/*.sh "$HOME_DIR"/learn/*.py \
         "$HOME_DIR"/hermes/hooks/*.sh "$HOME_DIR"/hermes/*.py \
         "$HOME_DIR"/hermes-jobs/*.sh 2>/dev/null || true
echo "✓ ~/.moe ready"

# 3. Trust the workspace.
#
# Without this, Claude Code prints "Ignoring N permissions.allow entries from
# .claude/settings.json: this workspace has not been trusted" — to stderr, where
# you'd never see it — and silently drops Moe's entire permission policy. ~/.moe
# holds only files Moe created, so trusting it is safe. It happens here, in a
# script you ran, rather than quietly inside the app.
python3 - "$HOME_DIR" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.claude.json")
target = sys.argv[1]
try:
    with open(path) as f: cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
entry = cfg.setdefault("projects", {}).setdefault(target, {})
if entry.get("hasTrustDialogAccepted") is True:
    print("✓ workspace already trusted")
else:
    entry["hasTrustDialogAccepted"] = True
    tmp = path + ".moe-tmp"
    with open(tmp, "w") as f: json.dump(cfg, f, indent=2)
    os.replace(tmp, path)
    print("✓ trusted ~/.moe so Alfie's permission rules apply")
PY

# 3b. A signature that stays the same, so permissions stay granted.
#
# macOS ties every permission you grant — Microphone, Accessibility, Full Disk
# Access, Automation — to the app's *designated requirement*, and the two ways
# to sign a build produce very different ones. Both dumped on macOS 26.5.2 on
# 2026-08-30, not remembered:
#
#   with "Moe Code Signing":
#     designated => identifier "com.memoe.app" and certificate root = H"…"
#   ad-hoc (codesign --sign -):
#     designated => cdhash H"…"
#
# The first pins the certificate, which does not change, so a rebuilt Moe is
# the same app to macOS and the grants survive an update. The second pins the
# code hash, which is new on every single build, so every update is a stranger
# and asks for everything again.
#
# Since 2026-10-06 there is a third, and it comes first when the keychain has
# it (scripts/sign-build.sh):
#
#   with our Developer ID:
#     designated => identifier "com.memoe.app" and anchor apple generic and
#                   … leaf[subject.OU] = "5Y8C3ZR5X6"
#
# It pins the team, which is also what the published release carries, and it
# gives keychain items a `teamid:` partition instead of a `cdhash:` one — the
# self-signed certificate keeps TCC grants across a rebuild but NOT the consent
# key, which every self-signed rebuild re-minted (one Google sign-in each).
#
# Without the Developer ID, build.sh prefers the certificate (scripts/
# sign-build.sh: `security find-certificate -c "Moe Code Signing"`), and make-signing-cert.sh already creates it and is
# idempotent. What was missing is this: nobody ever ran it. So the author had a
# stable identity by luck and every stranger fell through to ad-hoc and was
# re-prompted forever. It has to happen before build.sh, or the first build is
# signed the wrong way and has to be redone.
#
#   MOE_SIGNING_CERT   auto (default) | yes | no
#     auto  do it, when there is a terminal; report and skip otherwise
#     yes   do it regardless (the tests)
#     no    don't
SIGNING_CERT="${MOE_SIGNING_CERT:-auto}"
STABLE_SIGNATURE=0
if [ "$SIGNING_CERT" = no ]; then
  echo "› Skipping Alfie's signing certificate, as asked."
elif [ "$SIGNING_CERT" != yes ] && [ "$DRY_RUN" = 1 ]; then
  # Under a dry run this must not so much as read the keychain:
  # scripts/test-fresh-install.sh proves a dry run never calls `security`.
  echo "› Signing certificate: a real run would make one here (skipped: MOE_DRY_RUN)"
elif DEVID_SHA="$("$REPO/scripts/sign-build.sh" --devid-sha1 2>/dev/null)"; then
  # Our Developer ID is the identity build.sh signs a local build with when
  # it is here (scripts/sign-build.sh): a Team ID, so the consent key and
  # every permission survive both a rebuild and a Sparkle update. Nothing to
  # make, and make-signing-cert.sh is not offered.
  STABLE_SIGNATURE=1
  echo "✓ This Mac has Alfie's Developer ID; the build is signed with it (team ${MOE_DEVID_TEAM:-5Y8C3ZR5X6})"
elif security find-certificate -c "Moe Code Signing" >/dev/null 2>&1; then
  # Asked before the no-TTY check on purpose: looking is read-only and raises
  # no dialog, and a scripted install on a Mac that already has the
  # certificate must not report it as missing — that warns about permission
  # re-prompts that will not happen.
  STABLE_SIGNATURE=1
  echo "✓ Alfie already has its signing certificate on this Mac"
elif [ "$SIGNING_CERT" != yes ] && [ ! -t 0 ]; then
  # Making one may put a dialog on screen. Not something to trigger behind
  # the back of a scripted install with nobody watching.
  echo "› Signing certificate: a real run would make one here (skipped: nothing here to ask at)"
else
  # make-signing-cert.sh puts a certificate in the login keychain, and macOS
  # asks about that. Said before it happens, because an unexplained security
  # dialog in the middle of an install is how someone decides to cancel.
  echo
  echo "  Alfie is about to make itself a certificate on this Mac. It's what lets the"
  echo "  permissions you grant stay granted, instead of macOS asking again after"
  echo "  every update. macOS will ask you to allow it — once, and only this once."
  echo
  if MOE_CERT_QUIET_NEXT=1 "$REPO/scripts/make-signing-cert.sh"; then
    STABLE_SIGNATURE=1
  else
    # Not fatal. An ad-hoc build works; it just gets re-asked. The closing
    # message says so, and only on the runs where it is true.
    echo "✗ That didn't work, so Alfie will sign itself a different way. Everything still"
    echo "  installs — macOS will just ask for the microphone and the rest again after"
    echo "  an update."
  fi
fi

# Everything above this line puts files where the app and the shell scripts
# look for them; everything below it compiles, copies into /Applications and
# talks to launchd. A dry run stops here, having done the first for real.
if [ "$DRY_RUN" = 1 ]; then
  echo "✓ dry run: ~/.moe populated at $HOME_DIR; nothing built, installed or loaded"
  exit 0
fi

# 4. Build and install.
#
# A word about which code this builds, because it is the one that bit.
#
# This installs into /Applications, over the Moe the person is using. Each
# worktree on this machine is on its own branch, and those drift: measured on
# 2026-09-02, one was 126 commits behind main, another 94, another 88. Running
# this from any of them replaces the user's Moe with one missing everything
# that landed since the branch forked — which is how a 0.3.8 install became a
# 0.3.7 install while somebody was using it.
#
# So a stale branch is said out loud. Not refused: installing your own
# in-progress build is the entire point of this script, and it is often
# exactly what you want. But it should never be a surprise.
if git rev-parse --git-dir >/dev/null 2>&1 && [ "$DRY_RUN" = 0 ]; then
  if git fetch -q origin 2>/dev/null; then
    behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
    if [ "${behind:-0}" -gt 20 ]; then
      echo
      echo "  ⚠ This branch is $behind commits behind main."
      echo "    The Alfie you are about to install is missing all of it."
      echo "    If you meant to test the current product:  git merge origin/main"
      echo
    elif [ "${behind:-0}" -gt 0 ]; then
      echo "› note: this branch is $behind commit(s) behind main"
    fi
  fi
fi

echo "› Building Alfie. The first build takes about a minute…"
# Not >/dev/null: what build.sh says about what it put in the bundle is
# the only place a missing model shows up, and discarding it is how an
# app shipped without the voice it was configured to speak in — twice.
# The summary lines only; the compiler's thousands stay hidden.
#
# On 2026-09-03 this line was `./build.sh | grep … || true`, and it left Izzy's
# Moe unopenable. Two correct intentions compounded into a defect: the pipe put
# build.sh on the LEFT, so the pipeline reported grep's status and not the
# build's — and `|| true` then discarded even that, because grep exits 1 when it
# matches nothing and a build whose summary lines change must not abort a good
# install. This file is `set -euo pipefail`, which would have caught it; the
# `|| true` defeated pipefail for this one command. So build.sh printed
#   ✗ the default voice is 'pocket' but pocket-tts is not in the bundle
# and exited non-zero, install.sh printed "✓ built", and the swap proceeded with
# a bundle that had MacOS and Resources and nothing else.
#
# Build to a file, check the status explicitly, then read the file. `|| true`
# stays where it belongs — on the grep alone.
BUILD_LOG="${TMPDIR:-/tmp}/moe-install-build.$$.log"
if ! ./build.sh > "$BUILD_LOG" 2>&1; then
  tail -20 "$BUILD_LOG" >&2
  echo "✗ the build failed — nothing was installed, and the Alfie you have is untouched." >&2
  rm -f "$BUILD_LOG"
  exit 1
fi
grep -E "^  (models|payload|hermes|bundle|google):" "$BUILD_LOG" || true
rm -f "$BUILD_LOG"
echo "✓ built"

# ── Replacing the app that is actually in use ───────────────────────────────
#
# /Applications/Memoe.app is not this checkout's private output. It is the Moe
# the person at this Mac is using right now, and on a machine with several
# worktrees, several sessions run this script. Two rules follow from that, and
# both were learned the hard way on 2026-09-02.
#
# **Never destroy what is there before the replacement is ready.** This used
# to be `rm -rf "$APP"` followed by a 1.7 GB `cp -R`. Interrupt that — a
# killed session, a full disk, ⌃C — and the user is left with a bundle that
# has Resources and MacOS but no Info.plist and no Frameworks. macOS cannot
# launch it, and the crash report says only "Library missing". That happened,
# and the app was dead until someone noticed. So: copy beside, then swap. The
# old app stays whole and runnable until a complete new one exists, and the
# swap itself is two renames.
#
# **Never quietly go backwards.** Each worktree builds its own version, so a
# session on an older branch running this replaced a newer Moe with an older
# one — silently, on a machine where somebody was using it. A downgrade now
# has to be asked for.
INSTALLED_V=""
[ -f "$APP/Contents/Info.plist" ] && INSTALLED_V="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
NEW_V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$BUILT/Contents/Info.plist" 2>/dev/null || echo "")"
if [ -n "$INSTALLED_V" ] && [ -n "$NEW_V" ] \
   && [ "$INSTALLED_V" -gt "$NEW_V" ] 2>/dev/null \
   && [ "${MOE_ALLOW_DOWNGRADE:-}" != 1 ]; then
  echo "✗ /Applications/Memoe.app is build $INSTALLED_V; this checkout builds $NEW_V." >&2
  echo "  Refusing to replace a newer Alfie with an older one — somebody is using it." >&2
  echo "  Merge main here, or set MOE_ALLOW_DOWNGRADE=1 if you really mean it." >&2
  exit 1
fi

# Whose build is standing there now.
#
# Sixteen sessions work on this machine, several in this repo with their
# own worktrees, and any of them may install. On 2026-09-03 one did,
# nine minutes after another had verified its own install, and the person
# testing spent a session on code that predated the fixes he was testing
# — because two builds from different trees were both "16" and nothing
# else distinguished them. `MoeCommit` distinguishes them now, so this
# can be seen rather than reconstructed.
#
# The rule is not "only one session may install": no agreement between
# two sessions binds a third. The rule is that replacing somebody else's
# newer build is a surprising thing, and surprising things are refused
# out loud.
# By ancestry, not by clock: this script builds before it installs, so the
# bundle it is about to install is always the newer file and a timestamp
# comparison can never fire. What matters is not which is newer but
# whether the installed app contains work this checkout does not have.
#
# ── Overriding this takes the owner's password, not an environment variable
#
# MOE_ALLOW_REPLACE=1 used to be enough on its own, and an environment
# variable is exactly what a background session can set. The owner asked for
# the opposite: "make it so that it cannot go backwards without my password".
#
# So for the REAL Moe, the refusals below can only be passed by
# authenticating at this Mac — macOS's own administrator dialog, which wants
# a password or Touch ID and which nothing running unattended can answer.
# MOE_ALLOW_REPLACE still says "I mean to do this"; it no longer says "and I
# am allowed to".
#
# Moe Dev is deliberately exempt. It is the workbench, replacing it costs
# nobody anything, and a guard that fires on the safe path fifty times a day
# is one people learn to type past.
authorise_replacement() {
  local why="$1"
  [ "$MOE_DEV" = 1 ] && return 0

  # A variable that can only make this STRICTER, never weaker. Tests need to
  # exercise the refusal without a password dialog appearing on somebody's
  # screen, and a seam that can only deny is not a hole: nothing that sets it
  # gains anything.
  if [ "${MOE_AUTH_MUST_FAIL:-0}" = 1 ]; then
    echo "  (authorisation forced to fail: MOE_AUTH_MUST_FAIL=1)" >&2
    return 1
  fi

  echo "› replacing the real Alfie needs your permission — answer the dialog" >&2
  # `with administrator privileges` is the standard macOS authorisation
  # dialog: password, or Touch ID where it is set up. It is not `sudo` on
  # purpose — sudo caches a timestamp for five minutes, so a session that
  # happened to run one earlier would sail through this one.
  if osascript -e "do shell script \"true\" with prompt \"Alfie: $why\" with administrator privileges" >/dev/null 2>&1; then
    mkdir -p "$HOME/.moe/logs"
    printf '%s  %s  AUTHORISED at the keyboard: %s  from %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)" "$why" "$REPO" \
      >> "$HOME/.moe/logs/overrides.log"
    return 0
  fi
  echo "✗ not authorised — the installed Alfie was left alone." >&2
  return 1
}

INSTALLED_COMMIT=""
[ -f "$APP/Contents/Info.plist" ] && INSTALLED_COMMIT="$(/usr/libexec/PlistBuddy \
  -c 'Print :MoeCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
NEW_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo "")"
# MOE_ALLOW_REPLACE says what you intend. For the real Moe it is not what
# permits it: that takes the dialog above, asked for HERE rather than inside
# each refusal, so there is exactly one place where "backwards is allowed"
# can become true and it is one a script cannot reach.
if [ "${MOE_ALLOW_REPLACE:-}" = 1 ] && [ -n "$INSTALLED_COMMIT" ] && [ "$MOE_DEV" != 1 ]; then
  authorise_replacement "replace the installed Alfie ($INSTALLED_COMMIT) with $NEW_COMMIT" \
    || exit 1
fi
if [ "${MOE_ALLOW_REPLACE:-}" != 1 ] && [ -n "$INSTALLED_COMMIT" ]; then
  base="${INSTALLED_COMMIT%+dirty}"
  # Two different questions, asked separately. `--is-ancestor` *errors* on
  # something that is not a commit rather than answering "no", so a guard
  # that reads only its exit code cannot tell "built from work you have
  # not merged" from "that is not a commit at all" — and would report the
  # wrong one. A well-formed identifier that resolves to nothing is more
  # dangerous than an absent one, because absence is honest. (There is one
  # in the wild: `deadbee`, which I wrote into the plist myself while
  # testing this guard and left there.)
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
    echo "✗ /Applications/Memoe.app is stamped $INSTALLED_COMMIT, which is not a commit in this repository." >&2
    echo "  A stamp that resolves to nothing tells you less than no stamp at all: what is in that" >&2
    echo "  app cannot be known, so replacing it cannot be known to be safe." >&2
    echo "  Set MOE_ALLOW_REPLACE=1 if you know what it is — for the real Alfie" >&2
    echo "  that also asks you to authenticate at this Mac." >&2
    echo "  Who installed what, and when: ~/.moe/logs/installs.log" >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$base" HEAD; then
    echo "✗ $APP is commit $INSTALLED_COMMIT, which this checkout does not have." >&2
    echo "  Somebody else built it from work you have not merged, and installing over it would" >&2
    echo "  take that away — from them, and from whoever is testing it right now." >&2
    echo "  Merge it first:  git fetch origin && git rebase origin/main" >&2
    echo "  Who installed what, and when: ~/.moe/logs/installs.log" >&2
    exit 1
  fi
elif [ "${MOE_ALLOW_REPLACE:-}" != 1 ] && [ -f "$APP/Contents/Info.plist" ]; then
  # No stamp at all: built before build.sh recorded one, so its contents
  # cannot be known. Say so rather than assume it is ours to replace.
  echo "› note: the installed Alfie carries no commit stamp, so what is in it cannot be checked"
fi

# What is about to be installed, held to the same standard.
#
# An app built from an uncommitted tree matches no commit: nobody can
# reproduce it, and when it turns out to be wrong there is nothing to
# read. The installed one right now is `3b27d9a+dirty`, and it quietly
# reverted a script somebody's job had been running against for an hour.
#
# Refused, but not absolutely. CLAUDE.md records what an unsatisfiable
# refusal costs: somebody routed around this script with `rm -rf` and a
# 1.7 GB copy, and left Moe with no Info.plist, dead until noticed. And
# there is a legitimate case — being asked to install work in progress is
# dirty by definition. So: one named override, and the receipt records
# that a person typed it.
DIRTY=""
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=1
if [ -n "$DIRTY" ] && [ "${MOE_ALLOW_DIRTY:-}" != 1 ]; then
  echo "✗ this checkout has uncommitted changes, so the app it builds matches no commit." >&2
  echo "  Nobody could reproduce it, and when something in it is wrong there is nothing to read." >&2
  echo "  Commit first, or set MOE_ALLOW_DIRTY=1 — which is recorded in ~/.moe/logs/installs.log." >&2
  git status --porcelain 2>/dev/null | head -5 | sed 's/^/      /' >&2
  exit 1
fi

# A running Moe must go first: `open` on an already-running app only brings
# the old instance forward, so without this every install "succeeds" while
# the previous build keeps running.
#
# THIS app and no other. Both bundles' binaries are called `Moe`, so
# `pgrep -x Moe` / `pkill -x Moe` matched whichever was running — on
# 2026-09-11 a Moe Dev install quit the owner's real Moe out from under
# them, exactly what a dev build exists never to do. Match on the full
# path of this install's binary, and quit through the bundle identifier,
# which is the one name macOS never confuses.
# >>> quit the running Moe (scripts/test-catch-up.sh §19 runs these lines as written)
# The real Moe updates silently (docs/DEFAULTS.md row 46): Sparkle stages a
# release and its installer waits for Moe to quit — and quitting Moe is what
# the next lines do. Left alone, that staged release could land over the
# build this install is about to put in place, which is 2026-09-03's "Moe
# went backwards" by a new door. So the installer is stopped and the staged
# update removed first, and a Sparkle that will not let go stops the install
# with nothing replaced. Moe Dev has no updater, so only the real one.
if [ "$MOE_DEV" != 1 ]; then
  "$REPO/scripts/sparkle-clear-staged.sh" "$BUNDLE_ID" || {
    echo "✗ Sparkle has an update staged for $WHICH that would install when it quits." >&2
    echo "  Nothing was quit and nothing was replaced. Run this again in a moment." >&2
    exit 1
  }
fi
RUNNING_BIN="$APP/Contents/MacOS/Moe"
this_moe_running() { pgrep -f "^$RUNNING_BIN( |\$)" >/dev/null 2>&1; }
WAS_RUNNING=0
if this_moe_running; then
  WAS_RUNNING=1
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do this_moe_running || break; sleep 0.25; done
  this_moe_running && pkill -f "^$RUNNING_BIN( |\$)" && sleep 1
  echo "✓ closed the copy of $WHICH that was running"
fi
# <<< quit the running Moe

# ditto rather than cp -R: it is the tool that preserves the resource forks,
# extended attributes and the code signature of a bundle, and a signature that
# does not verify is an app Gatekeeper refuses.
# Is this thing an app at all? Every other gate here asks about PROVENANCE —
# which commit, whose branch, was the tree clean. On 2026-09-03 all of them
# passed and the bundle still could not open, because nothing had asked. A
# partial build has MacOS and Resources and nothing else; macOS answers with
# "Moe cannot be opened because of a problem" and no more.
#
# No override. Staleness has a legitimate case and so does a dirty tree —
# installing an app that cannot launch has none, and a wall is only wrong when
# there is something on the other side of it worth reaching.
for part in Info.plist MacOS Frameworks _CodeSignature; do
  [ -e "$BUILT/Contents/$part" ] || {
    echo "✗ "$BUILT" has no Contents/$part — this is a partial build, not an app." >&2
    echo "  macOS would refuse to open it. Nothing was installed; the Alfie you have" >&2
    echo "  is untouched. Run ./build.sh and read what it says." >&2
    exit 1
  }
done
plutil -lint "$BUILT/Contents/Info.plist" >/dev/null 2>&1 || {
  echo "✗ "$BUILT/Contents/Info.plist" is not valid — macOS cannot read it." >&2
  echo "  Nothing was installed. (A version bump once clipped a comment's opening" >&2
  echo "  tag in build.sh's template and every build failed this way.)" >&2
  exit 1
}
# --verify --strict, and deliberately not --deep. Strict rejects the nested
# and sealed-resource defects a plain -v lets through; --deep is the flag
# Apple tells you not to use for validation, because it walks nested code with
# the OUTER requirement and reports on bundles the loader will never consult.
codesign --verify --strict "$BUILT" 2>/dev/null || {
  echo "✗ "$BUILT"'s signature does not verify. Installing it would replace a" >&2
  echo "  working app with one Gatekeeper refuses. Nothing was installed." >&2
  exit 1
}

# And whose signature it is. When this keychain holds our Developer ID, the
# build must carry its Team ID. A build without one partitions its keychain
# items by code hash, so the next build cannot read the consent key, deletes
# it, mints another and asks the owner to sign in to Google again — after
# every catch-up, which is what 2026-10-06 measured. build.sh falls back to
# "Moe Code Signing" quietly when the Developer ID is unusable (a missing G2
# intermediate, a sandboxed codesign), so the side effect is asserted here,
# on the bundle about to be installed, not the choice build.sh printed.
"$REPO/scripts/sign-build.sh" --check-team "$BUILT" || exit 1

# And then: run it. Everything above this line inspects a directory, and a
# directory that looks like an app is not an app that runs — the whole lesson
# of 2026-09-03 was that only running the thing proves it is there. `strings`
# on this same binary finds `wake-bench` and misses `wake-record`; a bundle
# can pass every structural check and still fail to launch on a missing
# dylib, a bad arch, or a Swift runtime it cannot find.
#
# The falsifier names its artefact: the binary must report the commit THIS
# tree is on. That closes a gap the structural checks cannot see at all — a
# dist/ left over from an earlier build of a different branch is complete,
# correctly signed, and the wrong app. Four sessions replaced each other's
# work today; twice the confusion was about which build was on screen.
#
# No override, for the same reason as the checks above.
SMOKE_WANT="$(git rev-parse --short HEAD 2>/dev/null || echo "")"
SMOKE_OUT="$("$BUILT/Contents/MacOS/Moe" --build-info 2>&1 | head -1 || true)"
if [ -z "$SMOKE_OUT" ]; then
  echo "✗ "$BUILT" is complete and signed, but running it printed nothing." >&2
  echo "  An app that cannot answer --build-info is one macOS may not be able to" >&2
  echo "  open either. Nothing was installed; the Alfie you have is untouched." >&2
  exit 1
fi
case "$SMOKE_OUT" in
  *"$SMOKE_WANT"*) : ;;
  *)
    echo "✗ "$BUILT" runs, but it is not this checkout's build." >&2
    echo "    it says:   $SMOKE_OUT" >&2
    echo "    HEAD here: $SMOKE_WANT" >&2
    echo "  This is a stale dist/ from another branch — complete, signed, and the" >&2
    echo "  wrong app. Run ./build.sh. Nothing was installed." >&2
    exit 1
    ;;
esac

# Where the swap happens. Normally beside the app in /Applications. A
# STANDARD account (no admin) cannot create anything in /Applications -- it is
# root:admin 775 -- but the bundle it installed earlier is its own, so the
# swap moves one level down: the new Contents is copied in beside the old one
# INSIDE the bundle and the two are exchanged by rename, which is the same
# guarantee (an interrupted copy leaves the working app untouched) with no
# write to /Applications. Measured 2026-10-06: the owner's account was made
# standard on purpose and catch-up stopped at `ditto: Memoe.app.incoming:
# Permission denied`.
# swap_in BUILT APP: sets SWAP_TO; tested alone by scripts/test-install-no-admin.sh.
swap_in() {
  local BUILT="$1" APP="$2"
  SWAP_FROM="$BUILT"; SWAP_TO="$APP"
  if [ ! -w "$(dirname "$APP")" ] && [ -d "$APP/Contents" ] && [ -w "$APP" ]; then
    SWAP_FROM="$BUILT/Contents"; SWAP_TO="$APP/Contents"
    echo "› this account cannot write to $(dirname "$APP"); replacing the app's contents in place"
  fi
  rm -rf "$SWAP_TO.incoming"
  if ! ditto "$SWAP_FROM" "$SWAP_TO.incoming"; then
    rm -rf "$SWAP_TO.incoming"
    echo "✗ could not copy the new Alfie into /Applications — the one you had is untouched." >&2
    [ -w "$(dirname "$APP")" ] || echo "  (this account cannot write to $(dirname "$APP"), and $APP is not its own to replace)" >&2
    return 1
  fi
  # Only now is anything about the live app disturbed, and only by renames.
  rm -rf "$SWAP_TO.previous"
  [ -e "$SWAP_TO" ] && mv "$SWAP_TO" "$SWAP_TO.previous"
  mv "$SWAP_TO.incoming" "$SWAP_TO"
  # In place, the old Contents sits inside the bundle root, where a signature
  # check reads it as unsealed content: gone before anything verifies the app.
  if [ "$SWAP_TO" = "$APP/Contents" ]; then rm -rf "$SWAP_TO.previous"; fi
  return 0
}
swap_in "$BUILT" "$APP" || exit 1
# The receipt. "Why is the app not what I installed?" should be one
# `tail`, not forensics across four worktrees — which is what it cost the
# first time this happened.
mkdir -p "$HOME/.moe/logs"
printf '%s  %s  commit %s%s  from %s  (pid %s)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)" "${NEW_COMMIT:-unstamped}" \
  "${DIRTY:+ +dirty, MOE_ALLOW_DIRTY was set}" "$REPO" "$$" \
  >> "$HOME/.moe/logs/installs.log"
rm -rf "$SWAP_TO.previous"

# The receipt above records what was installed. It cannot record what macOS
# will LAUNCH, and those turned out to be different things for two days.
#
# An app's identity to macOS is its CFBundleIdentifier, and Launch Services
# had ~130 bundles registered as com.memoe.app — every worktree's dist/,
# every temp directory a test built one in. Launching "Moe" could produce any
# of them, so the owner's Moe "went back to an old version" perhaps thirty
# times while /Applications was correct the whole time and every install
# guard passed. An install that leaves that true has not finished.
#
# `-u` on the bundle just built as well: it is a release-identity copy of the
# app sitting in dist/, i.e. the exact shape of the thing that caused this.
#
# **This block is ADVICE, and on 2026-09-10 it failed the install.**
# `only-one-moe.sh --check` exits 1 when squatters remain -- correctly, it is
# a check -- and `set -euo pipefail` at the top of this file turned that into
# the death of a script that had already swapped the bundle and written its
# receipt. The person was told "the install stopped ... your Moe was not
# replaced" by catch-up.sh, with **no reason printed above it**, and
# /Applications/Memoe.app was the new build the whole time. That is this
# repository's own recorded bug -- "catch-up.sh told the owner his Moe was
# not replaced after replacing it" -- returning by a different route, and it
# is the false-reassurance direction inverted: a person who believes a good
# install failed will install again, or worse, go looking for what broke.
#
# Line 100 of this same file already knows the hazard in words: "Spelled out
# as an if rather than `cmd && var=...`: under `set -e` ...". The rule this
# earns, and it is not "add || true": **a step that can only ever print
# advice must not be able to decide the outcome.** So the whole block runs in
# a subshell with errexit off, and the line that says the install succeeded
# is printed BEFORE the advice rather than after it -- the fact is not
# contingent on the footnote.
echo "✓ Alfie is installed in your Applications folder"
if [ "$MOE_DEV" != 1 ] && [ -x "$REPO/scripts/only-one-moe.sh" ]; then
  (
    set +e
    "$REPO/scripts/only-one-moe.sh" >/dev/null 2>&1
    swept="$("$REPO/scripts/only-one-moe.sh" --check 2>&1 \
             | sed -n 's/.*squatters *\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [ -n "$swept" ] && [ "$swept" != 0 ]; then
      echo "› note: $swept other bundle(s) are still registered as Alfie; ./scripts/only-one-moe.sh"
    fi
  ) || true
fi

# And put it back the way it was found. Killing someone's running app and not
# starting it again leaves them staring at a Mac with no Moe on it, wondering
# what happened — which is precisely how this was reported.
if [ "$WAS_RUNNING" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  open -a "$APP" >/dev/null 2>&1 || true
  echo "✓ started it again"
fi

# 5. Background jobs.
#
# ProgramArguments[0] is the app binary, not /bin/bash, and that is the whole
# point: macOS attributes Full Disk Access and Automation to the launching
# process. A bash-launched job asks for permission as Apple's shell, which has
# no usage strings and which you cannot usefully grant — so the Messages,
# Calendar, Notes and Reminders connectors would be denied forever no matter
# what you ticked in System Settings.
AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$AGENTS"

# AGENT_HUMAN is what the user reads. The label — com.moe.sync and friends —
# is what launchd needs and means nothing to anyone else; it only appears when
# something has gone wrong and the label is the thing you need to fix it.
AGENT_HUMAN=""
write_agent() { # label, interval (0 = KeepAlive, -1 = run at load only), program args…
  local label="$1" interval="$2"; shift 2
  local plist="$AGENTS/$label.plist"

  # Built with plistlib so paths containing &, < or ' can't produce a plist
  # that launchd silently refuses to parse.
  # AGENT_ENV, when set, is NAME=VALUE pairs separated by spaces. It is how
  # the scheduled run is told it may elect the hourly digest, so that a person
  # typing `Moe --sync` — or the Settings pane's Refresh now — does not spend
  # a model call the user never asked for.
  python3 - "$plist" "$label" "$interval" "$HOME_DIR/logs/$label.err" "${AGENT_ENV:-}" "$@" <<'PY'
import plistlib, sys
plist, label, interval, errlog, envspec, *args = sys.argv[1:]
d = {"Label": label, "ProgramArguments": args, "RunAtLoad": True,
     "StandardErrorPath": errlog}
if envspec.strip():
    d["EnvironmentVariables"] = dict(
        pair.split("=", 1) for pair in envspec.split() if "=" in pair)
if int(interval) > 0:
    d["StartInterval"] = int(interval)
elif int(interval) == 0:
    d["KeepAlive"] = True
with open(plist, "wb") as f:
    plistlib.dump(d, f)
PY

  launchctl bootout "gui/$UID/$label" 2>/dev/null || true
  if launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null \
     || launchctl load "$plist" 2>/dev/null; then
    echo "✓ ${AGENT_HUMAN:-$label}"
  else
    # Reported, not swallowed: "Moe doesn't know anything" is almost always
    # this, and silently claiming success makes it unfindable. This is the one
    # place a command to type is unavoidable — there is no other way to load it.
    echo "✗ ${AGENT_HUMAN:-$label} — this didn't start. To try it by hand:"
    echo "      launchctl bootstrap gui/$UID $plist"
  fi
}

# One agent, not two. com.moe.sync and com.moe.digest ran the same binary on
# two timers, so System Settings listed one product three times under "Allow
# in Background". The hourly digest is gone altogether — Hermes's
# `moe-proactive` cron job does that work — so this is one plain timer.
# Re-running this script used to resurrect both — and because the app writes
# its migration marker once, nothing would ever have removed them again.
# com.moe.assistant is the login item a pre-rename copy wrote. The bundle
# identifier is com.memoe.app now, so nothing else would ever remove it.
for stale in com.moe.sync com.moe.digest com.moe.assistant; do
  launchctl bootout "gui/$UID/$stale" 2>/dev/null || true
  rm -f "$AGENTS/$stale.plist"
done

AGENT_HUMAN="Alfie will keep up with your calendar and messages every 10 minutes"
write_agent com.moe.jobs 600 "$APP/Contents/MacOS/Moe" --sync

# 6. Start at login. A menu-bar assistant that is not running is one the
# user forgets exists, so the default is yes; the question is only asked when
# there is a terminal to ask at (a piped or scripted install takes the
# default). Answering n keeps the old behaviour: you open it yourself.
yn=y
if [ -t 0 ]; then
  # `read` returns 1 at EOF and `set -e` would abort the whole install here.
  read -r -p "Start Alfie automatically at login? [Y/n] " yn || yn=y
fi
if [[ ! "${yn:-y}" =~ ^[Nn] ]]; then
  # RunAtLoad only. `open` exits at once, so KeepAlive would re-run it every
  # few seconds — and each run is a "reopen" that drags the user to Moe's Space.
  AGENT_HUMAN="Alfie will start when you log in"
  write_agent "$BUNDLE_ID" -1 /usr/bin/open -a "$APP"
fi

# The Telegram bot that used to run as com.moe.bot is now Hermes's own
# telegram platform (configure-hermes.py carries the BotFather token across).
# An older install's job would fight it for the same bot, so it goes —
# unconditionally: a plist that isn't loaded right now is still RunAtLoad,
# and would bring the bot back at next login. soul.sh is stale the same way.
stale=""
for f in "$AGENTS/com.moe.bot.plist" "$HOME_DIR/bot/telegram_bot.py" "$HOME_DIR/soul.sh"; do
  [ -e "$f" ] && stale="$stale $f"
done
launchctl bootout "gui/$UID/com.moe.bot" >/dev/null 2>&1 || true
rm -f "$AGENTS/com.moe.bot.plist" "$HOME_DIR/bot/telegram_bot.py" "$HOME_DIR/soul.sh"
if [ -n "$stale" ]; then
  echo "✓ tidied away what an older Alfie left behind"
fi

echo
echo "› Reading your calendar and reminders so Alfie starts out knowing something…"
"$APP/Contents/MacOS/Moe" --sync >/dev/null 2>&1 || true

open "$APP"

# 7. Make Hermes Moe's core. configure-hermes.py merges Moe's config into
# ~/.hermes, carries a Telegram token across, migrates memory, and ends by
# checking for the Claude sign-in. Non-fatal: exit 2 means everything was
# written and only the sign-in is missing — the app asks for that with one
# button when it opens — and any other failure is one line here, with the
# full transcript in ~/.moe/logs/install.log, not a wall of text.
HERMES_CONFIGURED=skipped
if [ "$HERMES_OK" = 1 ] && [ -x "$HOME_DIR/hermes/configure-hermes.py" ]; then
  {
    echo "── configure-hermes.py $(date '+%Y-%m-%d %H:%M:%S') ──"
    # A hung merge (a Hermes CLI waiting on something) must not hold the
    # installer: five minutes, then it is killed and reported as unfinished.
    # perl, because stock macOS has no `timeout`.
    /usr/bin/perl -e 'alarm 300; exec @ARGV or die "$!\n"' -- "$HOME_DIR/hermes/configure-hermes.py" </dev/null 2>&1
    echo "exit=$?"
  } >> "$HOME_DIR/logs/install.log" 2>&1 || true
  case "$(tail -n 1 "$HOME_DIR/logs/install.log" 2>/dev/null)" in
    exit=0) HERMES_CONFIGURED=yes;    echo "✓ Alfie's core is set up" ;;
    exit=2) HERMES_CONFIGURED=signin; echo "✓ Alfie's core finishes setting up once you sign in (it asks when it opens)" ;;
    *)      HERMES_CONFIGURED=no;     echo "… Setting up Alfie's core didn't finish — Alfie tries again when it opens" ;;
  esac
fi

# The closing words. No script paths: everything a new user does from here
# happens inside the app (Settings › Connections runs the connect scripts,
# the sign-in has its own button) or in System Settings. The talk key on a
# fresh install is right ⌥ — Config.talkKey's default, which Settings › Voice
# can change later, and the same words the onboarding screen uses
# (OnboardingWindow.holdKey).
cat <<EOF

  Alfie is in your menu bar. Hold right ⌥ and talk; let go when you're done.
  Settings → Connections to add Gmail, Slack, Telegram and more.

  macOS asks for the microphone, Notes and Calendar the first time — say yes.
  (Messages and call history also need Full Disk Access for Alfie.)

EOF

# The sign-in is a browser step Moe handles itself, and it has not happened
# yet. Saying "installed" without saying this reads as "done", and then
# nothing works and nobody knows why.
if [ "$CLAUDE_OK" = 1 ]; then
cat <<EOF
  One thing is still yours to do: sign in to your Claude account. Alfie asks the
  first time you need it and opens the page in your browser — there is nothing
  to find or paste in a terminal.

EOF
fi

# The one wording, printed rather than copied so this script cannot drift from
# the app, the website and the ship checklist. first-open-notice.sh reads
# docs/FIRST-OPEN.md; scripts/test-first-open.sh proves the other three match.
if [ -x "$REPO/scripts/first-open-notice.sh" ]; then
  echo "  ────────────────────────────────────────────────────────────────────"
  "$REPO/scripts/first-open-notice.sh" "  " || true
  echo
fi

# Only true on the runs where it is true. With the Developer ID or the
# certificate above, the designated requirement pins the team or the
# certificate and grants survive an update;
# without it the app is ad-hoc signed, the requirement pins the code hash, and
# every update is a new app to macOS.
if [ "$STABLE_SIGNATURE" != 1 ]; then
cat <<EOF
  One more thing, and only on this Mac: Alfie could not make itself a signing
  certificate, so macOS will ask for the microphone, Accessibility and the rest
  again after an update. Nothing is broken — say yes again. Running this
  installer again is what fixes it for good.

EOF
fi

if [ "$CLAUDE_OK" != 1 ]; then
cat <<EOF
  ✗ Claude Code isn't installed, and Alfie can't think without it. Install it and
    run this installer again (safe to repeat):
        curl -fsSL $CLAUDE_INSTALLER_URL | bash

EOF
fi

if [ "$HERMES_OK" != 1 ]; then
cat <<EOF
  ✗ Alfie's core isn't installed, so Alfie won't be able to answer. Fix what the ✗
    line above said, then run this installer again (safe to repeat).

EOF
fi

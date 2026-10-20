#!/bin/bash
# reseed-hermes.sh <bundled-seed> [--home <hermes-home>] [--to <sha>] [--check]
#
# Lays the Hermes seed this copy of Memoe carries over the seed already on the
# Mac, when the two differ in what their venv CONTAINS — the one move
# refresh-hermes-seed.sh refuses by design.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# A pin bump that touches uv.lock, pyproject.toml or .python-version reached
# nobody who already had Moe. refresh-hermes-seed.sh moves a seed by
# rewriting tracked source and NEVER rebuilds a venv (a rebuild on the
# person's Mac means PyPI, a uv-managed interpreter that is not the seed's,
# and wheels nobody signed), so it refuses; HermesSeed.installIfNeeded lays a
# seed only where there is none. The release carried the new seed in
# Contents/Resources and nothing ever put it down. Step A of the 2026-10
# catch-up (0479a430fb) already moved the lockfiles; the Python 3.14 move
# (Step B) moves the interpreter, the venv layout and the tool store too.
#
# The answer is not to rebuild anything on the Mac. It is to put down the
# venv that was built, checked and signed with the release — the same bytes a
# fresh install gets — exactly as HermesSeed.swift does at first launch, and
# keep everything else in ~/.hermes.
#
# ── What it replaces, and what it never touches ─────────────────────────────
#
#   replaced   hermes-agent/   the code + its venv (a seed has no .git, so no
#                              branch or unpushed work can be in it)
#              tools/          Hermes's pm tool store (new with the 3.14 seed)
#   carried    hermes-agent/scripts/whatsapp-bridge/node_modules, when the new
#              seed has none — the bridge's npm install, made on this Mac
#   untouched  everything else: config.yaml, .env, auth, state.db, sessions,
#              memories, skills, plugins, cron, whatsapp/, bin/, and the old
#              python/ and node/ (a uv tool such as browser-use may still be
#              built on that python — removing it is what broke browsing for
#              three days on 2026-09-25)
#
# Order, so that every failure leaves a Hermes that runs:
#   1. clone the bundled seed beside the live one (APFS clonefile: no bytes)
#   2. substitute @HERMES_ROOT@ the way HermesSeed.substitute does
#   3. start the NEW Python from the staging copy — refuse if it cannot
#   4. move the live parts aside, move the new ones in (renames)
#   5. run `hermes --version` from the final place, offline-safe
#      (HERMES_DISABLE_LAZY_INSTALLS=1) — on failure put the old parts back
#   6. only then delete what was moved aside
#
# Exit 0 = the seed at <hermes-home> is now the bundled one. Anything else =
# nothing changed (or it was put back), with the reason on stderr.
set -u

usage() {
  echo "usage: reseed-hermes.sh <bundled-seed> [--home <hermes-home>] [--to <sha>] [--check]" >&2
  exit 2
}

BUNDLE=""
HHOME="${HERMES_HOME:-$HOME/.hermes}"
TO=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home)  HHOME="${2:-}"; shift 2 || usage ;;
    --to)    TO="${2:-}"; shift 2 || usage ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage ;;
    -*) echo "✗ unknown option $1" >&2; usage ;;
    *)  [ -n "$BUNDLE" ] && usage; BUNDLE="$1"; shift ;;
  esac
done
[ -n "$BUNDLE" ] || usage

die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }
say() { echo "› $*"; }

PLACEHOLDER='@HERMES_ROOT@'
AGENT="$HHOME/hermes-agent"

STAGE="$HHOME/.hermes-reseeding"
ASIDE="$HHOME/.hermes-reseed-previous"
# ── 0. A run that died between the moves ────────────────────────────────────
# The live parts may be in $ASIDE. Put them back BEFORE anything asks what is
# installed — otherwise the missing hermes-agent reads as "no Hermes here" and
# the person's tree is left in a hidden directory. Never deleted blind.
if [ -e "$ASIDE" ] && [ "$CHECK" = 0 ]; then
  if [ ! -d "$AGENT" ] && [ -d "$ASIDE/hermes-agent" ]; then
    mv "$ASIDE/hermes-agent" "$AGENT" || die "found an interrupted reseed and could not restore $AGENT from $ASIDE"
    say "put back $AGENT from an interrupted reseed"
  fi
  if [ ! -d "$HHOME/tools" ] && [ -d "$ASIDE/tools" ]; then mv "$ASIDE/tools" "$HHOME/tools" || true; fi
  rm -rf "$ASIDE"
fi

# ── 1. What is being laid, over what ────────────────────────────────────────
[ -d "$BUNDLE/hermes-agent" ] && [ -d "$BUNDLE/tools" ] \
  || die "$BUNDLE is not a 3.14 Hermes seed (it needs hermes-agent/ and tools/); nothing was changed"
NEW="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$BUNDLE/hermes-agent/.moe-seed-commit" 2>/dev/null | head -1)"
case "$NEW" in ""|*[!0-9a-f]*) die "the bundled seed has no readable .moe-seed-commit; nothing was changed" ;; esac
[ ${#NEW} -eq 40 ] || die "the bundled seed's stamp is not a full sha; nothing was changed"
if [ -n "$TO" ] && [ "$TO" != "$NEW" ]; then
  die "the bundled seed is ${NEW:0:10}, not the pin ${TO:0:10} — this Memoe carries a different Hermes than it pins.
  Nothing was changed. (build.sh's check-hermes-seed-commit.sh is the gate that should have refused this build.)"
fi

[ -d "$AGENT" ] || die "no Hermes at $AGENT — a Mac with none gets the seed from HermesSeed at launch; nothing was changed"
if [ -e "$AGENT/.git" ]; then
  die "$AGENT is a git checkout, not a seed — install-hermes.sh moves a checkout with uv; this never replaces one,
  because it may hold somebody's branches and unpushed work. Nothing was changed."
fi
OLD="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$AGENT/.moe-seed-commit" 2>/dev/null | head -1)"
case "$OLD" in
  ""|*[!0-9a-f]*) die "$AGENT has no readable .moe-seed-commit, so nothing can say what it is; an unknown tree is not one to overwrite. Nothing was changed." ;;
esac
if [ "$OLD" = "$NEW" ] && [ -d "$HHOME/tools" ]; then
  ok "$AGENT is already the bundled Hermes (${NEW:0:10}); nothing to lay"
  exit 0
fi

LIVE_PY="$(ls -d "$AGENT"/.venv/lib/python3.* 2>/dev/null | head -1)"
NEW_PY="$(ls -d "$BUNDLE"/hermes-agent/.venv/lib/python3.* 2>/dev/null | head -1)"
say "laying the bundled Hermes ${NEW:0:10} ($(basename "${NEW_PY:-?}")) over ${OLD:0:10} ($(basename "${LIVE_PY:-?}")) at $HHOME"
if [ "$CHECK" = 1 ]; then
  ok "--check: would replace hermes-agent/ and tools/; nothing was changed"
  exit 0
fi

rm -rf "$STAGE"

# ── 2. Clone and substitute ─────────────────────────────────────────────────
mkdir -p "$STAGE" || die "cannot write to $HHOME"
for part in hermes-agent tools; do
  cp -Rc "$BUNDLE/$part" "$STAGE/$part" 2>/dev/null || cp -R "$BUNDLE/$part" "$STAGE/$part" \
    || { rm -rf "$STAGE"; die "could not copy $part out of $BUNDLE; nothing was changed"; }
done
# HermesSeed.substitute, line for line: bin/* or a text extension, under 4 MB,
# UTF-8 — and the executable bits on bin/* put back.
if ! python_out="$(/usr/bin/python3 - "$STAGE" "$HHOME" "$PLACEHOLDER" <<'PYEOF' 2>&1
import os, sys
stage, real, token = sys.argv[1:4]
ext = {"cfg", "pth", "json", "txt", "py", "sh", "toml", "yaml", "yml"}
n = 0
for d, _, files in os.walk(stage):
    isbin = os.path.basename(d) == "bin"
    for f in files:
        p = os.path.join(d, f)
        if os.path.islink(p):
            continue
        e = f.rsplit(".", 1)[-1] if "." in f else ""
        if isbin:
            try:
                os.chmod(p, 0o755)
            except OSError:
                pass
        if not (isbin or e in ext):
            continue
        try:
            raw = open(p, "rb").read()
        except OSError:
            continue
        if len(raw) >= 4_000_000 or token.encode() not in raw:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        mode = os.stat(p).st_mode
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text.replace(token, real))
        os.chmod(p, mode)
        n += 1
left = []
for d, _, files in os.walk(stage):
    for f in files:
        p = os.path.join(d, f)
        if os.path.islink(p):
            continue
        try:
            if os.path.getsize(p) < 8_000_000 and token.encode() in open(p, "rb").read():
                left.append(p)
        except OSError:
            pass
if left:
    print("still names the seed's build path: %s" % left[0])
    sys.exit(1)
print(n)
PYEOF
)"; then
  rm -rf "$STAGE"
  die "the placeholder rewrite did not finish ($python_out); nothing was changed"
fi

# ── 3. The new Python starts, from its own store, before anything moves ─────
PY="$STAGE/hermes-agent/.venv/bin/python"
base="$("$PY" -c 'import encodings, ssl, json, sys; print(sys.base_prefix)' 2>&1)" || {
  rm -rf "$STAGE"; die "the bundled seed's Python cannot start here ($base); nothing was changed"; }
case "$base" in
  "$STAGE"/tools/*|"$(cd "$STAGE" && pwd -P)"/tools/*) ;;
  *) rm -rf "$STAGE"; die "the bundled seed's Python started from $base, outside the seed; nothing was changed" ;;
esac

# ── 4. Carry what this Mac built inside the old tree ────────────────────────
BRIDGE=scripts/whatsapp-bridge/node_modules
if [ -d "$AGENT/$BRIDGE" ] && [ ! -d "$STAGE/hermes-agent/$BRIDGE" ] && [ -d "$STAGE/hermes-agent/scripts/whatsapp-bridge" ]; then
  cp -Rc "$AGENT/$BRIDGE" "$STAGE/hermes-agent/$BRIDGE" 2>/dev/null || cp -R "$AGENT/$BRIDGE" "$STAGE/hermes-agent/$BRIDGE" \
    || say "could not carry the WhatsApp bridge's node_modules across; \`hermes whatsapp\` reinstalls them"
fi

# ── 5. Swap, by rename ──────────────────────────────────────────────────────
restore() {
  [ -d "$ASIDE/hermes-agent" ] || return 0
  rm -rf "$AGENT.reseed-failed"
  [ -d "$AGENT" ] && mv "$AGENT" "$AGENT.reseed-failed"
  mv "$ASIDE/hermes-agent" "$AGENT"
  if [ -d "$ASIDE/tools" ]; then rm -rf "$HHOME/tools"; mv "$ASIDE/tools" "$HHOME/tools"
  elif [ "$HAD_TOOLS" = 0 ]; then rm -rf "$HHOME/tools"; fi
  rm -rf "$AGENT.reseed-failed" "$ASIDE"
}
HAD_TOOLS=0
mkdir -p "$ASIDE" || { rm -rf "$STAGE"; die "cannot write $ASIDE; nothing was changed"; }
mv "$AGENT" "$ASIDE/hermes-agent" || { rm -rf "$STAGE" "$ASIDE"; die "could not move $AGENT aside; nothing was changed"; }
if [ -d "$HHOME/tools" ]; then
  HAD_TOOLS=1
  mv "$HHOME/tools" "$ASIDE/tools" || { restore; rm -rf "$STAGE"; die "could not move $HHOME/tools aside; put the old Hermes back"; }
fi
if ! { mv "$STAGE/hermes-agent" "$AGENT" && mv "$STAGE/tools" "$HHOME/tools"; }; then
  restore; rm -rf "$STAGE"
  die "could not move the new Hermes into place; put the old one back"
fi
rmdir "$STAGE" 2>/dev/null || rm -rf "$STAGE"

# ── 6. It runs from where it now is ─────────────────────────────────────────
# Not `| head -1`: a pipeline reports head's status, and this has to be the
# status of the Hermes it just put down.
out="$(cd / && env HERMES_HOME="$HHOME" HERMES_DISABLE_LAZY_INSTALLS=1 "$AGENT/.venv/bin/hermes" --version 2>&1)"
rc=$?
ver="$(printf '%s\n' "$out" | head -1)"
if [ "$rc" -ne 0 ] || ! printf '%s' "$ver" | grep -q "Hermes"; then
  restore
  die "the new Hermes did not start from $AGENT (${ver:-no output}); the old one is back in place"
fi
# ── 7. The browser the old store already had ────────────────────────────────
# The bundled seed carries no Chromium (slim-hermes-tools.py). When the store
# just replaced held the build the new pin names — a move between two 3.14
# seeds — it is cloned across (offline, no second 330 MB). Otherwise the new
# store stays `.browser-pending` and install-hermes.sh / the next launch fetch
# it (fetch-hermes-browser.sh). Never fatal: Hermes runs without it.
FETCH="${MOE_FETCH_BROWSER:-$(cd "$(dirname "$0")" && pwd)/fetch-hermes-browser.sh}"
if [ -f "$HHOME/tools/.browser-pending" ] && [ -d "$ASIDE/tools" ] && [ -x "$FETCH" ]; then
  if bout="$("$FETCH" --home "$HHOME" --reuse-from "$ASIDE/tools" --no-download 2>&1)"; then
    say "$(printf '%s\n' "$bout" | grep '^✓' | tail -1 | sed 's/^✓ //')"
  else
    say "the browser was not carried across ($(printf '%s\n' "$bout" | grep '^›' | head -1 | sed 's/^› //')); it is fetched next"
  fi
fi
rm -rf "$ASIDE"
ok "Hermes at $AGENT is now the bundled ${NEW:0:10}: $ver"

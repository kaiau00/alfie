#!/bin/bash
# Make /Applications/Memoe.app the only thing on this Mac that macOS will
# launch as Moe.
#
# ── The bug this exists for, which took thirty sightings to find ───────────
#
# The owner's Moe "went back to an old version" perhaps thirty times over two
# days. Every guard written for it asked whether an INSTALL should be allowed,
# and every one of them worked: the receipts in ~/.moe/logs/installs.log show
# no install ever moving /Applications backwards, and on the day this was
# written the installed app was correct and current the whole time.
#
# Nothing was being installed. `ps` showed the only Moe running on the Mac was
#
#     /Users/<you>/moe/dist/Memoe.app
#
# a build from a worktree, made the previous day, carrying no commit stamp —
# and the login agent that started it says `open -a /Applications/Memoe.app`.
#
# The reason is Launch Services. An app's identity to macOS is its
# CFBundleIdentifier, and `lsregister -dump` had about 130 bundles claiming
# `com.memoe.app`: every worktree's dist/, every dist/releases/N/, every
# temp directory a test ever built one in, and two old backups under ~/.moe.
# LS resolves a launch by identifier and may answer with any of them. So the
# Dock icon, the menu bar, the hotkeys and the login item could all belong to
# a build nobody installed, with no way to see it from the outside — the
# version string is identical, the icon is identical, the name is identical.
#
# This unregisters every one of them except the installed app. It does not
# delete anybody's build: a worktree's dist/ is somebody's work in progress,
# and taking it away is not this script's business. It removes their claim to
# BE Moe, which was never theirs.
#
#   ./scripts/only-one-moe.sh            report and fix
#   ./scripts/only-one-moe.sh --check    report only, non-zero if squatters
#
# Related: Sources/Moe/RunningFromHere.swift makes a build REFUSE to run as
# the release identity from anywhere but /Applications, which stops new ones
# from ever taking the Dock. This script is what clears the ones already
# registered, including builds too old to contain that check.
set -uo pipefail

LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALLED="/Applications/Memoe.app"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -x "$LSR" ] || { echo "✗ lsregister is not where it should be: $LSR" >&2; exit 1; }

DUMP="$(mktemp)"
trap 'rm -f "$DUMP"' EXIT
"$LSR" -dump > "$DUMP" 2>/dev/null

# Bundles registered under the RELEASE identifier. Moe Dev has its own
# identifier and is not a squatter — that is the entire point of it.
# `mapfile` does not exist here: macOS ships bash 3.2, and a script that
# reaches for bash 4 dies at the first line that uses it — several checks in,
# with everything above it already printed and looking fine.
squatters=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ "$p" = "$INSTALLED" ] && continue
  case "$p" in *"/Memoe Dev.app") continue ;; esac
  squatters=("${squatters[@]+"${squatters[@]}"}" "$p")
done < <(grep -oE "path: +[^ ].*/Memoe\.app" "$DUMP" | sed 's/path: *//' | sort -u)

echo "Moe bundles macOS would accept as com.memoe.app"
echo "──────────────────────────────────────────────────"
echo "  installed   $INSTALLED"
echo "  squatters   ${#squatters[@]}"
if [ "${#squatters[@]}" -gt 0 ]; then
  printf '    %s\n' "${squatters[@]+"${squatters[@]}"}" | head -8
  [ "${#squatters[@]}" -gt 8 ] && echo "    … and $(( ${#squatters[@]} - 8 )) more"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  [ "${#squatters[@]}" -eq 0 ] && { echo "✓ only the installed Moe can be launched as Moe"; exit 0; }
  echo "✗ $(printf '%s' "${#squatters[@]}") other bundle(s) could be launched as Moe. Run ./scripts/only-one-moe.sh" >&2
  exit 1
fi

if [ "${#squatters[@]}" -eq 0 ]; then
  # Same sentence as the sweeping path, deliberately: "nothing to do" and
  # "swept and verified" are the same fact about the machine, and a caller
  # (or a test) should not have to parse two shapes to learn it.
  echo "✓ nothing to do; still registered elsewhere: 0"
  echo "✓ only $INSTALLED can be launched as Moe now"
  exit 0
fi

echo
for p in "${squatters[@]+"${squatters[@]}"}"; do
  "$LSR" -u "$p" >/dev/null 2>&1
done
# Re-assert the installed one AFTER the removals, so the identifier resolves
# to it and not to nothing: an app that is registered nowhere does not open
# from the Dock either.
[ -d "$INSTALLED" ] && "$LSR" -f "$INSTALLED" >/dev/null 2>&1

# Say what is true NOW rather than what was asked for — an unregister can
# fail silently, and a script that reports its intention is the kind of check
# that passes forever.
"$LSR" -dump > "$DUMP" 2>/dev/null
left=0
while read -r p; do
  [ -n "$p" ] || continue
  [ "$p" = "$INSTALLED" ] && continue
  case "$p" in *"/Memoe Dev.app") continue ;; esac
  left=$((left + 1))
done < <(grep -oE "path: +[^ ].*/Memoe\.app" "$DUMP" | sed 's/path: *//' | sort -u)

echo "unregistered ${#squatters[@]}; still registered elsewhere: $left"
if [ "$left" -eq 0 ]; then
  echo "✓ only $INSTALLED can be launched as Moe now"
else
  echo "› $left remain — LS re-registers a bundle when it is next run or scanned;"
  echo "  the lasting fix is that they refuse to run (RunningFromHere.swift)."
fi

mkdir -p "$HOME/.moe/logs"
printf '%s  %s  unregistered %d Moe bundle(s), %d left\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)" "${#squatters[@]}" "$left" \
  >> "$HOME/.moe/logs/installs.log"

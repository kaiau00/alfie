#!/bin/bash
# Proves a downloaded Moe can hear and speak on a Mac that has never fetched a
# model — the thing the bundling exists for, and the one claim that cannot be
# checked by looking at file sizes.
#
# It moves this Mac's two FluidAudio caches aside, links the app's own copies
# into the empty roots, and loads every model with `ModelHub.offlineMode` on,
# so any attempted download is a typed error rather than a silent success.
# The caches are put back on the way out, whatever happens — including a
# Ctrl-C, which is what the trap is for.
#
#   1. the models are in the bundle
#   2. nothing personal rode along with them
#   3. an empty cache gets links, not copies
#   4. every model loads with the network refused
#   5. a real download already there is never touched
#   6. a link left over from an older app is repointed
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
BIN="$ROOT/dist/Alfie.app/Contents/MacOS/Moe"
MODELS="$ROOT/dist/Alfie.app/Contents/Resources/Models"
APP_SUPPORT="$HOME/Library/Application Support/FluidAudio/Models"
CACHE="$HOME/.cache/fluidaudio/Models"
STAMP=$(date +%s)
SCRATCH="${MOE_TEST_SCRATCH:-$(mktemp -d)}"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

moved_app=0
moved_cache=0
# Restoring must be safe to run more than once, and it is run more than once:
# the INT handler calls it and then `exit`s, which fires the EXIT handler,
# which calls it again. An earlier version put `rm -rf "$APP_SUPPORT"` outside
# the "is there something to move back" guard, so the second call deleted the
# 461 MB cache the first call had just restored — in the suite whose header
# promises the caches come back "whatever happens, including a Ctrl-C".
#
# So: each root is claimed once, released once, and `restored` records that it
# is done. Nothing is removed unless there is a saved copy to put in its place,
# except the scratch links this suite made itself — and those only while the
# root is still ours.
restored=0
restore() {
  [ "$restored" = 1 ] && return 0
  restored=1
  if [ "$moved_app" = 1 ]; then
    if [ -d "$APP_SUPPORT.moved-$STAMP" ]; then
      rm -rf "$APP_SUPPORT"
      mv "$APP_SUPPORT.moved-$STAMP" "$APP_SUPPORT"
    elif [ -z "$(find "$APP_SUPPORT" -maxdepth 1 ! -type l ! -path "$APP_SUPPORT" 2>/dev/null)" ]; then
      # Nothing was moved aside, so this root did not exist before. It holds
      # only the links this suite made; taking it away leaves the Mac as it
      # was. Anything that is not a link is not ours and stays.
      rm -rf "$APP_SUPPORT"
    fi
  fi
  if [ "$moved_cache" = 1 ]; then
    if [ -d "$CACHE.moved-$STAMP" ]; then
      rm -rf "$CACHE"
      mv "$CACHE.moved-$STAMP" "$CACHE"
    elif [ -z "$(find "$CACHE" -maxdepth 1 ! -type l ! -path "$CACHE" 2>/dev/null)" ]; then
      rm -rf "$CACHE"
    fi
  fi
  rm -rf "$SCRATCH"
  return 0
}
# `trap restore INT` alone would restore and then *continue at the next
# statement* — which, if the interrupt landed in step 4, is step 5's `rm -rf`
# of a directory that is once again the developer's real one. Exit explicitly,
# and let the idempotence above absorb the second call that `exit` triggers.
trap restore EXIT
trap 'restore; exit 130' INT TERM

if [ ! -x "$BIN" ]; then
  echo "✗ no dist/Alfie.app — run ./build.sh first" >&2; exit 1
fi

echo "1. the models are in the bundle"
if [ -d "$MODELS" ]; then
  ok "Contents/Resources/Models ($(du -sh "$MODELS" | cut -f1))"
  # Not a list repeated here. It used to be — six names, hardcoded, while
  # scripts/fetch-models.sh named eight — so this said "all six present"
  # over a bundle missing silero-vad and campplus and carrying 937 MB of
  # two engines deleted from the lists three days earlier. A check that
  # enumerates its own expectations agrees with itself and nothing else.
  if ./scripts/check-bundled-models.sh "$MODELS" >/dev/null 2>&1; then
    ok "the bundled set is exactly what the lists name"
  else
    bad "the bundled set does not match scripts/fetch-models.sh:"
    ./scripts/check-bundled-models.sh "$MODELS" 2>&1 | sed 's/^/      /'
  fi
  find "$MODELS" -type l 2>/dev/null | grep -q . \
    && bad "the bundled models contain symlinks — they would dangle on any other Mac" \
    || ok "they are real directories, not links"
else
  echo "  … this build has no bundled models (./scripts/fetch-models.sh, then ./build.sh)"
  echo; echo "$pass passed, $fail failed"; exit 0
fi

echo "2. nothing personal rode along"
# These weights are the same for everyone. Anything user-shaped in here would
# be shipped to every person who downloads Moe.
if find "$MODELS" -type f \( -name '*.json' -o -name '*.txt' -o -name '*.yaml' \) -print0 2>/dev/null \
   | xargs -0 grep -lIE '/Users/[a-z]|BEGIN [A-Z ]*PRIVATE KEY' 2>/dev/null | head -1 | grep -q .; then
  bad "a personal path or key is inside the model files:"
  find "$MODELS" -type f \( -name '*.json' -o -name '*.txt' -o -name '*.yaml' \) -print0 2>/dev/null \
    | xargs -0 grep -lIE '/Users/[a-z]' 2>/dev/null | sed 's/^/      /' | head -5
else
  ok "no home paths, addresses or keys in any model metadata"
fi

echo "3. an empty cache gets links, not copies"
# Counted from the bundle rather than written down: this said six for as
# long as six models shipped, and failed the day a seventh did — which is
# a test breaking on the change it exists to check.
WANT=$(ls "$MODELS" 2>/dev/null | wc -l | tr -d ' ')
SB="$SCRATCH/roots"
out="$("$BIN" --link-models "$SB" 2>&1)"
case "$out" in *"linked $WANT"*) ok "$WANT links made ($out)" ;; *) bad "unexpected: $out (wanted $WANT)" ;; esac
n=$(find "$SB" -type l | wc -l | tr -d ' ')
[ "$n" = "$WANT" ] && ok "all $WANT are symlinks — no gigabyte copied" || bad "$n symlinks, expected $WANT"
sz=$(du -sk "$SB" | cut -f1)
[ "$sz" -lt 200 ] && ok "the links weigh ${sz}K" || bad "the 'links' weigh ${sz}K"

echo "4. every model loads with the network refused"
# The real test. Both caches are moved aside so nothing already downloaded can
# answer, the bundle is linked into the empty roots, and downloads are refused.
# `moved` means "this root is ours for the duration", not "there was
# something here". On a Mac that has never downloaded a FluidAudio model —
# a fresh machine, or the stranger this suite exists to simulate — the old
# version set neither flag, created the roots anyway, linked six symlinks
# into the developer's *real* cache, and then bailed out at step 5 leaving
# them there, pointing into a build directory the next ./build.sh deletes.
# That is the dangling-link breakage this very commit fixed elsewhere.
# The flag goes up *before* the move, not after. An interrupt landing between
# a successful `mv` and the assignment would otherwise leave the developer's
# real cache parked under a .moved-<stamp> name with nothing that knows to put
# it back — not lost, but indistinguishable from lost at the moment it
# matters. restore() is written to cope with a flag set for a move that never
# happened; it cannot cope with a move that nothing recorded.
moved_app=1
if [ -d "$APP_SUPPORT" ]; then
  mv "$APP_SUPPORT" "$APP_SUPPORT.moved-$STAMP" || { echo "✗ could not move $APP_SUPPORT aside" >&2; exit 1; }
fi
moved_cache=1
if [ -d "$CACHE" ]; then
  mv "$CACHE" "$CACHE.moved-$STAMP" || { echo "✗ could not move $CACHE aside" >&2; exit 1; }
fi
mkdir -p "$APP_SUPPORT" "$CACHE"

link_out="$("$BIN" --link-models 2>&1)"
case "$link_out" in *"linked $WANT"*) ok "linked into the real, now-empty roots" ;; *) bad "link: $link_out" ;; esac

if verify="$("$BIN" --verify-models 2>&1)"; then
  ok "every bundled model loaded offline"
else
  bad "offline load failed"
  printf '%s\n' "$verify" | grep -E '^(✗|…)' | sed 's/^/      /' | head -8
fi

echo "5. a real download is never replaced by a link"
# Guarded on the move having actually happened. Steps 5 and 6 rm -rf a model
# directory, and if step 4's `mv` had failed that directory would be the
# developer's real 461 MB download rather than the scratch one.
if [ "$moved_app" != 1 ]; then
  bad "this suite does not own the cache root — refusing to touch it"
  echo; echo "$pass passed, $fail failed"; exit 1
fi
rm -rf "$APP_SUPPORT/parakeet-tdt-0.6b-v3"
mkdir -p "$APP_SUPPORT/parakeet-tdt-0.6b-v3"
printf 'not ours\n' > "$APP_SUPPORT/parakeet-tdt-0.6b-v3/marker"
out5="$("$BIN" --link-models 2>&1)"
[ -f "$APP_SUPPORT/parakeet-tdt-0.6b-v3/marker" ] \
  && ok "the existing directory is left exactly as it was" \
  || bad "a real model directory was replaced: $out5"

echo "6. a stale link is repointed"
rm -rf "$APP_SUPPORT/parakeet-tdt-0.6b-v3"
ln -s /nowhere/at/all "$APP_SUPPORT/parakeet-tdt-0.6b-v3"
"$BIN" --link-models >/dev/null 2>&1
target=$(readlink "$APP_SUPPORT/parakeet-tdt-0.6b-v3" 2>/dev/null)
case "$target" in
  "$MODELS/parakeet-tdt-0.6b-v3") ok "a link to an app that moved is repaired" ;;
  *) bad "still points at: $target" ;;
esac

# 7. the guard that keeps section 1 honest
#
# Sections 1–6 all run against whatever this checkout staged. If the guard
# has stopped firing, every one of them still passes — which is exactly how
# 937 MB of de-listed models reached /Applications. So the guard is run here
# against directories built to fail it, and a guard that allows them is the
# failure. Reverting check-bundled-models.sh turns these three red.
echo
echo "7. the staged-set guard refuses what it must"
GUARD_DIR="$SCRATCH/guard"
lists=$(sed -n 's/^APP_SUPPORT_MODELS="\(.*\)"$/\1/p; s/^CACHE_MODELS="\(.*\)"$/\1/p' scripts/fetch-models.sh | tr ' ' '\n' | grep -v '^$')

mkdir -p "$GUARD_DIR/exact"
for m in $lists; do mkdir -p "$GUARD_DIR/exact/$m"; done
if ./scripts/check-bundled-models.sh "$GUARD_DIR/exact" >/dev/null 2>&1; then
  ok "an exact set passes"
else
  bad "the guard rejects a set that matches the lists — it would block every build"
fi

cp -R "$GUARD_DIR/exact" "$GUARD_DIR/extra"
mkdir -p "$GUARD_DIR/extra/supertonic-3"
out=$(./scripts/check-bundled-models.sh "$GUARD_DIR/extra" 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "supertonic-3"; then
  ok "a de-listed model is refused, and named"
else
  bad "a de-listed model passed the guard (exit $rc) — this is the 2026-09-06 bug"
fi

cp -R "$GUARD_DIR/exact" "$GUARD_DIR/short"
first=$(printf '%s\n' $lists | head -1)
rm -rf "$GUARD_DIR/short/$first"
out=$(./scripts/check-bundled-models.sh "$GUARD_DIR/short" 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$first"; then
  ok "a missing model is refused, and named"
else
  bad "a bundle missing $first passed the guard (exit $rc)"
fi

# And the case that matters most: a guard that cannot run must not pass.
out=$(./scripts/check-bundled-models.sh "$GUARD_DIR/exact" /dev/null 2>&1); rc=$?
if [ "$rc" = 2 ]; then
  ok "unreadable lists fail the check rather than passing it"
else
  bad "the guard reported success with no lists to check against (exit $rc)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

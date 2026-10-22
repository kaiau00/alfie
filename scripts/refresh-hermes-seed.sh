#!/bin/bash
# refresh-hermes-seed.sh <hermes-agent-dir> [--to <sha>] [--installer <path>] [--check]
#
# **The one route by which a pinned Hermes commit reaches a Mac that already
# has a seeded Hermes.** It refreshes the tracked source the commit covers and
# nothing else, and it REFUSES — it never falls back to replacing the tree.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# Since 0.3.13 `~/.hermes/hermes-agent` is not a git checkout. It is a seed:
# a read-only template inside Memoe.app, cloned out with `@HERMES_ROOT@`
# substituted and stamped with `.moe-seed-commit`. Bumping `HERMES_COMMIT` in
# scripts/install-hermes.sh is how a fix in the fork reaches people, and it
# reached nobody who already had a Hermes, by three closed doors:
#
#   1. HermesSeed.installIfNeeded leaves an existing hermes-agent alone, full
#      stop, and names "the network installer" as what runs instead. That rule
#      is right — a half-installed checkout and a broken venv look identical
#      from the outside, and deleting one destroys work.
#   2. install-hermes.sh saw no `.git` and said "exists but is not a git
#      checkout — move it aside and re-run". Followed, that advice DESTROYS a
#      working Hermes. It is the thing HermesSeed's comment sends you to.
#   3. HermesUpgrade.swift reported the seed honestly as "not a checkout;
#      cannot fast-forward" and stopped there.
#
# So the rule in (1) keeps its other half, here: something that can move a
# seed forward without deleting it.
#
# ── What it will not touch, and why that is the whole design ────────────────
#
# `.venv/` is 246 MB and on the Mac this was written for it carries a HAND
# REPAIR that exists in no bundle: 0.3.13 shipped a seed whose `cp -RL`
# dereferenced the venv's interpreter symlink, and a python-build-standalone
# binary outside its own prefix cannot find its stdlib. Somebody relinked it
# by hand. No commit covers `.venv`, so no stamp can describe it and no
# re-lay can reproduce it. **"Re-lay on stamp mismatch" is therefore
# disqualified**, and so is anything else that replaces the tree.
#
# What a refresh reaches is the tracked source the two commits differ in, and
# nothing else. Auth, the claimstore, the channel directory and config.yaml
# live one level up in $HERMES_HOME and are never in scope at all.
#
# ── The refusals ────────────────────────────────────────────────────────────
#
# Each names WHICH question failed, because a refusal that misnames its reason
# sends the next person somewhere there is nothing to find — which is exactly
# how "no .git" came to be reported as "broken checkout":
#
#   • no directory                    • it is a git checkout, not a seed
#   • no .moe-seed-commit             • the stamp is not a 40-character sha
#   • the stamp names a commit the fork does not have
#   • the target is not on the fork
#   • a file this refresh would overwrite has been edited since the stamp
#   • the commit changes uv.lock / pyproject.toml / .python-version (exit 3:
#     install-hermes.sh then lays the seed the app carries, reseed-hermes.sh)
#
# The last one matters most. This route refreshes source; it never rebuilds a
# venv. `uv sync` would re-resolve, and on this Mac it would look for a
# uv-managed interpreter, not find the seed's own one at
# $HERMES_HOME/python/…, and rebuild `.venv` — taking the hand repair with it.
# So a dependency-changing pin is refused OUT LOUD rather than half-applied.
# Silence is what let the pin sit unnoticed in the first place.
#
# ── Measured, on this Mac, 2026-09-08 ───────────────────────────────────────
#
#   ~/.hermes/hermes-agent is stamped bc7d807e; the pin is af69bf56.
#   10,716 files tracked at the stamp; 6,324 present (the seed prunes
#   tests/, docs/, examples/, benchmarks/, website/, .github, .claude);
#   11 differ from the stamp — every one a `*.ps1`, and `.gitattributes`
#   says `*.ps1 text eol=crlf`. They are byte-identical after stripping CR.
#   **A drift check that did not know that would refuse on every Mac**, so
#   the comparison below accepts a pure line-ending difference and only that.
#   bc7d807e → af69bf56 is 9 paths: 7 modified, 2 deleted, no uv.lock.
set -u

usage() {
  cat >&2 <<'EOF'
usage: refresh-hermes-seed.sh <hermes-agent-dir> [options]
  --to <sha>          the commit to refresh to (default: the installer's pin)
  --installer <path>  where to read the pin from (default: this repo's scripts/install-hermes.sh)
  --check             say what would happen and change nothing
EOF
  exit 2
}

AGENT=""
TO=""
INSTALLER=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)        TO="${2:-}"; shift 2 || usage ;;
    --installer) INSTALLER="${2:-}"; shift 2 || usage ;;
    --check)     CHECK=1; shift ;;
    -h|--help)   usage ;;
    -*)          echo "✗ unknown option $1" >&2; usage ;;
    *)           [ -n "$AGENT" ] && usage; AGENT="$1"; shift ;;
  esac
done
[ -n "$AGENT" ] || usage

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="${INSTALLER:-$HERE/install-hermes.sh}"
MOE_HOME="${MOE_HOME:-$HOME/.moe}"

die()  { echo "✗ $*" >&2; exit 1; }
say()  { echo "› $*"; }
ok()   { echo "✓ $*"; }

command -v git >/dev/null 2>&1 || die "no git on this Mac, so nothing can read the fork; $AGENT is untouched"

# ── 1. Is this a seed at all? ───────────────────────────────────────────────
[ -d "$AGENT" ] || die "no Hermes at $AGENT — there is nothing to refresh (onboarding installs one)"
if [ -e "$AGENT/.git" ]; then
  die "$AGENT is a git checkout, not a seed.
  scripts/install-hermes.sh fast-forwards a checkout; this refuses to touch one,
  because a checkout may hold somebody's branches and unpushed work."
fi
STAMP_FILE="$AGENT/.moe-seed-commit"
if [ ! -f "$STAMP_FILE" ]; then
  # Never "move it aside and re-run". That advice, followed, deletes a
  # working Hermes and 246 MB of venv nothing can rebuild from a commit.
  die "$AGENT has no .moe-seed-commit, so nothing can say which Hermes it is.
  A seed with no stamp is UNKNOWN, not current, and an unknown tree is not one
  to overwrite. Nothing was changed. Leave it in place: whatever is there is
  working, and a fresh install goes to a different Mac, not over this one."
fi
# Trimmed at the ends, NOT squeezed. `tr -d '[:space:]'` would join a sha split
# across two lines into forty perfectly valid characters — while
# HermesUpgrade.installed() reads the same file with `trimmingCharacters` and
# refuses exactly that. Two parsers disagreeing about one file is how a tree
# gets called current by one half of the system and unknown by the other; the
# stricter reading is the right one, so this one moves.
FROM="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$STAMP_FILE" | head -1)"
[ "$(grep -c . "$STAMP_FILE" 2>/dev/null || echo 0)" -le 1 ] || FROM="(more than one line)"
case "$FROM" in
  ""|*[!0-9a-f]*) die "$STAMP_FILE does not hold a commit sha (it holds '$FROM'); nothing was changed" ;;
esac
[ ${#FROM} -eq 40 ] || die "$STAMP_FILE holds '$FROM', not a full 40-character sha; nothing was changed"

# ── 2. Where is it going? ───────────────────────────────────────────────────
# The pin is read out of the installer, by the one pattern HermesPin.read,
# scripts/check-hermes-seed-commit.sh and scripts/test-hermes-upgrade.sh all
# read. Never a second constant: a pin that lives in two places is two pins.
if [ -z "$TO" ]; then
  [ -f "$INSTALLER" ] || die "cannot read the pin: no installer at $INSTALLER"
  TO="$(sed -n 's/^HERMES_COMMIT="\${HERMES_COMMIT-\([0-9a-f]\{40\}\)}"$/\1/p' "$INSTALLER" | head -1)"
  [ -n "$TO" ] || die "cannot read the Hermes pin out of $INSTALLER (no HERMES_COMMIT=\"\${HERMES_COMMIT-<sha>}\" line); nothing was changed"
fi
case "$TO" in *[!0-9a-f]*) die "--to '$TO' is not a sha" ;; esac
[ ${#TO} -eq 40 ] || die "--to '$TO' is not a full 40-character sha"

FORK="${HERMES_FORK:-https://github.com/Izzy-Gottz/hermes-agent}"

if [ "$FROM" = "$TO" ]; then
  ok "$AGENT is already the pinned Hermes (${TO:0:10}); nothing to refresh"
  exit 0
fi

# ── 3. The objects ──────────────────────────────────────────────────────────
# A bare cache under Moe's own directory: not inside $AGENT (it would become
# part of the tree the next stage-hermes-seed.sh copies) and not inside a
# worktree's hermes-seed/ (it would be bundled into Memoe.app).
CACHE="${MOE_SEED_REFRESH_GIT:-$MOE_HOME/cache/hermes-fork.git}"
mkdir -p "$(dirname "$CACHE")" || die "cannot create $(dirname "$CACHE")"
if [ ! -d "$CACHE" ]; then
  git init -q --bare "$CACHE" || die "could not create the object cache at $CACHE"
fi
# Every refresh adds two shallow fetches of a large tree and nothing ever
# removed them, so on a Mac that keeps updating this grows without limit in the
# person's own directory. It is a cache: throwing it away costs one refetch.
CACHE_KB="$(du -sk "$CACHE" 2>/dev/null | awk '{print $1}')"
if [ -n "${CACHE_KB:-}" ] && [ "$CACHE_KB" -gt 500000 ]; then
  say "the object cache at $CACHE is $((CACHE_KB / 1024)) MB — starting it again"
  rm -rf "$CACHE"
  git init -q --bare "$CACHE" || die "could not recreate the object cache at $CACHE"
fi
export GIT_DIR="$CACHE"
export GIT_TERMINAL_PROMPT=0

have() { git cat-file -e "$1^{commit}" 2>/dev/null; }
fetch_one() {
  have "$1" && return 0
  git fetch -q --no-tags --depth=1 "$FORK" "$1" 2>/dev/null && have "$1" && return 0
  # The same proxy bypass every other network step in install-hermes.sh gets.
  # A local TLS-inspecting proxy breaks git's proxy discovery, and without this
  # the one network call on the seed path was the only one in the installer
  # with no second attempt — so a Mac behind Canopy could update its app and
  # never its agent, with the refusal blaming the fork for not having a commit
  # that is plainly there.
  env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
      NO_PROXY='*' no_proxy='*' \
      git fetch -q --no-tags --depth=1 "$FORK" "$1" 2>/dev/null && have "$1"
}

if ! fetch_one "$FROM"; then
  die "the seed is stamped ${FROM:0:10}, and $FORK does not have that commit.
  A well-formed sha that resolves to nothing is worse than none: there is no way
  to tell what this tree is supposed to contain, so nothing was changed."
fi
if ! fetch_one "$TO"; then
  die "the pinned ${TO:0:10} is not on $FORK — push it, or fix HERMES_COMMIT in $INSTALLER.
  Nothing was changed."
fi

# ── 4. What the commit covers ───────────────────────────────────────────────
# --no-renames so every path is a plain A/M/D and nothing has to be paired up.
CHANGES="$(git diff --no-renames --name-status "$FROM" "$TO")" \
  || die "could not diff ${FROM:0:10}..${TO:0:10}; nothing was changed"

# A dependency change is a venv change, and this route does not rebuild venvs.
DEPS="$(printf '%s\n' "$CHANGES" | awk -F'\t' '$2=="uv.lock"||$2=="pyproject.toml"||$2==".python-version"{print $2}')"
if [ -n "$DEPS" ]; then
  # Exit 3, not 1: this refusal has a remedy the others do not. The release
  # that moved the pin carries a seed built at it, and install-hermes.sh lays
  # that down instead (scripts/reseed-hermes.sh) — offline, the signed bytes,
  # never a rebuild here. Every other refusal still means "a person looks".
  echo "✗ ${FROM:0:10} → ${TO:0:10} changes $(printf '%s' "$DEPS" | tr '\n' ' ')— that is a change to what the venv contains.
  This route refreshes tracked source and never rebuilds a venv, because rebuilding
  one here would re-resolve against PyPI with an interpreter that is not the seed's
  and replace $AGENT/.venv with unsigned wheels. Nothing was changed.
  The way across is the seed the new Alfie carries (scripts/reseed-hermes.sh)." >&2
  exit 3
fi

# The seed is pruned — stage-hermes-seed.sh drops tests/, docs/, examples/,
# benchmarks/, website/, .github and .claude. Rather than carry a copy of that
# list, which would go stale the first time it changes there, a top-level
# directory is treated as PRUNED when it is tracked at the stamp and entirely
# absent from disk. Additions under a pruned directory are skipped; additions
# anywhere else — a new module such as optional-mcps/github — are written.
# Since 2026-09-08 the seed records what staging removed, in
# `.moe-seed-pruned`. Before that it recorded nothing, and this function had to
# guess from "tracked at the stamp and entirely absent from disk" — which
# cannot tell staging's prune from somebody deleting the directory themselves.
# Those mean opposite things: skip, or refuse over their work. The guess called
# both "pruned", kept a hand-deleted `skills/` deleted, said "not carried by
# this seed" about a directory the seed did carry, and advanced the stamp to a
# commit that says it exists — three false statements from one silent skip.
# **`-s`, not `-f`: an empty record is no record.** A zero-byte file counted as
# authoritative would switch the fallback off and make every pruned directory
# look like a hand deletion — refusing on every Mac that carried such a seed,
# which is strictly worse than the inference it replaced. And a zero-byte record
# is producible: `stage-hermes-seed.sh` derives it by comparing the tree before
# its prune against after, so staging from a source that was ALREADY pruned —
# a seed — yields an empty diff while the pruned directories are still absent.
# The stager now refuses that source outright; this is the second lock, because
# a seed built by an older stager can still arrive here.
#
# The limit of all this, said plainly: the record is a trust anchor with no
# cross-check. A record that wrongly LISTS a directory the person really
# deleted gives back exactly the silent skip and false stamp this file exists
# to prevent. Nothing the real stager can produce has that shape — it derives
# the list from what it removed itself — but a hand-edited or corrupted record
# is believed.
PRUNED_LIST="$AGENT/.moe-seed-pruned"
HAVE_PRUNE_RECORD=0
[ -s "$PRUNED_LIST" ] && HAVE_PRUNE_RECORD=1
pruned_top() {
  local top="${1%%/*}"
  if [ "$HAVE_PRUNE_RECORD" = 1 ]; then
    # Exact: staging said so, or it did not — and it says so about FILES as
    # well as directories. The record comes from `ls -A`, which lists both;
    # discarding the files here threw away half of what it had just been
    # taught to write. The fork tracks `.env.example` and `.envrc` at top
    # level and staging prunes both by name, so any pin range touching one of
    # them refused on every Mac, accusing the owner of a deletion staging had
    # made.
    [ -e "$AGENT/$top" ] && return 1
    grep -qxF -- "$top" "$PRUNED_LIST"
    return $?
  fi
  # No record — which is every seed on this Mac today, all four of them, so
  # this is the live path and not a legacy one. Fall back to the old inference:
  # right for the ordinary case, blind to a hand deletion.
  #
  # It refuses to guess about a top-level FILE. Not because "absent and deleted
  # are the same observation" — that is equally true of directories, and the
  # line below guesses about those anyway. The real reason is the cost of being
  # wrong in each direction. Guessing "pruned" about a directory skips a subtree
  # the seed demonstrably does not carry; guessing it about a single top-level
  # file skips a file the seed almost certainly does carry, since staging prunes
  # only a handful by name. So the file case errs toward the drift refusal,
  # which is loud and recoverable, rather than toward a silent skip.
  #
  # The live consequence, so nobody is surprised by it: the fork tracks
  # `.env.example` and `.envrc` at top level and staging prunes both, so a pin
  # range touching either refuses on all four seeds here until they are
  # re-staged with a record. The current range does not touch them.
  [ "$top" = "$1" ] && return 1
  [ -e "$AGENT/$top" ] && return 1
  git cat-file -e "$FROM:$top" 2>/dev/null
}

# ── 5. Is the tree still what the stamp says it is? ─────────────────────────
# **Scoped to the paths this refresh would overwrite or delete, and that scope
# is a real limit — write it down rather than leave it to be rediscovered.**
#
# What it guarantees: nothing this run writes over had been changed since the
# stamp. What it does NOT guarantee: that the rest of the tree matches the
# stamp. A file edited somewhere this commit does not touch is not seen, and
# after a successful refresh the stamp advances and still does not describe it.
# That is not a regression — the stamp never described it — but it means the
# stamp is a statement about provenance, not an integrity check.
#
# The scope is deliberate on both sides. A file this run does not touch cannot
# be destroyed by it, so the safety question is fully answered; and a whole-tree
# comparison would refuse on every Mac, because `.gitattributes` carries
# `*.ps1 text eol=crlf` and eleven files in the live seed therefore differ from
# their blob by CR alone (measured 2026-09-08, all eleven byte-identical after
# stripping CR). A pure line-ending difference is accepted here; anything else
# is drift.
same_as_blob() {
  local file="$1" blob="$2"
  [ "$(git hash-object -- "$file" 2>/dev/null)" = "$blob" ] && return 0
  # `git cat-file` piped into a hash loses its exit status, and the hash of no
  # output is a perfectly good hash — so a failed read would compare equal to
  # an empty file and call drift "unchanged". Materialise it and check.
  local raw a b
  raw="$(mktemp "${TMPDIR:-/tmp}/moe-blob.XXXXXX")" || return 1
  if ! git cat-file blob "$blob" > "$raw" 2>/dev/null; then rm -f "$raw"; return 1; fi
  a="$(tr -d '\r' < "$raw" | shasum -a 256 | awk '{print $1}')"
  b="$(tr -d '\r' < "$file" | shasum -a 256 | awk '{print $1}')"
  rm -f "$raw"
  [ "$a" = "$b" ]
}

DRIFT=""
WRITE=""      # status<TAB>path, the ones that will actually be applied
SKIPPED=0
while IFS=$'\t' read -r st path; do
  [ -n "${path:-}" ] || continue
  case "$st" in
    D)
      # `-e` alone is false for a dangling symlink, which would then be left
      # in place by a commit that deletes it.
      if [ ! -e "$AGENT/$path" ] && [ ! -L "$AGENT/$path" ]; then
        SKIPPED=$((SKIPPED+1)); continue
      fi
      ;;
    A)
      # `-e` is false for a DANGLING symlink, so `! -e && ! -L` together are
      # what "really is not there" means. Getting this wrong is how a
      # repointed-but-broken link reached the wrong branch below.
      if [ ! -e "$AGENT/$path" ] && [ ! -L "$AGENT/$path" ]; then
        pruned_top "$path" && { SKIPPED=$((SKIPPED+1)); continue; }
      fi
      # It is an addition, and something is already at that path. The drift
      # check below cannot see this: it asks for the blob at $FROM, and an `A`
      # has none, so the whole branch was skipped and the file was clobbered —
      # `1 written`, rc 0, and the user's content gone, with the backup
      # discarded on success. This file's stated rule is that a path it would
      # overwrite must not have changed since the stamp; #6 already said
      # deleting a file is editing it, and creating one is too. The seed did
      # not carry this path at $FROM, so whatever is here, somebody put it here.
      if [ -e "$AGENT/$path" ] || [ -L "$AGENT/$path" ]; then
        DRIFT="$DRIFT$path (added by hand; the commit adds it too)"$'\n'
        continue
      fi
      ;;
    M|T)
      if [ ! -e "$AGENT/$path" ] && [ ! -L "$AGENT/$path" ]; then
        # Absent, and there are two very different reasons for that.
        #
        # Pruned at stage time — the seed never carried it — so leave it
        # pruned rather than resurrect a directory this seed deliberately
        # does not have.
        if pruned_top "$path"; then SKIPPED=$((SKIPPED+1)); continue; fi
        # Otherwise the seed DID carry it and it is gone, which means somebody
        # removed it. **Deleting a file is editing it.** Skipping here would
        # leave the file missing, advance the stamp to a commit that says it
        # exists, and report it as "not carried by this seed" — three wrong
        # statements from one silent skip. It is drift, and it refuses.
        DRIFT="$DRIFT$path (deleted)"$'\n'
        continue
      fi
      ;;
    *)
      die "the diff ${FROM:0:10}..${TO:0:10} has a status '$st' for $path that this refresh does not know how to apply; nothing was changed" ;;
  esac
  # Everything that survives to here is a path we are about to write over or
  # remove, so it is a path whose current content has to be accounted for.
  if [ -L "$AGENT/$path" ]; then
    # A symlink. It used to be skipped, which meant a link somebody had
    # repointed — the whole reason .venv is untouchable is one such repair —
    # was replaced with no refusal at all. A link's content is its target.
    want="$(git cat-file blob "$FROM:$path" 2>/dev/null || true)"
    if [ -n "$want" ] && [ "$(readlink "$AGENT/$path")" != "$want" ]; then
      DRIFT="$DRIFT$path (symlink repointed)"$'\n'
    fi
  elif [ -e "$AGENT/$path" ]; then
    blob="$(git rev-parse -q --verify "$FROM:$path" 2>/dev/null || true)"
    if [ -n "$blob" ] && ! same_as_blob "$AGENT/$path" "$blob"; then
      DRIFT="$DRIFT$path"$'\n'
    fi
  fi
  WRITE="$WRITE$st"$'\t'"$path"$'\n'
done <<< "$CHANGES"

if [ -n "$DRIFT" ]; then
  n="$(printf '%s' "$DRIFT" | grep -c . || true)"
  echo "✗ $AGENT is stamped ${FROM:0:10}, but $n file(s) this refresh would overwrite have been" >&2
  echo "  edited or deleted since then. The stamp does not describe what is on disk, so a refresh" >&2
  echo "  would silently discard somebody's work. Nothing was changed:" >&2
  printf '%s' "$DRIFT" | sed -n '1,5p' | sed 's/^/      /' >&2
  [ "$n" -gt 5 ] && echo "      … and $((n-5)) more" >&2
  echo "  This is a refusal, not a fallback: there is deliberately no option here that" >&2
  echo "  replaces the tree instead." >&2
  exit 1
fi

COUNT_W="$(printf '%s' "$WRITE" | grep -c . || true)"
if [ "$COUNT_W" = 0 ]; then
  # Every changed path was pruned out of this seed. The commit still arrives:
  # the stamp is what says which Hermes this is, and it is now the pin.
  if [ "$CHECK" = 1 ]; then
    ok "would restamp $AGENT ${FROM:0:10} → ${TO:0:10} (the commit touches nothing this seed carries)"
    exit 0
  fi
  printf '%s\n' "$TO" > "$STAMP_FILE" || die "could not write $STAMP_FILE"
  ok "refreshed $AGENT: ${FROM:0:10} → ${TO:0:10} (0 files; the commit touches nothing this seed carries)"
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  say "would refresh $AGENT: ${FROM:0:10} → ${TO:0:10}"
  printf '%s' "$WRITE" | sed 's/^/    /'
  [ "$SKIPPED" -gt 0 ] && say "and skip $SKIPPED path(s) this seed does not carry"
  exit 0
fi

# ── 6. Apply, with everything it touches saved first ────────────────────────
BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/moe-seed-refresh.XXXXXX")" || die "cannot make a scratch directory"
RESTORED=0
RESTORE_FAILED=0
restore() {
  [ "$RESTORED" = 1 ] && return 0
  RESTORED=1
  RESTORE_FAILED=0
  # Put back exactly what was saved, and remove anything that was created.
  # Each step is checked: an undo that reports success without having run is
  # the same class of lie as the guard this file replaced, and the caller's
  # sentence is built from RESTORE_FAILED rather than assuming.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$BACKUP/saved/$rel" ] || [ -L "$BACKUP/saved/$rel" ]; then
      mkdir -p "$(dirname "$AGENT/$rel")" 2>/dev/null
      rm -rf "$AGENT/$rel" 2>/dev/null
      cp -RP "$BACKUP/saved/$rel" "$AGENT/$rel" 2>/dev/null || RESTORE_FAILED=$((RESTORE_FAILED+1))
    else
      rm -f "$AGENT/$rel" 2>/dev/null || RESTORE_FAILED=$((RESTORE_FAILED+1))
    fi
  done < "$BACKUP/touched"
}

# What to say after a restore — measured from RESTORE_FAILED, never assumed.
restore_note() {
  if [ "$RESTORE_FAILED" = 0 ]; then
    printf 'every file this run had touched was put back, and %s is still %s' "$AGENT" "${FROM:0:10}"
  else
    printf 'CHECK IT: %s file(s) could NOT be put back in %s — it is part-way between %s and %s' \
      "$RESTORE_FAILED" "$AGENT" "${FROM:0:10}" "${TO:0:10}"
  fi
}
cleanup() { rm -rf "$BACKUP"; }
trap cleanup EXIT
# A killed run must not leave a half-applied tree. The stamp is written last,
# so an interrupted run would otherwise leave files from the new commit under
# a stamp naming the old one — and the next run would read that as somebody's
# hand edit and refuse for the wrong reason.
trap 'restore; echo "✗ interrupted — $(restore_note)" >&2; cleanup; exit 1' INT TERM HUP

mkdir -p "$BACKUP/saved"
: > "$BACKUP/touched"

wrote=0
removed=0
failure=""
while IFS=$'\t' read -r st path; do
  [ -n "${path:-}" ] || continue
  # Save first, always, whether or not the file exists — `touched` is the
  # undo list and an absent entry there means "created, so remove it".
  printf '%s\n' "$path" >> "$BACKUP/touched"
  if [ -e "$AGENT/$path" ] || [ -L "$AGENT/$path" ]; then
    mkdir -p "$(dirname "$BACKUP/saved/$path")"
    cp -RP "$AGENT/$path" "$BACKUP/saved/$path" 2>/dev/null || { failure="could not save $path aside"; break; }
  fi
  if [ "$st" = D ]; then
    rm -f "$AGENT/$path" 2>/dev/null || { failure="could not remove $path"; break; }
    removed=$((removed+1))
    continue
  fi
  meta="$(git ls-tree "$TO" -- "$path" | head -1)"
  mode="${meta%% *}"
  case "$mode" in
    100644|100755)
      mkdir -p "$(dirname "$AGENT/$path")" 2>/dev/null || { failure="could not create the directory for $path"; break; }
      rm -f "$AGENT/$path" 2>/dev/null
      if ! git cat-file blob "$TO:$path" > "$AGENT/$path" 2>/dev/null; then
        failure="could not write $path"; break
      fi
      if [ "$mode" = 100755 ]; then chmod 755 "$AGENT/$path"; else chmod 644 "$AGENT/$path"; fi
      wrote=$((wrote+1))
      ;;
    120000)
      mkdir -p "$(dirname "$AGENT/$path")" 2>/dev/null
      target="$(git cat-file blob "$TO:$path" 2>/dev/null)"
      [ -n "$target" ] || { failure="could not read the symlink target for $path"; break; }
      rm -f "$AGENT/$path" 2>/dev/null
      ln -s "$target" "$AGENT/$path" 2>/dev/null || { failure="could not create the symlink $path"; break; }
      wrote=$((wrote+1))
      ;;
    *)
      failure="$path is mode '$mode' at ${TO:0:10}, which this refresh does not apply"
      break
      ;;
  esac
done <<< "$WRITE"

if [ -n "$failure" ]; then
  restore
  die "$failure — $(restore_note)"
fi

# ── 7. Stamp, last ──────────────────────────────────────────────────────────
if ! printf '%s\n' "$TO" > "$STAMP_FILE"; then
  restore
  die "could not write $STAMP_FILE — $(restore_note)"
fi

# `.venv/.moe-sync` is deliberately NOT rewritten.
#
# An earlier version of this file moved its sha field forward, arguing that the
# next install-hermes.sh would otherwise `uv sync` for a difference that does
# not exist. That argument is false against the code as written: `.moe-sync` has
# exactly two readers, and neither is reached for a seed. install-hermes.sh
# compares it only in the `elif` of its step 4, and a seed takes the `if` above
# it; `syncStamp` is reached only through `venvHealthy`, which `decide` does not
# call for seeds, and through `perform()`, which seeds never enter.
#
# So the write bought nothing, and cost three things: it was the ONLY write into
# `.venv` in a design whose whole premise is never to touch `.venv`; it asserted
# something unverified ("this venv was synced for $TO" — it was not, nothing
# synced anything); and it forced this suite's `.venv` fingerprint to be taken
# AROUND the one file that changed, so "byte-for-byte" was asserted about
# everything except the exception. The stamp beside it is what says which Hermes
# this is, and that is enough.

# Bytecode, so the interpreter's view follows the disk.
#
# CPython's `.pyc` files here are timestamp-based (`flags == 0`), so a rewritten
# source file — written just now, hence newer than any cached bytecode — is
# recompiled and the new code runs. That is true today and it rests on two
# properties nobody had written down: HermesSeed.swift copies with mtimes
# preserved, and no build step normalises timestamps. **The second is exactly
# the kind of thing somebody changes for a good unrelated reason** —
# SOURCE_DATE_EPOCH for reproducible builds, `touch -t` for notarisation
# diffing — and the moment two seeds share a fixed mtime and a file's size does
# not change, CPython keeps the stale `.pyc`: refreshed bytes on disk, old code
# running, and every hash-based check in this repo green. That is
# "exists somewhere is not arrives here" one layer in, at the interpreter.
#
# Rather than leave that resting on an invariant, drop the cached bytecode for
# every file rewritten. It costs one recompile and removes the dependency.
while IFS=$'\t' read -r st path; do
  [ -n "${path:-}" ] || continue
  case "$path" in *.py) ;; *) continue ;; esac
  d="$(dirname "$AGENT/$path")"
  b="$(basename "$path" .py)"
  rm -f "$d/__pycache__/$b."*.pyc 2>/dev/null
done <<< "$WRITE"

# "not carried by this seed" is a claim, and only a seed that recorded its own
# prune list can make it. Without that record the honest word is "absent".
skipped_note=""
if [ "$SKIPPED" -gt 0 ]; then
  if [ "$HAVE_PRUNE_RECORD" = 1 ]; then
    skipped_note=", $SKIPPED not carried by this seed"
  else
    skipped_note=", $SKIPPED absent (this seed does not record what staging pruned)"
  fi
fi
ok "refreshed $AGENT: ${FROM:0:10} → ${TO:0:10} ($wrote written, $removed removed$skipped_note)"
exit 0

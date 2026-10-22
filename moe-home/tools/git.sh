#!/bin/bash
# Moe's window onto your code — GitHub and the repos on this Mac.
#
# No MCP server and no OAuth: the `gh` CLI is already signed in as you, with
# repo, read:org and workflow scopes. Shelling out to it is simpler, faster and
# has fewer moving parts than a remote MCP server that would need its own token.
#
# Read-only by design. Nothing here pushes, merges, or comments — see the note
# at the bottom.
set -uo pipefail

usage() {
  cat <<'EOF'
GITHUB
  repos [n]                  your repositories, most recently pushed first
  recent [n]                 your latest commits across everything
  commits <repo> [n]         commits in one repo   (owner/name or just name)
  prs [state]                your pull requests    (open|closed|merged|all)
  issues [state]             issues assigned to you
  activity [n]               what you've been doing lately
  search <query>             search your code
  show <repo>                description, language, branches, last push

LOCAL
  local                      git repos on this Mac, with their status
  status <path>              branch, staged/unstaged changes, ahead/behind
  log <path> [n]             recent commits in a local repo
  diff <path>                uncommitted changes
EOF
}

die() { echo "$1" >&2; exit 2; }
num() { case "${1:-}" in (''|*[!0-9]*) echo "$2";; (*) echo "$1";; esac; }

# Every GitHub command below needs a signed-in `gh`, and none of them can tell
# you so from its own exit status: `gh search prs` with no auth exits non-zero
# exactly like a search that found nothing, and `recent` swallows the failure
# in a for-loop and prints an empty list. An empty list is read as "you have no
# pull requests", which is a false statement dressed as an answer — so ask once,
# up front, and name the real cause.
#
# The remedy is deliberately not "run gh auth login". Most people running Moe
# do not have the GitHub CLI and are not going to install it; the GitHub row in
# Connections signs in with a token and needs no terminal at all.
need_gh() {
  command -v gh >/dev/null 2>&1 \
    || die "the GitHub CLI isn't installed on this Mac — connect GitHub in Alfie's Connections instead, or install gh"
  gh auth status >/dev/null 2>&1 \
    || die "the GitHub CLI isn't signed in — connect GitHub in Alfie's Connections, or run: gh auth login"
}

# Fill in the owner when only a repo name is given.
qualify() {
  case "$1" in
    */*) echo "$1" ;;
    *)   echo "$(gh api user --jq .login 2>/dev/null)/$1" ;;
  esac
}

case "${1:-}" in

repos)
  need_gh
  n=$(num "${2:-}" 20)
  gh repo list --limit "$n" \
    --json nameWithOwner,description,primaryLanguage,pushedAt,isPrivate \
    --jq '.[] | "\(.nameWithOwner)  [\(.primaryLanguage.name // "—")]\(if .isPrivate then " (private)" else "" end)\n    \(.description // "no description")\n    last push \(.pushedAt[0:10])"' \
    2>/dev/null || die "couldn't list your repositories"
  ;;

recent)
  need_gh
  n=$(num "${2:-}" 15)
  # Most recently pushed repos, then their newest commits.
  for repo in $(gh repo list --limit 8 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null); do
    out=$(gh api "repos/$repo/commits?per_page=3" \
      --jq '.[] | "  \(.commit.author.date[0:10])  \(.commit.message | split("\n")[0])"' 2>/dev/null)
    [ -n "$out" ] && { echo "$repo"; echo "$out"; }
  done | head -"$((n * 2))"
  ;;

commits)
  need_gh
  [ -n "${2:-}" ] || die "which repo?"
  repo=$(qualify "$2"); n=$(num "${3:-}" 20)
  gh api "repos/$repo/commits?per_page=$n" \
    --jq '.[] | "\(.commit.author.date[0:16] | sub("T";" "))  \(.commit.author.name)  \(.commit.message | split("\n")[0])"' \
    2>/dev/null || die "couldn't read $repo"
  ;;

prs)
  need_gh
  state="${2:-open}"
  gh search prs --author=@me --state="$state" --limit 20 \
    --json repository,title,state,updatedAt,url \
    --jq '.[] | "\(.repository.nameWithOwner)  \(.state)  \(.title)\n    \(.url)"' 2>/dev/null \
    || die "couldn't search pull requests"
  ;;

issues)
  need_gh
  state="${2:-open}"
  gh search issues --assignee=@me --state="$state" --limit 20 \
    --json repository,title,state,updatedAt,url \
    --jq '.[] | "\(.repository.nameWithOwner)  \(.state)  \(.title)\n    \(.url)"' 2>/dev/null \
    || die "couldn't search issues"
  ;;

activity)
  need_gh
  n=$(num "${2:-}" 25)
  gh api "users/$(gh api user --jq .login)/events?per_page=$n" \
    --jq '.[] | "\(.created_at[0:16] | sub("T";" "))  \(.type | sub("Event";""))  \(.repo.name)"' \
    2>/dev/null || die "couldn't read your activity"
  ;;

search)
  need_gh
  [ -n "${2:-}" ] || die "search for what?"
  gh search code "$2" --owner "$(gh api user --jq .login)" --limit 20 \
    --json repository,path,url \
    --jq '.[] | "\(.repository.nameWithOwner)  \(.path)"' 2>/dev/null \
    || die "code search failed"
  ;;

show)
  need_gh
  [ -n "${2:-}" ] || die "which repo?"
  repo=$(qualify "$2")
  gh repo view "$repo" 2>/dev/null | head -40 || die "couldn't read $repo"
  ;;

local)
  # Everything with a .git directory, and whether it's clean.
  find "$HOME" -maxdepth 4 -name .git -type d 2>/dev/null | sed 's|/\.git$||' | while read -r dir; do
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    last=$(git -C "$dir" log -1 --format=%cd --date=short 2>/dev/null)
    printf '%s  [%s]  %s%s\n' "${dir/#$HOME/~}" "${branch:-?}" \
      "$( [ "$dirty" -gt 0 ] && echo "$dirty uncommitted" || echo "clean" )" \
      "${last:+  last commit $last}"
  done
  ;;

status)
  d="${2:?path required}"
  git -C "$d" status -sb 2>/dev/null || die "not a git repo: $d"
  ;;

log)
  d="${2:?path required}"; n=$(num "${3:-}" 15)
  git -C "$d" log -"$n" --format='%cd  %an  %s' --date=short 2>/dev/null \
    || die "not a git repo: $d"
  ;;

diff)
  d="${2:?path required}"
  git -C "$d" diff --stat 2>/dev/null
  git -C "$d" diff --cached --stat 2>/dev/null
  ;;

*) usage; exit 1 ;;
esac

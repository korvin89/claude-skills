#!/usr/bin/env bash
#
# cleanup.sh — remove the scratch korvin89 review skills keep for one pull
# request, after checking it is the scratch you mean.
#
# Every review keeps its scratch in <git-common-dir>/code-review/<key>/, where
# <key> is pr-<N> for a pull request and `local` for a review without one:
#   head/              the PR head worktree (code-review)
#   batch.json         the findings batch (code-review)
#   artifacts/<slug>/  screenshots, configs and their worktrees (review-artifacts)
#   watch.pid          the pid of a running draft watcher (draft.sh)
# It sits inside .git, so it never shows in `git status`.
#
# Usage:
#   cleanup.sh <pr | #pr | pr-url | local> [--yes]  remove that scratch
#   cleanup.sh --stale [--keep <N>]                 remove the scratch of merged or
#                                                   closed PRs that passes every check,
#                                                   except PR <N>'s
#   cleanup.sh path <pr | local>                    print the scratch dir, creating it
#   cleanup.sh list                                 print every scratch dir and its size
#
# Checks before removing; each finding is a warning:
#   - the PR cannot be looked up, or no git remote of this repository points at
#     the PR's repository;
#   - head/ is at a commit that is neither the PR head nor an ancestor of it;
#   - a worktree in the scratch has uncommitted changes or untracked files;
#   - the current directory is inside the scratch;
#   - a draft watcher for the PR is still running.
# With warnings and no --yes nothing is removed: the script prints CONFIRM and
# the warnings, and exits 10. --stale never confirms: it keeps such scratch and
# says why. Nothing outside <git-common-dir>/code-review/ is ever removed.
#
# Exit codes: 0 ok, also nothing to clean · 2 not a git repo · 4 bad usage · 10 needs confirmation

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }
usage() { die 4 "Usage: cleanup.sh <pr-number | pr-url | local> [--yes] | --stale | path <pr | local> | list"; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 2 "Not inside a git repository."
root="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/code-review"

# key <pr | #pr | pr-url | local> — the scratch key, pr-<N> or local.
key() {
  local a="${1#\#}"
  case "$a" in
    local)         echo local ;;
    */pull/[0-9]*) a="${a##*/pull/}"; echo "pr-${a%%[!0-9]*}" ;;
    ""|*[!0-9]*)   return 1 ;;
    *)             echo "pr-$a" ;;
  esac
}

# worktrees <dir> — every registered worktree inside <dir>.
worktrees() {
  git worktree list --porcelain | awk -v d="$1/" '
    /^worktree / { p = substr($0, 10); if (index(p "/", d) == 1) print p }'
}

size() { du -sh "$1" 2>/dev/null | awk '{ print $1 }'; }

# warnings <key> <dir> <pr-ref> — print one line per check that fails.
warnings() {
  local k="$1" dir="$2" ref="$3" info url want name u found="" prhead wt h pid n
  if [ "$k" != local ]; then
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh is not installed: PR ${k#pr-} cannot be looked up"
    elif ! info="$(gh pr view "$ref" --json url,headRefOid --jq '"\(.url) \(.headRefOid)"' 2>/dev/null)"; then
      echo "PR ${k#pr-} is not found from this repository"
    else
      url="${info%% *}"; prhead="${info#* }"
      want="$(printf '%s' "$url" | sed -E 's#^[a-z]+://[^/]+(/[^/]+/[^/]+)/pull/.*#\1#' | tr '[:upper:]' '[:lower:]')"
      while read -r name u _; do
        u="$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]' | tr ':' '/')"; u="${u%/}"; u="${u%.git}"
        case "$u" in *"$want") found="$name"; break ;; esac
      done < <(git remote -v | awk '$3 == "(fetch)"')
      [ -n "$found" ] || echo "no git remote of this repository points at ${want#/}: this scratch may not be that PR's"
      wt="$dir/head"
      if [ -e "$wt/.git" ] && h="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" && [ "$h" != "$prhead" ]; then
        if ! git merge-base --is-ancestor "$h" "$prhead" 2>/dev/null; then
          echo "head/ is at ${h:0:12}, which is neither the head of PR ${k#pr-} (${prhead:0:12}) nor an ancestor of it"
        fi
      fi
    fi
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    n="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" = 0 ] || echo "worktree ${wt#$root/} has $n uncommitted or untracked file(s)"
  done < <(worktrees "$dir")
  case "$(pwd -P)/" in "$dir"/*) echo "the current directory is inside ${dir#$root/}" ;; esac
  if [ -f "$dir/watch.pid" ] && pid="$(cat "$dir/watch.pid")" && kill -0 "$pid" 2>/dev/null; then
    echo "a draft watcher (pid $pid) is still running for ${k}"
  fi
  return 0
}

# remove <dir> — remove its worktrees and the dir itself.
remove() {
  local dir="$1" s wt
  case "$dir" in "$root"/pr-[0-9]*|"$root"/local) ;; *) die 4 "Refusing to remove $dir: not a scratch dir." ;; esac
  s="$(size "$dir")"
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    git worktree remove --force "$wt" 2>/dev/null || err "could not remove worktree $wt"
  done < <(worktrees "$dir")
  rm -rf "$dir"
  git worktree prune
  printf 'cleaned %s (%s)\n' "${dir#$root/}" "${s:-0}"
}

[ $# -ge 1 ] || usage
case "$1" in
  path)
    [ $# -eq 2 ] || usage
    k="$(key "$2")" || usage
    mkdir -p "$root/$k"
    printf '%s\n' "$root/$k" ;;
  list)
    [ $# -eq 1 ] || usage
    found=0
    for dir in "$root"/pr-* "$root"/local; do
      [ -d "$dir" ] || continue
      found=1
      printf '%s\t%s\n' "${dir#$root/}" "$(size "$dir")"
    done
    [ "$found" = 1 ] || echo "no scratch in this repository" ;;
  --stale)
    keep=""
    case "$#:${2:-}" in 1:) ;; 3:--keep) keep="$3" ;; *) usage ;; esac
    command -v gh >/dev/null 2>&1 || exit 0
    for dir in "$root"/pr-*; do
      [ -d "$dir" ] || continue
      n="${dir##*/pr-}"
      [ "$n" != "$keep" ] || continue
      state="$(gh pr view "$n" --json state --jq .state 2>/dev/null)" || continue
      case "$state" in MERGED|CLOSED) ;; *) continue ;; esac
      w="$(warnings "pr-$n" "$dir" "$n")"
      if [ -n "$w" ]; then
        printf 'kept pr-%s (%s): %s\n' "$n" "$state" "$(printf '%s' "$w" | paste -sd ';' -)"
      else
        remove "$dir"
      fi
    done ;;
  *)
    yes=0; ref=""
    for a in "$@"; do
      case "$a" in
        --yes) yes=1 ;;
        --*)   usage ;;
        *)     [ -z "$ref" ] || usage; ref="${a#\#}" ;;
      esac
    done
    k="$(key "$ref")" || usage
    dir="$root/$k"
    if [ ! -d "$dir" ]; then
      echo "nothing to clean: no scratch for $k in this repository"
      exit 0
    fi
    w="$(warnings "$k" "$dir" "$ref")"
    if [ -n "$w" ] && [ "$yes" = 0 ]; then
      echo "CONFIRM"
      printf '%s\n' "$w"
      exit 10
    fi
    remove "$dir" ;;
esac

#!/usr/bin/env bash
#
# base.sh — bring the base branch into a task worktree by merging it; a pushed
# branch is never rebased.
#
# Usage:
#   base.sh merge <worktree>      fetch origin/<base> and merge it. On conflicts
#                                 the merge stays in progress and one
#                                 "CONFLICT <path>" line per file is printed;
#                                 resolve only mechanical conflicts (imports,
#                                 lockfiles, adjacent edits), else abort
#   base.sh continue <worktree>   conclude the merge once no path is unmerged
#   base.sh abort <worktree>      abandon the merge
#
# Exit codes: 0 merged or already up to date · 4 bad usage · 7 not a task
#             worktree, or unmerged paths remain · 9 conflicts (merge in progress)

set -euo pipefail
. "$(dirname "$0")/common.sh"

[ $# -eq 2 ] || die 4 "Usage: base.sh merge|continue|abort <worktree>"
cmd="$1"
wt="$(CDPATH='' cd -P -- "$2" 2>/dev/null && pwd -P)" || die 4 "No such worktree: $2"
hit="$(task_of "$wt")"; [ -n "$hit" ] || die 7 "$wt is not the worktree of a task unit."
key="${hit%%$'\t'*}"
task_lock "$key"
base="$(task_get "$key" .base)"

case "$cmd" in
  merge)
    git -C "$wt" fetch --quiet origin "$base"
    if git -C "$wt" merge-base --is-ancestor "origin/$base" HEAD; then
      printf 'up to date with origin/%s\n' "$base"; exit 0
    fi
    if git -C "$wt" merge --no-edit --quiet "origin/$base" >/dev/null 2>&1; then
      printf 'merged origin/%s\n' "$base"; exit 0
    fi
    git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/CONFLICT /'
    exit 9 ;;
  continue)
    unmerged="$(git -C "$wt" diff --name-only --diff-filter=U)"
    [ -z "$unmerged" ] || die 7 "Still unmerged: $(echo $unmerged)"
    git -C "$wt" commit --no-edit --quiet
    printf 'merged origin/%s\n' "$base" ;;
  abort)
    git -C "$wt" merge --abort
    printf 'merge of origin/%s aborted\n' "$base" ;;
  *) die 4 "Usage: base.sh merge|continue|abort <worktree>" ;;
esac

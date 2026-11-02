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
# Exit codes: 0 merged or already up to date · 1 git error · 4 bad usage
#             · 7 not a task worktree, uncommitted changes, or unmerged paths
#             remain · 9 the task is driven by another session · 11 conflicts
#             (merge in progress)

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
    [ -z "$(git -C "$wt" status --porcelain)" ] || die 7 "$wt has uncommitted changes; commit them before merging the base."
    git -C "$wt" fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base"
    if git -C "$wt" merge-base --is-ancestor "origin/$base" HEAD; then
      printf 'up to date with origin/%s\n' "$base"; exit 0
    fi
    if git -C "$wt" merge --no-edit --quiet "origin/$base" >/dev/null 2>&1; then
      printf 'merged origin/%s\n' "$base"; exit 0
    fi
    git -C "$wt" rev-parse --verify --quiet MERGE_HEAD >/dev/null || die 1 "Could not merge origin/$base into $wt."
    git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/CONFLICT /'
    exit 11 ;;
  continue)
    unmerged="$(git -C "$wt" diff --name-only --diff-filter=U)"
    [ -z "$unmerged" ] || die 7 "Still unmerged: $(echo $unmerged)"
    git -C "$wt" commit --no-edit --quiet
    printf 'merge concluded\n' ;;
  abort)
    git -C "$wt" rev-parse --verify --quiet MERGE_HEAD >/dev/null || die 7 "No merge in progress in $wt."
    git -C "$wt" merge --abort
    printf 'merge of origin/%s aborted\n' "$base" ;;
  *) die 4 "Usage: base.sh merge|continue|abort <worktree>" ;;
esac

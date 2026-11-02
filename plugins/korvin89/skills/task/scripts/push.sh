#!/usr/bin/env bash
#
# push.sh — the only way a task pushes. In the unit's worktree, in order:
#   1. fetch the unit's branch; when it moved on the remote (the author pushed,
#      "Commit suggestion", "Update branch"), merge it in — never rebase;
#   2. refuse uncommitted changes: everything pushed is committed;
#   3. run the task's check commands (task.sh checks) at HEAD;
#   4. push HEAD to refs/heads/<branch> of the unit's remote, fast-forward
#      only: no --force, ever.
#
# Usage: push.sh <worktree>
#
# Exit codes: 0 pushed (or nothing to push) · 1 git error · 4 bad usage or no
#             checks recorded · 7 not a task worktree / uncommitted changes
#             · 9 the remote branch moved and merging it conflicts (merge
#             aborted), or the task is driven by another session
#             · 10 a check failed (its output tail is printed)

set -euo pipefail
. "$(dirname "$0")/common.sh"

[ $# -eq 1 ] || die 4 "Usage: push.sh <worktree>"
wt="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || die 4 "No such worktree: $1"
hit="$(task_of "$wt")"; [ -n "$hit" ] || die 7 "$wt is not the worktree of a task unit."
key="${hit%%$'\t'*}"; idx="${hit#*$'\t'}"
task_lock "$key"
branch="$(task_get "$key" ".units[$idx].branch")"
remote="$(task_get "$key" ".units[$idx].remote")"
detached="$(task_get "$key" ".units[$idx].detached")"
if [ "$detached" != true ]; then
  [ "$(git -C "$wt" symbolic-ref --quiet --short HEAD || true)" = "$branch" ] \
    || die 7 "$wt is not on its branch $branch; nothing pushed."
fi

# 1. The remote branch may have moved without us.
if git -C "$wt" fetch --quiet "$remote" "$branch" 2>/dev/null; then
  if ! git -C "$wt" merge-base --is-ancestor "$remote/$branch" HEAD; then
    if ! git -C "$wt" merge --no-edit --quiet "$remote/$branch" >/dev/null 2>&1; then
      files="$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')"
      git -C "$wt" merge --abort
      die 9 "$remote/$branch moved and merging it conflicts in: ${files}— merge aborted, nothing pushed."
    fi
    printf 'merged %s/%s (moved on the remote)\n' "$remote" "$branch"
  fi
fi

# 2. Everything pushed is committed.
[ -z "$(git -C "$wt" status --porcelain)" ] || die 7 "$wt has uncommitted changes; commit them first. Nothing pushed."

# 3. The repository's checks, at HEAD.
n="$(task_get "$key" '.checks | length')"
[ "$n" -gt 0 ] || die 4 "No checks recorded for $key; record the lint/test commands with: task.sh checks $key '<command>'…"
log="$(task_dir "$key")/checks.log"; : > "$log"
i=0
while [ "$i" -lt "$n" ]; do
  c="$(task_get "$key" ".checks[$i]")"
  printf '$ %s\n' "$c" >> "$log"
  if ! (cd "$wt" && bash -c "$c") >> "$log" 2>&1; then
    tail -n 40 "$log"
    die 10 "Check failed: $c — nothing pushed. Full log: $log"
  fi
  i=$((i + 1))
done

# 4. Fast-forward only.
sha="$(git -C "$wt" rev-parse HEAD)"
if [ "$(git -C "$wt" rev-parse --verify --quiet "$remote/$branch" || true)" = "$sha" ]; then
  printf 'nothing to push: %s/%s is already at %s\n' "$remote" "$branch" "$sha"; exit 0
fi
git -C "$wt" push --quiet "$remote" "HEAD:refs/heads/$branch" || die 9 "Push of $branch was rejected; fetch and run push.sh again."
printf 'pushed %s to %s/%s\n' "$sha" "$remote" "$branch"

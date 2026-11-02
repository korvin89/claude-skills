#!/usr/bin/env bash
#
# push.sh — the only way a task pushes. In the unit's worktree, in order:
#   1. refuse uncommitted changes: everything pushed is committed;
#   2. fetch the unit's branch; when it moved on the remote (the author pushed,
#      "Commit suggestion", "Update branch"), merge it in — never rebase. On a
#      conflict the merge stays in progress: resolve it like a base conflict
#      (base.sh continue / abort), then run push.sh again;
#   3. run the task's check commands (task.sh checks) at HEAD;
#   4. push HEAD to refs/heads/<branch> of the unit's remote, fast-forward
#      only: no --force, ever.
#
# Usage: push.sh <worktree>
#
# Exit codes: 0 pushed (or nothing to push) · 1 git error · 4 bad usage or no
#             checks recorded (task.sh checks) · 7 not a task worktree, or
#             uncommitted changes · 9 the task is driven by another session
#             · 10 a check failed (its output tail is printed) · 11 the remote
#             branch moved and merging it conflicts ("CONFLICT <path>" lines;
#             the merge is in progress) · 12 the push was rejected; run again

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

# 1. Everything pushed is committed — and a merge needs a clean tree.
[ -z "$(git -C "$wt" status --porcelain)" ] || die 7 "$wt has uncommitted changes (or a merge in progress); commit or resolve them first. Nothing pushed."

# 2. The remote branch may have moved without us. An explicit refspec keeps the
#    remote-tracking ref even in single-branch clones.
if git -C "$wt" fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null; then
  if ! git -C "$wt" merge-base --is-ancestor "$remote/$branch" HEAD; then
    if ! git -C "$wt" merge --no-edit --quiet "$remote/$branch" >/dev/null 2>&1; then
      if git -C "$wt" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
        git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/CONFLICT /'
        die 11 "$remote/$branch moved and merging it conflicts; the merge is in progress. Nothing pushed."
      fi
      die 1 "Could not merge $remote/$branch into $wt; nothing pushed."
    fi
    printf 'merged %s/%s (moved on the remote)\n' "$remote" "$branch"
  fi
fi

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
git -C "$wt" push --quiet "$remote" "HEAD:refs/heads/$branch" || die 12 "Push of $branch was rejected; run push.sh again."
printf 'pushed %s to %s/%s\n' "$sha" "$remote" "$branch"

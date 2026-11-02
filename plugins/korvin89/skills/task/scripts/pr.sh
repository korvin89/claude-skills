#!/usr/bin/env bash
#
# pr.sh — the task's draft PR and the agent's block in its body. The block
# sits between <!-- korvin89:task:start --> and <!-- korvin89:task:end -->;
# text outside it is the author's and is never touched.
#
# Usage:
#   pr.sh titles                          titles of the last 10 merged PRs, to
#                                         model a new title on
#   pr.sh create <worktree> <title> <block-file>
#                                         create the unit's PR as a DRAFT with the
#                                         block as its body; if GitHub refuses a
#                                         draft, stop — never open a ready PR
#   pr.sh block <worktree> <block-file>   replace the block: re-read the body
#                                         right before writing, keep everything
#                                         outside the block, and carry the
#                                         author's [x] over by item text
#   pr.sh steps <worktree>                the block's manual steps as JSON:
#                                         [{text, done}] from "- [ ] Manual step: …"
#
# Exit codes: 0 ok · 1 GitHub error · 4 bad usage · 7 not a task worktree, or
#             the unit already has / has no PR · 9 the task is driven by
#             another session

set -euo pipefail
. "$(dirname "$0")/common.sh"

START='<!-- korvin89:task:start -->'
END='<!-- korvin89:task:end -->'
usage() { die 4 "Usage: pr.sh titles | create <worktree> <title> <block-file> | block <worktree> <block-file> | steps <worktree>"; }
[ $# -ge 1 ] || usage
cmd="$1"; shift
gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"' EXIT

unit_of() {
  local hit
  WT="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || die 4 "No such worktree: $1"
  hit="$(task_of "$WT")"; [ -n "$hit" ] || die 7 "$WT is not the worktree of a task unit."
  KEY="${hit%%$'\t'*}"; IDX="${hit#*$'\t'}"
}

# body_block <file> — the text between the markers, or nothing.
body_block() { awk -v s="$START" -v e="$END" '$0 == e { on = 0 } on { print } $0 == s { on = 1 }' "$1"; }

case "$cmd" in
  titles)
    [ $# -eq 0 ] || usage
    gh pr list --state merged --limit 10 --json title --jq '.[].title' ;;

  create)
    [ $# -eq 3 ] || usage
    unit_of "$1"; title="$2"; block="$3"
    [ -f "$block" ] || die 4 "No block file: $block"
    task_lock "$KEY"
    [ "$(task_get "$KEY" ".units[$IDX].pr // empty")" = "" ] || die 7 "This unit already has a PR."
    branch="$(task_get "$KEY" ".units[$IDX].branch")"; base="$(task_get "$KEY" .base)"
    { printf '%s\n' "$START"; cat "$block"; printf '%s\n' "$END"; } > "$GH_TMP/body.md"
    if ! gh_call "$GH_TMP/url" pr create --draft --base "$base" --head "$branch" --title "$title" --body-file "$GH_TMP/body.md"; then
      die 1 "GitHub did not create a draft PR (private repositories on GitHub Free have no drafts). Stopping: a ready PR is never opened instead."
    fi
    url="$(tail -n 1 "$GH_TMP/url")"
    task_set "$KEY" ".units[$IDX].pr = \$u" --arg u "$url"
    printf '%s\n' "$url" ;;

  block)
    [ $# -eq 2 ] || usage
    unit_of "$1"; block="$2"
    [ -f "$block" ] || die 4 "No block file: $block"
    task_lock "$KEY"
    pr="$(task_get "$KEY" ".units[$IDX].pr // empty")"; [ -n "$pr" ] || die 7 "This unit has no PR yet."
    gh_call "$GH_TMP/body.md" pr view "$pr" --json body --jq .body || exit 1
    body_block "$GH_TMP/body.md" | grep -E '^[[:space:]]*- \[[xX]\] ' | sed -E 's/^[[:space:]]*- \[[xX]\] //' > "$GH_TMP/done.txt" || true
    # The new block, with the author's ticks carried over by item text.
    awk 'NR == FNR { done[$0] = 1; next }
         match($0, /^[[:space:]]*- \[ \] /) { item = substr($0, RLENGTH + 1); if (item in done) sub(/- \[ \] /, "- [x] ") }
         { print }' "$GH_TMP/done.txt" "$block" > "$GH_TMP/block.md"
    if grep -qxF "$START" "$GH_TMP/body.md" && grep -qxF "$END" "$GH_TMP/body.md"; then
      awk -v s="$START" -v e="$END" -v f="$GH_TMP/block.md" '
        $0 == s { print; while ((getline l < f) > 0) print l; skip = 1; next }
        $0 == e { skip = 0 }
        !skip { print }' "$GH_TMP/body.md" > "$GH_TMP/new.md"
    else
      { cat "$GH_TMP/body.md"; printf '\n%s\n' "$START"; cat "$GH_TMP/block.md"; printf '%s\n' "$END"; } > "$GH_TMP/new.md"
    fi
    gh_call /dev/null pr edit "$pr" --body-file "$GH_TMP/new.md" || exit 1
    printf 'block updated in %s\n' "$pr" ;;

  steps)
    [ $# -eq 1 ] || usage
    unit_of "$1"
    pr="$(task_get "$KEY" ".units[$IDX].pr // empty")"; [ -n "$pr" ] || die 7 "This unit has no PR yet."
    gh_call "$GH_TMP/body.md" pr view "$pr" --json body --jq .body || exit 1
    { body_block "$GH_TMP/body.md" | grep -E '^[[:space:]]*- \[[ xX]\] Manual step:' || true; } \
      | jq -R -s -c 'split("\n") | map(select(length > 0)
          | {done: test("^\\s*- \\[[xX]\\]"), text: sub("^\\s*- \\[[ xX]\\] Manual step:\\s*"; "")})' ;;

  *) usage ;;
esac

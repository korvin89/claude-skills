#!/usr/bin/env bash
#
# ci.sh — the checks of a task unit's PR, read per check, never from the
# rollup's overall state: on a draft, a job skipped by
# `if: github.event.pull_request.draft == false` is SKIPPED while the rollup
# says SUCCESS.
#
# Usage:
#   ci.sh state <worktree>          JSON: the PR's head, draft and mergeable
#                                   state, every check (kind: actions / app /
#                                   status) and a summary — pending, failed,
#                                   skipped, expected (declared failures),
#                                   green (nothing pending, failed or skipped)
#   ci.sh log <worktree> <check>    the failed run's log, trimmed: up to 40
#                                   "##[error]" lines, then the last 120 lines
#                                   (Actions only; others print their link)
#   ci.sh rerun <worktree> <check>  rerun a failed Actions check — only while its
#                                   run is on the PR head, at most 2 reruns by
#                                   GitHub's own attempt counter
#   ci.sh fixes <worktree> <check>  how many commits on the branch carry
#                                   "CI-fix: <check>" (the cap is 3)
#
# Checks that fail by design are listed in AGENTS.md of the base branch, read
# from origin/<base> (the branch itself can't change them), as bullets under
# a "## Expected failing checks" heading.
# Check names seen on an earlier head are remembered in the task ledger: right
# after a push, a check that has not shown up yet counts as pending, not as
# passed.
#
# Exit codes: 0 ok · 1 GitHub error · 4 bad usage · 7 not a task worktree, or
#             a rerun refused

set -euo pipefail
. "$(dirname "$0")/common.sh"

usage() { die 4 "Usage: ci.sh state|log|rerun|fixes <worktree> [<check>]"; }
[ $# -ge 2 ] || usage
cmd="$1"; shift
WT="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || die 4 "No such worktree: $1"; shift
hit="$(task_of "$WT")"; [ -n "$hit" ] || die 7 "$WT is not the worktree of a task unit."
KEY="${hit%%$'\t'*}"; IDX="${hit#*$'\t'}"
gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"' EXIT
pr="$(task_get "$KEY" ".units[$IDX].pr // empty")"; [ -n "$pr" ] || die 7 "This unit has no PR yet."
gh_pr "$pr" || exit 1
ledger="$(task_dir "$KEY")/ledger.json"

STATE_QUERY='query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $n) {
  state isDraft mergeable headRefOid
  commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100) { nodes { __typename
    ... on CheckRun { name status conclusion detailsUrl checkSuite { app { slug } workflowRun { databaseId } } }
    ... on StatusContext { context state targetUrl } } } } } } } } } }'

# state_json — the normalized state; also remembers the check names it saw.
state_json() {
  local raw base expected seen
  raw="$(gql "$STATE_QUERY" "$(jq -n --arg o "$PR_OWNER" --arg r "$PR_REPO" --argjson n "$PR_NUM" '{o: $o, r: $r, n: $n}')")" || return 1
  base="$(task_get "$KEY" .base)"
  expected="$(git -C "$WT" show "origin/$base:AGENTS.md" 2>/dev/null \
    | awk '/^## / { on = ($0 ~ /^## Expected failing checks/) ; next } on && /^[-*] / { sub(/^[-*] +/, ""); gsub(/`/, ""); print }' \
    | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  seen="$(jq -c --arg pr "$pr" '.checks_seen[$pr] // []' "$ledger")"
  jq -c --argjson expected "$expected" --argjson seen "$seen" --arg local "$(git -C "$WT" rev-parse HEAD)" '
    .data.repository.pullRequest as $p
    | [ ($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[]
        | if .__typename == "CheckRun" then
            {name, kind: (if .checkSuite.app.slug == "github-actions" and .checkSuite.workflowRun != null then "actions" else "app" end),
             run: .checkSuite.workflowRun.databaseId, url: .detailsUrl,
             result: (if .status != "COMPLETED" then "pending"
                      elif (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL") then "ok"
                      elif .conclusion == "SKIPPED" then "skipped"
                      else "failed" end)}
          else
            {name: .context, kind: "status", run: null, url: .targetUrl,
             result: (if .state == "SUCCESS" then "ok" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "failed" end)}
          end ] as $checks
    | ([$checks[].name]) as $names
    | { state: $p.state, draft: $p.isDraft, mergeable: $p.mergeable, head: $p.headRefOid,
        pushed: ($p.headRefOid == $local), checks: $checks,
        summary: {
          pending: ([$checks[] | select(.result == "pending") | .name] + [$seen[] | select(. as $s | any($names[]; . == $s) | not)]),
          failed:  [$checks[] | select(.result == "failed" and (.name as $n | any($expected[]; . == $n) | not)) | .name],
          skipped: [$checks[] | select(.result == "skipped") | .name],
          expected: [$checks[] | select(.result == "failed" and (.name as $n | any($expected[]; . == $n))) | .name] } }
    | .summary.green = ((.summary.pending + .summary.failed + .summary.skipped | length) == 0 and ($checks | length) > 0)
  ' <<<"$raw" > "$GH_TMP/state.json"
  # Remember the names, so a fresh push without checks yet is not read as green.
  jq --arg pr "$pr" --argjson n "$(jq -c '[.checks[].name]' "$GH_TMP/state.json")" \
    'if ($n | length) > 0 then .checks_seen[$pr] = ($n | unique) else . end' "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
  cat "$GH_TMP/state.json"
}

# check_of <name> — read the state into $GH_TMP/s.json and set C to that check.
check_of() {
  state_json > "$GH_TMP/s.json" || exit 1
  C="$(jq -e -c --arg c "$1" 'first(.checks[] | select(.name == $c))' "$GH_TMP/s.json")" || die 4 "No check named $1 on $pr."
}

case "$cmd" in
  state)
    [ $# -eq 0 ] || usage
    state_json ;;

  log)
    [ $# -eq 1 ] || usage
    check_of "$1"; c="$C"
    if [ "$(jq -r .kind <<<"$c")" != actions ]; then
      printf 'No log here for a %s check; see %s\n' "$(jq -r .kind <<<"$c")" "$(jq -r '.url // "-"' <<<"$c")"; exit 0
    fi
    gh_call "$GH_TMP/log" run view "$(jq -r .run <<<"$c")" --repo "$PR_OWNER/$PR_REPO" --log-failed || exit 1
    sed $'s/\x1b\\[[0-9;]*m//g' "$GH_TMP/log" > "$GH_TMP/clean"
    if grep -q '##\[error\]' "$GH_TMP/clean"; then
      echo "--- errors"; grep '##\[error\]' "$GH_TMP/clean" | head -n 40
    fi
    echo "--- last 120 lines"; tail -n 120 "$GH_TMP/clean" ;;

  rerun)
    [ $# -eq 1 ] || usage
    check_of "$1"; c="$C"
    [ "$(jq -r .kind <<<"$c")" = actions ] || die 7 "Only GitHub Actions checks can be rerun from here; ${1} is a $(jq -r .kind <<<"$c") check."
    run="$(jq -r .run <<<"$c")"
    gh_call "$GH_TMP/run.json" api --hostname "$PR_HOST" "repos/$PR_OWNER/$PR_REPO/actions/runs/$run" || exit 1
    [ "$(jq -r .head_sha "$GH_TMP/run.json")" = "$(jq -r .head "$GH_TMP/s.json")" ] \
      || die 7 "Run $run is not on the PR head any more; nothing rerun."
    [ "$(jq -r .status "$GH_TMP/run.json")" = completed ] || die 7 "Run $run is still going; nothing rerun."
    attempt="$(jq -r .run_attempt "$GH_TMP/run.json")"
    [ "$attempt" -lt 3 ] || die 7 "Run $run already had $attempt attempts (2 reruns); treat $1 as a real failure."
    gh_call /dev/null run rerun "$run" --failed --repo "$PR_OWNER/$PR_REPO" || exit 1
    printf 'rerun of %s requested (attempt %s)\n' "$1" "$((attempt + 1))" ;;

  fixes)
    [ $# -eq 1 ] || usage
    git -C "$WT" log --format='%(trailers:key=CI-fix,valueonly)' HEAD | grep -cxF "$1" || true ;;

  *) usage ;;
esac

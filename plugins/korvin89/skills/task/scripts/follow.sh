#!/usr/bin/env bash
#
# follow.sh — the state of a whole task, and the watcher over its open PRs.
#
# Usage:
#   follow.sh status <key>    JSON, one entry per unit: slug, branch, worktree,
#                             PR, CI (ci.sh state), discussion (threads.sh scan),
#                             manual steps; plus the parked events. The source
#                             of truth after a context compaction
#   follow.sh watch <key> [--interval S] [--max-interval S] [--quiet S]
#                             watch every unit with an open PR and print one line:
#     MERGED <pr>             merged       } announced once; that PR is not
#     CLOSED <pr>             closed       } polled again
#     READY <pr>              the author moved it out of draft
#     CONFLICTS <pr>          the base conflicts
#     CI_FAILED <pr> <checks> failed checks, none of them parked on this head
#     CI_DONE <pr>            every check passed on the head (announced once per head)
#     COMMENTS <pr> <n>       n unhandled triggers (see threads.sh), once they
#                             stop changing for --quiet seconds
#     AUTH … / ERROR …        as in lib/watch.sh
#   The watch runs until it has something to say; polls back off from
#   --interval (20) to --max-interval (300).
#
# Parked events (task.sh park) stay quiet while their lift has not changed:
#   head:<sha>      the PR head
#   base:<sha>      the base branch head on GitHub (baseRefOid)
#   comment:<n>     the author's comment count on the PR (threads.sh `mine`)
# Park ids: ci:<pr>:<check>, conflict:<pr>, or a trigger's comment id.
#
# Exit codes: 0 ok · 1 GitHub error · 4 bad usage · 9 the task is driven by
#             another session

set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$TASK_LIB/watch.sh"

usage() { die 4 "Usage: follow.sh status|watch <key> [options]"; }
[ $# -ge 2 ] || usage
cmd="$1"; KEY="$2"; shift 2
[ -f "$(task_dir "$KEY")/task.json" ] || die 4 "No task $KEY in this repository."
gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"; watch_release' EXIT
HERE="$(dirname "$0")"
LEDGER="$(task_dir "$KEY")/ledger.json"

# open_units — "<worktree>\t<pr>" for every unit with an open PR and a worktree,
# leaving out PRs already announced as merged or closed.
open_units() {
  jq -r --slurpfile l "$LEDGER" '($l[0].ended // {}) as $e
    | .units[] | select(.pr != null and .worktree != null and .status != "done" and ($e[.pr] == null))
    | "\(.worktree)\t\(.pr)"' "$(task_dir "$KEY")/task.json"
}

# parked <id> <head> <base> — true while that event is parked and its lift holds.
parked() {
  jq -e --arg id "$1" --arg head "$2" --arg base "$3" '
    any(.parked[]; .id == $id and (
      (.lift | startswith("head:") and .[5:] == $head) or
      (.lift | startswith("base:") and .[5:] == $base)))' "$LEDGER" >/dev/null
}

ledger_set() { ledger_update "$KEY" "$@"; }

task_probe() {
  local wt pr ci th base head n ids fp="" waits=0 failed
  while IFS=$'\t' read -r wt pr; do
    [ -n "$wt" ] || continue
    ci="$(bash "$HERE/ci.sh" state "$wt")" || return 1
    head="$(jq -r .head <<<"$ci")"; base="$(jq -r '.base // ""' <<<"$ci")"
    case "$(jq -r .state <<<"$ci")" in
      MERGED|CLOSED)
        ledger_set '.ended = ((.ended // {}) + {($pr): $s})' --arg pr "$pr" --arg s "$(jq -r .state <<<"$ci")"
        printf 'NOW\t%s %s\n' "$(jq -r .state <<<"$ci")" "$pr"; return 0 ;;
    esac
    if [ "$(jq -r .draft <<<"$ci")" = false ] && ! jq -e --arg pr "$pr" 'any(.ready[]?; . == $pr)' "$LEDGER" >/dev/null; then
      ledger_set '.ready = ((.ready // []) + [$pr])' --arg pr "$pr"
      printf 'NOW\tREADY %s\n' "$pr"; return 0
    fi
    if [ "$(jq -r .mergeable <<<"$ci")" = CONFLICTING ] && ! parked "conflict:$pr" "$head" "$base"; then
      printf 'NOW\tCONFLICTS %s\n' "$pr"; return 0
    fi
    failed="$(jq -r '.summary.failed[]' <<<"$ci" | while IFS= read -r c; do
                parked "ci:$pr:$c" "$head" "$base" || printf '%s,' "$c"; done)"
    if [ -n "$failed" ]; then
      printf 'NOW\tCI_FAILED %s %s\n' "$pr" "${failed%,}"; return 0
    fi
    if jq -e '.summary.green' <<<"$ci" >/dev/null \
       && ! jq -e --arg pr "$pr" --arg h "$head" '(.ci_done // {})[$pr] == $h' "$LEDGER" >/dev/null; then
      ledger_set '.ci_done = ((.ci_done // {}) + {($pr): $h})' --arg pr "$pr" --arg h "$head"
      printf 'NOW\tCI_DONE %s\n' "$pr"; return 0
    fi
    th="$(bash "$HERE/threads.sh" scan "$wt")" || return 1
    # Triggers parked on the head or the base stay quiet (comment: lifts are
    # handled by threads.sh itself).
    ids="$(jq -r '(.valid + .commands + .bots)[].id' <<<"$th" | while IFS= read -r id; do
             parked "$id" "$head" "$base" || printf '%s\n' "$id"; done)"
    n="$(printf '%s' "$ids" | grep -c . || true)"
    if [ "$n" -gt 0 ]; then
      waits=$((waits + n))
      fp="$fp$(printf '%s' "$ids" | tr '\n' ',')"
      WAIT_PR="$pr"
    fi
  done < <(open_units)
  [ "$waits" -eq 0 ] || printf 'WAIT\t%s\tCOMMENTS %s %s\n' "$fp" "$WAIT_PR" "$waits"
}

case "$cmd" in
  status)
    [ $# -eq 0 ] || usage
    units="[]"
    while IFS= read -r u; do
      wt="$(jq -r '.worktree // empty' <<<"$u")"; pr="$(jq -r '.pr // empty' <<<"$u")"
      if [ -n "$wt" ] && [ -n "$pr" ]; then
        ci="$(bash "$HERE/ci.sh" state "$wt" 2>/dev/null || echo null)"
        th="$(bash "$HERE/threads.sh" scan "$wt" 2>/dev/null || echo null)"
        st="$(bash "$HERE/pr.sh" steps "$wt" 2>/dev/null || echo null)"
      else
        ci=null; th=null; st=null
      fi
      units="$(jq -c --argjson u "$u" --argjson ci "$ci" --argjson th "$th" --argjson st "$st" \
        '. + [$u + {ci: $ci, discussion: $th, steps: $st}]' <<<"$units")"
    done < <(task_get "$KEY" '.units[] | @json')
    jq -n --argjson t "$(cat "$(task_dir "$KEY")/task.json")" --argjson units "$units" --argjson l "$(cat "$LEDGER")" \
      '{key: $t.key, source: $t.source, base: $t.base, checks: $t.checks, units: $units, parked: $l.parked}' ;;

  watch)
    WATCH_INTERVAL=20; WATCH_MAX_INTERVAL=300
    while [ $# -gt 0 ]; do
      case "$1" in
        --interval)     WATCH_INTERVAL="${2:-}" ;;
        --max-interval) WATCH_MAX_INTERVAL="${2:-}" ;;
        --quiet)        WATCH_QUIET="${2:-}" ;;
        *)              usage ;;
      esac
      case "${2:-}" in ''|*[!0-9]*) die 4 "$1 needs a whole number of seconds." ;; esac
      shift 2
    done
    task_lock "$KEY"
    watch_pid "$(task_dir "$KEY")/watch-task.pid"
    WAIT_PR=""
    watch_loop task_probe ;;

  *) usage ;;
esac

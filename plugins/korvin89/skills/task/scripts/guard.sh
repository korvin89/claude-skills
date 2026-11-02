#!/usr/bin/env bash
#
# guard.sh — the task skill's PreToolUse hook. It holds the skill's "never"
# rules in code while a task is active in this session (task.sh activate):
#   - Edit / Write / MultiEdit / NotebookEdit only inside the active tasks'
#     worktrees, the review scratch (<git-common-dir>/code-review) and temp
#     dirs — never in the user's own checkout;
#   - Bash:
#     · no raw `git push` (push.sh does it), no history rewrites or discards
#       (rebase, reset --hard, stash, clean, commit --amend), no branch or
#       worktree deletion, no switch, no checkout other than resolving a
#       conflict (--theirs / --ours / -- <path>);
#     · git writes (add, commit, merge, restore, reset, …) only when the
#       command addresses a task worktree (`git -C <worktree>` or
#       `cd <worktree>`): never in the user's checkout;
#     · no GitHub writes outside the task scripts: gh pr / issue writes,
#       gh run rerun/cancel, gh api mutations, -X/--method other than GET, or
#       fields / --input on a REST call (an implicit POST).
#   Quotes count as command separators, so `bash -c 'git push'` is caught; a
#   message that merely mentions such a command is not.
# With no active task for this session it says nothing and every call goes
# through as usual. It never fails a call by crashing: errors allow.
#
# Input: the hook JSON on stdin (session_id, cwd, tool_name, tool_input).
# Output: nothing (no opinion), or a PreToolUse deny decision.

set -u
input="$(cat)"
deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0
session="$(jq -r '.session_id // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
tool="$(jq -r '.tool_name // empty' <<<"$input")"
[ -n "$session" ] && [ -n "$cwd" ] || exit 0
common="$(cd "$cwd" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || exit 0
root="$(cd "$cwd" && CDPATH='' cd -P -- "$common" && pwd -P)/code-review" || exit 0

# The worktrees of the tasks this session drives, one per line; none → no opinion.
grep -lx "$session" "$root"/task-*/active >/dev/null 2>&1 || exit 0
active="$(for f in "$root"/task-*/active; do
            [ -f "$f" ] && [ "$(cat "$f")" = "$session" ] && jq -r '.units[].worktree // empty' "${f%/active}/task.json"
          done 2>/dev/null)"
list="$(printf '%s' "$active" | tr '\n' ',' | sed 's/,$//')"

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")"
    [ -n "$path" ] || exit 0
    case "$path" in /*) ;; *) path="$cwd/$path" ;; esac
    dir="$(dirname "$path")"
    while [ ! -d "$dir" ] && [ "$dir" != / ]; do dir="$(dirname "$dir")"; done
    real="$(cd "$dir" && pwd -P)/"
    inside() { local r; r="$(cd "$1" 2>/dev/null && pwd -P)" || return 1; case "$real" in "$r"/*) return 0 ;; esac; return 1; }
    # The scratch and the task worktrees first; then never the user's checkout,
    # wherever it lives; then temp dirs.
    inside "$root" && exit 0
    while IFS= read -r ok; do [ -n "$ok" ] && inside "$ok" && exit 0; done <<<"$active"
    main="$(cd "$cwd" && git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10); exit }')"
    if [ -n "$main" ] && ! inside "$main"; then
      for ok in "${TMPDIR:-/tmp}" /tmp /private/tmp /private/var/folders; do inside "$ok" && exit 0; done
    fi
    deny "A task is active in this session: edits go only into its worktrees ($list) or the scratch dir. $path is outside them — for the user's own checkout, say «пауза» / pause (task.sh deactivate) first." ;;

  Bash)
    raw="$(jq -r '.tool_input.command // empty' <<<"$input")"
    c="$(printf '%s' "$raw" | tr "'\"" ';;')"
    has() { printf '%s' "$c" | grep -Eq "$1"; }
    lead='(^|[;&|(`]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
    git="${lead}git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+"
    end='([[:space:]]|;|$)'

    has "${git}push${end}" \
      && deny "Raw git push is blocked while a task is active: push with the task's push.sh, which merges a moved branch, runs the checks and never forces."
    if has "${git}(rebase|stash|clean|switch)${end}" || has "${git}reset[[:space:]]+(.*[[:space:]])?--hard" \
       || has "${git}commit[[:space:]].*--amend" || has "${git}branch[[:space:]]+(.*[[:space:]])?(-[dD]|--delete)" \
       || has "${git}worktree[[:space:]]+(remove|prune)" \
       || { has "${git}checkout${end}" && ! has "${git}checkout[[:space:]]+(--theirs|--ours|--)[[:space:]]"; }; then
      deny "This git command rewrites history, discards changes, switches branches or deletes a branch/worktree; the task never does that. Use the task scripts (base.sh, wt.sh finish), resolve a conflict with checkout --theirs/--ours -- <path>, or ask the user."
    fi
    if has "${git}(add|commit|merge|pull|restore|reset|rm|mv|apply|am|cherry-pick|revert|tag|checkout)${end}"; then
      targeted=no
      while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        case "$raw" in *"-C $wt"*|*"-C \"$wt\""*|*"-C '$wt'"*|*"cd $wt"*|*"cd \"$wt\""*|*"cd '$wt'"*) targeted=yes ;; esac
      done <<<"$active"
      [ "$targeted" = yes ] \
        || deny "git writes while a task is active go only into a task worktree: run them as git -C <worktree> … (or cd <worktree> && …). Worktrees: $list. Never in the user's own checkout."
    fi
    if has "${lead}gh[[:space:]]+pr[[:space:]]+(ready|merge|close|reopen|review|create|edit|comment)${end}" \
       || has "${lead}gh[[:space:]]+issue[[:space:]]+(comment|create|edit|close|reopen|delete|transfer|pin|unpin|lock|unlock)${end}" \
       || has "${lead}gh[[:space:]]+run[[:space:]]+(rerun|cancel|delete)${end}"; then
      deny "gh writes are blocked while a task is active: the PR is created and edited by pr.sh, reruns go through ci.sh; draft/ready, merge, reviews and issues belong to the user."
    fi
    if has "${lead}gh[[:space:]]+api[[:space:]]"; then
      if has "${lead}gh[[:space:]]+api[[:space:]]+(.*[[:space:]])?graphql${end}"; then
        if printf '%s' "$c" | grep -Eqi 'mutation' || has '[[:space:]]--input([[:space:]=]|$)'; then
          deny "GitHub GraphQL writes are blocked while a task is active: use the task scripts (threads.sh, ci.sh, pr.sh)."
        fi
      elif printf '%s' "$c" | grep -Eqi '(-X|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)' \
           || has '[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
        deny "GitHub REST writes are blocked while a task is active (fields or --input make gh api POST): use the task scripts."
      fi
    fi ;;
esac
exit 0

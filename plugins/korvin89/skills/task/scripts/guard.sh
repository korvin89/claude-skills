#!/usr/bin/env bash
#
# guard.sh — the task skill's PreToolUse hook. It holds the skill's "never"
# rules in code while a task is active in this session (task.sh activate):
#   - Edit / Write / MultiEdit / NotebookEdit only inside the active tasks'
#     worktrees, the review scratch (<git-common-dir>/code-review) and temp
#     dirs — never in the user's own checkout;
#   - Bash never runs a raw `git push` (push.sh does it), force or history
#     rewrites (rebase, reset --hard, stash, commit --amend, clean), branch or
#     worktree deletion, checkout/switch, or GitHub writes outside the task
#     scripts (gh pr ready/merge/close/review/create/edit, gh api mutations,
#     POST/PUT/PATCH/DELETE).
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

# Worktrees of the tasks this session drives; none → no opinion.
active="$(for f in "$root"/task-*/active; do
            [ -f "$f" ] && [ "$(cat "$f")" = "$session" ] && jq -r '.units[].worktree // empty' "${f%/active}/task.json"
          done 2>/dev/null)"
ls "$root"/task-*/active >/dev/null 2>&1 || exit 0
grep -lx "$session" "$root"/task-*/active >/dev/null 2>&1 || exit 0

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
    for ok in $active; do inside "$ok" && exit 0; done
    main="$(cd "$cwd" && git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10); exit }')"
    if [ -n "$main" ] && ! inside "$main"; then
      for ok in "${TMPDIR:-/tmp}" /tmp /private/tmp /private/var/folders; do inside "$ok" && exit 0; done
    fi
    deny "A task is active in this session: edits go only into its worktrees ($(echo $active | tr ' ' ',')) or the scratch dir. $path is outside them — for the user's own checkout, say «пауза» / pause (task.sh deactivate) first." ;;
  Bash)
    c="$(jq -r '.tool_input.command // empty' <<<"$input")"
    lead='(^|[;&|(`]|\$\()[[:space:]]*'
    git_cmd="${lead}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+"
    if printf '%s' "$c" | grep -Eq "${git_cmd}push([[:space:]]|$)"; then
      deny "Raw git push is blocked while a task is active: push with the task's push.sh, which merges a moved branch, runs the checks and never forces."
    fi
    if printf '%s' "$c" | grep -Eq "${git_cmd}(rebase|stash|clean|checkout|switch)([[:space:]]|$)|${git_cmd}reset[[:space:]]+(.*[[:space:]])?--hard|${git_cmd}commit[[:space:]].*--amend|${git_cmd}(branch[[:space:]]+(.*[[:space:]])?(-[dD]|--delete)|worktree[[:space:]]+(remove|prune))"; then
      deny "This git command rewrites history, discards changes or deletes a branch/worktree; the task never does that. Use the task scripts (base.sh for the base, wt.sh finish to clean up), or ask the user."
    fi
    if printf '%s' "$c" | grep -Eq "${lead}gh[[:space:]]+pr[[:space:]]+(ready|merge|close|review|create|edit|comment)([[:space:]]|$)"; then
      deny "gh pr writes are blocked while a task is active: the PR is created and its block edited by pr.sh; draft/ready, merge and reviews belong to the user."
    fi
    if printf '%s' "$c" | grep -Eq "${lead}gh[[:space:]]+api[[:space:]]" \
       && printf '%s' "$c" | grep -Eqi "mutation|(-X|--method)[[:space:]]*(POST|PUT|PATCH|DELETE)"; then
      deny "GitHub writes through gh api are blocked while a task is active: use the task scripts (threads.sh, ci.sh, pr.sh)."
    fi ;;
esac
exit 0

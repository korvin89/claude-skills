# common.sh — task state shared by the task scripts. Source it after
# `set -euo pipefail`; it sources the plugin's lib/gh.sh as well.
#
# A task keeps its state in <git-common-dir>/code-review/task-<key>/:
#   task.json    the task: source, repository, base branch, check commands and
#                its units (one per PR: slug, branch, worktree, PR URL, …)
#   brief.md     the task text as given or read from its source
#   ledger.json  handled and parked events, comment ids already seen
#   lock         "<session id> <claude pid> <epoch>" of the session driving it
#   watch-task.pid
# Worktrees live next to the repository, outside it:
#   <parent of the main worktree>/<its name>.worktrees/<branch>
#
#   task_main                 the main worktree's path
#   task_root                 <git-common-dir>/code-review
#   task_dir <key>            the task's state dir (not created)
#   task_wt_dir               the sibling dir that holds the task worktrees
#   task_get <key> <jq>       read task.json through a jq filter
#   task_set <key> <jq> [jq args…]
#   ledger_update <key> <jq> [jq args…]
#                             rewrite task.json / ledger.json through a jq
#                             filter, atomically and under a lock
#   task_of <path>            "<key>\t<unit index>" of the unit whose worktree
#                             holds <path>, or nothing
#   task_lock <key>           take the task's lock for this Claude session
#                             (CLAUDE_CODE_SESSION_ID); exit 9 when another
#                             session holds it and its Claude process (CLAUDE_PID)
#                             is still alive

TASK_LIB="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
. "$TASK_LIB/gh.sh"

task_main() {
  git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }'
}

task_root() {
  printf '%s/code-review\n' "$(CDPATH='' cd -P -- "$(git rev-parse --git-common-dir)" && pwd -P)"
}

task_dir() { printf '%s/task-%s\n' "$(task_root)" "$1"; }

task_wt_dir() {
  local main
  main="$(task_main)"
  printf '%s/%s.worktrees\n' "$(dirname "$main")" "$(basename "$main")"
}

task_get() { jq -r "$2" "$(task_dir "$1")/task.json"; }

task_set() {
  local key="$1"; shift
  json_update "$(task_dir "$key")/task.json" "$@"
}

ledger_update() {
  local key="$1"; shift
  json_update "$(task_dir "$key")/ledger.json" "$@"
}

# json_update <file> <jq> [jq args…] — read-modify-write under a mkdir lock,
# through a private temp file: the watcher and the agent write the same files.
json_update() {
  local file="$1" filter="$2" tmp n=0 rc=0; shift 2
  until mkdir "$file.lock" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 100 ] || die 1 "Could not lock $file (stale $file.lock?)."
    sleep 0.1
  done
  tmp="$(mktemp "$file.XXXXXX")"
  if jq "$@" "$filter" "$file" > "$tmp"; then mv "$tmp" "$file"; else rc=1; rm -f "$tmp"; fi
  rmdir "$file.lock"
  return "$rc"
}

task_of() {
  local p f key
  p="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || return 0
  for f in "$(task_root)"/task-*/task.json; do
    [ -f "$f" ] || continue
    key="$(jq -r .key "$f")"
    jq -r --arg p "$p" --arg k "$key" '
      .units | to_entries[] | .value.worktree as $w
      | select($w != null and ($p == $w or ($p | startswith($w + "/"))))
      | "\($k)\t\(.key)"' "$f"
  done | head -n 1
}

task_lock() {
  local file holder pid me
  file="$(task_dir "$1")/lock"
  me="${CLAUDE_CODE_SESSION_ID:-shell-$PPID}"
  if [ -f "$file" ]; then
    read -r holder pid _ < "$file" || true
    # Another session, alive. The same Claude process (e.g. after /clear gave it
    # a new session id) is still us.
    if [ "$holder" != "$me" ] && [ -n "$pid" ] && [ "$pid" != "${CLAUDE_PID:-$PPID}" ] && kill -0 "$pid" 2>/dev/null; then
      die 9 "Task $1 is driven by another Claude session (pid $pid). Finish it there, or close that session."
    fi
  fi
  printf '%s %s %s\n' "$me" "${CLAUDE_PID:-$PPID}" "$(date +%s)" > "$file"
}

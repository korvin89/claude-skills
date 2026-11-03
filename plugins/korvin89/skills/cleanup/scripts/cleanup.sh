#!/usr/bin/env bash
#
# cleanup.sh — remove the scratch korvin89 review skills keep for one review,
# after checking it is the scratch you mean.
#
# Every review keeps its scratch in <git-common-dir>/code-review/<key>/, where
# <key> is pr-<N> for a pull request, local-<id> for a review without one (one
# per checkout: <id> is the cksum of the checkout's top-level path), and
# task-<key> for a task of the task skill (its layout: task/scripts/common.sh;
# its worktrees live next to the repository and are covered too):
#   pr.url             the PR the scratch belongs to (pr-<N>)
#   owner              the checkout the scratch belongs to (local-<id>)
#   head/              the PR head worktree (code-review)
#   batch.json         the findings batch (code-review)
#   artifacts/<slug>/  screenshots, configs and their worktrees (review-artifacts)
#   watch.pid, watch-task.pid
#                      the pid of a running watcher (draft.sh, follow.sh)
#   watch.json         what draft.sh watch has announced (code-review)
# It sits inside .git, so it never shows in `git status`.
#
# Usage:
#   cleanup.sh <pr | #pr | pr-<N> | pr-url | local | local-<id> | task-<key>> [--yes=<code>]
#                                        remove that scratch
#   cleanup.sh path <pr-url | pr | local>
#                                        print the scratch dir, creating it and
#                                        recording whose it is
#   cleanup.sh list [--except <key>]     one line per scratch dir:
#                                        key, size, age, whose
#
# Before removing, these checks run; each finding is a warning:
#   - the scratch does not say whose it is, or says another PR / checkout;
#   - the PR cannot be looked up, or no git remote points at its repository;
#   - a worktree in the scratch has uncommitted or untracked files, or git
#     cannot read it (e.g. the repository folder was moved);
#   - the current directory is inside the scratch;
#   - a watcher for it is still running;
#   - for a task: it is active in a Claude session, or one of its worktrees
#     holds uncommitted files or commits not pushed to its branch.
# Removing a task also removes its worktrees, and its local branches only when
# every commit on them is pushed; others are kept and named.
# The warnings are always printed. With any warning, nothing is removed unless
# --yes=<code> carries the code of exactly these warnings: otherwise the script
# prints "CONFIRM <code>" with the warnings and exits 10. Only git's records of
# worktrees inside this scratch are dropped; nothing outside
# <git-common-dir>/code-review/<key>/ is removed.
#
# Exit codes: 0 ok, also nothing to clean · 1 a worktree could not be removed
#             · 2 not a git repo · 4 bad usage, or the scratch is another PR's (path)
#             · 10 needs confirmation

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }
usage() { die 4 "Usage: cleanup.sh <pr-number | pr-url | pr-<N> | local | task-<key>> [--yes=<code>] | path <pr | local> | list [--except <key>]"; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 2 "Not inside a git repository."
common="$(CDPATH='' cd -P -- "$(git rev-parse --git-common-dir)" && pwd -P)"
root="$common/code-review"
top="$(git rev-parse --show-toplevel)"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
size()  { du -sh "$1" 2>/dev/null | awk '{ print $1 }'; }

# key <arg> — set $k to the scratch key of an argument, and $given_url when it
# is a PR URL; return 1 for anything else.
k=""; given_url=""
key() {
  local a="${1#\#}"
  case "$a" in
    local)              k="local-$(printf '%s\n' "$top" | cksum | cut -d' ' -f1)" ;;
    local-[0-9]*)       case "${a#local-}" in *[!0-9]*) return 1 ;; esac; k="$a" ;;
    pr-[0-9]*)          case "${a#pr-}" in *[!0-9]*) return 1 ;; esac; k="$a" ;;
    task-?*)            case "${a#task-}" in *[!a-z0-9-]*) return 1 ;; esac; k="$a" ;;
    http*://*/pull/[0-9]*)
                        given_url="${a%%[?#]*}"; given_url="${given_url%/}"
                        a="${given_url##*/pull/}"; a="${a%%/*}"
                        given_url="${given_url%%/pull/*}/pull/$a"
                        case "$a" in ""|*[!0-9]*) return 1 ;; esac; k="pr-$a" ;;
    ""|*[!0-9]*)        return 1 ;;
    *)                  k="pr-$a" ;;
  esac
}

# pr_url <number> — the PR's URL as gh resolves it from this repository, cut
# after 15 s; the reason on stderr when it cannot.
pr_url() {
  local out pid dog rc=0
  command -v gh >/dev/null 2>&1 || { err "gh is not installed"; return 1; }
  out="$(mktemp)"
  gh pr view "$1" --json url --jq .url > "$out" 2> "$out.err" & pid=$!
  ( sleep 15 && kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & dog=$!
  wait "$pid" || rc=$?
  if kill -0 "$dog" 2>/dev/null; then pkill -P "$dog" 2>/dev/null || true; kill "$dog" 2>/dev/null || true
  elif [ "$rc" -ne 0 ]; then echo "no answer from GitHub in 15 s" > "$out.err"; fi
  wait "$dog" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then cat "$out"; else err "$(tail -n 1 "$out.err")"; fi
  rm -f "$out" "$out.err"
  return "$rc"
}

# repo_remote <pr-url> — true when a git remote points at the PR's repository.
repo_remote() {
  local want name u _
  want="$(lower "$(printf '%s' "$1" | sed -E 's#^[a-z]+://[^/]+(/[^/]+/[^/]+)/pull/.*#\1#')")"
  while read -r name u _; do
    u="$(lower "$u" | tr ':' '/')"; u="${u%/}"; u="${u%.git}"
    case "$u" in *"$want") return 0 ;; esac
  done < <(git remote -v | awk '$3 == "(fetch)"')
  return 1
}

# worktrees <dir> — every git checkout found on disk under <dir>.
worktrees() {
  find "$1" \( -name node_modules -o -name .git \) -prune -name .git -print 2>/dev/null \
    | while IFS= read -r g; do dirname "$g"; done
}

# inside <dir> — true when the current directory is <dir> or below it.
inside() {
  local p
  p="$(pwd -P)"
  while :; do
    [ "$p" -ef "$1" ] && return 0
    [ "$p" = / ] && return 1
    p="$(dirname "$p")"
  done
}

# warnings <key> <dir> — one line per failed check.
warnings() {
  local k="$1" dir="$2" rec url n wt out pid why
  case "$k" in
    pr-*)
      n="${k#pr-}"
      rec=""; [ -f "$dir/pr.url" ] && rec="$(cat "$dir/pr.url")"
      why="$(mktemp)"
      if [ -n "$given_url" ]; then url="$given_url"
      elif ! url="$(pr_url "$n" 2>"$why")"; then
        echo "PR $n cannot be looked up from this repository ($(tail -n 1 "$why"))"; url=""
      fi
      rm -f "$why"
      if [ -z "$rec" ]; then
        echo "the scratch does not record which PR it belongs to"
      elif [ -n "$url" ] && [ "$(lower "$rec")" != "$(lower "$url")" ]; then
        echo "the scratch belongs to $rec, not to $url"
      fi
      url="${rec:-$url}"
      if [ -n "$url" ] && ! repo_remote "$url"; then
        echo "no git remote of this repository points at the repository of $url"
      fi ;;
    task-*)
      if [ -f "$dir/active" ]; then
        echo "the task is active in a Claude session ($(cat "$dir/active")); say «стоп» there first"
      fi
      while IFS=$'\t' read -r wt branch remote _; do
        [ -d "$wt" ] || continue
        if ! out="$(git -C "$wt" status --porcelain 2>/dev/null)"; then
          echo "git cannot read the worktree $wt, so its changes cannot be checked"
        else
          [ -z "$out" ] || echo "the worktree $wt has $(printf '%s\n' "$out" | wc -l | tr -d ' ') uncommitted or untracked file(s)"
          n="$(git -C "$wt" rev-list --count "$remote/$branch..HEAD" 2>/dev/null \
               || git -C "$wt" rev-list --count "origin/$(jq -r .base "$dir/task.json")..HEAD" 2>/dev/null || echo '?')"
          [ "$n" = 0 ] || echo "the worktree $wt has $n commit(s) not pushed to $remote/$branch"
        fi
      done < <(task_units "$dir") ;;
    local-*)
      if [ ! -f "$dir/owner" ]; then
        echo "the scratch does not record which checkout it belongs to"
      elif [ ! "$(cat "$dir/owner")" -ef "$top" ]; then
        echo "the scratch belongs to the checkout $(cat "$dir/owner"), not to $top"
      fi ;;
  esac
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    if ! out="$(git -C "$wt" status --porcelain 2>/dev/null)"; then
      echo "git cannot read ${wt#$root/} (was the repository moved?), so its changes cannot be checked"
    elif [ -n "$out" ]; then
      echo "${wt#$root/} has $(printf '%s\n' "$out" | wc -l | tr -d ' ') uncommitted or untracked file(s)"
    fi
  done < <(worktrees "$dir")
  inside "$dir" && echo "the current directory is inside ${dir#$root/}"
  for f in "$dir"/watch*.pid; do
    if [ -f "$f" ] && pid="$(cat "$f")" && [ -n "$pid" ] \
       && ps -p "$pid" -o command= 2>/dev/null | grep -Eq 'draft\.sh|follow\.sh'; then
      echo "a watcher (pid $pid) is still running for $k"
    fi
  done
  return 0
}

# task_units <dir> — "<worktree>\t<branch>\t<remote>\t<own>" of a task's units;
# <own> is true for a local branch the task created itself.
task_units() {
  [ -f "$1/task.json" ] || return 0
  jq -r '.units[] | select(.worktree != null)
         | "\(.worktree)\t\(.branch)\t\(.remote)\t\((.created // false) and (.detached | not))"' "$1/task.json"
}

# remove <key> <dir> <confirmed> — remove the scratch's worktrees, git's records
# of them, and the dir.
remove() {
  local k="$1" dir="$2" confirmed="$3" s wt main rec
  case "$k" in pr-[0-9]*|local-[0-9]*|task-?*) ;; *) die 4 "Refusing to remove $dir: not a scratch dir." ;; esac
  [ "$dir" = "$root/$k" ] || die 4 "Refusing to remove $dir: not a scratch dir."
  s="$(size "$dir")"
  # Step out first, so nothing below runs from a folder about to vanish.
  main="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
  cd "${main:-$common}" 2>/dev/null || cd "$common"
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    if ! git worktree remove --force "$wt" 2>/dev/null; then
      [ "$confirmed" = 1 ] || die 1 "Could not remove the worktree $wt; nothing more was removed."
      rm -rf "$wt"
    fi
  done < <(worktrees "$dir")
  # A task's worktrees live outside the scratch; its branches go only when pushed.
  while IFS=$'\t' read -r wt branch remote own; do
    if [ -d "$wt" ] && ! git worktree remove --force "$wt" 2>/dev/null; then
      [ "$confirmed" = 1 ] || die 1 "Could not remove the worktree $wt; nothing more was removed."
      rm -rf "$wt"
    fi
    # Only that worktree's record, never a global prune.
    for rec in "$common"/worktrees/*/gitdir; do
      [ -f "$rec" ] && [ "$(cat "$rec")" = "$wt/.git" ] && rm -rf "${rec%/gitdir}"
    done
    if [ "$own" = true ] && git show-ref --verify --quiet "refs/heads/$branch"; then
      if [ "$(git rev-list --count "$remote/$branch..$branch" 2>/dev/null || echo x)" = 0 ]; then
        git branch -D "$branch" >/dev/null && printf 'deleted branch %s (pushed)\n' "$branch"
      else
        printf 'kept branch %s: it has commits not pushed to %s\n' "$branch" "$remote/$branch"
      fi
    fi
  done < <(task_units "$dir")
  # Records of worktrees that lived in this scratch, also from before a move.
  for rec in "$common"/worktrees/*/gitdir; do
    [ -f "$rec" ] || continue
    case "$(cat "$rec")" in */code-review/"$k"/*) rm -rf "${rec%/gitdir}" ;; esac
  done
  rm -rf "$dir"
  printf 'cleaned %s (%s)\n' "$k" "${s:-0}"
}

[ $# -ge 1 ] || usage
case "$1" in
  path)
    [ $# -eq 2 ] || usage
    key "$2" || usage
    dir="$root/$k"
    mkdir -p "$dir"
    case "$k" in
      pr-*)
        if [ -f "$dir/pr.url" ]; then
          if [ -n "$given_url" ] && [ "$(lower "$(cat "$dir/pr.url")")" != "$(lower "$given_url")" ]; then
            die 4 "The scratch $dir belongs to $(cat "$dir/pr.url"), not to $given_url."
          fi
        elif [ -n "$given_url" ]; then
          printf '%s\n' "$given_url" > "$dir/pr.url"
        elif url="$(pr_url "${k#pr-}" 2>/dev/null)"; then
          printf '%s\n' "$url" > "$dir/pr.url"
        fi ;;
      local-*)
        [ -f "$dir/owner" ] || printf '%s\n' "$top" > "$dir/owner" ;;
    esac
    printf '%s\n' "$dir" ;;
  list)
    except=""
    case "$#:${2:-}" in 1:) ;; 3:--except) except="$3" ;; *) usage ;; esac
    found=0; now="$(date +%s)"
    for dir in "$root"/pr-* "$root"/local-* "$root"/task-*; do
      [ -d "$dir" ] || continue
      k="${dir##*/}"
      [ "$k" != "$except" ] || continue
      found=1
      whose="$(cat "$dir/pr.url" "$dir/owner" 2>/dev/null | head -n 1 || true)"
      [ ! -f "$dir/task.json" ] || whose="$(jq -r '"\(.source.kind) \(.source.ref)"' "$dir/task.json")"
      printf '%s\t%s\t%sd\t%s\n' "$k" "$(size "$dir")" "$(( (now - $(date -r "$dir" +%s)) / 86400 ))" "${whose:--}"
    done
    [ "$found" = 1 ] || echo "no scratch in this repository" ;;
  *)
    ref=""; code=""
    for a in "$@"; do
      case "$a" in
        --yes=*) code="${a#--yes=}" ;;
        -*)      usage ;;
        *)       [ -z "$ref" ] || usage; ref="$a" ;;
      esac
    done
    key "$ref" || usage
    dir="$root/$k"
    if [ ! -d "$dir" ]; then
      echo "nothing to clean: no scratch for $k in this repository"
      exit 0
    fi
    w="$(warnings "$k" "$dir")"
    confirmed=0
    if [ -n "$w" ]; then
      want="$(printf '%s\n' "$w" | cksum | cut -d' ' -f1)"
      if [ "$code" != "$want" ]; then
        [ -z "$code" ] || echo "the warnings changed since the confirmation; nothing was removed"
        echo "CONFIRM $want"
        printf '%s\n' "$w" | sed 's/^/- /'
        exit 10
      fi
      printf '%s\n' "$w" | sed 's/^/confirmed: /'
      confirmed=1
    fi
    remove "$k" "$dir" "$confirmed" ;;
esac

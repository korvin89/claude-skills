#!/usr/bin/env bash
#
# collect-diff.sh — detect what to review and print it.
#
# Usage:
#   collect-diff.sh [PR_NUMBER | #PR_NUMBER | PR_URL] [--quick]
#
# The whole skill argument string can be passed through verbatim: --quick is
# accepted and ignored here. Anything else that is not a PR reference is an
# error (exit 4) — the script never guesses a mode from a malformed argument.
#
# Modes:
#   pr     a PR reference was given. Requires `gh`. The PR head is fetched from
#          the git remote that points at the PR's repository and checked out,
#          detached, into <git-common-dir>/code-review/pr-<N>: files are read at
#          the PR's version whatever the current checkout is, and the current
#          checkout is not touched. A later run for the same PR moves that
#          worktree to the new head.
#   local  no PR reference: everything not yet in the default branch — the
#          commits since the merge-base with origin/<default> (the local
#          default branch when there is no origin), uncommitted changes and
#          untracked files.
#
# Output is plain text; every section starts with "### ":
#   ### MODE: pr|local
#   ### TARGET: <human description>
#   ### WORKTREE: <path> (<sha>)                  (pr mode, when the head is checked out)
#   ### NOTE: …                                   (warnings, optional)
#   ### PR TITLE / ### PR BODY / ### EXISTING COMMENTS   (pr mode only)
#   ### CHANGED FILES
#   ### DIFF
#   ### UNTRACKED FILES                           (local mode, when present)
#
# Exit codes: 0 ok · 2 not a git repo · 3 gh missing · 4 bad argument · 5 nothing to review

set -euo pipefail

GH_DOCS="https://cli.github.com/"
err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 2 "Not inside a git repository — cannot collect a diff."

# ------------------------------------------------------------- arguments ----
pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) ;;                                              # a skill flag, not ours
    --*)     die 4 "Unknown flag: '$1'." ;;
    *)
      a="${1#\#}"                                            # allow "#123"
      case "$a" in
        */pull/[0-9]*) pr="$a" ;;
        ""|*[!0-9]*)   die 4 "Unrecognised argument: '$1'. Expected a PR number, #number, or a …/pull/N URL." ;;
        *)             pr="$a" ;;
      esac ;;
  esac
  shift
done

# Base ref for local comparisons. Prefer origin/<default>: a stale local main
# would leak upstream commits into the diff.
base_ref() {
  local name b
  name="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  name="${name#origin/}"
  for b in "$name" main master; do
    [ -n "$b" ] || continue
    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then printf 'origin/%s\n' "$b"; return 0; fi
    if git show-ref --verify --quiet "refs/heads/$b";         then printf '%s\n' "$b";        return 0; fi
  done
  return 1
}

# pr_worktree <owner> <repo> <num> — check the PR head out into the review
# worktree; print "<path>\t<sha>", or a reason on stderr and return 1.
pr_worktree() {
  local owner="$1" repo="$2" num="$3" want remote="" name url _ common wt sha
  want="$(printf '/%s/%s' "$owner" "$repo" | tr '[:upper:]' '[:lower:]')"
  # Any remote URL form ends in /owner/repo once ':' is '/' and .git is gone.
  while read -r name url _; do
    url="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]' | tr ':' '/')"
    url="${url%/}"; url="${url%.git}"
    case "$url" in *"$want") remote="$name"; break ;; esac
  done < <(git remote -v | awk '$3 == "(fetch)"')
  [ -n "$remote" ] || { err "no git remote points at $owner/$repo"; return 1; }

  git fetch --quiet --no-tags "$remote" "pull/$num/head" 2>/dev/null \
    || { err "git fetch $remote pull/$num/head failed"; return 1; }
  sha="$(git rev-parse FETCH_HEAD)"
  common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
  wt="$common/code-review/pr-$num"
  git worktree prune
  if [ -e "$wt/.git" ]; then
    git -C "$wt" checkout --quiet --force --detach "$sha" 2>/dev/null \
      || { err "could not move $wt to $sha"; return 1; }
  else
    mkdir -p "$common/code-review"
    git worktree add --quiet --detach "$wt" "$sha" 2>/dev/null \
      || { err "git worktree add $wt failed"; return 1; }
  fi
  printf '%s\t%s\n' "$wt" "$sha"
}

# --------------------------------------------------------------- PR mode ----
if [ -n "$pr" ]; then
  command -v gh >/dev/null 2>&1 || {
    err "GitHub CLI (gh) is required to review a pull request but was not found."
    err "Install it: $GH_DOCS"
    exit 3
  }
  head="$(gh pr view "$pr" --json number,url,baseRefName,headRefName \
    --jq '.url, "### MODE: pr", "### TARGET: pull request #\(.number) \(.url) — \(.headRefName) → \(.baseRefName)"')"
  url="${head%%$'\n'*}"
  rest="${url#*://}"; host="${rest%%/*}"; rest="${rest#*/}"
  owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"; num="${url##*/}"
  printf '%s\n' "${head#*$'\n'}"

  reason="$(mktemp)"
  trap 'rm -f "$reason"' EXIT
  if wt="$(pr_worktree "$owner" "$repo" "$num" 2>"$reason")"; then
    printf '### WORKTREE: %s (%s) — the PR head; read files here, not in the current checkout\n' \
      "${wt%%$'\t'*}" "${wt#*$'\t'}"
  else
    printf '### NOTE: the PR head is not checked out (%s). Review from the diff below: files in the current checkout may not be the PR version.\n' \
      "$(tail -n 1 "$reason")"
  fi

  # gist: the first informative line of a comment (skipping the AI marker), truncated.
  gist='def gist: split("\n") | map(select(length > 0 and . != "🤖 **AI generated**")) | (.[0] // "") | .[0:160];'

  gh pr view "$pr" --json title,body,comments,reviews --jq "$gist"'
    "",
    "### PR TITLE",
    .title,
    "",
    "### PR BODY",
    (if (.body // "") == "" then "(empty)" else .body end),
    "",
    "### EXISTING COMMENTS (already raised on this PR — do not re-post these)",
    (.comments[] | "- [issue] \(.author.login): \(.body | gist)"),
    (.reviews[] | select((.body // "") != "") | "- [review] \(.author.login): \(.body | gist)")
  '
  gh api --hostname "$host" "repos/$owner/$repo/pulls/$num/comments" --paginate \
    --jq "$gist"' .[] | "- [inline] \(.path):\(.line // .original_line) \(.user.login): \(.body | gist)"' \
    2>/dev/null || err "(could not list inline review comments)"

  files="$(gh pr diff "$pr" --name-only)"
  [ -n "$files" ] || die 5 "Pull request #$num has an empty diff — nothing to review."
  printf '\n### CHANGED FILES\n%s\n\n### DIFF\n' "$files"
  gh pr diff "$pr"
  exit 0
fi

# ------------------------------------------------------------ local mode ----
note=""
cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  if base="$(base_ref)"; then
    from="$(git merge-base "$base" HEAD 2>/dev/null)" || {
      from=HEAD
      note="### NOTE: $cur shares no history with $base; only uncommitted changes are reviewed."
    }
  else
    from=HEAD; base=""
    note="### NOTE: no origin/<default>, main or master; only uncommitted changes are reviewed."
  fi
  ahead="$(git rev-list --count "$from..HEAD")"
else
  # No commits yet: everything in the working tree is new.
  from="$(git hash-object -t tree /dev/null)"; base=""; ahead=0; cur="$cur (no commits yet)"
fi

files="$(git -c core.quotepath=false diff --name-only "$from")"
# New, never-added files do not appear in `git diff`; list them so the reviewer
# can read them directly (the index is left untouched).
untracked="$(git ls-files --others --exclude-standard)"
[ -n "$files$untracked" ] \
  || die 5 "Nothing to review: $cur has no commits beyond ${base:-HEAD} and the working tree is clean. Pass a PR reference to review a pull request."

target="$cur"
[ -n "$base" ] && target="$target: $ahead commit(s) since $base (merge-base $(git rev-parse --short "$from"))"
[ -n "$(git status --porcelain)" ] && target="$target + uncommitted changes"
printf '### MODE: local\n### TARGET: %s\n' "$target"
[ -z "$note" ] || printf '%s\n' "$note"
printf '\n### CHANGED FILES\n%s\n\n### DIFF\n' "$files"
git diff "$from"
if [ -n "$untracked" ]; then
  printf '\n### UNTRACKED FILES (not in diff — read these directly)\n%s\n' "$untracked"
fi

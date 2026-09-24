#!/usr/bin/env bash
#
# collect-diff.sh — auto-detect what to review and print it.
#
# Usage:
#   collect-diff.sh [PR_NUMBER | #PR_NUMBER | PR_URL] [--branch | --working] [other flags…]
#
# The whole skill argument string can be passed through verbatim: every other
# `--flag` (and the value after `--lang`) is ignored here. Any remaining
# argument that is not a PR reference is an error (exit 4) — the script never
# guesses a mode from a malformed argument.
#
# Detection order (first match wins):
#   1. PR mode      — a PR reference was given. Requires `gh`.
#   2. Working-tree — uncommitted changes exist (or --working).
#   3. Branch mode  — current branch vs its merge-base with the default branch
#                     (origin/<default> preferred over the local branch), or --branch.
#
# Output is plain text; every section starts with "### ":
#   ### MODE: pr|working|branch
#   ### TARGET: <human description>
#   ### NOTE: …                                   (warnings, optional)
#   ### PR TITLE / ### PR BODY / ### EXISTING COMMENTS   (PR mode only)
#   ### CHANGED FILES
#   ### DIFF
#   ### UNTRACKED FILES                           (working mode, when present)
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
force=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch|--working) force="${1#--}" ;;
    --lang)             if [ $# -gt 1 ]; then shift; fi ;;   # skip its value too
    --*)                ;;                                   # other skill flags
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
if [ -n "$pr" ] && [ -n "$force" ]; then
  die 4 "--$force cannot be combined with a PR reference."
fi

# Base ref for branch comparisons. Prefer origin/<default>: a stale local
# main would leak upstream commits into the diff.
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

# --------------------------------------------------------------- PR mode ----
if [ -n "$pr" ]; then
  command -v gh >/dev/null 2>&1 || {
    err "GitHub CLI (gh) is required to review a pull request but was not found."
    err "Install it: $GH_DOCS"
    exit 3
  }
  url="$(gh pr view "$pr" --json url --jq .url)"
  rest="${url#*://}"; host="${rest%%/*}"; rest="${rest#*/}"
  owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"; num="${url##*/}"

  # gist: the first informative line of a comment (skipping the AI marker), truncated.
  gist='def gist: split("\n") | map(select(length > 0 and . != "🤖 **AI generated**")) | (.[0] // "") | .[0:160];'

  gh pr view "$pr" --json number,url,title,body,baseRefName,headRefName,comments,reviews --jq "$gist"'
    "### MODE: pr",
    "### TARGET: pull request #\(.number) \(.url) — \(.headRefName) → \(.baseRefName)",
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

# ------------------------------------------------------ Working-tree mode ----
if { [ -z "$force" ] && [ -n "$(git status --porcelain)" ]; } || [ "$force" = working ]; then
  # Diff against HEAD, or the empty tree when the repo has no commits yet.
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    work_base="HEAD"
  else
    work_base="$(git hash-object -t tree /dev/null)"
  fi
  printf '### MODE: working\n### TARGET: working tree (staged + unstaged vs %s)\n' "$work_base"

  # The branch's own commits are NOT in this diff; say so when there are any.
  if base="$(base_ref)" && [ "$work_base" = HEAD ]; then
    ahead="$(git rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    if [ "$ahead" -gt 0 ]; then
      printf '### NOTE: branch %s is %s commit(s) ahead of %s; those commits are not in this diff. Re-run with --branch to review them instead.\n' \
        "$(git rev-parse --abbrev-ref HEAD)" "$ahead" "$base"
    fi
  fi

  files="$(git -c core.quotepath=false diff --name-only "$work_base")"
  # New, never-added files do not appear in `git diff`; surface them so the
  # reviewer can read them directly (the index is left untouched).
  untracked="$(git ls-files --others --exclude-standard)"
  if [ -z "$files" ] && [ -z "$untracked" ]; then
    die 5 "Working tree has no changes — nothing to review."
  fi
  printf '\n### CHANGED FILES\n%s\n\n### DIFF\n' "$files"
  git diff "$work_base"
  if [ -n "$untracked" ]; then
    printf '\n### UNTRACKED FILES (not in diff — read these directly)\n%s\n' "$untracked"
  fi
  exit 0
fi

# ------------------------------------------------------------ Branch mode ----
base="$(base_ref)" || die 4 "Cannot determine the default branch (no origin/HEAD, main, or master)."
cur="$(git rev-parse --abbrev-ref HEAD)"
if [ "$(git rev-parse "$base")" = "$(git rev-parse HEAD)" ]; then
  die 5 "HEAD is at $base with a clean working tree — nothing to review. Check out a feature branch or pass a PR reference."
fi
files="$(git -c core.quotepath=false diff --name-only "$base...HEAD")"
[ -n "$files" ] || die 5 "Branch $cur has no changes against $base — nothing to review."
printf '### MODE: branch\n### TARGET: %s...%s (base: %s)\n\n### CHANGED FILES\n%s\n\n### DIFF\n' \
  "$base" "$cur" "$base" "$files"
git diff "$base...HEAD"

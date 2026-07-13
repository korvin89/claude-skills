#!/usr/bin/env bash
#
# collect-diff.sh — auto-detect what to review and print its diff.
#
# Usage:
#   collect-diff.sh [PR_NUMBER | PR_URL]
#
# Detection order (first match wins):
#   1. PR mode      — the argument looks like a PR number/URL.  Requires `gh`.
#   2. Working-tree — the working tree has uncommitted changes (staged+unstaged).
#   3. Branch mode  — diff the current branch against its merge-base with the
#                     default branch (origin/HEAD, else main, else master).
#
# Output is plain text:
#   ### MODE: <pr|working|branch>
#   ### TARGET: <human description>
#
#   ### CHANGED FILES
#   <one path per line>
#
#   ### DIFF
#   <unified diff>
#
# Exit codes: 0 ok · 2 not a git repo · 3 PR mode but `gh` is missing.

set -euo pipefail

GH_DOCS="https://cli.github.com/"
err() { printf '%s\n' "$*" >&2; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "Not inside a git repository — cannot collect a diff."
  exit 2
fi

arg="${1:-}"

# Does the argument look like a pull request reference?
is_pr_ref() {
  case "$1" in
    "")                       return 1 ;;  # empty
    *github.com/*/pull/*)     return 0 ;;  # PR URL
    *[!0-9]*)                 return 1 ;;  # contains a non-digit → not a bare number
    *)                        return 0 ;;  # all digits → PR number
  esac
}

# Best guess at the repository's default branch.
default_branch() {
  local b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  if [ -n "$b" ]; then printf '%s\n' "$b"; return; fi
  local c
  for c in main master; do
    if git show-ref --verify --quiet "refs/heads/$c"; then printf '%s\n' "$c"; return; fi
  done
  git rev-parse --abbrev-ref HEAD
}

# ---------------------------------------------------------------- PR mode ----
if is_pr_ref "$arg"; then
  if ! command -v gh >/dev/null 2>&1; then
    err "GitHub CLI (gh) is required to review a pull request but was not found."
    err "Install it: $GH_DOCS"
    exit 3
  fi
  printf '### MODE: pr\n### TARGET: pull request %s\n\n' "$arg"
  printf '### CHANGED FILES\n'
  gh pr diff "$arg" --name-only
  printf '\n### DIFF\n'
  gh pr diff "$arg"
  exit 0
fi

# ------------------------------------------------------- Working-tree mode ----
if [ -n "$(git status --porcelain)" ]; then
  # Diff against HEAD, or the empty tree when the repo has no commits yet.
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    work_base="HEAD"
  else
    work_base="$(git hash-object -t tree /dev/null)"
  fi
  printf '### MODE: working\n### TARGET: working tree (staged + unstaged vs %s)\n\n' "$work_base"
  printf '### CHANGED FILES\n'
  # Print the post-rename path; works for added/modified/renamed entries.
  git -c core.quotepath=false diff --name-only "$work_base"
  printf '\n### DIFF\n'
  git diff "$work_base"
  # New, never-added files do not appear in `git diff`; surface them so the
  # reviewer can read them directly (the index is left untouched).
  untracked="$(git ls-files --others --exclude-standard)"
  if [ -n "$untracked" ]; then
    printf '\n### UNTRACKED FILES (not in diff — read these directly)\n%s\n' "$untracked"
  fi
  exit 0
fi

# ------------------------------------------------------------- Branch mode ----
base="$(default_branch)"
cur="$(git rev-parse --abbrev-ref HEAD)"
printf '### MODE: branch\n### TARGET: %s...%s (base: %s)\n\n' "$base" "$cur" "$base"
printf '### CHANGED FILES\n'
git -c core.quotepath=false diff --name-only "$base"...HEAD
printf '\n### DIFF\n'
git diff "$base"...HEAD

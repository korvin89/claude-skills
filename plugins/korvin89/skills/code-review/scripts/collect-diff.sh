#!/usr/bin/env bash
#
# collect-diff.sh — detect what to review and print it.
#
# Usage:
#   collect-diff.sh [PR_NUMBER | #PR_NUMBER | PR_URL] [--quick]
#   collect-diff.sh <PR> --update
#
# The whole skill argument string can be passed through verbatim. --quick
# only turns off the re-review part (### SINCE). Anything else that is not a
# PR reference is an error (exit 4) — the script never guesses a mode from a
# malformed argument.
#
# --update, after a push: move the review worktree to the PR head and print
# only what the push changed — ### WORKTREE, then ### NEW COMMITS and
# ### PUSH DELTA (from the commit head/ was on to the head, the PR's files
# only).
#
# Modes:
#   pr     a PR reference was given. Requires `gh`. The PR head is fetched from
#          the git remote that points at the PR's repository and checked out,
#          detached, into <scratch>/head: files are read at the PR's version
#          whatever the current checkout is, and the current checkout is not
#          touched. A later run for the same PR moves that worktree to the new
#          head. When you have already reviewed the code of the PR (see
#          `draft.sh threads`), the commit of that review is ### SINCE, and
#          what changed after it — the commits, and the diff of the PR's files
#          from that commit to the head — follows the diff.
#   local  no PR reference: everything not yet in the default branch — the
#          commits since the merge-base with origin/<default> (the local
#          default branch when there is no origin), uncommitted changes and
#          untracked files.
#
# <scratch> is <git-common-dir>/code-review/pr-<N>, or local-<id> (one per
# checkout) without a PR: the one place for everything a review leaves behind.
# Its layout and its removal live in ../../cleanup/scripts/cleanup.sh. This
# script records the PR's URL in it (pr.url), never moves a head/ that holds
# local changes, and only lists other reviews' scratch in a note — it removes
# nothing. Looking up your earlier review, it runs `draft.sh threads`, which
# marks the current review request and replies as answered in watch.json.
#
# Output is plain text; every section starts with "### ":
#   ### MODE: pr|local
#   ### TARGET: <human description>
#   ### SCRATCH: <dir>                            (created on demand in local mode)
#   ### WORKTREE: <path> (<sha>)                  (pr mode, when the head is checked out)
#   ### SINCE: <sha> — your last review <url> (<date>)
#                                                 (pr mode, when you have reviewed the code before)
#   ### NOTE: …                                   (warnings and the other reviews' scratch, optional)
#   ### PR TITLE / ### PR BODY / ### EXISTING COMMENTS   (pr mode only)
#   ### CHANGED FILES
#   ### DIFF
#   ### COMMITS SINCE YOUR REVIEW / ### DELTA     (after ### SINCE, when its commit is available)
#   ### NEW COMMITS / ### PUSH DELTA              (--update only; nothing else follows WORKTREE)
#   ### UNTRACKED FILES                           (local mode, when present)
#
# Exit codes: 0 ok · 1 gh failed (PR not found, auth) · 2 not a git repo · 3 gh missing
#             · 4 bad argument, or the PR's scratch belongs to another PR · 5 nothing to review

set -euo pipefail

GH_DOCS="https://cli.github.com/"
err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 2 "Not inside a git repository — cannot collect a diff."

# ------------------------------------------------------------- arguments ----
pr=""; quick=0; update=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick)  quick=1 ;;
    --update) update=1 ;;
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
[ "$update" = 0 ] || [ -n "$pr" ] || die 4 "--update needs a PR reference."

scratch_root="$(CDPATH='' cd -P -- "$(git rev-parse --git-common-dir)" && pwd -P)/code-review"
cleanup="$(dirname "$0")/../../cleanup/scripts/cleanup.sh"

# others <key> — a note naming the other reviews' scratch, if there is any.
others() {
  local list=""
  [ -f "$cleanup" ] && list="$(bash "$cleanup" list --except "$1" 2>/dev/null \
    | awk -F'\t' '$1 ~ /^(pr-|local-)/ { printf "%s%s (%s, %s)", sep, $1, $2, $3; sep = ", " }')"
  [ -z "$list" ] || printf '### NOTE: scratch of other reviews: %s — /korvin89:cleanup <pr> removes one\n' "$list"
}

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

# pr_remote <owner> <repo> — the git remote that points at that repository.
pr_remote() {
  local want name url _
  want="$(printf '/%s/%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')"
  # Any remote URL form ends in /owner/repo once ':' is '/' and .git is gone.
  while read -r name url _; do
    url="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]' | tr ':' '/')"
    url="${url%/}"; url="${url%.git}"
    case "$url" in *"$want") printf '%s\n' "$name"; return 0 ;; esac
  done < <(git remote -v | awk '$3 == "(fetch)"')
  return 1
}

# pr_worktree <owner> <repo> <num> — check the PR head out into the review
# worktree; print "<path>\t<checked-out sha>\t<PR head sha>[\t<note>]", or a
# reason on stderr and return 1.
pr_worktree() {
  local owner="$1" repo="$2" num="$3" remote wt sha
  remote="$(pr_remote "$owner" "$repo")" || { err "no git remote points at $owner/$repo"; return 1; }

  git fetch --quiet --no-tags "$remote" "pull/$num/head" 2>/dev/null \
    || { err "git fetch $remote pull/$num/head failed"; return 1; }
  sha="$(git rev-parse FETCH_HEAD)"
  wt="$scratch_root/pr-$num/head"
  if [ -e "$wt/.git" ]; then
    local dirty old
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null)" \
      || { err "git cannot read $wt (was the repository moved?); /korvin89:cleanup $num and run again"; return 1; }
    if [ -n "$dirty" ]; then
      # Never throw away changes someone made in head/: keep it where it is.
      old="$(git -C "$wt" rev-parse HEAD)"
      printf '%s\t%s\t%s\t%s\n' "$wt" "$old" "$sha" "head/ has local changes and was not moved to the PR head $sha; its files may be outdated"
      return 0
    fi
    git -C "$wt" checkout --quiet --detach "$sha" 2>/dev/null \
      || { err "could not move $wt to $sha"; return 1; }
  else
    mkdir -p "$scratch_root/pr-$num"
    # --force only lets the path be reused when its folder was deleted by hand
    # while git still lists it; the checkout is detached, no branch is taken.
    git worktree add --quiet --force --detach "$wt" "$sha" 2>/dev/null \
      || { err "git worktree add $wt failed"; return 1; }
  fi
  printf '%s\t%s\t%s\n' "$wt" "$sha" "$sha"
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

  # The scratch is keyed by number; pr.url says which repository's PR it is.
  scratch="$scratch_root/pr-$num"
  if [ -f "$scratch/pr.url" ] \
     && [ "$(tr '[:upper:]' '[:lower:]' < "$scratch/pr.url")" != "$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')" ]; then
    die 4 "The scratch $scratch belongs to $(cat "$scratch/pr.url"). Remove it with /korvin89:cleanup $(cat "$scratch/pr.url") and run again."
  fi
  mkdir -p "$scratch"
  printf '%s\n' "$url" > "$scratch/pr.url"
  printf '### SCRATCH: %s\n' "$scratch"
  [ "$update" = 1 ] || others "pr-$num"

  old=""
  [ ! -e "$scratch/head/.git" ] || old="$(git -C "$scratch/head" rev-parse HEAD 2>/dev/null || true)"
  reason="$(mktemp)"
  trap 'rm -f "$reason"' EXIT
  wt_sha=""; pr_head=""
  if wt="$(pr_worktree "$owner" "$repo" "$num" 2>"$reason")"; then
    IFS=$'\t' read -r wt_path wt_sha pr_head wt_note <<<"$wt"
    printf '### WORKTREE: %s (%s) — the PR head; read files here, not in the current checkout\n' "$wt_path" "$wt_sha"
    [ -z "$wt_note" ] || printf '### NOTE: %s\n' "$wt_note"
  else
    printf '### NOTE: the PR head is not checked out (%s). Review from the diff below: files in the current checkout may not be the PR version.\n' \
      "$(tail -n 1 "$reason")"
  fi

  # File names from the API: `gh pr diff --name-only` escapes non-ASCII paths.
  files="$(gh api --hostname "$host" "repos/$owner/$repo/pulls/$num/files?per_page=100" --paginate --jq '.[].filename')"
  [ -n "$files" ] || die 5 "Pull request #$num has an empty diff — nothing to review."
  pr_files=()
  while IFS= read -r f; do pr_files+=("$f"); done <<<"$files"
  # delta <from> <to> — the PR's files only; names are never globs.
  delta() { git -c core.quotepath=false --literal-pathspecs diff "$1" "$2" -- "${pr_files[@]}"; }

  if [ "$update" = 1 ]; then
    if [ -z "$old" ] || [ -z "$pr_head" ]; then
      printf '### NOTE: no earlier checkout to compare with; no push delta.\n'
    elif [ "$old" = "$pr_head" ]; then
      printf '### NOTE: head/ is already at the PR head; no push delta.\n'
    else
      printf '\n### NEW COMMITS\n'
      git log --oneline --no-decorate "$old..$pr_head"
      printf '\n### PUSH DELTA (%s..%s, the PR'"'"'s files only)\n' "$(git rev-parse --short "$old")" "$(git rev-parse --short "$pr_head")"
      delta "$old" "$pr_head"
    fi
    exit 0
  fi

  # Your latest review of the code: a run after it is a re-review.
  since=""
  if [ "$quick" = 0 ]; then
    if t="$(bash "$(dirname "$0")/draft.sh" threads "$url" 2>"$reason")"; then
      since_line="$(jq -r '.review | if . == null then empty else "\(.commit) \(.url) \(.submitted)" end' <<<"$t")"
      if [ -n "$since_line" ]; then
        read -r since since_url since_at <<<"$since_line"
        printf '### SINCE: %s — your last review %s (%s)\n' "$since" "$since_url" "$since_at"
      fi
    else
      printf '### NOTE: could not check for an earlier review of yours (%s); reviewing as a first review.\n' "$(tail -n 1 "$reason")"
    fi
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

  printf '\n### CHANGED FILES\n%s\n\n### DIFF\n' "$files"
  gh pr diff "$pr"

  if [ -n "$since" ]; then
    if [ -z "$pr_head" ]; then
      printf '\n### NOTE: the PR head is not checked out, so there is no delta: review the whole diff, and check your threads all the same.\n'
    else
      # The reviewed commit is in the head's history unless the branch was
      # force-pushed; then try to fetch it by its sha.
      git cat-file -e "$since^{commit}" 2>/dev/null \
        || { remote="$(pr_remote "$owner" "$repo")" && git fetch --quiet --no-tags "$remote" "$since" 2>/dev/null; } \
        || true
      if ! git cat-file -e "$since^{commit}" 2>/dev/null; then
        printf '\n### NOTE: the commit of your last review (%s) is not available (force-push?); no delta, review the whole diff.\n' "$since"
      elif [ "$since" = "$pr_head" ]; then
        printf '\n### NOTE: no new commits since your last review.\n'
      else
        printf '\n### COMMITS SINCE YOUR REVIEW\n'
        git log --oneline --no-decorate "$since..$pr_head"
        printf '\n### DELTA (%s..%s, the PR'"'"'s files only)\n' "$(git rev-parse --short "$since")" "$(git rev-parse --short "$pr_head")"
        delta "$since" "$pr_head"
      fi
    fi
  fi
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
untracked="$(git -c core.quotepath=false ls-files --others --exclude-standard --full-name -- :/)"
[ -n "$files$untracked" ] \
  || die 5 "Nothing to review: $cur has no commits beyond ${base:-HEAD} and the working tree is clean. Pass a PR reference to review a pull request."

target="$cur"
[ -n "$base" ] && target="$target: $ahead commit(s) since $base (merge-base $(git rev-parse --short "$from"))"
[ -n "$(git status --porcelain)" ] && target="$target + uncommitted changes"
# One local scratch per checkout (cleanup.sh derives the same key).
key="local-$(git rev-parse --show-toplevel | cksum | cut -d' ' -f1)"
printf '### MODE: local\n### TARGET: %s\n### SCRATCH: %s\n' "$target" "$scratch_root/$key"
[ -z "$note" ] || printf '%s\n' "$note"
others "$key"
printf '\n### CHANGED FILES\n%s\n\n### DIFF\n' "$files"
git diff "$from"
if [ -n "$untracked" ]; then
  printf '\n### UNTRACKED FILES (not in diff — read these directly)\n%s\n' "$untracked"
fi

#!/usr/bin/env bash
#
# post-review.sh — post a curated batch of findings to a pull request as ONE
# review (event COMMENT): inline comments on diff lines plus a review body.
#
# Usage:
#   post-review.sh <pr-number | #number | pr-url> <batch.json> [--dry-run]
#
# batch.json:
#   {
#     "body": "top-level text (the legend); may be empty",
#     "unattached_heading": "heading for findings that are not on a diff line (optional)",
#     "comments": [
#       { "path": "src/x.ts", "line": 42, "body": "🔴 **blocker** — …" }
#     ]
#   }
#   `line` is a line of the file as it is at the PR head (new side).
#
# Guarantees applied here so the caller does not have to:
#   - every posted text (the body and each inline comment) starts with the
#     "🤖 **AI generated**" marker — it is prepended when missing;
#   - a comment whose path:line is not part of the PR diff cannot be inline
#     (GitHub rejects it) — it is moved into the review body under
#     `unattached_heading`, keeping its path:line reference;
#   - with no body and no comments nothing is posted (exit 5).
#
# --dry-run prints the final payload and posts nothing.
#
# Requires: gh (authenticated) and jq.
# Exit codes: 0 ok · 3 gh missing · 4 bad usage/input · 5 nothing to post · 6 jq missing

set -euo pipefail

MARKER='🤖 **AI generated**'
GH_DOCS="https://cli.github.com/"
JQ_DOCS="https://jqlang.github.io/jq/download/"
err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

# ------------------------------------------------------------- arguments ----
pr=""; batch=""; dry=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --*)       die 4 "Unknown flag: $a" ;;
    *) if   [ -z "$pr" ];    then pr="${a#\#}"
       elif [ -z "$batch" ]; then batch="$a"
       else die 4 "Unexpected argument: $a"; fi ;;
  esac
done
{ [ -n "$pr" ] && [ -n "$batch" ]; } || die 4 "Usage: post-review.sh <pr-number|pr-url> <batch.json> [--dry-run]"
[ -f "$batch" ] || die 4 "Batch file not found: $batch"

command -v gh >/dev/null 2>&1 || {
  err "GitHub CLI (gh) is required to post to a pull request but was not found."
  err "Install it: $GH_DOCS"
  exit 3
}
command -v jq >/dev/null 2>&1 || {
  err "jq is required to build the review payload but was not found."
  err "Install it: $JQ_DOCS"
  exit 6
}
jq -e 'type == "object"' "$batch" >/dev/null 2>&1 || die 4 "$batch is not a JSON object."

url="$(gh pr view "$pr" --json url --jq .url)"
rest="${url#*://}"; host="${rest%%/*}"; rest="${rest#*/}"
owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"; num="${url##*/}"

# ------------------------------------------- commentable lines of the PR ----
# Every new-side line inside a hunk (added or context) accepts an inline comment.
commentable="$(mktemp)"
trap 'rm -f "$commentable"' EXIT
gh pr diff "$pr" | awk '
  /^diff --git / { inhunk = 0; next }
  /^\+\+\+ /     { path = substr($0, 5); sub(/^b\//, "", path); next }
  /^@@ /         { s = $3; sub(/^\+/, "", s); split(s, p, ","); n = p[1] + 0; inhunk = 1; next }
  inhunk && /^-/  { next }
  inhunk && /^\\/ { next }
  inhunk          { print path "\t" n; n++ }
' > "$commentable"

# ----------------------------------------------------------------- payload ----
payload="$(jq -c --arg marker "$MARKER" --rawfile lines "$commentable" '
  def mark:   if startswith($marker) then . else $marker + "\n\n" + . end;
  def unmark: if startswith($marker) then .[($marker | length):] | ltrimstr("\n") | ltrimstr("\n") else . end;
  def key:    "\(.path)\t\(.line)";
  ($lines | split("\n") | map(select(length > 0))) as $ok
  | (.comments // []) as $c
  | ($c | map(select(key as $k | any($ok[]; . == $k))))       as $inline
  | ($c | map(select(key as $k | any($ok[]; . == $k) | not))) as $loose
  | (.body // "") as $given
  | ($given
     + (if ($loose | length) > 0
        then "\n\n**" + (.unattached_heading // "Not attached to a diff line") + "**\n"
             + ($loose | map("- `\(.path):\(.line)` — " + (.body | unmark)) | join("\n"))
        else "" end)) as $body
  | { event: "COMMENT",
      body: ($body | mark),
      comments: ($inline | map({path, line: (.line | tonumber), side: "RIGHT", body: (.body | mark)})),
      _inline: ($inline | length),
      _loose:  ($loose  | length),
      _empty:  ((($given | gsub("\\s"; "") | length) == 0) and (($c | length) == 0)) }
' "$batch")"

inline="$(printf '%s' "$payload" | jq -r ._inline)"
loose="$(printf '%s'  "$payload" | jq -r ._loose)"
empty="$(printf '%s'  "$payload" | jq -r ._empty)"
[ "$empty" = false ] || die 5 "Nothing to post: the batch has neither a body nor comments."
final="$(printf '%s' "$payload" | jq 'del(._inline, ._loose, ._empty)')"

if [ "$dry" = 1 ]; then
  printf '%s\n' "$final"
  err "(dry run) would post to $url: $inline inline comment(s), $loose moved into the review body."
  exit 0
fi

# -------------------------------------------------------------------- post ----
resp="$(printf '%s' "$final" \
  | gh api --hostname "$host" --method POST "repos/$owner/$repo/pulls/$num/reviews" --input -)"
printf 'Posted review: %s\n' "$(printf '%s' "$resp" | jq -r '.html_url // "(no url in response)"')"
printf 'Inline comments: %s · moved into the review body: %s\n' "$inline" "$loose"

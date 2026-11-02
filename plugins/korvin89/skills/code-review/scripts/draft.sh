#!/usr/bin/env bash
#
# draft.sh — work inside the reviewer's pending review (the draft) of a PR.
# Nothing is ever submitted: the reviewer presses Submit in GitHub. A draft the
# reviewer already started is joined, not replaced — GitHub allows one pending
# review per user per PR.
#
# Usage:
#   draft.sh add    <pr> <batch.json> [--dry-run]  add AI findings as draft threads
#   draft.sh state  <pr>                           print the draft as JSON
#   draft.sh reply  <pr> <thread-id>               agent reply in a thread (body on stdin)
#   draft.sh edit   <pr> <comment-id>              replace a comment body (body on stdin)
#   draft.sh delete <pr> <comment-id>...           delete draft comments, newest first
#   draft.sh watch  <pr> [--interval S] [--quiet S] [--timeout S]
#
# <pr> is a number, #number or a …/pull/N URL.
#
# batch.json for add:
#   { "comments": [ { "path": "src/x.ts", "line": 42, "body": "🔴 **blocker** — …" } ] }
#   `line` is a line of the file at the PR head (new side). A line outside the
#   diff becomes a file-level thread with `path:line` on top; a file outside the
#   diff is skipped and reported. The AI marker is prepended when missing.
#
# Comment kinds in `state` (draft comments are always the reviewer's account):
#   ai         a finding: starts with "🤖 **AI generated**"
#   bot        an agent reply: starts with "🤖💬"; never meant to be submitted
#   cmd        addressed to the agent: starts with "ai:" — also "ии:", or either
#              typed in the other keyboard layout ("фш:", "bb:"), the colon
#              included ("фшЖ", "bb^", "bb%") — or is any other reply in a
#              thread whose root is an `ai` finding
#   own        the reviewer's own review comment
#   published  already submitted, by anyone; context only
# A thread is actionable when its latest cmd/bot comment is a cmd.
#
# Guards: edit refuses published comments; delete refuses own and published
# ones (and deletes nothing when any id is refused); reply prepends "🤖💬"
# when missing and only goes into threads that hold draft comments.
#
# watch polls the draft every --interval seconds (default 20), prints one line
# and exits 0:
#   ACTIONABLE <n>    actionable threads exist and their cmd comments have not
#                     changed for --quiet seconds (default 60)
#   SUBMITTED <url>   the draft seen earlier was submitted
#   DISCARDED         the draft seen earlier is gone without a submit
#   IDLE              --timeout seconds passed (default 7200) and no command is
#                     waiting; a command found after a long laptop sleep still
#                     gets its ACTIONABLE
# Five failed polls in a row print "ERROR <message>" and exit 1.
#
# Requires: gh (authenticated) and jq.
# Exit codes: 0 ok · 1 GitHub error · 3 gh missing · 4 bad usage · 5 nothing to add
#             · 6 jq missing · 7 refused by a guard

set -euo pipefail

MARKER='🤖 **AI generated**'
CHAT='🤖💬'
GH_DOCS="https://cli.github.com/"
JQ_DOCS="https://jqlang.github.io/jq/download/"
err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }
usage() { die 4 "Usage: draft.sh add|state|reply|edit|delete|watch <pr> … (see the header of this script)"; }

[ $# -ge 2 ] || usage
cmd="$1"; pr="${2#\#}"; shift 2
case "$cmd" in add|state|reply|edit|delete|watch) ;; *) usage ;; esac

command -v gh >/dev/null 2>&1 || {
  err "GitHub CLI (gh) is required to work with a pull request but was not found."
  err "Install it: $GH_DOCS"
  exit 3
}
command -v jq >/dev/null 2>&1 || {
  err "jq is required to work with the draft but was not found."
  err "Install it: $JQ_DOCS"
  exit 6
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="$(gh pr view "$pr" --json url --jq .url)"
rest="${url#*://}"; host="${rest%%/*}"; rest="${rest#*/}"
owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"; num="${url##*/}"

# ------------------------------------------------------------- GraphQL ----
STATE_QUERY='query($owner: String!, $repo: String!, $num: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      id url
      viewerLatestReview { id state url }
      reviews(states: PENDING, first: 10) { nodes { id author { login } comments { totalCount } } }
      reviewThreads(last: 100) {
        nodes {
          id path line originalLine isOutdated subjectType
          comments(first: 100) { nodes { id fullDatabaseId url body state createdAt updatedAt author { login } } }
        }
      }
    }
  }
}'
CREATE_REVIEW='mutation($pr: ID!) {
  addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } }
}'
ADD_LINE='mutation($review: ID!, $path: String!, $line: Int!, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line,
    side: RIGHT, subjectType: LINE, body: $body}) { thread { id } }
}'
ADD_FILE='mutation($review: ID!, $path: String!, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path,
    subjectType: FILE, body: $body}) { thread { id } }
}'
REPLY='mutation($review: ID!, $thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewId: $review,
    pullRequestReviewThreadId: $thread, body: $body}) { comment { id } }
}'
EDIT='mutation($id: ID!, $body: String!) {
  updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $body}) {
    pullRequestReviewComment { id }
  }
}'
DELETE='mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }'

# Raw response → the draft: threads that hold at least one draft comment, each
# comment classified (see the header), plus counts.
NORMALIZE='
def lead: sub("^\\s+"; "");
.data.viewer.login as $me
| .data.repository.pullRequest as $p
| ([$p.reviews.nodes[] | select(.author.login == $me)] | first) as $rev
| { url: $p.url,
    pr_id: $p.id,
    review: ($rev.id // null),
    latest: $p.viewerLatestReview,
    threads: [ $p.reviewThreads.nodes[]
      | (.comments.nodes | sort_by(.createdAt)) as $cs
      | select(any($cs[]; .state == "PENDING"))
      | (($cs[0].state == "PENDING") and ($cs[0].body | lead | startswith($marker))) as $ai_root
      | { id, path, line: (.line // .originalLine), outdated: .isOutdated,
          file_level: (.subjectType == "FILE"),
          comments: [ range(0; $cs | length) as $i | $cs[$i]
            | { id,
                kind: (if .state != "PENDING" then "published"
                       elif (.body | lead | startswith($marker)) then "ai"
                       elif (.body | lead | startswith($chat)) then "bot"
                       elif (.body | lead | test("^(ai|ии|фш|bb)[:;жЖ^%]"; "i")) then "cmd"
                       elif $ai_root and $i > 0 then "cmd"
                       else "own" end),
                db_id: .fullDatabaseId, url, author: .author.login,
                created: .createdAt, updated: .updatedAt, body } ] }
      | .actionable = (([.comments[] | select(.kind == "cmd" or .kind == "bot")] | last | .kind?) == "cmd") ] }
| .counts = (reduce (.threads[].comments[].kind) as $k
             ({ai: 0, own: 0, cmd: 0, bot: 0, published: 0}; .[$k] += 1)
             + {actionable: ([.threads[] | select(.actionable)] | length)})
| (.counts.ai + .counts.own + .counts.cmd + .counts.bot) as $seen
| .warning = (if ($rev.comments.totalCount // 0) > $seen
              then "the draft holds \($rev.comments.totalCount) comments, only \($seen) are in the last 100 threads"
              else null end)
'

# gql <query> <variables-json> — print the response; fail on any GraphQL error.
gql() {
  local resp
  resp="$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' \
    | gh api graphql --hostname "$host" --method POST --input - 2>"$tmp/gh.err")" || {
    err "GitHub API error: $(tail -n 1 "$tmp/gh.err")"
    return 1
  }
  printf '%s\n' "$resp"
}

fetch_state() {
  local raw
  raw="$(gql "$STATE_QUERY" "$(jq -n --arg o "$owner" --arg r "$repo" --argjson n "$num" \
    '{owner: $o, repo: $r, num: $n}')")" || return 1
  printf '%s' "$raw" | jq --arg marker "$MARKER" --arg chat "$CHAT" "$NORMALIZE"
}

read_body() {
  local body
  body="$(cat)"
  [ -n "${body//[[:space:]]/}" ] || die 4 "Empty comment body on stdin."
  printf '%s' "$body"
}

# ------------------------------------------------------------------ add ----
cmd_add() {
  local batch="" dry=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --*)       die 4 "Unknown flag: $a" ;;
      *) if [ -z "$batch" ]; then batch="$a"; else die 4 "Unexpected argument: $a"; fi ;;
    esac
  done
  [ -n "$batch" ] || usage
  [ -f "$batch" ] || die 4 "Batch file not found: $batch"
  jq -e '(.comments | type) == "array"' "$batch" >/dev/null 2>&1 || die 4 "$batch has no \"comments\" array."
  jq -e '.comments | length > 0' "$batch" >/dev/null || die 5 "Nothing to add: the batch has no comments."

  # Files of the PR, and every new-side line inside a hunk (added or context):
  # those accept a line comment.
  gh pr diff "$pr" --name-only > "$tmp/files"
  gh pr diff "$pr" | awk '
    /^diff --git / { inhunk = 0; next }
    /^\+\+\+ /     { path = substr($0, 5); sub(/^b\//, "", path); next }
    /^@@ /         { s = $3; sub(/^\+/, "", s); split(s, p, ","); n = p[1] + 0; inhunk = 1; next }
    inhunk && /^-/  { next }
    inhunk && /^\\/ { next }
    inhunk          { print path "\t" n; n++ }
  ' > "$tmp/lines"

  local plan
  plan="$(jq -c --arg marker "$MARKER" --rawfile lines "$tmp/lines" --rawfile files "$tmp/files" '
    def set(s): s | split("\n") | map(select(length > 0) | {(.): true}) | add // {};
    def unmark: if startswith($marker) then .[($marker | length):] | sub("^\\s+"; "") else . end;
    set($lines) as $ok | set($files) as $in
    | [ .comments[]
        | (.line | if . == null then null else tonumber end) as $line
        | (if $line == null then .path else "\(.path):\($line)" end) as $where
        | (.body | unmark) as $text
        | if $line != null and $ok["\(.path)\t\($line)"] then
            {to: "line", where: $where, path, line: $line, body: ($marker + "\n\n" + $text)}
          elif $in[.path] then
            {to: "file", where: $where, path,
             body: ($marker + "\n\n" + (if $line == null then "" else "`\($where)`\n\n" end) + $text)}
          else
            {to: "skip", where: $where}
          end ]
  ' "$batch")"

  if [ "$dry" = 1 ]; then
    printf '%s\n' "$plan" | jq .
    err "(dry run) $url: $(jq '[.[] | select(.to == "line")] | length' <<<"$plan") line, $(jq '[.[] | select(.to == "file")] | length' <<<"$plan") file-level, $(jq '[.[] | select(.to == "skip")] | length' <<<"$plan") skipped; nothing written."
    return 0
  fi

  local state review how
  state="$(fetch_state)" || exit 1
  review="$(jq -r '.review // empty' <<<"$state")"
  if [ -n "$review" ]; then
    how="joined the existing draft"
  else
    review="$(gql "$CREATE_REVIEW" "$(jq -c '{pr: .pr_id}' <<<"$state")" \
      | jq -r '.data.addPullRequestReview.pullRequestReview.id')" || exit 1
    how="started a new draft"
  fi

  local item to where vars q added=0 files=0 skipped=0 failed=0
  while IFS= read -r item; do
    to="$(jq -r .to <<<"$item")"; where="$(jq -r .where <<<"$item")"
    case "$to" in
      line) q="$ADD_LINE"; vars="$(jq -c --arg r "$review" '{review: $r, path, line, body}' <<<"$item")" ;;
      file) q="$ADD_FILE"; vars="$(jq -c --arg r "$review" '{review: $r, path, body}' <<<"$item")" ;;
      *)    printf 'skipped  %s — file is not in the PR diff\n' "$where"; skipped=$((skipped + 1)); continue ;;
    esac
    if gql "$q" "$vars" >/dev/null; then
      added=$((added + 1))
      if [ "$to" = file ]; then files=$((files + 1)); printf 'added    %s (file-level)\n' "$where"
      else printf 'added    %s\n' "$where"; fi
    else
      failed=$((failed + 1)); printf 'failed   %s\n' "$where"
    fi
  done < <(jq -c '.[]' <<<"$plan")

  printf 'Draft: %s/files — %s; added %s (%s file-level), skipped %s, failed %s. Nothing was submitted.\n' \
    "$url" "$how" "$added" "$files" "$skipped" "$failed"
  [ "$failed" = 0 ] || exit 1
}

# --------------------------------------------------------------- reply ----
cmd_reply() {
  [ $# -eq 1 ] || usage
  local thread="$1" body state review
  body="$(read_body)"
  case "$body" in "$CHAT"*) ;; *) body="$CHAT $body" ;; esac
  state="$(fetch_state)" || exit 1
  review="$(jq -r '.review // empty' <<<"$state")"
  [ -n "$review" ] || die 7 "There is no draft on $url; reply refused."
  jq -e --arg t "$thread" 'any(.threads[]; .id == $t)' <<<"$state" >/dev/null \
    || die 7 "Thread $thread holds no draft comments; reply refused."
  gql "$REPLY" "$(jq -n --arg r "$review" --arg t "$thread" --arg b "$body" \
    '{review: $r, thread: $t, body: $b}')" >/dev/null || exit 1
  printf 'replied  %s\n' "$thread"
}

# ---------------------------------------------------------------- edit ----
cmd_edit() {
  [ $# -eq 1 ] || usage
  local id="$1" body state kind
  body="$(read_body)"
  state="$(fetch_state)" || exit 1
  kind="$(jq -r --arg id "$id" 'first(.threads[].comments[] | select(.id == $id) | .kind) // empty' <<<"$state")"
  case "$kind" in
    "")        die 7 "Comment $id is not in the draft; edit refused." ;;
    published) die 7 "Comment $id is already submitted; edit refused." ;;
  esac
  gql "$EDIT" "$(jq -n --arg id "$id" --arg b "$body" '{id: $id, body: $b}')" >/dev/null || exit 1
  printf 'edited   %s (%s)\n' "$id" "$kind"
}

# -------------------------------------------------------------- delete ----
cmd_delete() {
  [ $# -ge 1 ] || usage
  local state picked refused id
  state="$(fetch_state)" || exit 1
  picked="$(jq -c --args '
    [.threads[].comments[]] as $all
    | [ $ARGS.positional[] as $id
        | (first($all[] | select(.id == $id)) // {id: $id, kind: "missing"}) ]
  ' "$@" <<<"$state")"
  refused="$(jq -r '[.[] | select(.kind == "own" or .kind == "published" or .kind == "missing")
                    | "\(.id) (\(.kind))"] | join(", ")' <<<"$picked")"
  [ -z "$refused" ] || die 7 "Delete refused, nothing deleted: $refused."
  # Newest first, so a thread root goes after its replies.
  for id in $(jq -r 'sort_by(.created) | reverse | .[].id' <<<"$picked"); do
    gql "$DELETE" "$(jq -n --arg id "$id" '{id: $id}')" >/dev/null || exit 1
    printf 'deleted  %s\n' "$id"
  done
}

# --------------------------------------------------------------- watch ----
cmd_watch() {
  local interval=20 quiet=60 timeout=7200
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:-}" ;;
      --quiet)    quiet="${2:-}" ;;
      --timeout)  timeout="${2:-}" ;;
      *)          die 4 "Unknown argument: $1" ;;
    esac
    case "${2:-}" in ''|*[!0-9]*) die 4 "$1 needs a whole number of seconds." ;; esac
    shift 2
  done

  local start now s review seen="" fp prev="" since=0 fails=0
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    if s="$(fetch_state 2>"$tmp/watch.err")"; then
      fails=0
      review="$(jq -r '.review // empty' <<<"$s")"
      if [ -n "$review" ]; then
        seen="$review"
      elif [ -n "$seen" ]; then
        if jq -e --arg id "$seen" '.latest.id == $id and .latest.state != "PENDING"' <<<"$s" >/dev/null; then
          printf 'SUBMITTED %s\n' "$(jq -r '.latest.url // ""' <<<"$s")"
        else
          printf 'DISCARDED\n'
        fi
        return 0
      fi
      # Debounce: fire once the pending commands stop changing.
      fp="$(jq -c '[.threads[] | select(.actionable) | .comments[] | select(.kind == "cmd") | [.id, .updated]]' <<<"$s")"
      if [ "$fp" != "$prev" ]; then prev="$fp"; since="$now"; fi
      if [ "$fp" != "[]" ] && [ $((now - since)) -ge "$quiet" ]; then
        printf 'ACTIONABLE %s\n' "$(jq '.counts.actionable' <<<"$s")"
        return 0
      fi
    else
      fails=$((fails + 1))
      if [ "$fails" -ge 5 ]; then
        printf 'ERROR %s\n' "$(tail -n 1 "$tmp/watch.err")"
        return 1
      fi
    fi
    if [ "${prev:-[]}" = "[]" ] && [ $((now - start)) -ge "$timeout" ]; then
      printf 'IDLE\n'; return 0
    fi
    sleep "$interval"
  done
}

case "$cmd" in
  add)    cmd_add "$@" ;;
  state)  [ $# -eq 0 ] || usage; fetch_state ;;
  reply)  cmd_reply "$@" ;;
  edit)   cmd_edit "$@" ;;
  delete) cmd_delete "$@" ;;
  watch)  cmd_watch "$@" ;;
esac

#!/usr/bin/env bash
#
# draft.sh — work inside the reviewer's pending review (the draft) of a PR.
# Nothing is ever submitted: the reviewer presses Submit in GitHub. A draft the
# reviewer already started is joined, not replaced — GitHub allows one pending
# review per user per PR.
#
# Usage:
#   draft.sh add    <pr> <batch.json> [--head <sha>] [--dry-run]
#                                                  add AI findings as draft threads
#   draft.sh state  <pr>                           print the draft as JSON
#   draft.sh reply  <pr> <thread-id>               agent reply in a thread (body on stdin)
#   draft.sh edit   <pr> <comment-id>              replace a comment body (body on stdin)
#   draft.sh delete <pr> <comment-id>...           delete draft comments, newest first
#   draft.sh validate <pr>                         what must be settled before Submit
#   draft.sh watch  <pr> [--review <id>] [--interval S] [--quiet S] [--timeout S]
#
# <pr> is a …/pull/N URL — or a number, which gh resolves against the current
# directory's repository.
#
# batch.json for add:
#   { "comments": [ { "path": "src/x.ts", "line": 42, "body": "🔴 **blocker** — …" } ] }
#   `line` is a line of the file at the PR head (new side). Commentable lines
#   come from the PR's file list (GitHub API), not from parsing a diff. A line
#   outside the diff becomes a file-level thread with `path:line` on top; a
#   file outside the diff is skipped and reported. The AI marker is prepended
#   when missing. --head <sha> refuses (exit 8, nothing added) when the PR head
#   is no longer that commit, so findings never land on lines that moved.
#
# Comment kinds in `state` (draft comments are always the reviewer's account):
#   ai         a finding: starts with "🤖 **AI generated**"
#   bot        an agent reply: starts with "🤖💬"; never meant to be submitted
#   cmd        addressed to the agent: starts with "ai:" — also "ии:", or either
#              typed in the other keyboard layout ("фш:", "bb:"), the colon
#              included ("фшЖ", "bb^", "bb%") — or is any other reply in a
#              thread whose root is an `ai` finding or a cmd, or that follows
#              an agent reply in its thread
#   own        the reviewer's own review comment
#   published  already submitted, by anyone; context only
# A thread is actionable when its latest cmd/bot comment is a cmd.
#
# Guards: edit refuses published comments and keeps the marker of an `ai` or
# `bot` comment; delete refuses own and published ones (and deletes nothing
# when any id is refused); reply prepends "🤖💬" when missing and only goes
# into threads that hold draft comments.
#
# validate prints JSON: `pending` — threads with commands not handled yet;
# `open` — discussions where the agent's reply is the last word; `outdated` —
# threads whose line changed since they were written; `warning` — the draft
# holds more threads than state can see; `clean` — true when all are empty.
# Each pending/open entry lists `service`: the ids of its cmd and bot comments,
# which are what Submit would publish by mistake.
#
# watch polls the draft every --interval seconds (default 20), prints one line
# and exits:
#   ACTIONABLE <n>    actionable threads exist and their cmd comments have not
#                     changed for --quiet seconds (default 60)
#   SUBMITTED <url>   the draft was submitted
#   DISCARDED         the draft is gone without a submit
#   IDLE              a successful poll found no command waiting after
#                     --timeout seconds (default 7200)
#   AUTH <message>    gh is not authenticated (HTTP 401 or no login), at start
#                     or later: exit 1 at once, as every later poll would fail
#   ERROR <message>   the PR lookup at start failed, or five polls in a row did:
#                     exit 1
# A draft counts as seen once a poll finds it, or from the start with --review
# <id> (the `review` of the last `state`), so a submit between two watchers is
# still SUBMITTED. While watch runs, <git-common-dir>/code-review/pr-<N>/watch.pid
# holds its pid.
#
# The GitHub plumbing, the pending-review calls and the polling loop come from
# ../../../lib (gh.sh, pending.sh, watch.sh). Every GitHub call is cut after
# GH_CALL_DEADLINE seconds (default 30), so a hung network call fails like any
# other instead of stalling the watcher.
#
# Requires: gh (authenticated) and jq 1.6+.
# Exit codes: 0 ok · 1 GitHub error · 3 gh missing · 4 bad usage · 5 nothing to add
#             · 6 jq missing or too old · 7 refused by a guard · 8 PR head moved

set -euo pipefail

MARKER='🤖 **AI generated**'
CHAT='🤖💬'
PREFIX='^(ai|ии|фш|bb)[:;жЖ^%]'
LIB="$(CDPATH='' cd -P -- "$(dirname "$0")/../../../lib" && pwd)"
. "$LIB/gh.sh"; . "$LIB/pending.sh"; . "$LIB/watch.sh"
usage() { die 4 "Usage: draft.sh add|state|reply|edit|delete|validate|watch <pr> … (see the header of this script)"; }

[ $# -ge 2 ] || usage
cmd="$1"; pr="${2#\#}"; shift 2
case "$cmd" in add|state|reply|edit|delete|validate|watch) ;; *) usage ;; esac

gh_require
gh_tmp_init
trap 'rm -rf "$GH_TMP"; watch_release' EXIT

if ! gh_pr "$pr" 2>"$GH_TMP/start.err"; then
  cat "$GH_TMP/start.err" >&2
  # watch always answers with one line, even when it cannot start.
  if [ "$cmd" = watch ]; then
    if [ -f "$GH_TMP/auth" ]; then printf 'AUTH %s\n' "$(tail -n 1 "$GH_TMP/start.err")"
    else printf 'ERROR %s\n' "$(tail -n 1 "$GH_TMP/start.err")"; fi
  fi
  exit 1
fi
url="$PR_URL"; host="$PR_HOST"; owner="$PR_OWNER"; repo="$PR_REPO"; num="$PR_NUM"

# ------------------------------------------------------------- GraphQL ----
STATE_QUERY='query($owner: String!, $repo: String!, $num: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      id url headRefOid
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
# Raw response → the draft: threads that hold at least one draft comment, each
# comment classified (see the header), plus counts.
NORMALIZE='
def lead: sub("^\\s+"; "");
.data.viewer.login as $me
| .data.repository.pullRequest as $p
| ([$p.reviews.nodes[] | select(.author.login == $me)] | first) as $rev
| { url: $p.url,
    pr_id: $p.id,
    head: $p.headRefOid,
    review: ($rev.id // null),
    latest: $p.viewerLatestReview,
    threads: [ $p.reviewThreads.nodes[]
      | (.comments.nodes | sort_by(.createdAt)) as $cs
      | select(any($cs[]; .state == "PENDING"))
      | [ $cs[] | if .state != "PENDING" then "published"
                  elif (.body | lead | startswith($marker)) then "ai"
                  elif (.body | lead | startswith($chat)) then "bot"
                  elif (.body | lead | test($prefix; "i")) then "cmd"
                  else "plain" end ] as $base
      | { id, path, line: (.line // .originalLine), outdated: .isOutdated,
          file_level: (.subjectType == "FILE"),
          comments: [ range(0; $cs | length) as $i | $cs[$i]
            | { id,
                kind: (if $base[$i] != "plain" then $base[$i]
                       elif $i > 0 and ($base[0] == "ai" or $base[0] == "cmd"
                                        or any($base[0:$i][]; . == "bot")) then "cmd"
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

fetch_state() {
  local raw
  raw="$(gql "$STATE_QUERY" "$(jq -n --arg o "$owner" --arg r "$repo" --argjson n "$num" \
    '{owner: $o, repo: $r, num: $n}')")" || return 1
  printf '%s' "$raw" | jq --arg marker "$MARKER" --arg chat "$CHAT" --arg prefix "$PREFIX" "$NORMALIZE"
}

read_body() {
  local body
  body="$(cat)"
  [ -n "${body//[[:space:]]/}" ] || die 4 "Empty comment body on stdin."
  printf '%s' "$body"
}

# ------------------------------------------------------------------ add ----
cmd_add() {
  local batch="" dry=0 want=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --head)    want="${2:-}"; [ -n "$want" ] || die 4 "--head needs a commit sha."; shift ;;
      --*)       die 4 "Unknown flag: $1" ;;
      *) if [ -z "$batch" ]; then batch="$1"; else die 4 "Unexpected argument: $1"; fi ;;
    esac
    shift
  done
  [ -n "$batch" ] || usage
  [ -f "$batch" ] || die 4 "Batch file not found: $batch"
  jq -e '(.comments | type) == "array"' "$batch" >/dev/null 2>&1 || die 4 "$batch has no \"comments\" array."
  jq -e '.comments | length > 0' "$batch" >/dev/null || die 5 "Nothing to add: the batch has no comments."

  # The PR's files with their patches; every new-side line inside a hunk
  # (added or context) accepts a line comment.
  gh_call "$GH_TMP/files.ndjson" api --hostname "$host" "repos/$owner/$repo/pulls/$num/files?per_page=100" \
    --paginate --jq '.[] | {filename, patch}' || exit 1

  local plan
  plan="$(jq -c --arg marker "$MARKER" --slurpfile files "$GH_TMP/files.ndjson" '
    def newlines:
      if .patch == null then []
      else reduce (.patch | split("\n"))[] as $l ({n: 0, out: []};
             if ($l | startswith("@@")) then .n = ($l | capture("\\+(?<c>[0-9]+)").c | tonumber)
             elif $l == "" or ($l | startswith("-")) or ($l | startswith("\\")) then .
             else .out += [.n] | .n += 1 end) | .out
      end;
    def unmark: if startswith($marker) then .[($marker | length):] | sub("^\\s+"; "") else . end;
    ($files | map({key: .filename, value: (newlines | map({(tostring): true}) | add // {})}) | from_entries) as $ok
    | [ .comments[]
        | .path as $path
        | (.line | if . == null then null else tonumber end) as $line
        | (if $line == null then $path else "\($path):\($line)" end) as $where
        | (.body | unmark) as $text
        | if $line != null and ($ok[$path] // {})[$line | tostring] then
            {to: "line", where: $where, path, line: $line, body: ($marker + "\n\n" + $text)}
          elif $ok | has($path) then
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

  local state head review how
  state="$(fetch_state)" || exit 1
  head="$(jq -r '.head // ""' <<<"$state")"
  if [ -n "$want" ]; then
    case "$head" in
      "$want"*) ;;
      *) die 8 "PR head moved: reviewed $want, the head is now $head. Nothing was added." ;;
    esac
  fi
  review="$(jq -r '.review // empty' <<<"$state")"
  if [ -n "$review" ]; then
    how="joined the existing draft"
  else
    review="$(pending_open)" || exit 1
    how="started a new draft"
  fi

  local item to where path ok added=0 files=0 skipped=0 failed=0
  while IFS= read -r item; do
    to="$(jq -r .to <<<"$item")"; where="$(jq -r .where <<<"$item")"; path="$(jq -r .path <<<"$item")"
    case "$to" in
      line) ok="$(pending_thread_line "$review" "$path" "$(jq -r .line <<<"$item")" "$(jq -r .body <<<"$item")")" || ok="" ;;
      file) ok="$(pending_thread_file "$review" "$path" "$(jq -r .body <<<"$item")")" || ok="" ;;
      *)    printf 'skipped  %s — file is not in the PR diff\n' "$where"; skipped=$((skipped + 1)); continue ;;
    esac
    if [ -n "$ok" ]; then
      added=$((added + 1))
      if [ "$to" = file ]; then files=$((files + 1)); printf 'added    %s (file-level)\n' "$where"
      else printf 'added    %s\n' "$where"; fi
    else
      failed=$((failed + 1)); printf 'failed   %s\n' "$where"
    fi
  done < <(jq -c '.[]' <<<"$plan")

  printf 'Draft: %s/files — %s (review %s); added %s (%s file-level), skipped %s, failed %s. Nothing was submitted.\n' \
    "$url" "$how" "$review" "$added" "$files" "$skipped" "$failed"
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
  pending_reply "$review" "$thread" "$body" >/dev/null || exit 1
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
    # A finding or an agent reply that lost its marker would turn into the
    # reviewer's own comment and stall its thread.
    ai)  case "$body" in "$MARKER"*) ;; *) body="$MARKER"$'\n\n'"$body" ;; esac ;;
    bot) case "$body" in "$CHAT"*) ;; *) body="$CHAT $body" ;; esac ;;
  esac
  pending_edit "$id" "$body" >/dev/null || exit 1
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
    pending_delete "$id" >/dev/null || exit 1
    printf 'deleted  %s\n' "$id"
  done
}

# ------------------------------------------------------------ validate ----
cmd_validate() {
  [ $# -eq 0 ] || usage
  local state
  state="$(fetch_state)" || exit 1
  jq '
    def where: if .file_level then .path else "\(.path):\(.line)" end;
    def service: [.comments[] | select(.kind == "cmd" or .kind == "bot") | .id];
    def has_service: any(.comments[]; .kind == "cmd" or .kind == "bot");
    { review,
      pending:  [.threads[] | select(.actionable) | {thread: .id, where: where, service: service}],
      open:     [.threads[] | select((.actionable | not) and has_service)
                 | {thread: .id, where: where, service: service,
                    reply: ([.comments[] | select(.kind == "bot")] | last | .body | .[0:200])}],
      outdated: [.threads[] | select(.outdated and any(.comments[]; .kind == "ai" or .kind == "own"))
                 | {thread: .id, where: where}],
      warning }
    | .clean = (.review != null and (.pending + .open + .outdated | length) == 0 and .warning == null)
  ' <<<"$state"
}

# --------------------------------------------------------------- watch ----
# The draft probe for watch_loop: SUBMITTED / DISCARDED at once, ACTIONABLE once
# the pending commands stop changing. $seen remembers the draft between polls.
seen=""
draft_probe() {
  local s review fp
  s="$(fetch_state)" || return 1
  review="$(jq -r '.review // empty' <<<"$s")"
  if [ -n "$review" ]; then
    seen="$review"
  elif [ -n "$seen" ]; then
    if jq -e --arg id "$seen" '.latest.id == $id and .latest.state != "PENDING"' <<<"$s" >/dev/null; then
      printf 'NOW\tSUBMITTED %s\n' "$(jq -r '.latest.url // ""' <<<"$s")"
    else
      printf 'NOW\tDISCARDED\n'
    fi
    return 0
  fi
  fp="$(jq -c '[.threads[] | select(.actionable) | .comments[] | select(.kind == "cmd") | [.id, .updated]]' <<<"$s")"
  [ "$fp" = "[]" ] || printf 'WAIT\t%s\tACTIONABLE %s\n' "$fp" "$(jq '.counts.actionable' <<<"$s")"
}

cmd_watch() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --review)   seen="${2:-}"; [ -n "$seen" ] || die 4 "--review needs a review id."; shift 2; continue ;;
      --interval) WATCH_INTERVAL="${2:-}"; WATCH_MAX_INTERVAL="${2:-}" ;;
      --quiet)    WATCH_QUIET="${2:-}" ;;
      --timeout)  WATCH_TIMEOUT="${2:-}" ;;
      *)          die 4 "Unknown argument: $1" ;;
    esac
    case "${2:-}" in ''|*[!0-9]*) die 4 "$1 needs a whole number of seconds." ;; esac
    shift 2
  done
  # Mark the review's scratch as in use while watching: cleanup.sh warns
  # before removing it (see cleanup/scripts/cleanup.sh for the layout).
  local common
  if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
    watch_pid "$(CDPATH='' cd -P -- "$common" && pwd -P)/code-review/pr-$num/watch.pid"
  fi
  watch_loop draft_probe
}

case "$cmd" in
  add)    cmd_add "$@" ;;
  state)  [ $# -eq 0 ] || usage; fetch_state ;;
  reply)  cmd_reply "$@" ;;
  edit)   cmd_edit "$@" ;;
  delete) cmd_delete "$@" ;;
  validate) cmd_validate "$@" ;;
  watch)  cmd_watch "$@" ;;
esac

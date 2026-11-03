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
#   draft.sh threads <pr>                          your submitted threads still open, as JSON
#   draft.sh reply  <pr> <thread-id> [--finding]   agent reply in a thread (body on stdin)
#   draft.sh edit   <pr> <comment-id>              replace a comment body (body on stdin)
#   draft.sh delete <pr> <comment-id>...           delete draft comments, newest first
#   draft.sh validate <pr>                         what must be settled before Submit
#   draft.sh watch  <pr> [--interval S] [--max-interval S] [--quiet S]
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
# Comment kinds in `state` and `threads` (draft comments are always the
# reviewer's account):
#   ai         a finding: starts with "🤖 **AI generated**"
#   bot        an agent reply: starts with "🤖💬"; never meant to be submitted
#   cmd        addressed to the agent: starts with "ai:" — also "ии:", or either
#              typed in the other keyboard layout ("фш:", "bb:"), the colon
#              included ("фшЖ", "bb^", "bb%") — or is any other reply in a
#              thread whose root is an `ai` finding or a cmd, or that follows
#              an agent reply in a thread that began in the draft. In a
#              thread of a submitted review only the prefix makes a cmd: a
#              plain reply there is the reviewer's answer to the author
#   own        the reviewer's own review comment
#   published  already submitted, by anyone; context only
# A thread is actionable when its latest cmd/bot comment is a cmd.
#
# threads prints your latest review of the code (`review`: url, the commit it
# was made on, when; a bare thread reply — a COMMENTED review with no body and
# one comment that answers another — does not count) and every unresolved
# thread whose first comment is yours and submitted, with all its comments
# (`mine` marks yours): what a re-review checks. It also records in watch.json
# the review request and the replies it answers, so watch announces neither
# again.
#
# Guards: edit refuses published comments and keeps the marker of an `ai` or
# `bot` comment; delete refuses own and published ones (and deletes nothing
# when any id is refused); reply prepends "🤖💬" when missing — the AI marker
# with --finding, a reply meant to be submitted — and only goes into threads
# that hold draft comments or are in `threads`; it opens a draft when there is
# none.
#
# validate prints JSON: `pending` — threads with commands not handled yet;
# `open` — discussions where the agent's reply is the last word; `outdated` —
# threads whose line changed since they were written; `warning` — the draft
# holds more threads than state can see; `clean` — true when all are empty.
# Each pending/open entry lists `service`: the ids of its cmd and bot comments,
# which are what Submit would publish by mistake.
#
# watch follows the PR until there is something to act on, prints one line and
# exits:
#   MERGED / CLOSED   the PR is merged or closed
#   SUBMITTED <url>   the draft was submitted
#   DISCARDED [following]
#                     the draft is gone without a submit; `following` when you
#                     have reviewed the code before, so the PR is still yours
#                     to follow
#   ACTIONABLE <n>    actionable threads exist and their cmd comments have not
#                     changed for --quiet seconds (default 60)
#   PUSHED <sha> [draft]
#                     the PR head is a commit neither checked out in the
#                     review's head/ worktree nor announced before, and it has
#                     not changed for --quiet seconds; `draft` when your draft
#                     holds comments
#   REREQUESTED       your draft holds no comments, and you are asked to review
#                     again after your latest review of the code (a request to
#                     a team you are in does not count)
#   REPLIED <n> <url> n new comments by others in your open submitted threads,
#                     once they stop coming for --quiet seconds; <url> is the
#                     first of them. New means after your latest comment in
#                     that thread, draft ones included, and after the last
#                     REPLIED
#   AUTH <message>    gh is not authenticated (HTTP 401 or no login), at start
#                     or later: exit 1 at once, as every later poll would fail
#   ERROR <message>   the lookups at start failed, the review's scratch does not
#                     exist, or five polls in a row failed: exit 1
# Earlier lines win when several apply. There is no idle timeout: polls start
# --interval apart (default 20) and, while the draft holds no comments and
# nothing is pending, back off to --max-interval (default 300).
# The review's scratch, <git-common-dir>/code-review/pr-<N>, keeps what watch
# has announced in watch.json — the draft it has seen, the head, the review
# request, the newest reply — so the next watch does not repeat an event and a
# submit between two watches is still SUBMITTED. The file is read and written
# field by field, so `threads` can mark a request while a watch runs.
# watch.pid holds the pid of the running watch. watch refuses to run without
# the scratch.
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
usage() { die 4 "Usage: draft.sh add|state|threads|reply|edit|delete|validate|watch <pr> … (see the header of this script)"; }

[ $# -ge 2 ] || usage
cmd="$1"; pr="${2#\#}"; shift 2
case "$cmd" in add|state|threads|reply|edit|delete|validate|watch) ;; *) usage ;; esac

gh_require
gh_tmp_init
trap 'rm -rf "$GH_TMP"; watch_release' EXIT

# start_failed — relay a failed lookup at start; watch always answers with one
# line, even when it cannot start.
start_failed() {
  cat "$GH_TMP/start.err" >&2
  if [ "$cmd" = watch ]; then
    if [ -f "$GH_TMP/auth" ]; then printf 'AUTH %s\n' "$(tail -n 1 "$GH_TMP/start.err")"
    else printf 'ERROR %s\n' "$(tail -n 1 "$GH_TMP/start.err")"; fi
  fi
  exit 1
}
gh_pr "$pr" 2>"$GH_TMP/start.err" || start_failed
url="$PR_URL"; host="$PR_HOST"; owner="$PR_OWNER"; repo="$PR_REPO"; num="$PR_NUM"
# The viewer's login filters the query to your own reviews.
me_raw="$(gql 'query { viewer { login } }' '{}' 2>"$GH_TMP/start.err")" || start_failed
me="$(jq -r '.data.viewer.login // empty' <<<"$me_raw")"
[ -n "$me" ] || { echo "GitHub did not say who you are." > "$GH_TMP/start.err"; start_failed; }

# scratch_init — the review's scratch (layout: cleanup/scripts/cleanup.sh) and
# watch.json in it; SCRATCH stays empty when there is none.
SCRATCH=""; WATCH_FILE=""
scratch_init() {
  local common dir
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  dir="$(CDPATH='' cd -P -- "$common" && pwd -P)/code-review/pr-$num"
  [ -d "$dir" ] || return 0
  SCRATCH="$dir"; WATCH_FILE="$dir/watch.json"
}

# ------------------------------------------------------------- GraphQL ----
STATE_QUERY='query($owner: String!, $repo: String!, $num: Int!, $me: String!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      id url state headRefOid
      viewerLatestReview { id state url }
      reviews(states: PENDING, first: 10) { nodes { id author { login } comments { totalCount } } }
      submitted: reviews(author: $me, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED], last: 50) {
        nodes { id url state body submittedAt commit { oid } comments(first: 1) { totalCount nodes { replyTo { id } } } }
      }
      reviewRequests(first: 50) { nodes { requestedReviewer { ... on User { login } } } }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 50) {
        nodes { ... on ReviewRequestedEvent { id createdAt requestedReviewer { ... on User { login } } } }
      }
      reviewThreads(last: 100) {
        nodes {
          id path line originalLine isOutdated isResolved subjectType
          comments(first: 100) {
            nodes { id fullDatabaseId url body state createdAt publishedAt updatedAt author { login } }
          }
        }
      }
    }
  }
}'
# A raw thread → its comments in order, each classified (see the header).
CLASSIFY='
def lead: sub("^\\s+"; "");
def classify:
  (.comments.nodes | sort_by(.createdAt)) as $cs
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
                                    or ($base[0] != "published" and any($base[0:$i][]; . == "bot"))) then "cmd"
                   else "own" end),
            db_id: .fullDatabaseId, url, author: .author.login,
            created: .createdAt, updated: .updatedAt, body } ] }
  | .actionable = (([.comments[] | select(.kind == "cmd" or .kind == "bot")] | last | .kind?) == "cmd");
# Your latest review of the code, or null. A bare thread reply is a review
# too — COMMENTED, no body, one comment that answers another — but not one of
# the code.
def submitted: [.submitted.nodes[] | select(.state != "COMMENTED" or ((.body // "") | test("\\S"))
                                            or .comments.totalCount != 1 or .comments.nodes[0].replyTo == null)] | last;
# Unresolved threads that open with your submitted comment.
def yours($me): .reviewThreads.nodes[] | select(.isResolved | not)
  | select(.comments.nodes | sort_by(.createdAt) | .[0] | .author.login == $me and .state != "PENDING");
'
# Raw response → the draft: threads that hold at least one draft comment, plus
# counts.
NORMALIZE='
.data.viewer.login as $me
| .data.repository.pullRequest as $p
| ([$p.reviews.nodes[] | select(.author.login == $me)] | first) as $rev
| { url: $p.url,
    pr_id: $p.id,
    head: $p.headRefOid,
    review: ($rev.id // null),
    latest: $p.viewerLatestReview,
    threads: [ $p.reviewThreads.nodes[] | select(any(.comments.nodes[]; .state == "PENDING")) | classify ] }
| .counts = (reduce (.threads[].comments[].kind) as $k
             ({ai: 0, own: 0, cmd: 0, bot: 0, published: 0}; .[$k] += 1)
             + {actionable: ([.threads[] | select(.actionable)] | length)})
| (.counts.ai + .counts.own + .counts.cmd + .counts.bot) as $seen
| .warning = (if ($rev.comments.totalCount // 0) > $seen
              then "the draft holds \($rev.comments.totalCount) comments, only \($seen) are in the last 100 threads"
              else null end)
'
# Raw response → what a re-review checks (see the header).
THREADS='
.data.viewer.login as $me
| .data.repository.pullRequest as $p
| { url: $p.url,
    head: $p.headRefOid,
    review: ($p | submitted | if . == null then null else {url, commit: .commit.oid, submitted: .submittedAt} end),
    threads: [ $p | yours($me) | classify | del(.actionable)
               | .comments |= map(. + {mine: (.author == $me)}) ] }
'
# Raw response → what watch follows besides the draft comments.
FOLLOW='
.data.viewer.login as $me
| .data.repository.pullRequest as $p
| ($p | submitted | .submittedAt?) as $sub
| { pr_state: $p.state,
    head: $p.headRefOid,
    reviewed: ($sub != null),
    # A pending review with no comments left is no draft to work on.
    draft_open: (([$p.reviews.nodes[] | select(.author.login == $me) | .comments.totalCount] | first // 0) > 0),
    sent: [$p.submitted.nodes[] | {id, url}],
    request: (if $sub != null and any($p.reviewRequests.nodes[]; .requestedReviewer.login? == $me)
              then ([$p.timelineItems.nodes[] | select(.requestedReviewer.login? == $me)] | last
                    | if . != null and .createdAt > $sub then .id else null end)
              else null end),
    # Replies by others after your latest comment in the thread, draft ones
    # included: what you have answered is not news.
    replies: ([ $p | yours($me) | (.comments.nodes | sort_by(.createdAt)) as $cs
                | ([$cs[] | select(.author.login? == $me) | .createdAt] | max) as $mine
                | $cs[] | select(.author.login? != $me and .state != "PENDING")
                | {id, url, at: (.publishedAt // .createdAt)} | select(.at > $mine) ] | sort_by(.at)) }
'

fetch_raw() {
  gql "$STATE_QUERY" "$(jq -n --arg o "$owner" --arg r "$repo" --argjson n "$num" --arg me "$me" \
    '{owner: $o, repo: $r, num: $n, me: $me}')"
}

# view <jq program> — apply a view to the raw response on stdin.
view() { jq --arg marker "$MARKER" --arg chat "$CHAT" --arg prefix "$PREFIX" "$CLASSIFY$1"; }

fetch_state() {
  local raw
  raw="$(fetch_raw)" || return 1
  view "$NORMALIZE" <<<"$raw"
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
  local thread="" finding=0 body raw state review
  while [ $# -gt 0 ]; do
    case "$1" in
      --finding) finding=1 ;;
      --*)       die 4 "Unknown flag: $1" ;;
      *)         [ -z "$thread" ] || usage; thread="$1" ;;
    esac
    shift
  done
  [ -n "$thread" ] || usage
  body="$(read_body)"
  if [ "$finding" = 1 ]; then
    case "$body" in "$MARKER"*) ;; *) body="$MARKER"$'\n\n'"$body" ;; esac
  else
    case "$body" in "$CHAT"*) ;; *) body="$CHAT $body" ;; esac
  fi
  raw="$(fetch_raw)" || exit 1
  state="$(view "$NORMALIZE" <<<"$raw")"
  jq -e --arg t "$thread" 'any(.threads[]; .id == $t)' <<<"$state" >/dev/null \
    || view "$THREADS" <<<"$raw" | jq -e --arg t "$thread" 'any(.threads[]; .id == $t)' >/dev/null \
    || die 7 "Thread $thread holds no draft comments and is not one of your open submitted threads; reply refused."
  review="$(jq -r '.review // empty' <<<"$state")"
  [ -n "$review" ] || review="$(pending_open)" || exit 1
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
      outdated: [.threads[] | select(.outdated and .comments[0].kind != "published"
                                     and any(.comments[]; .kind == "ai" or .kind == "own"))
                 | {thread: .id, where: where}],
      warning }
    | .clean = (.review != null and (.pending + .open + .outdated | length) == 0 and .warning == null)
  ' <<<"$state"
}

# --------------------------------------------------------------- watch ----
# The probe for watch_loop. What it has announced lives in watch.json, read
# and written field by field, so `threads` can mark a request in between.
first_head=""    # the head at the first poll: the baseline when nothing is known
push_sha=""; push_since=0; reply_fp=""; reply_since=0

watch_get() {
  [ -n "$WATCH_FILE" ] && [ -f "$WATCH_FILE" ] || return 0
  jq -r --arg k "$1" '.[$k] // ""' "$WATCH_FILE" 2>/dev/null || true
}

# watch_set <key> <value> [<key> <value>…]
watch_set() {
  [ -n "$WATCH_FILE" ] && [ -d "${WATCH_FILE%/*}" ] || return 0
  local json
  json="$(jq -c 'if type == "object" then . else {} end' "$WATCH_FILE" 2>/dev/null)" || json=""
  [ -n "$json" ] || json='{}'
  while [ $# -ge 2 ]; do
    json="$(jq -c --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"$json")"; shift 2
  done
  printf '%s\n' "$json" > "$WATCH_FILE.$$" && mv "$WATCH_FILE.$$" "$WATCH_FILE"
}

draft_probe() {
  local raw s f review seen open id url fp now head known wt req new n
  raw="$(fetch_raw)" || return 1
  s="$(view "$NORMALIZE" <<<"$raw")" && f="$(view "$FOLLOW" <<<"$raw")" && [ -n "$s" ] && [ -n "$f" ] \
    || { err "could not read the PR state"; return 1; }
  case "$(jq -r .pr_state <<<"$f")" in
    MERGED) printf 'NOW\tMERGED\n'; return 0 ;;
    CLOSED) printf 'NOW\tCLOSED\n'; return 0 ;;
  esac

  review="$(jq -r '.review // empty' <<<"$s")"; seen="$(watch_get review)"
  if [ -n "$review" ]; then
    [ "$review" = "$seen" ] || watch_set review "$review"
  elif [ -n "$seen" ]; then
    id="$seen"; watch_set review ""
    url="$(jq -r --arg id "$id" 'first(.sent[] | select(.id == $id) | .url) // empty' <<<"$f")"
    [ -n "$url" ] || url="$(jq -r --arg id "$id" 'select(.latest.id == $id and .latest.state != "PENDING") | .latest.url // ""' <<<"$s")"
    if [ -n "$url" ]; then
      printf 'NOW\tSUBMITTED %s\n' "$url"
    elif jq -e .reviewed <<<"$f" >/dev/null; then
      printf 'NOW\tDISCARDED following\n'
    else
      printf 'NOW\tDISCARDED\n'
    fi
    return 0
  fi

  fp="$(jq -c '[.threads[] | select(.actionable) | .comments[] | select(.kind == "cmd") | [.id, .updated]]' <<<"$s")"
  if [ "$fp" != "[]" ]; then
    printf 'WAIT\t%s\tACTIONABLE %s\n' "$fp" "$(jq '.counts.actionable' <<<"$s")"; return 0
  fi

  open="$(jq -r .draft_open <<<"$f")"
  now="$(date +%s)"
  head="$(jq -r '.head // empty' <<<"$f")"
  [ -n "$head" ] || { err "the PR has no head commit"; return 1; }
  wt=""; [ ! -e "$SCRATCH/head/.git" ] || wt="$(git -C "$SCRATCH/head" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$first_head" ] || first_head="$head"
  known="$(watch_get head)"; [ -n "$known" ] || known="${wt:-$first_head}"
  if [ "$head" != "$known" ] && [ "$head" != "$wt" ]; then
    [ "$head" = "$push_sha" ] || { push_sha="$head"; push_since="$now"; }
    if [ $((now - push_since)) -ge "$WATCH_QUIET" ]; then
      watch_set head "$head"
      if [ "$open" = true ]; then printf 'NOW\tPUSHED %s draft\n' "$head"; else printf 'NOW\tPUSHED %s\n' "$head"; fi
      return 0
    fi
    printf 'HOT\n'; return 0
  fi

  req="$(jq -r '.request // empty' <<<"$f")"
  if [ "$open" != true ] && [ -n "$req" ] && [ "$req" != "$(watch_get request)" ]; then
    watch_set request "$req"
    printf 'NOW\tREREQUESTED\n'; return 0
  fi

  new="$(jq -c --arg since "$(watch_get replied)" '[.replies[] | select(.at > $since)]' <<<"$f")"
  n="$(jq length <<<"$new")"
  if [ "$n" -gt 0 ]; then
    fp="$(jq -r 'map(.id) | join(",")' <<<"$new")"
    [ "$fp" = "$reply_fp" ] || { reply_fp="$fp"; reply_since="$now"; }
    if [ $((now - reply_since)) -ge "$WATCH_QUIET" ]; then
      watch_set replied "$(jq -r 'map(.at) | max' <<<"$new")"
      printf 'NOW\tREPLIED %s %s\n' "$n" "$(jq -r 'first | .url' <<<"$new")"; return 0
    fi
    printf 'HOT\n'; return 0
  fi

  # A draft with comments means the reviewer is at work: poll at the first gap.
  [ "$open" != true ] || printf 'HOT\n'
}

cmd_watch() {
  WATCH_MAX_INTERVAL=300
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval)     WATCH_INTERVAL="${2:-}" ;;
      --max-interval) WATCH_MAX_INTERVAL="${2:-}" ;;
      --quiet)        WATCH_QUIET="${2:-}" ;;
      *)              die 4 "Unknown argument: $1" ;;
    esac
    case "${2:-}" in ''|*[!0-9]*) die 4 "$1 needs a whole number of seconds." ;; esac
    shift 2
  done
  # Without the scratch nothing would remember what was announced, and every
  # watch would repeat it.
  [ -n "$SCRATCH" ] || { printf 'ERROR no review scratch for %s in this repository: run the review first\n' "$url"; exit 1; }
  watch_pid "$SCRATCH/watch.pid"
  watch_loop draft_probe
}

# threads — print what a re-review checks, and record in watch.json that the
# re-review answers the current review request and the replies so far, so
# watch announces neither again.
cmd_threads() {
  [ $# -eq 0 ] || usage
  local raw f req last
  raw="$(fetch_raw)" || exit 1
  view "$THREADS" <<<"$raw"
  f="$(view "$FOLLOW" <<<"$raw")" || return 0
  req="$(jq -r '.request // empty' <<<"$f")"
  [ -z "$req" ] || watch_set request "$req"
  last="$(jq -r '[.replies[].at] | max // empty' <<<"$f")"
  if [ -n "$last" ] && [[ "$last" > "$(watch_get replied)" ]]; then watch_set replied "$last"; fi
}

scratch_init
case "$cmd" in
  add)    cmd_add "$@" ;;
  state)  [ $# -eq 0 ] || usage; fetch_state ;;
  threads) cmd_threads "$@" ;;
  reply)  cmd_reply "$@" ;;
  edit)   cmd_edit "$@" ;;
  delete) cmd_delete "$@" ;;
  validate) cmd_validate "$@" ;;
  watch)  cmd_watch "$@" ;;
esac

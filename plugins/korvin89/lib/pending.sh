# pending.sh — the viewer's pending review (the draft) of a PR, raw: no
# markers, no guards; each skill brings its own. Source after gh.sh and a
# successful gh_pr. Every function prints the id it created or changed.
#
#   pending_id                                    the pending review id, or nothing
#   pending_open                                  the pending review id, created when missing
#   pending_thread_line <review> <path> <line> <body>
#   pending_thread_file <review> <path> <body>
#   pending_reply <review> <thread-id> <body>     works in any thread with viewerCanReply,
#                                                 published ones included
#   pending_edit <comment-id> <body>
#   pending_delete <comment-id>
#
# Verified on GitHub: an author can open a pending review on their own PR and
# reply inside it to a published thread; while a pending review is open, the
# web UI puts the author's thread replies into it as well.

PENDING_FIND='query($o: String!, $r: String!, $n: Int!) {
  viewer { login }
  repository(owner: $o, name: $r) {
    pullRequest(number: $n) { id reviews(states: PENDING, first: 10) { nodes { id author { login } } } }
  }
}'

pending_vars() { jq -n --arg o "$PR_OWNER" --arg r "$PR_REPO" --argjson n "$PR_NUM" '{o: $o, r: $r, n: $n}'; }

pending_id() {
  gql "$PENDING_FIND" "$(pending_vars)" | jq -r '
    .data.viewer.login as $me
    | first((.data.repository.pullRequest.reviews.nodes // [])[] | select(.author.login == $me) | .id) // empty'
}

pending_open() {
  local raw id
  raw="$(gql "$PENDING_FIND" "$(pending_vars)")" || return 1
  id="$(jq -r '.data.viewer.login as $me
    | first((.data.repository.pullRequest.reviews.nodes // [])[] | select(.author.login == $me) | .id) // empty' <<<"$raw")"
  if [ -z "$id" ]; then
    id="$(gql 'mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }' \
      "$(jq -c '{pr: .data.repository.pullRequest.id}' <<<"$raw")" \
      | jq -r '.data.addPullRequestReview.pullRequestReview.id')" || return 1
  fi
  printf '%s\n' "$id"
}

pending_thread_line() {
  gql 'mutation($r: ID!, $p: String!, $l: Int!, $b: String!) {
    addPullRequestReviewThread(input: {pullRequestReviewId: $r, path: $p, line: $l, side: RIGHT,
      subjectType: LINE, body: $b}) { thread { id } } }' \
    "$(jq -n --arg r "$1" --arg p "$2" --argjson l "$3" --arg b "$4" '{r: $r, p: $p, l: $l, b: $b}')" \
    | jq -r '.data.addPullRequestReviewThread.thread.id'
}

pending_thread_file() {
  gql 'mutation($r: ID!, $p: String!, $b: String!) {
    addPullRequestReviewThread(input: {pullRequestReviewId: $r, path: $p, subjectType: FILE, body: $b}) {
      thread { id } } }' \
    "$(jq -n --arg r "$1" --arg p "$2" --arg b "$3" '{r: $r, p: $p, b: $b}')" \
    | jq -r '.data.addPullRequestReviewThread.thread.id'
}

pending_reply() {
  gql 'mutation($r: ID!, $t: ID!, $b: String!) {
    addPullRequestReviewThreadReply(input: {pullRequestReviewId: $r, pullRequestReviewThreadId: $t, body: $b}) {
      comment { id } } }' \
    "$(jq -n --arg r "$1" --arg t "$2" --arg b "$3" '{r: $r, t: $t, b: $b}')" \
    | jq -r '.data.addPullRequestReviewThreadReply.comment.id'
}

pending_edit() {
  gql 'mutation($id: ID!, $b: String!) {
    updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $b}) {
      pullRequestReviewComment { id } } }' \
    "$(jq -n --arg id "$1" --arg b "$2" '{id: $id, b: $b}')" \
    | jq -r '.data.updatePullRequestReviewComment.pullRequestReviewComment.id'
}

pending_delete() {
  gql 'mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }' \
    "$(jq -n --arg id "$1" '{id: $id}')" >/dev/null && printf '%s\n' "$1"
}

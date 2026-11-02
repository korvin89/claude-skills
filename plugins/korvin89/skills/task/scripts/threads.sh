#!/usr/bin/env bash
#
# threads.sh — what the PR's discussion asks of the agent. Only three sources
# may change code:
#   - the author's `valid` in someone else's unresolved thread: the first word
#     of the comment, in either keyboard layout ("valid", "мфдшв"), quoted
#     lines and emphasis aside; the rest of the comment refines the fix.
#     "invalid", "not valid", "validate", "valid?" never match;
#   - the author's command: a comment starting with the code-review prefixes
#     (ai:, ии:, фш:, bb:, …), in a thread or as a PR comment;
#   - an unresolved review thread opened by an allowlisted bot (task.json
#     .bots, default copilot-pull-request-reviewer) that the author has not
#     answered yet.
# Everything else — review bodies, other people's comments, other bots — is
# information only. Comments the agent wrote carry <!-- korvin89:task --> and
# never count as the author's.
#
# Handled means: a commit pushed to the PR branch carries "Addresses:
# <comment id>" (a fix only counts once the reviewer can see it), or the id is
# in the task ledger's `seen` (task.sh seen) — commands that need no code, and
# information already shown. Ids parked with task.sh park are left out while
# their lift holds; `mine` (the author's comments on the PR) drives the
# comment:<n> lift.
#
# Usage:
#   threads.sh scan <worktree>     JSON: valid, commands, bots (unhandled
#                                  triggers), waiting (others' threads with no
#                                  verdict from the author yet), info (unseen
#                                  review bodies and comments), pending (the
#                                  author's own comments still in their draft)
#   threads.sh reply <worktree> <thread-id>
#                                  draft a reply (body on stdin) into the
#                                  author's pending review, marked as the
#                                  agent's; the author submits it
#   threads.sh resolve <worktree> <thread-id>
#                                  resolve a thread — only an allowlisted bot's,
#                                  only once a commit addresses its root
#
# Exit codes: 0 ok · 1 GitHub error · 4 bad usage · 7 not a task worktree, or
#             resolving refused

set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$TASK_LIB/pending.sh"

TASK_MARK='<!-- korvin89:task -->'
AI_MARK='🤖 **AI generated**'
PREFIX='^(ai|ии|фш|bb)[:;жЖ^%]'
VALID='^\s*(valid|мфдшв)([^[:alnum:]_?]|$)'

usage() { die 4 "Usage: threads.sh scan|reply|resolve <worktree> [<thread-id>]"; }
[ $# -ge 2 ] || usage
cmd="$1"; shift
WT="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || die 4 "No such worktree: $1"; shift
hit="$(task_of "$WT")"; [ -n "$hit" ] || die 7 "$WT is not the worktree of a task unit."
KEY="${hit%%$'\t'*}"; IDX="${hit#*$'\t'}"
gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"' EXIT
pr="$(task_get "$KEY" ".units[$IDX].pr // empty")"; [ -n "$pr" ] || die 7 "This unit has no PR yet."
gh_pr "$pr" || exit 1

PR_QUERY='query($o: String!, $r: String!, $n: Int!) {
  viewer { login }
  repository(owner: $o, name: $r) { pullRequest(number: $n) {
    reviewThreads(last: 100) { nodes { id isResolved isOutdated path line viewerCanResolve
      comments(first: 100) { nodes { id fullDatabaseId state body createdAt url author { __typename login } } } } }
    reviews(last: 50) { nodes { id fullDatabaseId state body submittedAt url author { __typename login } } }
    comments(last: 100) { nodes { id fullDatabaseId body createdAt url author { __typename login } } } } } }'

case "$cmd" in
  scan)
    [ $# -eq 0 ] || usage
    raw="$(gql "$PR_QUERY" "$(jq -n --arg o "$PR_OWNER" --arg r "$PR_REPO" --argjson n "$PR_NUM" '{o: $o, r: $r, n: $n}')")" || exit 1
    remote="$(task_get "$KEY" ".units[$IDX].remote")"; branch="$(task_get "$KEY" ".units[$IDX].branch")"
    handled="$( { git -C "$WT" log --format='%(trailers:key=Addresses,valueonly)' "$remote/$branch" 2>/dev/null || true; } \
                | tr ', ' '\n\n' | sed '/^$/d' | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))')"
    seen="$(jq -c '.seen' "$(task_dir "$KEY")/ledger.json")"
    parked="$(jq -c '[.parked[] | select(.lift | startswith("comment:")) | {id, n: (.lift[8:] | tonumber? // -1)}]' "$(task_dir "$KEY")/ledger.json")"
    bots="$(task_get "$KEY" '.bots // ["copilot-pull-request-reviewer"]' | jq -c .)"
    jq --arg mark "$TASK_MARK" --arg prefix "$PREFIX" --arg valid "$VALID" \
       --argjson handled "$handled" --argjson seen "$seen" --argjson bots "$bots" --argjson parked "$parked" '
      def id: (.fullDatabaseId // .id | tostring);
      def agent: (.body // "") | contains($mark);
      # The first words as written: quoted lines and emphasis do not count.
      def lead: (.body // "") | gsub("\r"; "") | split("\n") | map(select(test("^\\s*>") | not)) | join("\n")
                | sub("^[\\s*_]+"; "");
      .data.viewer.login as $me
      | ([.data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[], .data.repository.pullRequest.comments.nodes[]]
         | map(select(.author.login == $me and (agent | not))) | length) as $mine
      | def handled: id as $i | any($handled[]; . == $i) or any($seen[]; . == $i)
                     or any($parked[]; .id == $i and .n == $mine);
      def where($t): if $t.line == null then $t.path else "\($t.path):\($t.line)" end;
      .data.repository.pullRequest as $p
      | [ $p.reviewThreads.nodes[] | . as $t | (.comments.nodes | sort_by(.createdAt)) as $cs
          | {t: $t, cs: $cs, root: $cs[0]} ] as $threads
      | { valid: [ $threads[] | select(.root.author.login != $me and (.t.isResolved | not)) | . as $x
                   | .cs[] | select(.author.login == $me and (agent | not) and (lead | test($valid; "i")) and (handled | not))
                   | {thread: $x.t.id, id: id, url, where: where($x.t), pending: (.state == "PENDING"),
                      instruction: (lead | sub($valid; ""; "i") | sub("^\\s+"; "")), asked: $x.root.body} ],
          commands: ( [ $threads[] | select(.t.isResolved | not) | . as $x
                        | .cs[] | select(.author.login == $me and (agent | not) and (lead | test($prefix; "i")) and (handled | not))
                        | {thread: $x.t.id, id: id, url, where: where($x.t), pending: (.state == "PENDING"), body} ]
                    + [ $p.comments.nodes[] | select(.author.login == $me and (agent | not) and (lead | test($prefix; "i")) and (handled | not))
                        | {thread: null, id: id, url, where: null, pending: false, body} ] ),
          bots: [ $threads[] | . as $x
                  | select($x.root.author.__typename == "Bot" and any($bots[]; . == $x.root.author.login)
                           and ($x.t.isResolved | not) and ($x.root | handled | not)
                           and (any($x.cs[]; agent or .author.login == $me) | not))
                  | {thread: .t.id, id: (.root | id), url: .root.url, where: where(.t), bot: .root.author.login,
                     body: .root.body, canResolve: .t.viewerCanResolve} ],
          waiting: [ $threads[] | select(.root.author.login != $me and .root.author.__typename != "Bot" and (.t.isResolved | not))
                     | select(any(.cs[]; .author.login == $me and (lead | test($valid; "i"))) | not)
                     | {thread: .t.id, where: where(.t), reviewer: .root.author.login, url: .root.url,
                        last: (.cs | last | .body | .[0:200])} ],
          info: ( [ $p.reviews.nodes[] | select(.author.login != $me and ((.body // "") | length) > 0 and (handled | not))
                    | {id: id, kind: "review", state, author: .author.login, url, excerpt: (.body | .[0:300])} ]
                + [ $p.comments.nodes[] | select(.author.login != $me and (handled | not))
                    | {id: id, kind: "comment", author: .author.login, bot: (.author.__typename == "Bot"), url,
                       excerpt: (.body | .[0:300])} ] ),
          pending: ([ $threads[].cs[] | select(.author.login == $me and .state == "PENDING" and (agent | not)) ] | length),
          mine: $mine }
    ' <<<"$raw" ;;

  reply)
    [ $# -eq 1 ] || usage
    thread="$1"; body="$(cat)"
    [ -n "${body//[[:space:]]/}" ] || die 4 "Empty reply body on stdin."
    case "$body" in "$AI_MARK"*) ;; *) body="$AI_MARK"$'\n\n'"$body" ;; esac
    body="$body"$'\n\n'"$TASK_MARK"
    review="$(pending_open)" || exit 1
    pending_reply "$review" "$thread" "$body" >/dev/null || exit 1
    printf 'drafted a reply in %s (review %s); the author submits it\n' "$thread" "$review" ;;

  resolve)
    [ $# -eq 1 ] || usage
    thread="$1"
    raw="$(gql "$PR_QUERY" "$(jq -n --arg o "$PR_OWNER" --arg r "$PR_REPO" --argjson n "$PR_NUM" '{o: $o, r: $r, n: $n}')")" || exit 1
    bots="$(task_get "$KEY" '.bots // ["copilot-pull-request-reviewer"]' | jq -c .)"
    root="$(jq -c --arg t "$thread" --argjson bots "$bots" '
      first(.data.repository.pullRequest.reviewThreads.nodes[] | select(.id == $t)) as $th
      | ($th.comments.nodes | sort_by(.createdAt) | .[0]) as $r
      | {bot: ($r.author.__typename == "Bot" and any($bots[]; . == $r.author.login)), can: $th.viewerCanResolve,
         id: ($r.fullDatabaseId // $r.id | tostring)}' <<<"$raw")"
    [ -n "$root" ] || die 7 "No thread $thread on $pr."
    jq -e .bot <<<"$root" >/dev/null || die 7 "Only an allowlisted bot's thread is resolved; a person closes their own."
    jq -e .can <<<"$root" >/dev/null || die 7 "GitHub does not let you resolve $thread."
    id="$(jq -r .id <<<"$root")"
    remote="$(task_get "$KEY" ".units[$IDX].remote")"; branch="$(task_get "$KEY" ".units[$IDX].branch")"
    { git -C "$WT" log --format='%(trailers:key=Addresses,valueonly)' "$remote/$branch" 2>/dev/null || true; } \
      | tr ', ' '\n\n' | grep -x "$id" >/dev/null \
      || die 7 "No pushed commit addresses $id yet; fix and push it first."
    gql 'mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }' \
      "$(jq -n --arg t "$thread" '{t: $t}')" >/dev/null || exit 1
    printf 'resolved %s\n' "$thread" ;;

  *) usage ;;
esac

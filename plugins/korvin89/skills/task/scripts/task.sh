#!/usr/bin/env bash
#
# task.sh — the task registry: what a task is, where its state lives, what is
# already in flight. See common.sh for the state layout.
#
# Usage:
#   task.sh resolve <input>      what the input is, as JSON: kind (task — a key we
#                                already track — tracker, issue, pr, text), key,
#                                url, title, and candidates — open PRs and local
#                                branches of the viewer that already match it
#   task.sh init <key> <kind> <ref> [--url <url>] [--base <branch>]
#                                start tracking a task; the brief comes on stdin
#   task.sh list                 the tasks in flight in this repository
#   task.sh show <key>           task.json
#   task.sh checks <key> <command>…
#                                the lint/test commands push.sh runs before a push
#   task.sh unit <key> <slug> [--after <slug>]
#                                add a plan unit (one PR); branch <key>-<slug>
#   task.sh park <key> <id> <lift> <note>
#                                park an event until <lift> changes: head:<sha>,
#                                base:<sha> or comment:<author-comment-count>
#   task.sh unpark <key> <id>
#   task.sh seen <key> <comment-id>…
#                                comments read that ask for nothing
#   task.sh activate <key>       this Claude session works the task now: the
#                                guard hook confines edits to its worktrees
#   task.sh deactivate <key>     lift that (pause, stop, done)
#
# Keys: an external tracker key lower-cased (abc-123), issue-<N>, pr-<N>, or
# t-<yyyymmdd>-<slug> for a task given as text. Matching of existing work is
# on exact tokens: the branch is the key or starts with "<key>-"; a body links
# the issue as "#N" or by URL, or names the tracker key as a word.
#
# Exit codes: 0 ok · 2 not a git repo · 3 gh missing · 4 bad usage · 6 jq missing
#             · 9 the task is driven by another session

set -euo pipefail
. "$(dirname "$0")/common.sh"

usage() { die 4 "Usage: task.sh resolve|init|list|show|checks|unit|park|unpark|seen|activate|deactivate … (see the header)"; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 2 "Not inside a git repository."
[ $# -ge 1 ] || usage
cmd="$1"; shift

# repo_of_cwd — "<host> <owner> <repo>" of the current repository.
repo_of_cwd() {
  gh repo view --json url --jq .url | sed -E 's#^https?://([^/]+)/([^/]+)/([^/]+).*#\1 \2 \3#'
}

# candidates <key> <token-jq> — open PRs by the viewer and local branches that
# match the key; <token-jq> is a jq expression testing .title / .body.
candidates() {
  local key="$1" test="$2"
  {
    gh pr list --author @me --state open --limit 100 --json url,headRefName,title,body 2>/dev/null \
      | jq -c --arg k "$key" "
          .[] | select((.headRefName | ascii_downcase) as \$b | \$b == \$k or (\$b | startswith(\$k + \"-\")) or ($test))
          | {kind: \"pr\", url, branch: .headRefName, title}" || true
    git for-each-ref refs/heads --format='%(refname:short)' \
      | jq -R -c --arg k "$key" '(. | ascii_downcase) as $b
          | select($b == $k or ($b | startswith($k + "-"))) | {kind: "branch", branch: .}' || true
  } | jq -s -c 'unique_by(.url // .branch)'
}

case "$cmd" in
  resolve)
    [ $# -eq 1 ] || usage
    gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"' EXIT
    input="$1"; root="$(task_root)"
    # A key we already track wins.
    if [ -f "$root/task-$input/task.json" ]; then
      jq -c '{kind: "task", key, url: .source.url, title: .source.title, candidates: []}' "$root/task-$input/task.json"
      exit 0
    fi
    read -r PR_HOST owner repo <<<"$(repo_of_cwd)"
    num=""; url=""
    case "$input" in
      http*://*/issues/[0-9]*) num="${input##*/issues/}"; num="${num%%[!0-9]*}" ;;
      http*://*/pull/[0-9]*)   num="${input##*/pull/}";   num="${num%%[!0-9]*}" ;;
      \#[0-9]*|[0-9]*)         num="${input#\#}"; case "$num" in *[!0-9]*) num="" ;; esac ;;
    esac
    if [ -n "$num" ]; then
      case "$input" in http*) owner="$(sed -E 's#^https?://[^/]+/([^/]+)/.*#\1#' <<<"$input")"
                              repo="$(sed -E 's#^https?://[^/]+/[^/]+/([^/]+)/.*#\1#' <<<"$input")" ;; esac
      info="$(gql 'query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) {
          issueOrPullRequest(number: $n) { __typename
            ... on Issue { url title }
            ... on PullRequest { url title headRefName isDraft state isCrossRepository viewerDidAuthor } } } }' \
        "$(jq -n --arg o "$owner" --arg r "$repo" --argjson n "$num" '{o: $o, r: $r, n: $n}')")" || exit 1
      jq -e '.data.repository.issueOrPullRequest != null' <<<"$info" >/dev/null || die 4 "#$num is neither an issue nor a PR in $owner/$repo."
      if jq -e '.data.repository.issueOrPullRequest.__typename == "PullRequest"' <<<"$info" >/dev/null; then
        jq -c --arg k "pr-$num" '.data.repository.issueOrPullRequest
          | {kind: "pr", key: $k, url, title, branch: .headRefName, isDraft, state, isCrossRepository, viewerDidAuthor, candidates: []}' <<<"$info"
      else
        url="$(jq -r '.data.repository.issueOrPullRequest.url' <<<"$info")"
        jq -c --arg k "issue-$num" --argjson c "$(candidates "issue-$num" \
            "((.body // \"\") | test(\"(^|[^0-9A-Za-z])#$num([^0-9]|\$)\")) or ((.body // \"\") | contains(\"$url\"))")" \
          '.data.repository.issueOrPullRequest | {kind: "issue", key: $k, url, title, candidates: $c}' <<<"$info"
      fi
      exit 0
    fi
    if printf '%s' "$input" | grep -Eq '^[A-Za-z][A-Za-z0-9]*-[0-9]+$'; then
      key="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
      jq -n -c --arg k "$key" --arg ref "$input" --argjson c "$(candidates "$key" \
          "((.title + \" \" + (.body // \"\")) | ascii_downcase | test(\"(^|[^a-z0-9])$key([^0-9]|\$)\"))")" \
        '{kind: "tracker", key: $k, ref: $ref, url: null, title: null, candidates: $c}'
      exit 0
    fi
    jq -n -c --arg k "t-$(date +%Y%m%d)" '{kind: "text", key: null, key_prefix: $k, candidates: []}' ;;

  init)
    [ $# -ge 3 ] || usage
    key="$1"; kind="$2"; ref="$3"; shift 3; url=""; base=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --url)  url="${2:-}"; shift 2 ;;
        --base) base="${2:-}"; shift 2 ;;
        *)      usage ;;
      esac
    done
    case "$key" in ""|*[!a-z0-9-]*) die 4 "A key is lower-case letters, digits and dashes: $key" ;; esac
    dir="$(task_dir "$key")"
    [ ! -e "$dir/task.json" ] || die 4 "Task $key already exists: resume it instead."
    if [ -z "$base" ]; then
      base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
      base="${base#origin/}"
    fi
    mkdir -p "$dir"
    task_lock "$key"
    jq -n --arg k "$key" --arg kind "$kind" --arg ref "$ref" --arg url "$url" --arg base "$base" \
      --arg remote "$(git remote get-url origin 2>/dev/null || true)" \
      '{key: $k, source: {kind: $kind, ref: $ref, url: (if $url == "" then null else $url end)},
        base: $base, origin: $remote, checks: [], units: []}' > "$dir/task.json"
    echo '{"parked": [], "seen": []}' > "$dir/ledger.json"
    cat > "$dir/brief.md"
    printf '%s\n' "$dir" ;;

  list)
    [ $# -eq 0 ] || usage
    found=0
    for f in "$(task_root)"/task-*/task.json; do
      [ -f "$f" ] || continue
      found=1
      jq -r '"\(.key)\t\(.source.kind) \(.source.ref)\t" + ([.units[] | "\(.slug)=\(.pr // "no PR")"] | join(", "))' "$f"
    done
    [ "$found" = 1 ] || echo "no tasks in flight in this repository" ;;

  show)
    [ $# -eq 1 ] || usage
    cat "$(task_dir "$1")/task.json" ;;

  checks)
    [ $# -ge 2 ] || usage
    key="$1"; shift
    task_set "$key" '.checks = $c' --argjson c "$(jq -n -c '$ARGS.positional' --args "$@")" ;;

  unit)
    [ $# -ge 2 ] || usage
    key="$1"; slug="$2"; shift 2; after=""
    case "${1:-}" in --after) after="${2:-}"; [ -n "$after" ] || usage ;; "") ;; *) usage ;; esac
    case "$slug" in ""|*[!a-z0-9-]*) die 4 "A slug is lower-case letters, digits and dashes: $slug" ;; esac
    task_lock "$key"
    jq -e --arg s "$slug" 'any(.units[]; .slug == $s) | not' "$(task_dir "$key")/task.json" >/dev/null \
      || die 4 "Unit $slug already exists in $key."
    task_set "$key" '.units += [{slug: $s, branch: ($k + "-" + $s), after: (if $a == "" then null else $a end),
                                 worktree: null, pr: null, remote: "origin", detached: false, status: "planned"}]' \
      --arg s "$slug" --arg k "$key" --arg a "$after"
    printf '%s-%s\n' "$key" "$slug" ;;

  park)
    [ $# -eq 4 ] || usage
    f="$(task_dir "$1")/ledger.json"
    jq --arg id "$2" --arg lift "$3" --arg note "$4" \
      '.parked = ([.parked[] | select(.id != $id)] + [{id: $id, lift: $lift, note: $note}])' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;

  unpark)
    [ $# -eq 2 ] || usage
    f="$(task_dir "$1")/ledger.json"
    jq --arg id "$2" '.parked = [.parked[] | select(.id != $id)]' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;

  seen)
    [ $# -ge 2 ] || usage
    key="$1"; shift
    f="$(task_dir "$key")/ledger.json"
    jq --args '.seen = (.seen + $ARGS.positional | unique)' "$@" < "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;

  activate)
    [ $# -eq 1 ] || usage
    task_lock "$1"
    printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-shell-$PPID}" > "$(task_dir "$1")/active"
    printf 'task %s is active in this session\n' "$1" ;;

  deactivate)
    [ $# -eq 1 ] || usage
    rm -f "$(task_dir "$1")/active"
    printf 'task %s is no longer active\n' "$1" ;;

  *) usage ;;
esac

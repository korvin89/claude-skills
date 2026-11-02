# gh.sh — GitHub plumbing shared by korvin89 scripts. Source it after
# `set -euo pipefail`; it defines functions and a few variables, runs nothing.
# Works with macOS's stock bash 3.2.
#
#   err <msg> / die <code> <msg>   print to stderr / and exit
#   gh_require                     exit 3 without gh, 6 without jq 1.6+
#   gh_tmp_init                    create $GH_TMP; the caller's EXIT trap removes it
#   deadline <cmd…>                run cmd, TERM it after $GH_CALL_DEADLINE seconds
#                                  (default 30); status 124 on timeout
#   gh_call <out-file> <gh args…>  gh under the deadline, stdout to <out-file>, stderr
#                                  kept in $GH_TMP/gh.err; on failure one line on
#                                  stderr, and an auth failure (HTTP 401, no login)
#                                  leaves $GH_TMP/auth behind
#   gh_pr <pr>                     resolve a PR number or URL; sets PR_URL, PR_HOST,
#                                  PR_OWNER, PR_REPO, PR_NUM
#   gql <query> <variables-json>   print the response; fail on any GraphQL error

GH_DOCS="https://cli.github.com/"
JQ_DOCS="https://jqlang.github.io/jq/download/"
GH_CALL_DEADLINE="${GH_CALL_DEADLINE:-${DRAFT_CALL_DEADLINE:-30}}"
GH_TMP=""

err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

gh_require() {
  command -v gh >/dev/null 2>&1 || {
    err "GitHub CLI (gh) is required but was not found."
    err "Install it: $GH_DOCS"
    exit 3
  }
  command -v jq >/dev/null 2>&1 || {
    err "jq is required but was not found."
    err "Install it: $JQ_DOCS"
    exit 6
  }
  case "$(jq --version 2>/dev/null)" in
    jq-1.[0-5]|jq-1.[0-5][!0-9]*) die 6 "jq 1.6 or newer is required, found $(jq --version). Update it: $JQ_DOCS" ;;
  esac
}

gh_tmp_init() { GH_TMP="$(mktemp -d)"; }

deadline() {
  local pid dog rc=0
  "$@" & pid=$!
  ( sleep "$GH_CALL_DEADLINE" && kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & dog=$!
  wait "$pid" || rc=$?
  if kill -0 "$dog" 2>/dev/null; then
    pkill -P "$dog" 2>/dev/null || true
    kill "$dog" 2>/dev/null || true
  elif [ "$rc" -ne 0 ]; then
    rc=124
  fi
  wait "$dog" 2>/dev/null || true
  return "$rc"
}

gh_call() {
  local out="$1" rc=0; shift
  deadline gh "$@" > "$out" 2> "$GH_TMP/gh.err" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 124 ]; then
    err "GitHub API error: no answer in ${GH_CALL_DEADLINE}s"
  else
    grep -q -e 'HTTP 401' -e 'gh auth login' "$GH_TMP/gh.err" && : > "$GH_TMP/auth"
    err "GitHub API error: $(tail -n 1 "$GH_TMP/gh.err")"
  fi
  return 1
}

gh_pr() {
  local rest
  gh_call "$GH_TMP/pr-url" pr view "${1#\#}" --json url --jq .url || return 1
  PR_URL="$(cat "$GH_TMP/pr-url")"
  rest="${PR_URL#*://}"; PR_HOST="${rest%%/*}"; rest="${rest#*/}"
  PR_OWNER="${rest%%/*}"; rest="${rest#*/}"; PR_REPO="${rest%%/*}"; PR_NUM="${PR_URL##*/}"
}

gql() {
  jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' > "$GH_TMP/req.json"
  gh_call "$GH_TMP/resp.json" api graphql --hostname "$PR_HOST" --method POST --input "$GH_TMP/req.json" || return 1
  cat "$GH_TMP/resp.json"
}

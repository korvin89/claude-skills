#!/usr/bin/env bash
#
# wt.sh — the worktree of a task unit, from creation to removal. Worktrees
# live next to the repository: <parent>/<repo>.worktrees/<branch>. The user's
# own checkout is never switched or written.
#
# Usage:
#   wt.sh create <key> <slug>     branch <key>-<slug> from a freshly fetched
#                                 origin/<base>, without upstream tracking;
#                                 prints the worktree path
#   wt.sh adopt <key> <pr-url>    work on an existing PR of the viewer. A PR
#                                 from a fork pushes to the fork's remote. When
#                                 its branch is checked out elsewhere (e.g. in
#                                 the user's checkout), the worktree is detached
#                                 and push.sh pushes HEAD:<branch>
#   wt.sh bootstrap <worktree>    install dependencies from the lockfile; print
#                                 "env-candidate <path>" for untracked env files
#                                 of the main checkout the worktree may need
#   wt.sh copy-env <worktree> <path>…
#                                 copy those files (paths relative to the repo)
#   wt.sh finish <worktree>       only when the unit's PR is merged, the worktree
#                                 is clean and its HEAD is the PR head or an
#                                 ancestor of it (squash merges included):
#                                 remove the worktree (never --force), delete
#                                 the local branch, delete the remote branch
#                                 when GitHub did not and the viewer may
#
# Exit codes: 0 ok · 1 git/GitHub error · 2 not a git repo · 4 bad usage
#             · 7 refused (not the viewer's PR, not merged, unpushed or
#               uncommitted work) · 9 the task is driven by another session

set -euo pipefail
. "$(dirname "$0")/common.sh"

usage() { die 4 "Usage: wt.sh create|adopt|bootstrap|copy-env|finish … (see the header)"; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 2 "Not inside a git repository."
[ $# -ge 2 ] || usage
cmd="$1"; shift

# unit_of <worktree> — sets KEY and IDX for the unit that owns the worktree.
unit_of() {
  local hit
  hit="$(task_of "$1")"
  [ -n "$hit" ] || die 7 "$1 is not the worktree of a task unit."
  KEY="${hit%%$'\t'*}"; IDX="${hit#*$'\t'}"
}

case "$cmd" in
  create)
    [ $# -eq 2 ] || usage
    key="$1"; slug="$2"
    task_lock "$key"
    idx="$(task_get "$key" "[.units[].slug] | index(\"$slug\") // empty")"
    [ -n "$idx" ] || die 4 "No unit $slug in task $key; add it with task.sh unit."
    branch="$(task_get "$key" ".units[$idx].branch")"
    base="$(task_get "$key" .base)"
    path="$(task_wt_dir)/$branch"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      die 4 "Branch $branch already exists; resume its worktree instead."
    fi
    git fetch --quiet origin "$base"
    mkdir -p "$(task_wt_dir)"
    git worktree add --quiet --no-track -b "$branch" "$path" "origin/$base"
    path="$(CDPATH='' cd -P -- "$path" && pwd -P)"
    task_set "$key" ".units[$idx].worktree = \$p | .units[$idx].status = \"in-progress\"" --arg p "$path"
    printf '%s\n' "$path" ;;

  adopt)
    [ $# -eq 2 ] || usage
    key="$1"; ref="$2"
    gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"' EXIT
    task_lock "$key"
    gh_call "$GH_TMP/pr.json" pr view "$ref" \
      --json url,number,headRefName,baseRefName,isCrossRepository,headRepository,headRepositoryOwner,author || exit 1
    me="$(gh api user --jq .login)"
    [ "$(jq -r .author.login "$GH_TMP/pr.json")" = "$me" ] || die 7 "PR $ref is not yours; only your own PRs are adopted."
    url="$(jq -r .url "$GH_TMP/pr.json")"; branch="$(jq -r .headRefName "$GH_TMP/pr.json")"
    remote=origin
    if jq -e .isCrossRepository "$GH_TMP/pr.json" >/dev/null; then
      fork="$(jq -r '"\(.headRepositoryOwner.login)/\(.headRepository.name)"' "$GH_TMP/pr.json")"
      remote="$(git remote -v | awk -v f="$fork" '$3 == "(fetch)" && tolower($2) ~ tolower(f) "(\\.git)?/?$" { print $1; exit }')"
      if [ -z "$remote" ]; then
        remote="fork-$(jq -r .headRepositoryOwner.login "$GH_TMP/pr.json")"
        git remote add "$remote" "$(gh repo view "$fork" --json sshUrl --jq .sshUrl)"
      fi
    fi
    git fetch --quiet "$remote" "$branch"
    path="$(task_wt_dir)/$branch"; mkdir -p "$(task_wt_dir)"
    detached=false
    if git worktree list --porcelain | grep -qx "branch refs/heads/$branch"; then
      # Checked out elsewhere — most likely the user's checkout. Never switch it.
      git worktree add --quiet --detach "$path" "$remote/$branch"; detached=true
    elif git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add --quiet "$path" "$branch"
    else
      git worktree add --quiet --no-track -b "$branch" "$path" "$remote/$branch"
    fi
    path="$(CDPATH='' cd -P -- "$path" && pwd -P)"
    base="$(jq -r .baseRefName "$GH_TMP/pr.json")"
    task_set "$key" '.base = $b | .units += [{slug: "pr", branch: $br, after: null, worktree: $p, pr: $u,
                                              remote: $r, detached: ($d == "true"), status: "in-progress"}]' \
      --arg b "$base" --arg br "$branch" --arg p "$path" --arg u "$url" --arg r "$remote" --arg d "$detached"
    printf '%s\n' "$path"
    [ "$detached" = false ] || err "Note: $branch is checked out in another worktree; this one is detached and pushes HEAD:$branch, so that checkout will fall behind." ;;

  bootstrap)
    [ $# -eq 1 ] || usage
    wt="$1"; unit_of "$wt"
    if   [ -f "$wt/pnpm-lock.yaml" ];     then (cd "$wt" && pnpm install --frozen-lockfile)
    elif [ -f "$wt/package-lock.json" ];  then (cd "$wt" && npm ci)
    elif [ -f "$wt/yarn.lock" ];          then (cd "$wt" && yarn install --frozen-lockfile)
    elif [ -f "$wt/bun.lockb" ];          then (cd "$wt" && bun install --frozen-lockfile)
    fi
    main="$(task_main)"
    git -C "$main" ls-files --others --ignored --exclude-standard -- ':(glob).env*' ':(glob)**/.env*' 2>/dev/null \
      | grep -v -e '/node_modules/' | sed 's/^/env-candidate /' || true ;;

  copy-env)
    [ $# -ge 2 ] || usage
    wt="$1"; shift; unit_of "$wt"; main="$(task_main)"
    for f in "$@"; do
      case "$f" in /*|*..*) die 4 "Give paths relative to the repository: $f" ;; esac
      [ -f "$main/$f" ] || die 4 "Not a file in the main checkout: $f"
      mkdir -p "$(dirname "$wt/$f")"; cp "$main/$f" "$wt/$f"; printf 'copied %s\n' "$f"
    done ;;

  finish)
    [ $# -eq 1 ] || usage
    wt="$1"; unit_of "$wt"
    gh_require; gh_tmp_init; trap 'rm -rf "$GH_TMP"' EXIT
    task_lock "$KEY"
    pr="$(task_get "$KEY" ".units[$IDX].pr // empty")"; [ -n "$pr" ] || die 7 "Unit has no PR."
    branch="$(task_get "$KEY" ".units[$IDX].branch")"
    detached="$(task_get "$KEY" ".units[$IDX].detached")"
    gh_pr "$pr" || exit 1
    info="$(gql 'query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) {
        deleteBranchOnMerge pullRequest(number: $n) { state headRefOid viewerCanDeleteHeadRef headRef { name } } } }' \
      "$(jq -n --arg o "$PR_OWNER" --arg r "$PR_REPO" --argjson n "$PR_NUM" '{o: $o, r: $r, n: $n}')")" || exit 1
    [ "$(jq -r .data.repository.pullRequest.state <<<"$info")" = MERGED ] || die 7 "$pr is not merged; nothing removed."
    [ -z "$(git -C "$wt" status --porcelain)" ] || die 7 "$wt has uncommitted changes; nothing removed."
    head="$(jq -r .data.repository.pullRequest.headRefOid <<<"$info")"; local_head="$(git -C "$wt" rev-parse HEAD)"
    if [ "$local_head" != "$head" ] && ! git merge-base --is-ancestor "$local_head" "$head" 2>/dev/null; then
      die 7 "$wt has commits that are not in the merged PR (local $local_head, PR $head); nothing removed."
    fi
    git worktree remove "$wt"
    [ "$detached" = true ] || git branch -D "$branch" >/dev/null
    if jq -e '.data.repository.deleteBranchOnMerge == false and .data.repository.pullRequest.viewerCanDeleteHeadRef
              and .data.repository.pullRequest.headRef != null' <<<"$info" >/dev/null; then
      gh_call /dev/null api --hostname "$PR_HOST" -X DELETE "repos/$PR_OWNER/$PR_REPO/git/refs/heads/$branch" \
        && printf 'deleted remote branch %s\n' "$branch"
    fi
    task_set "$KEY" ".units[$IDX].status = \"done\" | .units[$IDX].worktree = null"
    printf 'finished %s (%s)\n' "$branch" "$pr" ;;

  *) usage ;;
esac

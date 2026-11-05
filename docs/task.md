# korvin89:task

[All skills](../README.md)

The author-side companion to [`code-review`](code-review.md): you are the
**author** of the PR. It takes one of your tasks to a merged PR — plans it,
implements it, reviews its own diff, opens a **draft** PR, and follows review
comments and CI until the merge. You decide what changes: it only acts on your
word. User-invoked only:

```text
/korvin89:task ABC-123              # a tracker task, read through the tracker skill your session has
/korvin89:task 56                   # a GitHub issue (or a PR number: then it follows that PR of yours)
/korvin89:task "cache the user list for 5 minutes"
/korvin89:task                      # the tasks in flight; pick one to continue
```

Requires `gh` and `jq` 1.6+.

Running it again with the same task continues where things stand: state comes
from git and GitHub, not from the session.

Worktrees live next to your checkout: for `~/src/app`, in
`~/src/app.worktrees/<key>-<slug>/`, one per PR.

## The flow

1. **Plan.** One PR by default, several only for a large task (no stacked
   PRs). A read-only critic checks the plan, then you approve it — the one
   point where it always waits for you.
2. **Implement.** Each PR gets its own worktree next to the repository,
   `<repo>.worktrees/<branch>`; your checkout is never switched or written.
   Dependencies are installed from the lockfile; it asks once about env files.
3. **Self-review.** Two independent read-only critics review the diff with
   the `code-review` rubric; the agent fixes what they agree on.
4. **Draft PR.** Pushed only after your repository's lint and tests pass, with
   a title in the style of your merged PRs. Its description has the agent's
   block between markers; your own text around it is never touched, and your
   ticks in its checklist are kept. Moving the PR out of draft is yours.
5. **Follow** (after `watch`): review comments, CI, conflicts, until the merge.
   Then the worktree and branch are removed, and the next PR of the plan
   starts. Once the last PR is merged, the task's working files go too;
   if anything looks off (uncommitted work, a watcher still running) it asks
   first.

## What makes it change code

Only three things:

- your `valid` as the first word of a reply in a reviewer's thread (text
  after it refines the fix: `valid, but keep the old name`);
- your `ai:` command, in a thread or as a PR comment;
- a Copilot review thread it agrees with (it argues the others in a draft
  reply and leaves them to you).

Everything else — review summaries, other people's comments, other bots — is
reported to you and never acted on. Threads where a reviewer waits for your
verdict are listed in `status`. Fixes carry an `Addresses: <comment id>`
trailer, so nothing is fixed twice after a restart. When a reply to a reviewer
is needed, it goes into **your pending review** as a draft for you to submit;
nothing is published on your behalf. Only Copilot threads it fixed are
resolved; a person's thread is theirs to close.

## CI and conflicts

- A failing check is classified from its log: a real failure gets fixed (at
  most 3 fix commits per check, then it stops and asks); a flake is rerun (at
  most twice); a broken base branch waits for the base to be fixed.
- Skipped checks on a draft never count as green.
- Checks that fail by design can be listed under `## Expected failing checks`
  in `AGENTS.md` of the base branch.
- Conflicts are resolved by merging the base in, only when mechanical;
  otherwise it stops and names the files.
- Never: force-push, rebasing pushed work, editing CI workflows or test
  config, disabling tests, or writing to your tracker.

## Session commands

| Command | What it does |
|---|---|
| `watch` | start following review comments and CI (nothing polls GitHub until you say it) |
| `sync` | handle what is there now, once |
| `status` | the task at a glance: PRs, CI, triggers, threads waiting for you, manual steps |
| `pause` | stop following and lift the edit guard, e.g. to work in your own checkout |
| `stop` | stop following; nothing is deleted |

[`/korvin89:cleanup task-<key>`](cleanup.md) removes an abandoned task, or
one where a PR was closed without a merge: its worktrees, and its branches
only when they are pushed. A task whose PRs all merged cleans itself up.

## Guard rails

While a task is active, a hook in the skill blocks:
- edits outside the task's worktrees;
- raw `git push`;
- history rewrites;
- `gh pr ready` / `merge`;
- GitHub writes outside the task's scripts.

`pause` lifts it.

## Leaving it in the background

The skill's own grant lasts only one turn, so for a background run add two
things to `~/.claude/settings.json`:
- an allow rule for the task scripts;
- the worktrees dir, which lies outside the project.

```json
{ "permissions": {
    "allow": ["Bash(bash *skills/task/scripts/*)"],
    "additionalDirectories": ["<parent>/<repo>.worktrees"] } }
```

# korvin89:cleanup

[All skills](../README.md)

Removes what the review skills keep for one pull request:
`<repo>/.git/code-review/pr-<N>/` — the PR head worktree, the findings batch,
and the screenshots, configs and worktrees of
[`review-artifacts`](review-artifacts.md). User-invoked only, and only for
the review you name:

```text
/korvin89:cleanup 1234     # the scratch of PR #1234 (also #1234, pr-1234 or the PR URL)
/korvin89:cleanup local    # the scratch of a review without a PR, in this checkout
/korvin89:cleanup task-<key>   # an abandoned task: its worktrees, and its branches when pushed
/korvin89:cleanup          # lists what exists; removes nothing
```

Requires `gh` for a PR and `jq` for a task.

Before removing anything it checks that the scratch belongs to that review and
is not in use:

- the scratch records the PR URL (or the checkout) it was made for, and it
  matches;
- a git remote of this repository points at the PR's repository;
- every worktree in it can be read by git and has no uncommitted or untracked
  files;
- the session is not inside the scratch;
- no draft watcher runs for the PR.

When a check fails it shows why and asks; a "yes" holds only for exactly the
warnings shown. Only git's records of worktrees inside that scratch are
dropped; your own worktrees are never pruned.

[`code-review`](code-review.md) runs the same script when a PR run ends and
keeps the scratch when a check fails. Nothing is ever removed without a review
named: other reviews' scratch is only listed when a review starts. Published
artifact pages and draft reviews are never touched.

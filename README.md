# claude-skills

A personal library of reusable [Claude Code](https://code.claude.com/docs)
skills, packaged as a plugin marketplace. Skills are installed into any project
with `/plugin install` — they live here, not in the repos that use them.

Skills are grouped under `korvin89`, a personal namespace plugin, and invoked
as `korvin89:<skill>`.

## Install

```text
/plugin marketplace add korvin89/claude-skills
/plugin install korvin89@claude-skills
```

## Update

```text
/plugin marketplace update claude-skills
/plugin update korvin89@claude-skills
/reload-plugins
```

From a shell: `claude plugin marketplace update claude-skills`, then
`claude plugin update korvin89@claude-skills`, then restart Claude Code.
`claude plugin list` shows the installed version.

## Skills

| Skill | What it does | Invoked by |
|---|---|---|
| [`code-review`](docs/code-review.md) | Reviews a PR or your local changes in ordered passes, with a severity and a confidence per finding. On a PR the findings go into your GitHub draft review: you curate them there with `ai:` comments and submit it yourself. | you, or Claude when you ask for a review |
| [`task`](docs/task.md) | The author side: takes your task — a tracker key, a GitHub issue or text — through a plan you approve to a draft PR, then follows review comments and CI until the merge. It changes code only on your word. | you |
| [`cleanup`](docs/cleanup.md) | Removes the scratch and worktrees that one review or task keeps, after checking that nothing in them is in use or unpushed. | you |
| [`review-artifacts`](docs/review-artifacts.md) | One shareable page of screenshot pairs (base vs PR) and the configs behind them, for a review finding. | you, or `code-review` on `artifacts` |

```text
/korvin89:code-review 1234       # review PR #1234 into your draft review
/korvin89:code-review            # review your local changes
/korvin89:task ABC-123           # take a task (tracker key, issue number or text) to a merged PR
/korvin89:cleanup 1234           # remove what the review of PR #1234 keeps
/korvin89:review-artifacts <what to compare>
```

The skills talk to you in Russian. `code-review` asks which language its
comments are in; `task` writes commits and PR text in the repository's style.

## Requirements

- `code-review`: `gh` and `jq` 1.6+, for a PR review only.
- `task`: `gh` and `jq` 1.6+.
- `cleanup`: `gh` for a PR, `jq` for a task.
- `review-artifacts`: `jq`, and a claude.ai login (CLI or desktop app) for the
  Artifact tool.

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

---

## `korvin89:code-review`

An interactive, curation-first code review. It collects the diff itself, reads
the full surrounding context of each changed file, reviews in ordered passes
(intent → correctness → architecture → tests → readability → nits) with a
severity and a confidence per finding, optionally runs an independent second
pass in a sub-agent, and then walks you through curation before anything is
posted. The conversation is in Russian; the language of posted comments is
chosen at run time. The style is fixed everywhere — dump, questions, posted
comments: dry, businesslike, no slang, no praise or grading of the reviewed
code.

The workflow itself is in
[SKILL.md](plugins/korvin89/skills/code-review/SKILL.md); the review rules are
in [references/rubric.md](plugins/korvin89/skills/code-review/references/rubric.md).

### Usage

```text
/korvin89:code-review                 # review the working tree if dirty, else the current branch
/korvin89:code-review 1234            # review PR #1234 (needs gh)
/korvin89:code-review 1234 --post     # …and post the curated batch as one PR review
/korvin89:code-review --quick         # single pass, dump findings, no questions
/korvin89:code-review --branch        # force branch mode even with a dirty tree
```

| Argument | What it does |
|---|---|
| `[pr-number \| #number \| pr-url]` | Review that PR (needs `gh`). Omit it → auto-detect: working tree if dirty, otherwise the current branch against `origin/<default>`. |
| `--post` | Post the finalized batch to the PR as a single review. Only in PR mode, only after you confirm. Ignored under `--quick`. |
| `--quick` | Skip the interactive flow: single pass, dump the findings, stop. |
| `--branch` | Force branch mode even when the working tree is dirty. |

Everything else is asked in one prompt before the review: whether to run the
second pass, the comment language, and any focus areas to scrutinize.

Claude can also trigger the skill on its own when you ask it to "review this
PR" or "review my changes".

### The flow (three stops)

1. **Config** — one prompt with the three questions above. In PR mode the
   Herdr tab (if any) is renamed to `pr-<id>`.
2. **Curation** — every finding is dumped in Russian, numbered, with a
   severity (🔴 `blocker` / 🟠 `should-fix` / 🔵 `nit` / ❓ `question`) and a
   confidence. You reply with the numbers to keep and optional per-item edits,
   and whether to include the fixed legend comment (on by default). `4: +артефакты`
   attaches an artifact page (screenshot pairs main vs PR plus configs) to that
   finding; see `korvin89:review-artifacts`.
3. **Confirm or groom** — the final batch is rendered as it will be posted, in
   your chosen language. Grooming loops back to curation.

With `--post`, the confirmed batch is posted as **one PR review**: inline
comments on diff lines plus the legend as the review body. Every posted text
starts with `🤖 AI generated`. Findings on lines outside the diff are listed in
the review body with their `path:line`. Posting requires `gh` and `jq`.

### Per-repo conventions layer (not shipped here)

A repo can add its own rules at

```
<that-repo>/.claude/skills/code-review-conventions/SKILL.md
```

The skill reads it when present and folds it into the review: the generic
rubric is the base, project conventions add to and override it, and on a direct
conflict the project layer wins. A line `comment-language: en` (or `ru`, or any
language name) in that file sets the repo's default comment language.

## `korvin89:herdr-tab-rename`

Renames the current [Herdr](https://herdr.dev) tab. User-invoked only (no
description is loaded into context), so it costs nothing until typed:

```text
/korvin89:herdr-tab-rename pr-1234
```

Its script, `scripts/rename.sh <name>`, is what other skills call directly:
outside Herdr (`HERDR_ENV` unset) it is a silent no-op, inside it runs
`herdr tab rename` on the current tab. `code-review` uses it in PR mode.

## `korvin89:review-artifacts`

Builds one shareable artifact page for a review finding: a short text on top,
a collapsed block of screenshot pairs (base vs PR, side by side), a collapsed
block of the configs behind them. Publishes it with Claude Code's Artifact
tool and returns the link; the page stays private until you press **Share**.
User-invoked only, and read by `code-review` for findings marked `+артефакты`:

```text
/korvin89:review-artifacts stacked bar with negative values, default and dark theme
```

The skill does not know how a given repo renders screenshots: it asks once
per run (command, story or fixture, viewport, theme), renders each pair in
separate `git worktree`s so your checkout is untouched, and assembles the page
with `scripts/build-page.sh` from a `manifest.json`. Requires `jq`; the
Artifact tool needs a claude.ai login (CLI or desktop app).

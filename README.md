# claude-skills

A personal library of reusable [Claude Code](https://code.claude.com/docs)
skills, packaged as a **plugin marketplace**. Skills are installed into any
project with `/plugin install` — they live here, not in the repos that use
them, so nothing has to be committed into those projects.

Skills are grouped under **`korvin89`**, a personal namespace plugin that can
hold many skills. Adding a skill later does not touch existing ones.

## Layout

```
claude-skills/
├── .claude-plugin/
│   └── marketplace.json            # the marketplace catalog (lists every plugin)
├── plugins/                        # one directory per plugin
│   └── korvin89/                   # personal namespace plugin (holds many skills)
│       ├── .claude-plugin/
│       │   └── plugin.json         # plugin manifest
│       └── skills/
│           ├── code-review/        # invoked as korvin89:code-review
│           │   ├── SKILL.md        # the workflow
│           │   ├── references/
│           │   │   ├── rubric.md   # passes, severity/confidence, finding format
│           │   │   └── legend.md   # the top-level review comment (RU/EN)
│           │   └── scripts/
│           │       ├── collect-diff.sh   # detects and prints what to review
│           │       └── post-review.sh    # posts the batch as one PR review
│           └── herdr-tab/          # invoked as korvin89:herdr-tab (by hand only)
│               ├── SKILL.md
│               └── scripts/
│                   └── rename.sh   # renames the current Herdr tab; no-op outside Herdr
├── README.md
└── .gitignore
```

- `.claude-plugin/marketplace.json` — required at the repo root. Lists each
  plugin with a `name` and a `source` relative to the repo root.
- Each plugin has its own `.claude-plugin/plugin.json`.
- Skills live at `skills/<name>/SKILL.md` inside a plugin and may bundle
  supporting files alongside. Each is invoked as `<plugin>:<skill>`.

## Install

The marketplace is this repo on GitHub. Add it once, then install the plugin:

```text
/plugin marketplace add korvin89/claude-skills
/plugin install korvin89@claude-skills
```

`claude plugin list` shows the installed version.

## Updating an installed plugin

Claude Code keeps two copies of a GitHub marketplace:

- the **catalog**, a clone of this repo's `main` at
  `~/.claude/plugins/marketplaces/claude-skills`;
- the **installed plugin**, a copy at
  `~/.claude/plugins/cache/claude-skills/korvin89/<version>`, pinned by the
  `version` field of `plugin.json`.

A change is only picked up when the version changes, so a release is:

1. Bump `version` in `plugins/korvin89/.claude-plugin/plugin.json`. Without
   the bump `/plugin update` finds nothing new, even after the catalog refresh.
2. Merge to `main` and push. The catalog follows `main`; a release branch is
   invisible to it.
3. In Claude Code:

   ```text
   /plugin marketplace update claude-skills    # refresh the catalog clone
   /plugin update korvin89@claude-skills       # install the new version into the cache
   /reload-plugins                             # apply in the current session (or restart)
   ```

   The same works from a shell: `claude plugin marketplace update claude-skills`
   and `claude plugin update korvin89@claude-skills`.

Optional: `claude plugin tag --push` creates and pushes a `korvin89--v<version>`
tag after checking that `plugin.json` and the marketplace entry agree.

Validate the manifests before publishing:

```text
claude plugin validate .
claude plugin validate ./plugins/korvin89
```

## Developing locally

Load the plugin straight from the working tree for one session; it overrides
the installed copy of the same name, so a release branch can be tried before it
is merged:

```text
claude --plugin-dir ./plugins/korvin89
```

After editing files, `/reload-plugins` picks up the changes without a restart.

## Adding more skills later

**Under the `korvin89` namespace** (most skills): create
`plugins/korvin89/skills/<new-skill>/SKILL.md`. It is invoked as
`korvin89:<new-skill>`; no marketplace change is needed.

**As a separate plugin** (only for a distinct install/namespace): create
`plugins/<new-plugin>/.claude-plugin/plugin.json` and
`plugins/<new-plugin>/skills/<new-skill>/SKILL.md`, then add an entry to the
`plugins` array in `.claude-plugin/marketplace.json`.

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
   and whether to include the fixed legend comment (on by default).
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

## `korvin89:herdr-tab`

Renames the current [Herdr](https://herdr.dev) tab. User-invoked only (no
description is loaded into context), so it costs nothing until typed:

```text
/korvin89:herdr-tab pr-1234
```

Its script, `scripts/rename.sh <name>`, is what other skills call directly:
outside Herdr (`HERDR_ENV` unset) it is a silent no-op, inside it runs
`herdr tab rename` on the current tab. `code-review` uses it in PR mode.

# claude-skills

A personal library of reusable [Claude Code](https://code.claude.com/docs)
skills, packaged as a **plugin marketplace**. Skills are installed into any
project with `/plugin install` — they live here, not in the repos that use
them, so nothing has to be committed into those projects.

The repo is built to grow: each skill is its own plugin listed in one
marketplace catalog. Adding a skill later does not touch existing ones.

## Layout

```
claude-skills/
├── .claude-plugin/
│   └── marketplace.json            # the marketplace catalog (lists every plugin)
├── plugins/                        # one directory per plugin
│   └── code-review/                # one plugin == one skill
│       ├── .claude-plugin/
│       │   └── plugin.json         # plugin manifest
│       └── skills/
│           └── code-review/
│               ├── SKILL.md        # the workflow
│               └── scripts/
│                   └── collect-diff.sh
├── README.md
└── .gitignore
```

- `.claude-plugin/marketplace.json` — required at the repo root. Lists each
  plugin with a `name` and a `source` relative to the repo root
  (e.g. `"./plugins/code-review"`).
- Each plugin has its own `.claude-plugin/plugin.json`.
- Skills live at `skills/<name>/SKILL.md` inside a plugin and may bundle
  supporting files (scripts, references) alongside `SKILL.md`.

## Install

From any project (or globally), point Claude Code at this repo, then install
the plugin:

```text
/plugin marketplace add /Users/alaev89/Desktop/pet-projects/claude-skills
/plugin install code-review@claude-skills
```

`/plugin marketplace add` also accepts a GitHub `owner/repo` or a git URL once
you push this repo somewhere — the local path above works for local use.

After installing, invoke the skill (plugin skills are namespaced
`<plugin>:<skill>`):

```text
/code-review:code-review                 # review the current diff
/code-review:code-review 1234            # review PR #1234 (needs gh)
/code-review:code-review 1234 --post     # review PR #1234 and post comments
/code-review:code-review --lang en       # force English comments this run
```

Claude can also trigger it automatically when you ask it to "review this PR" or
"review my changes" — that is what the English `description` in the frontmatter
is for.

Update after you push changes here:

```text
/plugin marketplace update claude-skills
```

## Adding more skills later

1. Create `plugins/<new-skill>/.claude-plugin/plugin.json`.
2. Create `plugins/<new-skill>/skills/<new-skill>/SKILL.md`.
3. Add an entry to the `plugins` array in
   `.claude-plugin/marketplace.json` with a `name` and
   `source: "./plugins/<new-skill>"`.

Nothing about the existing plugins changes.

---

## The `code-review` skill

A **workflow**, not a static checklist. It pulls the diff itself, reads the
**full surrounding context** of each changed file (not just the hunks), and
reports findings in ordered passes:

1. **Intent** — what the change is trying to do (PR description / linked issue).
2. **Correctness** — logic, edge cases, errors.
3. **Architecture & fit** — alignment with the project's existing patterns.
4. **Tests** — coverage of the change and whether the tests are meaningful.
5. **Readability & naming.**
6. **Minor / nits** — dead last.

It also applies a **frontend layer** where relevant: React (rules of hooks,
effect deps, avoidable re-renders, list keys), TypeScript (`any` leaks, typing
of public APIs), accessibility, and bundle/perf.

### Diff source (auto-detected)

The skill detects what to review, first match wins:

1. **PR** — you passed a PR number/URL → reviews that pull request.
2. **Working tree** — you have uncommitted changes → reviews staged + unstaged
   vs `HEAD`.
3. **Branch** — otherwise → reviews the current branch against its merge-base
   with the default branch (`origin/HEAD`, else `main`/`master`).

Detection is implemented in `scripts/collect-diff.sh`, which prints the mode,
the changed-file list, and the unified diff.

### `gh` requirement

Anything that touches a pull request (fetching/reviewing a PR, reading its
description or comments, posting) requires the GitHub CLI, `gh`. Before any such
operation the skill checks that `gh` is installed; if it is missing it prints

> Install it: https://cli.github.com/

and stops without doing anything else. **Local branch and working-tree reviews
do not require `gh`** and run without that check.

### Comment language (resolved at runtime)

The language of the comment text is **not** hard-coded in `SKILL.md`. It is
resolved when the skill runs, so different repos can use different languages.
First match wins:

1. **Explicit argument** — `--lang <code>` (e.g. `--lang ru`, `--lang en`).
2. **Project config** — the `language` field of `.claude/code-review.json` in
   the repo being reviewed.
3. **Fallback** — **English**.

`.claude/code-review.json` format:

```json
{
  "language": "ru"
}
```

To make a repo always review in Russian (or any language), commit that file
with the desired `language`. For a one-off, pass `--lang`.

The resolved language applies **only to the prose of the findings**. It does
**not** change:

- the frontmatter `description` (always English — more reliable for triggering
  and sharing),
- the severity labels `blocker` / `should-fix` / `nit` / `question` (kept as
  these exact terms),
- the `🤖 AI generated` marker.

### Output format

- All findings are delivered in **one batch**, not incrementally.
- The batch starts with the marker `🤖 **AI generated**`.
- If findings are posted to a PR as separate comments (`--post`), **each
  comment also starts with `🤖 AI generated`** so the marker is never lost when
  the batch is split.
- Each finding is `**[severity]** path:line — concrete problem, why it matters,
  suggested fix`. No filler praise, no hedging — it says what is actually wrong.

### Project conventions layer (per repo, not shipped here)

This skill is generic and goes into every repo unchanged. A specific repo can
add a project-local convention layer that **augments** it without being part of
this marketplace:

```
<that-repo>/.claude/skills/code-review-conventions/SKILL.md
```

When the generic skill runs, it looks for that file and folds its rules into
the relevant passes. **Composition:** the generic passes are the base; project
conventions add to and override them, and on any direct conflict the project
layer wins. This keeps the shared skill stable while letting each repo encode
its own naming rules, architectural constraints, and review priorities.

This `code-review-conventions` skill is intentionally **not** part of the
`claude-skills` repo — it is created inside whichever project needs it.

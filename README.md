# claude-skills

A personal library of reusable [Claude Code](https://code.claude.com/docs)
skills, packaged as a **plugin marketplace**. Skills are installed into any
project with `/plugin install` — they live here, not in the repos that use
them, so nothing has to be committed into those projects.

The repo is built to grow. Skills are grouped under **`korvin89`**, a personal
namespace plugin that can hold many skills; `code-review` is the first. Adding a
skill later does not touch existing ones.

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
│           └── code-review/        # one skill → invoked as korvin89:code-review
│               ├── SKILL.md        # the workflow
│               └── scripts/
│                   └── collect-diff.sh
├── README.md
└── .gitignore
```

- `.claude-plugin/marketplace.json` — required at the repo root. Lists each
  plugin with a `name` and a `source` relative to the repo root
  (e.g. `"./plugins/korvin89"`).
- Each plugin has its own `.claude-plugin/plugin.json`.
- Skills live at `skills/<name>/SKILL.md` inside a plugin and may bundle
  supporting files (scripts, references) alongside `SKILL.md`. A plugin can hold
  more than one skill; each is invoked as `<plugin>:<skill>`.

## Install

From any project (or globally), point Claude Code at this repo, then install
the plugin:

```text
/plugin marketplace add /Users/alaev89/Desktop/pet-projects/claude-skills
/plugin install korvin89@claude-skills
```

> **Renamed from `code-review@claude-skills`.** The plugin used to be called
> `code-review`; it is now the `korvin89` namespace. If you had the old one
> installed, remove it and install `korvin89@claude-skills` — the skill is now
> invoked as `korvin89:code-review`.

`/plugin marketplace add` also accepts a GitHub `owner/repo` or a git URL once
you push this repo somewhere — the local path above works for local use.

After installing, invoke the skill (plugin skills are namespaced
`<plugin>:<skill>`):

```text
/korvin89:code-review                 # review the current diff (interactive)
/korvin89:code-review 1234            # review PR #1234 (needs gh)
/korvin89:code-review 1234 --post     # review PR #1234 and post the curated batch
/korvin89:code-review --quick         # single pass, dump findings, no questions
/korvin89:code-review --lang en       # pre-fill English as the comment-language default
```

### Run arguments

There are only four command-line arguments — everything else is chosen
interactively (see [The flow](#the-flow-three-stops)):

| Argument | What it does |
|---|---|
| `[pr-number \| pr-url]` | Review that PR (needs `gh`). Omit it → auto-detect: working tree if dirty, otherwise the current branch. |
| `--post` (alias `--comment`) | Post the finalized batch to the PR. Only in PR mode, and only after you confirm the batch. Without it, nothing is ever posted. |
| `--quick` | Skip the whole interactive flow: single pass, dump the findings, stop. Uses defaults (`сухо` style, no second pass). |
| `--lang <code>` | Pre-fill the default for the comment-language question (e.g. `--lang en`). Still confirmed in the config prompt. |

**Not flags — asked interactively** in the config prompt (Stop 1): the comment
**style** (`сухо` / `вежливо`), whether to run a **second pass**, and the
**comment language** (`--lang` only pre-fills its default). This is deliberate:
the run is a conversation, not a long flag string.

Claude can also trigger it automatically when you ask it to "review this PR" or
"review my changes" — that is what the English `description` in the frontmatter
is for.

Update after you push changes here:

```text
/plugin marketplace update claude-skills
```

## Adding more skills later

Two ways, depending on whether the new skill belongs in the personal namespace:

**Under the `korvin89` namespace** (most skills):

1. Create `plugins/korvin89/skills/<new-skill>/SKILL.md`.
2. That's it — it is invoked as `korvin89:<new-skill>`. No marketplace change is
   needed, since `korvin89` is already listed.

**As a separate plugin** (only when you want a distinct install/namespace):

1. Create `plugins/<new-plugin>/.claude-plugin/plugin.json`.
2. Create `plugins/<new-plugin>/skills/<new-skill>/SKILL.md`.
3. Add an entry to the `plugins` array in `.claude-plugin/marketplace.json` with
   a `name` and `source: "./plugins/<new-plugin>"`.

Nothing about the existing plugins changes.

---

## The `korvin89:code-review` skill

An **interactive, curation-first workflow**, not a static checklist. It pulls the
diff itself, reads the **full surrounding context** of each changed file (not
just the hunks), reviews in ordered passes, and then walks you through a short
curation loop before anything is posted.

### Ordered passes

1. **Intent** — what the change is trying to do (PR description / linked issue).
2. **Correctness** — logic, edge cases, errors.
3. **Architecture & fit** — alignment with the project's existing patterns.
4. **Tests** — coverage of the change and whether the tests are meaningful.
5. **Readability & naming.**
6. **Minor / nits** — dead last.

It also applies a **frontend layer** where relevant: React (rules of hooks,
effect deps, avoidable re-renders, list keys), TypeScript (`any` leaks, typing
of public APIs), accessibility, and bundle/perf.

### The flow (three stops)

1. **Config (one prompt).** Before reviewing, it asks three things at once:
   - **comment style** — `сухо` (dry, for agents) or `вежливо` (polite, for
     humans — changes are phrased as courteous suggestions);
   - **second pass** — run an independent review in a sub-agent? (see below);
   - **comment language** — Russian / English / other.
2. **Curation.** After the review, it dumps every finding in **Russian**,
   numbered, each with a severity and a confidence. You reply in free text with
   the numbers to keep (and optional per-item additions). It also asks whether
   you want a **summary comment** and can draft one for you.
3. **Confirm or groom.** It renders the final batch the way it would be posted
   (in your chosen language and tone) and asks whether to post or keep grooming.
   Grooming loops back to curation.

`--quick` skips all of that: single pass, dump the findings, stop.

### Severity and confidence (two axes)

Every finding carries **both**:

- **severity** — `blocker` / `should-fix` / `nit` / `question` (kept as these
  exact English terms);
- **confidence** — `high` / `medium` / `low`. A low-confidence, high-severity
  finding is demoted to `question` rather than posted as a shaky blocker.
  Confidence is a working-layer triage signal and is **not** included in posted
  comments.

### Independent second pass (optional)

If you opt in, the skill spawns a sub-agent that reviews the **same** diff,
context, intent/ТЗ, and conventions — but **without** seeing the first pass's
findings, so its opinion is not anchored. The two lists are then merged: issues
found by **both** passes are marked `✓✓ подтверждено обоими проходами` and get
high confidence; issues found by only one pass are kept but flagged as such.

### Working language vs comment language

Two distinct languages, on purpose:

- **Working language = Russian.** The findings dump, the curation questions, and
  everything said to you in the conversation is in Russian — your triage
  surface.
- **Comment language** applies **only** to the comments that get posted to the
  PR, and is chosen in the config step (Russian / English / other). Defaults, in
  order: `--lang <code>` → the `language` field of `.claude/code-review.json` →
  English.

`.claude/code-review.json` format:

```json
{
  "language": "ru"
}
```

Fixed regardless of language: the frontmatter `description` (always English), the
severity labels, and the `🤖 AI generated` marker.

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

### Output format

- All findings are delivered in **one batch**, not incrementally.
- The batch starts with the marker `🤖 **AI generated**`.
- If findings are posted to a PR as separate comments (`--post`), **each
  comment also starts with `🤖 AI generated`** so the marker is never lost when
  the batch is split.
- Posting happens only with `--post`, only in PR mode, and only after you
  confirm the final batch. In working-tree or branch mode the batch is simply
  printed.

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

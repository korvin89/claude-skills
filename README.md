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
severity and a confidence per finding, and optionally runs an independent second
pass in a sub-agent. On a PR the findings go straight into **your GitHub draft
review**: curation happens there, and the review is submitted only by you. The
conversation is in Russian; the language of the findings is chosen at run
time. The style is fixed everywhere — dump, questions, comments: dry,
businesslike, no slang, no praise or grading of the reviewed code.

The workflow itself is in
[SKILL.md](plugins/korvin89/skills/code-review/SKILL.md); the review rules are
in [references/rubric.md](plugins/korvin89/skills/code-review/references/rubric.md).

### Usage

```text
/korvin89:code-review                 # review the working tree if dirty, else the current branch
/korvin89:code-review 1234            # review PR #1234 into your draft review (needs gh and jq)
/korvin89:code-review --quick         # single pass, dump findings, no questions, no draft
/korvin89:code-review --branch        # force branch mode even with a dirty tree
```

| Argument | What it does |
|---|---|
| `[pr-number \| #number \| pr-url]` | Review that PR; findings go into your draft review. Omit it → auto-detect: working tree if dirty, otherwise the current branch against `origin/<default>`. |
| `--quick` | Skip the interactive flow: single pass, dump the findings, stop. |
| `--branch` | Force branch mode even when the working tree is dirty. |

Everything else is asked in one prompt before the review: whether to run the
second pass, the comment language, and any focus areas to scrutinize.

Claude can also trigger the skill on its own when you ask it to "review this
PR" or "review my changes".

### The flow

1. **Config** — one prompt with the three questions above.
2. **Dump** — every finding is listed in the session in Russian, numbered, with
   a severity (🔴 `blocker` / 🟠 `should-fix` / 🔵 `nit` / ❓ `question`) and a
   confidence. Outside a PR the run ends here.
3. **Draft** — on a PR every finding becomes a thread in your pending review,
   opened with `🤖 AI generated`. If you have already started a draft (you can
   review in parallel), the findings join it, and points your own comments
   already make are left out. Findings in files outside the diff are listed in
   the session for your summary.
4. **Loop** — the session watches the draft in the background and edits it on
   your commands until you press **Submit** in GitHub.

### Talking to the agent in the draft

Everything in the draft is under your account, so the agent goes by these
rules:

- a reply in a thread that starts with a 🤖 finding is addressed to the agent;
- anywhere else, a comment starting with `ai:` is addressed to the agent: under
  your own comment («ai: оформи», «ai: короче, на en») or as a new comment on a
  line («ai: тут гонка с refetch?»). `ии:` works too, and so do both typed in
  the other keyboard layout: `фш:`, `bb:`, `фшЖ`;
- every other comment of yours is your review; the agent never edits or deletes
  it on its own.

The agent picks up commands once you have been quiet for about a minute,
handles them in one pass, and removes your commands and its own `🤖💬` replies
when a thread is resolved, so the draft stays ready to submit. A thread where
the agent asked a question stays until you answer. Watching ends by itself when
you submit or discard the draft, or after two hours without commands.

Commands are free text in Russian or English; these are the usual ones. In a
🤖 thread no prefix is needed; elsewhere start with `ai:`.

| Russian | English | What the agent does |
|---|---|---|
| `удали` | `delete` | deletes the 🤖 thread |
| `короче`, `мягче`, `переформулируй: …` | `shorter`, `softer`, `rephrase: …` | rewrites the comment |
| `en` / `ru` | `en` / `ru` | translates the comment |
| `nit`, `should-fix`, `blocker`, `question` | same | changes the severity tag |
| `предложи фикс` | `suggest fix` | adds a GitHub suggestion block |
| `где ещё?` | `where else?` | lists other places with the same problem |
| `артефакты` | `artifacts` | attaches a screenshot page (see `korvin89:review-artifacts`) |
| `почему?` | `why?` | answers in the thread; the thread stays open |
| `ок`, `оставь` | `ok`, `keep` | closes the discussion, keeps the comment |
| `объедини с <ссылка \| path:line>` | `merge with <link \| path:line>` | folds those threads into this one; a file name and a line are enough |
| `ai: оформи` | `ai: write up` | under your own comment: turns your note into a finding (gets the 🤖 marker) |
| `ai: <гипотеза>` | `ai: <hypothesis>` | on a line: checks it; confirmed → becomes a finding, otherwise an answer |

In the session: «синк» / `sync` runs a pass now, «стоп» / `stop` stops
watching; requests across the whole draft («убери все nit» / `drop all nits`)
work there too.

### Per-repo conventions layer (not shipped here)

A repo can add its own rules at

```
<that-repo>/.claude/skills/code-review-conventions/SKILL.md
```

The skill reads it when present and folds it into the review: the generic
rubric is the base, project conventions add to and override it, and on a direct
conflict the project layer wins. A line `comment-language: en` (or `ru`, or any
language name) in that file sets the repo's default comment language.

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

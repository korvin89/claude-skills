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
/korvin89:code-review                 # review your local changes: everything not yet in origin/<default>
/korvin89:code-review 1234            # review PR #1234 into your draft review (needs gh and jq 1.6+)
/korvin89:code-review --quick         # single pass, dump findings, no questions, no draft
```

| Argument | What it does |
|---|---|
| `[pr-number \| #number \| pr-url]` | Review that PR; findings go into your draft review. Omit it → your local changes: the branch's commits since `origin/<default>`, uncommitted changes and untracked files. |
| `--quick` | Skip the interactive flow: single pass, dump the findings, stop. |

On a PR the skill reads the code at the PR's head, not in your checkout: it
fetches the head from the git remote that points at the PR's repository into a
worktree in the review's scratch dir, `.git/code-review/pr-<N>/`. Your checkout
and branch stay as they are; run the skill from a clone of the PR's repository.
Everything else the review needs (the findings batch, artifact screenshots)
goes into the same dir, never into `/tmp`. The dir is removed when the PR run
ends (Submit, a discarded draft, «стоп», the end of `--quick`). It is kept when
watching stops on its own (two idle hours, an auth or network error), so
«синк» can resume, and kept when cleanup's checks find something. Every run
lists the other reviews' dirs; `korvin89:cleanup` removes them.

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
4. **Loop** — once you say «следи» in the session, it watches the draft in the
   background and edits it on your commands until you press **Submit** in
   GitHub. Until then nothing polls GitHub, so the draft can wait for you.

### Talking to the agent in the draft

Everything in the draft is under your account, so the agent goes by these
rules:

- a reply in a thread that starts with a 🤖 finding is addressed to the agent,
  and so is any reply after the agent's own `🤖💬` reply in a thread, until the
  agent closes that discussion;
- anywhere else, a comment starting with `ai:` is addressed to the agent: under
  your own comment («ai: оформи», «ai: короче, на en») or as a new comment on a
  line («ai: тут гонка с refetch?»). `ии:` works too, and so do both typed in
  the other keyboard layout: `фш:`, `bb:`, `фшЖ`;
- every other comment of yours is your review; the agent never edits or deletes
  it on its own.

While it watches, the agent picks up commands once you have been quiet for
about a minute, handles them in one pass, and removes your commands and its
own `🤖💬` replies when a thread is resolved, so the draft stays ready to
submit. A thread where the agent asked a question stays until you answer.
Watching ends by itself when you submit or discard the draft, or after two
hours without commands.

Session commands:

| Russian | English | What it does |
|---|---|---|
| «следи» | `watch` | start reacting to commands in the draft |
| «синк» | `sync` | handle what is in the draft now, once |
| «пауза» | `pause` | stop watching; «следи» resumes |
| «проверь драфт» | `validate draft` | before Submit: find commands not handled yet, open discussions and findings on lines that moved; remove the leftovers on your «да» |
| «стоп» | `stop` | stop watching and clean up |
| «убери все nit», … | `drop all nits`, … | a change across every 🤖 finding |

**Leaving the session in the background.** The skill's own tool grant lasts
only for the turn you start it in. Later `draft.sh` calls may stop at a
permission prompt that nobody sees, and the loop then waits. To avoid that,
allow the script in `~/.claude/settings.json`:

```json
{ "permissions": { "allow": ["Bash(bash *code-review/scripts/draft.sh*)"] } }
```

The wildcards match any command that runs a path ending in
`code-review/scripts/draft.sh`; add the rule only if that is acceptable to you,
otherwise answer the prompts when the session shows them.

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

### Per-repo conventions layer (not shipped here)

A repo can add its own rules at

```
<that-repo>/.claude/skills/code-review-conventions/SKILL.md
```

The skill reads it when present and folds it into the review: the generic
rubric is the base, project conventions add to and override it, and on a direct
conflict the project layer wins. A line `comment-language: en` (or `ru`, or any
language name) in that file sets the repo's default comment language.

## `korvin89:cleanup`

Removes what the review skills keep for one pull request:
`<repo>/.git/code-review/pr-<N>/` — the PR head worktree, the findings batch,
and the screenshots, configs and worktrees of `review-artifacts`. User-invoked
only, and only for the review you name:

```text
/korvin89:cleanup 1234     # the scratch of PR #1234 (also #1234, pr-1234 or the PR URL)
/korvin89:cleanup local    # the scratch of a review without a PR, in this checkout
/korvin89:cleanup          # lists what exists; removes nothing
```

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

`code-review` runs the same script when a PR run ends and keeps the scratch
when a check fails. Nothing is ever removed without a review named: other
reviews' scratch is only listed when a review starts. Published artifact pages
and draft reviews are never touched.

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
with `scripts/build-page.sh` from a `manifest.json`. Its files and worktrees go
into the review's scratch dir (`.git/code-review/<pr-N | local>/artifacts/`),
which `korvin89:cleanup` removes. Requires `jq`; the
Artifact tool needs a claude.ai login (CLI or desktop app).

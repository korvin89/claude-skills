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
ends (Submit, a discarded draft, `stop`, the end of `--quick`). It is kept on `pause`
and when watching stops on its own (two idle hours, an auth or network error),
so `watch` can resume, and kept when cleanup's checks find something. Every run
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
4. **Loop** — once you say `watch` in the session, it watches the draft in the
   background and edits it on your commands until you press **Submit** in
   GitHub; see *Working with the draft*.

### Working with the draft

A typical PR run:

1. `/korvin89:code-review 1234` — answer the config prompt; the findings land
   in your draft review and the session waits.
2. Open the PR's changes in GitHub when you have time, and say `watch` in the
   session: from now on the agent reacts to your commands in the draft.
3. Curate in the draft: delete, rephrase, ask, add your own comments, ask the
   agent to write them up.
4. Say `validate draft` before submitting, so nothing meant for the agent gets
   published.
5. Press **Submit review** in GitHub. A watching session notices, cleans up
   its scratch, and the run ends; if it was not watching, say `stop` there, or
   run `/korvin89:cleanup 1234` later.

Commands go to two places: **in the draft** for one finding or one line, **in
the session** for the watcher and the whole draft. Commands are free
text, in English or Russian; the tables list the usual forms.

#### In the draft: one finding or one line

Everything in the draft is under your account, so the agent goes by these
rules:

- a reply in a thread that starts with a 🤖 finding is addressed to the agent;
- after the agent's own `🤖💬` reply in a thread, your replies there are
  addressed to it too, until that discussion is closed;
- anywhere else, start the comment with `ai:` — under your own comment, or as a
  new comment on a line. `ии:` works too, and so do both typed in the other
  keyboard layout: `фш:`, `bb:`, `фшЖ`;
- every other comment of yours is your review; the agent never edits or deletes
  it on its own.

| Command | What the agent does |
|---|---|
| `delete` | deletes the 🤖 thread |
| `shorter`, `softer`, `rephrase: …` | rewrites the comment |
| `en` / `ru` | translates the comment |
| `nit`, `should-fix`, `blocker`, `question` | changes the severity tag |
| `suggest fix` | adds a GitHub suggestion block for the commented line |
| `where else?` | lists other places with the same problem |
| `artifacts` | attaches a screenshot page (see `korvin89:review-artifacts`) |
| `merge with <link \| path:line>` | folds those threads into this one; a file name and a line are enough |
| `why?` | answers in the thread with `🤖💬` |
| `ok`, `keep` | after the agent's `🤖💬`: closes the discussion, keeps the finding |
| `ai: write up` | under your own comment: turns your note into a finding (gets the 🤖 marker) |
| `ai: <hypothesis>` | on a line: checks it; confirmed → a finding, otherwise an answer in `🤖💬` |

When a thread is done the agent removes your commands and its own `🤖💬`
replies, so only the finding is left. When it answers or asks something, the
thread waits for you: `ok` closes it, anything else continues the discussion.
You never delete service comments by hand.

#### In the session: the watcher and the whole draft

Nothing polls GitHub until you say `watch`, so the draft can wait for you as
long as you like. While watching, the agent handles your draft commands once
you have been quiet for about a minute. Watching ends by itself when you submit
or discard the draft, or after two hours without commands.

| Command | What it does |
|---|---|
| `watch` | start reacting to commands in the draft (handles what is already there first) |
| `sync` | handle what is in the draft now, once, without watching |
| `pause` | stop watching; `watch` resumes |
| `validate draft` | before Submit: find commands not handled yet, open discussions and findings on lines that moved; remove the leftovers once you confirm |
| `stop` | stop watching and clean up the scratch |
| `drop all nits`, `translate all to en` | one change across every 🤖 finding |

#### Leaving the session in the background

The skill's own tool grant lasts only for the turn you start it in. Later
`draft.sh` calls may stop at a permission prompt that nobody sees, and the loop
then waits. To avoid that, allow the script in `~/.claude/settings.json`:

```json
{ "permissions": { "allow": ["Bash(bash *code-review/scripts/draft.sh*)"] } }
```

The wildcards match any command that runs a path ending in
`code-review/scripts/draft.sh`; add the rule only if that is acceptable to you,
otherwise answer the prompts when the session shows them.

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
User-invoked only, and read by `code-review` when you write `artifacts` in a finding's thread:

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

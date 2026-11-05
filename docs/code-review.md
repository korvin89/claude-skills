# korvin89:code-review

[All skills](../README.md)

An interactive, curation-first code review. It collects the diff itself, reads
the full surrounding context of each changed file, reviews in ordered passes
(intent → correctness → architecture → tests → readability → nits) with a
severity and a confidence per finding, and optionally runs an independent second
pass in a sub-agent. On a PR the findings go straight into **your GitHub draft
review**: curation happens there, and the review is submitted only by you.
After the submit it can follow the PR and re-review what changed when the
author asks again. The conversation is in Russian, the skill's fixed messages
are in English, and the language of the findings is chosen at run time. The
style is fixed everywhere — dump, questions, comments: dry, businesslike, no
slang, no praise or grading of the reviewed code.

The workflow itself is in
[SKILL.md](../plugins/korvin89/skills/code-review/SKILL.md); the review rules are
in [references/rubric.md](../plugins/korvin89/skills/code-review/references/rubric.md).

## Usage

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

Everything else is asked in one prompt before the review: whether to run the
second pass, the comment language, and any focus areas to scrutinize. Where
the skill cannot ask (a headless run, Claude agents), it takes the defaults —
no second pass, the default language, no focus areas — and runs the full flow
anyway. Only the `--quick` flag turns on quick mode.

Claude can also trigger the skill on its own when you ask it to "review this
PR" or "review my changes".

## The flow

1. **Config** — one prompt with the three questions above.
2. **Dump** — outside a PR and under `--quick`: every finding is listed in the
   session in Russian, numbered, with a severity (🔴 `blocker` / 🟠
   `should-fix` / 🔵 `nit` / ❓ `question`) and a confidence, and the run ends.
3. **Draft** — on a PR every finding becomes a thread in your pending review,
   opened with `🤖 AI generated`, and the session gets only a link to the PR's
   files and the list of commands. If you have already started a draft (you
   can review in parallel), the findings join it, and points your own comments
   already make are left out. Findings in files outside the diff are listed in
   the session for your summary.
4. **Loop** — once you say `watch` in the session, it watches the draft in the
   background and edits it on your commands until you press **Submit** in
   GitHub; see *Working with the draft*.
5. **Follow** — after the submit the same watcher follows the PR until it is
   merged or closed, and re-reviews it when the author asks you again; see
   *After the submit*.

## Working with the draft

A typical PR run:

1. `/korvin89:code-review 1234` — answer the config prompt; the findings land
   in your draft review and the session waits.
2. Open the PR's changes in GitHub when you have time, and say `watch` in the
   session: from now on the agent reacts to your commands in the draft.
3. Curate in the draft: delete, rephrase, ask, add your own comments, ask the
   agent to write them up.
4. Say `validate draft` before submitting, so nothing meant for the agent gets
   published.
5. Press **Submit review** in GitHub. A watching session notices and goes on
   following the PR (*After the submit*); when you are done with the PR, say
   `stop`, or run [`/korvin89:cleanup 1234`](cleanup.md) later.

Commands go to two places: **in the draft** for one finding or one line, **in
the session** for the watcher and the whole draft. Commands are free
text, in English or Russian; the tables list the usual forms.

### In the draft: one finding or one line

Everything in the draft is under your account, so the agent goes by these
rules:

- a reply in a thread that starts with a 🤖 finding is addressed to the agent;
- after the agent's own `🤖💬` reply in a thread, your replies there are
  addressed to it too, until that discussion is closed;
- anywhere else, start the comment with `ai:` — under your own comment, or as a
  new comment on a line. `ии:` works too, and so do both typed in the other
  keyboard layout: `фш:`, `bb:`, `фшЖ`;
- in a thread you have already submitted, only `ai:` comments are commands: a
  plain reply there is your answer to the author;
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
| `artifacts` | attaches a screenshot page (see [`korvin89:review-artifacts`](review-artifacts.md)) |
| `merge with <link \| path:line>` | folds those threads into this one; a file name and a line are enough |
| `why?` | answers in the thread with `🤖💬` |
| `ok`, `keep` | after the agent's `🤖💬`: closes the discussion, keeps the finding |
| `ai: write up` | under your own comment: turns your note into a finding (gets the 🤖 marker) |
| `ai: <hypothesis>` | on a line: checks it; confirmed → a finding, otherwise an answer in `🤖💬` |

When a thread is done the agent removes your commands and its own `🤖💬`
replies, so only the finding is left. When it answers or asks something, the
thread waits for you: `ok` closes it, anything else continues the discussion.
You never delete service comments by hand.

### In the session: the watcher and the whole draft

Nothing polls GitHub until you say `watch`, so the draft can wait for you as
long as you like. While watching, the agent handles your draft commands once
you have been quiet for about a minute. Watching ends by itself when the PR is
merged or closed, or your first draft is discarded; there is no idle timeout.

| Command | What it does |
|---|---|
| `watch` | start reacting to commands in the draft (handles what is already there first), then follow the PR |
| `sync` | handle what is in the draft now, once, without watching |
| `pause` | stop watching; `watch` resumes |
| `validate draft` | before Submit: find commands not handled yet, open discussions and findings on lines that moved; remove the leftovers once you confirm |
| `re-review` | review what changed since your last review (*After the submit*) |
| `help` | print the command list again |
| `stop` | stop watching and clean up the scratch |
| `drop all nits`, `translate all to en` | one change across every 🤖 finding |

If the author pushes while you are still curating, the agent moves the review
to the new code and deletes the 🤖 comments the push fixed, if you have not
touched them; the new code itself waits for the re-review.

### After the submit

The watcher goes on following the PR; polls slow down to once in five minutes
while there is no draft. It reports in the session, one line each:

- new commits on the PR;
- new replies by others in your open threads;
- the PR merged or closed: the run ends and the scratch is removed.

Discarding a draft after you have reviewed once keeps the PR followed;
discarding the first draft ends the run.

When the author asks for your review again — or you say `re-review`, or run
`/korvin89:code-review 1234` once more — the agent re-reviews: what changed
after your last review (a bare reply in a thread does not count), plus your
open threads. The result is a new draft:

- findings on the new code, as usual;
- in a thread the author fixed, or argued convincingly about: a `🤖💬` note
  for you; resolve the thread, and `validate draft` removes the note before
  Submit once you confirm;
- in a thread that is still not fixed: a 🤖 reply to the author, which goes
  out with your review. You curate it with the same commands, written with
  `ai:`.

### Leaving the session in the background

The skill's own tool grant lasts only for the turn you start it in. Later
calls — `draft.sh` for the draft, `collect-diff.sh` after a push and for a
re-review, `cleanup.sh` once the PR is merged — may stop at a permission
prompt that nobody sees, and the loop then waits. To avoid that, allow the
scripts in `~/.claude/settings.json`:

```json
{ "permissions": { "allow": [
  "Bash(bash *code-review/scripts/draft.sh*)",
  "Bash(bash *code-review/scripts/collect-diff.sh*)",
  "Bash(bash *cleanup/scripts/cleanup.sh*)"
] } }
```

The wildcards match any command that runs a path ending in those script
paths; add the rules only if that is acceptable to you, otherwise answer the
prompts when the session shows them.

## Where the files go

Everything a PR review needs (the head worktree, the findings batch, artifact
screenshots) goes into its scratch dir, `.git/code-review/pr-<N>/`, never into
`/tmp`. The dir is removed when the PR run ends (the PR is merged or closed,
your first draft is discarded, `stop`, the end of `--quick`). It is kept after
Submit, since the PR is still followed, on `pause`, and when watching stops on
an auth or network error, so `watch` can resume; and kept when cleanup's
checks find something. Every run lists the other reviews'
dirs; `korvin89:cleanup` removes them.

## Per-repo conventions layer (not shipped here)

A repo can add its own rules at

```
<that-repo>/.claude/skills/code-review-conventions/SKILL.md
```

The skill reads it when present and folds it into the review: the generic
rubric is the base, project conventions add to and override it, and on a direct
conflict the project layer wins. A line `comment-language: en` (or `ru`, or any
language name) in that file sets the repo's default comment language.

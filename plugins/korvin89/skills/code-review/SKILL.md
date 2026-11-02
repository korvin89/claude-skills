---
name: code-review
description: >-
  Curation-first code review of a pull request or of local changes: collects
  the diff, reads full file context, reviews in ordered
  passes with severity and confidence, optionally adds an independent second
  pass. On a PR the findings go into the reviewer's GitHub draft review, where
  the reviewer curates them with `ai:` comments and submits it themselves. Use
  when asked to review a PR, review changes or a diff, or check code before
  merge.
argument-hint: "[pr-number | pr-url] [--quick]"
allowed-tools: Read, Grep, Glob, Bash, Agent, AskUserQuestion, Artifact
---

# Code review

You run a **workflow**: collect the diff, build real context around it, review
it against the rubric. On a PR the findings then go into the reviewer's draft
review on GitHub, and you keep editing that draft on the reviewer's `ai:`
comments until they submit it. Every finding is located (`file:line`) and
concrete.

Files bundled with this plugin:

- `${CLAUDE_SKILL_DIR}/references/rubric.md` — passes, frontend layer,
  severity + confidence, the finding format. Read before pass 1.
- `${CLAUDE_SKILL_DIR}/scripts/collect-diff.sh` — collects the diff (Step 1).
- `${CLAUDE_SKILL_DIR}/scripts/draft.sh` — reads and edits the reviewer's draft
  review (Steps 3, 7, 8). Its header documents the subcommands, the comment
  kinds and the guards.
- `${CLAUDE_PLUGIN_ROOT}/skills/cleanup/scripts/cleanup.sh` — removes the
  review's scratch at the end (*Cleanup*).
- `${CLAUDE_PLUGIN_ROOT}/skills/review-artifacts/SKILL.md` — screenshot pairs
  and configs on an artifact page, for a thread that asks for artifacts
  (Step 8). Read only then.

`<pr>` below is the PR URL from `### TARGET:` — always the URL, never a bare
number, which would resolve against whatever repository the current directory
is in. `<scratch>` is the `### SCRATCH:` dir, `<head-sha>` the commit in
`### WORKTREE:`. `ai:` below stands for any
command prefix `draft.sh` accepts: `ai:`, `ии:`, and both typed in the other
keyboard layout (`фш:`, `bb:`, `фшЖ`, `bb^`); `draft.sh state` marks all of
them `cmd`.

## Invariants

- **Working language is Russian.** Everything said to the reviewer — in the
  conversation and in your `🤖💬` replies in the draft — is Russian.
- **Comment language** is the language of the findings in the draft only.
  Resolved in Step 2.
- **Style, everywhere** — the dump, the questions, the findings, the replies:
  dry and businesslike, no slang, only the matter at hand. The code under review
  is neither praised nor graded; a finding states the problem, why it matters,
  and the fix.
- **Severity tags** are `🔴 blocker` · `🟠 should-fix` · `🔵 nit` · `❓ question`:
  emoji, then the English term, unchanged in the dump and in the draft,
  whatever the comment language.
- **Draft only.** You write into the reviewer's pending review and never submit
  it; the reviewer submits in GitHub and writes the summary there. A draft they
  already started is joined, not replaced. Submitted comments are never touched.
- **Markers.** `🤖 **AI generated**` opens every finding in the draft
  (`draft.sh add` prepends it when missing; write it anyway). `🤖💬` opens every
  reply you write in a thread; replies are temporary and go once the thread is
  resolved.
- **The reviewer's own comments** (`own` in `draft.sh state`) are their review:
  you never delete one and rewrite one only on an `ai:` command in its thread.

## Arguments (`$ARGUMENTS`)

| Argument | Effect |
|---|---|
| `<number>` / `#<number>` / `<pr-url>` | PR mode (needs `gh`): findings go into the reviewer's draft (Steps 7–8). Omitted → local mode: everything not yet in `origin/<default>` — the branch's commits, uncommitted changes and untracked files. |
| `--quick` | Single pass, dump the findings, stop: no prompts, no second pass, no draft. |

When you cannot ask the reviewer (headless run), say so in one Russian line and
behave as `--quick`.

## Step 1 — Collect

The invocation's arguments are `$ARGUMENTS`. Pass each of them to the
collector in single quotes — an unquoted `#123` would start a shell comment and
silently turn the run into a local review:

```
bash "${CLAUDE_SKILL_DIR}/scripts/collect-diff.sh" '<argument>' …
```

The script skips the skill's own flags, detects the mode (`### MODE:` header)
and, in PR mode, prints the title, body, and every comment already on the PR.
Its exit codes:

- `3` — `gh` is missing. Stop the workflow and tell the reviewer exactly this,
  nothing more:
  > GitHub CLI (`gh`) is required to review a pull request but was not found.
  > Install it: https://cli.github.com/
- `1` / `2` / `4` / `5` — `gh` failed (no such PR, not logged in) / not a git
  repository / bad argument, or the PR's scratch belongs to another PR /
  nothing to review. Relay the script's message in Russian and stop.

`### SCRATCH:` is the one place for this review's files — the batch, artifact
pages' screenshots and worktrees; write nothing for the review to `/tmp`. In PR
mode, `### WORKTREE:` is a checkout of the PR head made for this review.
For the whole run — passes, second pass, draft loop — read and grep the PR's
files there, never in the current checkout: it may be on another branch.

`### NOTE:` lines: the head could not be checked out → review from the diff
alone and say so in one Russian line; `head/` was kept because it has local
changes → its files may be older than the PR, say so; the scratch of other
reviews → mention it once, in Step 2's message.

## Step 2 — Configuration (one prompt)

Skip under `--quick` (no second pass, no focus areas).

Show the reviewer, in Russian, the mode and target, the changed files (count and
the notable ones), the PR title or branch name, and the other reviews' scratch
if a note named it. Then ask **three questions
in a single `AskUserQuestion` call**:

1. **Второй проход** — `да` / `нет`, default `нет` (Step 5).
2. **Язык комментариев** — `Русский` / `English` / other via the free-text
   field. Default: the `comment-language:` line of the conventions layer
   (Step 3), else English. Pre-select it.
3. **На что смотреть особенно** — `Нет` (default), `Корректность`, `Тесты`, or
   the reviewer types their own focus in the free-text field (a file, a module,
   a risk: «таймзоны в billing»). Whatever they type is the focus areas.

Restate the resolved values in one Russian line and continue.

## Step 3 — Context

A hunk is not enough to judge a change.

- **Read every changed file in full** (`Read`; in PR mode under
  `### WORKTREE:`), and every path under
  `### UNTRACKED FILES`. Apply the noise rules from the rubric.
- **Follow the change outward:** `Grep` / `Glob` for callers of changed
  functions, the types involved, sibling modules, existing tests.
- **Write the intent statement** — two or three sentences on what the change is
  for, from `### PR TITLE` / `### PR BODY` in PR mode, or from the branch name
  and `git log` locally. It anchors pass 1 and briefs the second pass.
- **`### EXISTING COMMENTS`** is what is already raised on the PR. A point made
  there is not a new finding; mention it only when you add something to it.
- **The reviewer's draft** (PR mode). The reviewer may be reviewing in
  parallel, and their draft comments are context too:
  ```
  bash "${CLAUDE_SKILL_DIR}/scripts/draft.sh" state <pr>
  ```
  A point one of their `own` comments already makes is not a new finding. When
  `state` has a `warning` (more than 100 threads), relay it in one line:
  commands in older threads will not be seen.
- **Project conventions layer.** A repo may add its own rules at
  `.claude/skills/code-review-conventions/SKILL.md`; the rubric is the base,
  the layer adds to and overrides it, and wins on any direct conflict. A
  `comment-language: <value>` line in it sets the repo's default for Step 2.
  ```!
  cat .claude/skills/code-review-conventions/SKILL.md 2>/dev/null || echo "(no project conventions layer)"
  ```

## Step 4 — Pass 1

Read `${CLAUDE_SKILL_DIR}/references/rubric.md` and work its passes in order
over the context from Step 3, focus areas at elevated priority. Hold the
findings until Step 6.

## Step 5 — Second pass (only if chosen in Step 2)

An independent opinion, unanchored by pass 1. Spawn one sub-agent with the
`Agent` tool. Its brief contains:

- the absolute paths of `rubric.md` and of the conventions layer (if any) — it
  reads them itself;
- what to read: in PR mode the worktree path and `gh pr diff <pr>` for the
  diff — it must not run the collector, which would move the worktree under
  you; in local mode the exact collector command from Step 1. Either way it
  reads the changed files in full;
- the intent statement and the focus areas (as elevated priorities to
  scrutinize, not as findings to confirm);
- the return format: the rubric's finding format, numbered, in Russian.

The brief carries none of pass 1's findings — an uncontaminated look is the
whole point.

**Merge** the two lists into one:

- **Corroborated** (same file, ~same line, same root cause): keep one entry,
  confidence `high`, append `✓✓ подтверждено обоими проходами`.
- **Singletons**: keep, mark «только проход 1» / «только проход 2», and judge on
  the merits — a singleton is a signal, not a verdict.

## Step 6 — Dump (Russian)

Present **all** findings in one batch, numbered from 1, in the rubric's finding
format and order. Open with `🤖 **AI generated**`.

Style per the invariants: each finding states what is wrong, why it matters,
and the fix. Uncertainty is expressed through `question` and the confidence
axis, not through softened wording. When a real review found nothing worth
raising, say so in one line.

Under `--quick`, or outside PR mode, stop here (a `--quick` PR run removes its
worktree first — see *Cleanup*).

## Step 7 — Into the draft (PR mode)

No approval step: the draft is visible only to the reviewer until they submit
it, and curation happens there.

1. **Re-read the draft** (`draft.sh state <pr>`): the reviewer may have added
   comments while you reviewed, and an earlier run may have left findings
   there. Leave out a finding that an `own` comment or an `ai` finding already
   makes (same place, same point) and name its number in the report.
2. **Render** each remaining finding in the comment language, style per the
   invariants: marker, severity tag, problem, why, fix; confidence and `✓✓`
   removed. One finding is one thread.
3. **Add** them in one call:

   ```json
   { "comments": [ { "path": "src/x.ts", "line": 42, "body": "🤖 **AI generated**\n\n🔴 **blocker** — …" } ] }
   ```

   ```
   bash "${CLAUDE_SKILL_DIR}/scripts/draft.sh" add <pr> <scratch>/batch.json --head <head-sha>
   ```

   `line` is the new-side line. A line outside the diff becomes a file-level
   thread; a finding in a file outside the diff is skipped — give such findings
   to the reviewer in full, for the summary they write at submit. Leave out
   `--head` only when there is no `### WORKTREE:`. Exit codes:
   - `8` — the PR head moved since Step 1 and nothing was added. Tell the
     reviewer, run Step 1 again (the worktree moves to the new head), check
     every finding's line and text against the new code, then add.
   - `1` after some `added` lines — part of the batch went in. Run `state` and
     add only the findings that are not there; never re-run the whole batch.
   - `5` — nothing to add.
4. **Report** in Russian: a new draft or the reviewer's existing one, what went
   in, what was left out and why, the link from the script's last line. Keep
   the review id from that line, `(review …)`, for the watcher. On the first
   run in a session, add the protocol:

   > Находки в твоём драфте, Submit — за тобой. Мне можно писать прямо там:
   > ответ в 🤖-треде или комментарий, начинающийся с `ai:` или `ии:` (на любой
   > строке или под своим комментарием; `фш:` и `bb:` в другой раскладке тоже
   > пойму). Подхвачу, когда ты на минуту затихнешь, и сам уберу служебные
   > реплики. Команды — по-русски или по-английски. Твои комментарии без
   > префикса не трогаю.

Go on to Step 8 even when no finding went in: the reviewer can still call you
with `ai:` from their own comments.

## Step 8 — Draft loop

**Arm the watcher** with the Bash tool and `run_in_background: true`:

```
bash "${CLAUDE_SKILL_DIR}/scripts/draft.sh" watch <pr> --review <review-id>
```

`<review-id>` is the draft's id: the `(review …)` of the `add` line, or the
`review` of the latest `state`; omit `--review` when there is no draft yet. It
lets the watcher report a submit that happened while no watcher ran.

It polls the draft and exits with one line; you are woken then. Do not check
on it in between — no reading its output, no extra `state` calls: the polling
is its job. One watcher per PR: arm the next one only after the previous one
has exited. The reviewer may write in the session meanwhile; answer as usual,
the watcher keeps running.

| Watcher line | Then |
|---|---|
| `ACTIONABLE <n>` | run a pass (below), then arm the watcher again |
| `SUBMITTED <url>` | one Russian line with the link; clean up; the loop ends |
| `DISCARDED` | one line: the draft was discarded; clean up; the loop ends |
| `AUTH …` | one line: `gh` is not logged in, `gh auth login` then «синк»; the loop ends |
| `IDLE` | one line: two hours without commands, «синк» resumes; the loop ends |
| `ERROR …` | relay it in one line, «синк» resumes; the loop ends |
| exit with no line | a usage error: relay its stderr in one line; the loop ends |

**A pass.** Run `draft.sh state <pr>`. When its `review` is null the draft is
gone: `latest` (state not `PENDING`) means it was submitted, its `url` is the
review — handle the pass as `SUBMITTED`, otherwise as `DISCARDED`. Else take
every thread with `actionable: true`. For each:

1. **Read** the `cmd` comments after your last `🤖💬` reply, and the target:
   the thread's root — an `ai` finding or the reviewer's `own` comment — or,
   when the root itself is a `cmd`, the line the thread sits on. Take the
   target's body from this state: if the reviewer edited it in GitHub, their
   edit is the base.
2. **Do** what is asked (table below). Commands are free text; interpret them.
   Rewritten text follows the invariants and the comment language unless the
   command names another language. `draft.sh edit` replaces the whole body:
   keep the marker and the tag. A guard refusal (exit 7) means the request
   touches what you may not; say so in a reply instead.
3. **Close** the thread one of two ways:
   - done → delete the `cmd` comments you read and your `🤖💬` replies in this
     thread (`draft.sh delete <pr> <ids…>`), so only the target remains — a
     `cmd` root you have just rewritten into a finding is the target and
     stays;
   - you need an answer, or you are answering a question → reply
     (`draft.sh reply <pr> <thread-id>`, body on stdin) and leave the thread
     open.

   No thread ends a pass still actionable — the watcher would wake you again
   for nothing. A `cmd` that arrived after your `state` call waits for the
   next pass.

Then one Russian line per thread in the session (`path:line` — what was done),
and arm the watcher again — unless one is still running, as after a «синк»
pass.

Commands come in Russian or English, as free text; the table gives both forms.
The language of a command does not change the comment language.

| In the thread (RU · EN) | You do |
|---|---|
| `удали` · `delete` | delete the whole thread (`ai` root only; the reviewer deletes their own comments in GitHub) |
| `короче`, `мягче`, `переформулируй: …`, `en` · `shorter`, `softer`, `rephrase: …`, `ru` | rewrite the target in place |
| `nit` · `should-fix` · `blocker` · `question` (same in both) | change the tag; rewrite the text when the tag changes what it says |
| `предложи фикс` · `suggest fix` | append a `suggestion` block that replaces exactly the commented line; a wider fix goes into a plain code block |
| `где ещё?` · `where else?` | find the same problem elsewhere in the diff and add those `path:line` to the finding |
| `артефакты` · `artifacts` | follow `review-artifacts` with the finding as the subject and `<scratch>` as its scratch dir; append its `Артефакты: <link>` line |
| `почему?` · `why?`, any question | answer with a reply; the thread stays open |
| `ок`, `оставь` · `ok`, `keep` after your reply | delete the `cmd` comments and your replies; the target stays as it is |
| `объедини с <link \| path:line>` · `merge with <link \| path:line>`, one or more | merge the referenced threads into this one, which stays (see below) |
| `ai: оформи` · `ai: write up` under the reviewer's own comment | rewrite their note into a finding — tag, problem, why, fix — keeping their point; add the marker, since the wording is now yours |
| `ai: <hypothesis>` as a new comment on a line, either language | check it against the code. Confirmed → rewrite this comment into a finding (it becomes the thread's `ai` root). Not confirmed → reply why; on «ок» / `ok` delete the thread |

**Merging.** Find each referenced thread in the state. A link carries a
comment's `db_id` after `#discussion_r` or `#r`; `path:line` matches a thread's
`path` — a file name is enough when unique — and `line`. Rewrite this thread's
target into one finding that covers every place: the others' `path:line` in
the text, the highest severity among the merged. A rewritten `own` target gets
the marker, as with `оформи` / `write up`. Then delete each merged thread whose root is
`ai`, with all its comments. Any other merged thread stays — the reviewer's
own comment is theirs to delete: fold its point in and name it in the session.
A reference that matches nothing, or more than one thread, gets a reply asking
which.

**In the session** the reviewer can also say: «синк» · `sync` — run a pass
now (a running watcher keeps running; with none running, arm one after the
pass); a request across the whole draft («убери все nit» · `drop all nits`,
«переведи всё на en» · `translate all to en`) — apply it to every `ai` finding
and report; «стоп» · `stop` — stop the watcher (the task-stop tool on its
background task, or `kill "$(cat <scratch>/watch.pid)"`), clean up, and end
the loop.

**Cleanup.** When a PR run ends for good — `SUBMITTED`, `DISCARDED`, «стоп», or
the end of a `--quick` run — remove its scratch:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/cleanup/scripts/cleanup.sh" '<pr>'
```

Exit 10 means its checks found something (uncommitted work in a worktree, a
scratch that may be another PR's, a watcher still running) and nothing was
removed: relay the warnings in one Russian line and suggest
`/korvin89:cleanup <pr>`. Never confirm on the reviewer's behalf: no
`--yes=…` from this skill. After `IDLE`, `AUTH` or
`ERROR` keep the scratch: «синк» resumes the loop.

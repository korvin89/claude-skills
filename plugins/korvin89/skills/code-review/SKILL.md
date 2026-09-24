---
name: code-review
description: >-
  Curation-first code review of a pull request, the current branch, or the
  working tree: collects the diff, reads full file context, reviews in ordered
  passes with severity and confidence, optionally adds an independent second
  pass, then lets the reviewer pick which findings get posted. Use when asked
  to review a PR, review changes or a diff, or check code before merge.
argument-hint: "[pr-number | pr-url] [--post] [--quick] [--branch]"
allowed-tools: Read, Grep, Glob, Bash, Agent, AskUserQuestion, Artifact
---

# Code review

You run a **workflow**: collect the diff, build real context around it, review
it against the rubric, then walk the reviewer through a short curation loop
before anything is posted. Every finding is located (`file:line`) and concrete.

Files bundled with this plugin:

- `${CLAUDE_SKILL_DIR}/references/rubric.md` — passes, frontend layer,
  severity + confidence, the finding format. Read before pass 1.
- `${CLAUDE_SKILL_DIR}/references/legend.md` — the top-level review comment.
- `${CLAUDE_SKILL_DIR}/scripts/collect-diff.sh` — collects the diff (Step 1).
- `${CLAUDE_SKILL_DIR}/scripts/post-review.sh` — posts the batch (Step 9).
- `${CLAUDE_PLUGIN_ROOT}/skills/herdr-tab-rename/scripts/rename.sh` — names the
  Herdr tab (Step 1); a no-op outside Herdr.
- `${CLAUDE_PLUGIN_ROOT}/skills/review-artifacts/SKILL.md` — screenshot pairs
  and configs on an artifact page for a finding marked `+артефакты` (Step 7).
  Read only then.

## Invariants

- **Working language is Russian.** Everything said to the reviewer in the
  conversation — dump, questions, confirmations — is Russian.
- **Comment language** is the language of the *posted* text only. Resolved at
  Stop 1.
- **Style, everywhere** — the dump, the questions, the posted comments: dry and
  businesslike, no slang, only the matter at hand. The code under review is
  neither praised nor graded; a finding states the problem, why it matters, and
  the fix.
- **Severity tags** are `🔴 blocker` · `🟠 should-fix` · `🔵 nit` · `❓ question`:
  emoji, then the English term, unchanged in the dump, the legend, and posted
  comments, whatever the comment language.
- **`🤖 **AI generated**`** opens every posted text: each inline comment and the
  review body. `post-review.sh` prepends it when missing; write it anyway.
- **Posting** happens only with `--post`, only in PR mode, only after the
  reviewer confirms the final batch at Stop 3. Otherwise the batch is printed.

## Arguments (`$ARGUMENTS`)

| Argument | Effect |
|---|---|
| `<number>` / `#<number>` / `<pr-url>` | PR mode (needs `gh`). Omitted → working tree if dirty, else current branch. |
| `--post` | Post the confirmed batch to the PR (Step 9). Ignored under `--quick`. |
| `--quick` | Single pass, dump the findings, stop: no prompts, no second pass, no posting. |
| `--branch` | Force branch mode even when the working tree is dirty. |

When you cannot ask the reviewer (headless run), say so in one Russian line and
behave as `--quick`.

## Step 1 — Collect

```
bash "${CLAUDE_SKILL_DIR}/scripts/collect-diff.sh" $ARGUMENTS
```

Pass `$ARGUMENTS` through verbatim: the script skips the skill's own flags,
detects the mode (`### MODE:` header) and, in PR mode, prints the title, body,
and every comment already on the PR. Its exit codes:

- `3` — `gh` is missing. Stop the workflow and tell the reviewer exactly this,
  nothing more:
  > GitHub CLI (`gh`) is required to review a pull request but was not found.
  > Install it: https://cli.github.com/
- `4` / `5` — bad argument / nothing to review. Relay the script's message in
  Russian and stop.

In PR mode also name the Herdr tab after the PR. Outside Herdr the script is a
no-op; on failure relay its message in one line and continue:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/herdr-tab-rename/scripts/rename.sh" "pr-<pr-id>"
```

## Step 2 — Stop 1: configuration (one prompt)

Skip under `--quick` (no second pass, no focus areas).

Show the reviewer, in Russian, the mode and target, the changed files (count and
the notable ones), and the PR title or branch name. Then ask **three questions
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

- **Read every changed file in full** (`Read`), and every path under
  `### UNTRACKED FILES`. Apply the noise rules from the rubric.
- **Follow the change outward:** `Grep` / `Glob` for callers of changed
  functions, the types involved, sibling modules, existing tests.
- **Write the intent statement** — two or three sentences on what the change is
  for, from `### PR TITLE` / `### PR BODY` in PR mode, or from the branch name
  and `git log` locally. It anchors pass 1 and briefs the second pass.
- **`### EXISTING COMMENTS`** is what is already raised on the PR. A point made
  there is not a new finding; mention it only when you add something to it.
- **Project conventions layer.** A repo may add its own rules at
  `.claude/skills/code-review-conventions/SKILL.md`; the rubric is the base,
  the layer adds to and overrides it, and wins on any direct conflict. A
  `comment-language: <value>` line in it sets the repo's default for Stop 1.
  ```!
  cat .claude/skills/code-review-conventions/SKILL.md 2>/dev/null || echo "(no project conventions layer)"
  ```

## Step 4 — Pass 1

Read `${CLAUDE_SKILL_DIR}/references/rubric.md` and work its passes in order
over the context from Step 3, focus areas at elevated priority. Hold the
findings until Step 6.

## Step 5 — Second pass (only if chosen at Stop 1)

An independent opinion, unanchored by pass 1. Spawn one sub-agent with the
`Agent` tool. Its brief contains:

- the absolute paths of `rubric.md` and of the conventions layer (if any) — it
  reads them itself;
- the exact collector command from Step 1 — it runs it itself and reads the
  changed files in full;
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

Under `--quick`, stop here.

## Step 7 — Stop 2: curation

Ask in Russian for a free-text reply, for example:

> Ответь, какие пункты идут в финальный батч: номера через запятую (или «все»).
> К любому пункту можешь добавить детали — например «4: добавь, что это ломает и
> мобилку». «4: +артефакты» — соберу скриншоты main/PR и конфиги на отдельную
> страницу и подошью ссылку. Что не выбрано — не постим. Легенду (дисклеймер +
> теги) добавляем? По умолчанию да.

Keep only the selected numbers and apply any per-item edits. The legend
(`references/legend.md`) is included unless declined. Wait for the answer.

**Artifacts.** For every finding marked `+артефакты`, read
`${CLAUDE_PLUGIN_ROOT}/skills/review-artifacts/SKILL.md` and follow it with
that finding as the subject; append its final line (`Артефакты: <link>`, in the
comment language) to the finding. Do this before Stop 3 so the links are part
of the final batch.

## Step 8 — Stop 3: final batch

Render the batch exactly as it would be posted:

- prose in the comment language, style per the invariants;
- severity tags per the invariants; confidence and `✓✓` removed;
- each item and the legend opened with `🤖 **AI generated**`;
- the legend per `legend.md`, unless declined at Stop 2.

Then ask in Russian: всё ок и постим — или ещё почитать и погрумить? Grooming
loops back to Step 7. Proceed only on confirmation.

## Step 9 — Post (`--post`, PR mode, confirmed)

Write the batch to a JSON file and post it as **one PR review**:

```json
{
  "body": "<legend, or empty when declined>",
  "unattached_heading": "<heading for findings that are not on a diff line, in the comment language>",
  "comments": [
    { "path": "src/x.ts", "line": 42, "body": "🤖 **AI generated**\n\n🔴 **blocker** — …" }
  ]
}
```

```
bash "${CLAUDE_SKILL_DIR}/scripts/post-review.sh" <pr-ref> /tmp/review-batch.json
```

`line` is the new-side line. Findings on lines outside the diff are moved by
the script into the review body with their `path:line`. Report the script's
output (review URL, counts) to the reviewer in Russian.

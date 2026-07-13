---
name: code-review
description: >-
  Interactive, curation-first code review. Pulls the diff itself (auto-detecting
  PR vs local branch vs working tree), reads the full surrounding context of each
  changed file rather than just the hunks, and reviews in ordered passes —
  intent, correctness, architecture/fit, tests, readability, then minor nits
  last. Each finding carries a severity and a confidence. Optionally runs an
  independent second pass in a sub-agent (no access to the first pass's findings)
  and merges the two. You then curate which findings get posted. The working
  conversation is in Russian; the posted comment language and tone are chosen at
  runtime. Includes React / TypeScript / a11y / bundle-perf checks. Use when
  asked to review a PR, review changes, review a diff, do a code review, or check
  code before merge.
argument-hint: "[pr-number | pr-url] [--post] [--quick] [--lang <code>]"
allowed-tools: Read, Grep, Glob, Bash, Task, AskUserQuestion
---

# Code review

You are running a **workflow**, not reciting a checklist. You fetch the diff,
build real context around it, review it, and then walk the reviewer through a
short curation loop before anything is posted. Default to skepticism: only call
something out when you can name the file, the line, the concrete problem, and
(where useful) the fix.

## Working language vs comment language — read this first

There are **two** languages in this workflow, and they are not the same:

- **Working language = Russian.** Everything you say to the reviewer in the
  conversation — the findings dump, the curation questions, the synthesis, every
  clarification — is written in **Russian**. The reviewer here is a Russian
  speaker; this is their triage surface, not the artifact.
- **Comment language** — the language of the comments that get **posted** to the
  PR. It is chosen at runtime (Step 1) and may be Russian, English, or anything
  else. It applies **only** to the final, posted comment text.

What stays fixed regardless of either language:

- the frontmatter `description` (always English),
- the severity labels with their fixed emoji — 🔴 `blocker` / 🟠 `should-fix` /
  🔵 `nit` / ❓ `question` — kept as these exact English terms, in the dump and in
  posted comments alike,
- the `🤖 AI generated` marker on **every** posted comment — each inline finding
  and the single top-level legend comment (Step 8). The emoji and the English
  marker text stay fixed in every comment language.

Arguments you may receive in `$ARGUMENTS`:

- A **PR number or URL** → review that pull request (requires `gh`, see Step 3).
- `--post` (or `--comment`) → after the reviewer finalizes the batch, post the
  curated findings to the PR. Without this flag, **never** post anything.
- `--quick` → skip the interactive flow entirely: single pass, no second-pass
  sub-agent, no curation. Just dump all findings in Russian (Step 7) and stop.
- `--lang <code>` → pre-fill the comment-language default for Step 1 (e.g.
  `--lang ru`, `--lang en`, `--lang "Brazilian Portuguese"`).

---

## Session title (PR mode) — do this first

Claude Code has **no** programmatic session-rename API today (it is only a manual
`/rename` command; tracked upstream), so you cannot set the title yourself. When
you are reviewing a PR and know its number, emit exactly one Russian line inviting
the reviewer to rename the session, then continue **without waiting** on it:

> Для порядка переименуй сессию: `/rename Review #<pr-id>`

Substitute the real PR id. Skip this entirely in working-tree and branch mode
(there is no PR id) and never block the workflow on it.

---

## Step 1 — Stop 1: resolve the run configuration (one prompt)

Ask the reviewer **four things in a single `AskUserQuestion` call** (do not
split them into separate stops) — three configuration questions plus a focus
prompt. Batch them:

1. **Comment style** — how the *posted* comments should read:
   - `сухо` (dry) — terse, imperative, for an agent/automation audience.
   - `вежливо` (polite) — for humans: soften phrasing, frame changes as
     suggestions/requests ("Предлагаю…", "Было бы здорово…", "Может, стоит…"),
     keep it courteous. This tone applies to the final posted comments **only** —
     the Russian dump stays neutral either way.
2. **Second pass** — run an independent second review in a sub-agent? (`да` /
   `нет`). Default `нет`. See Step 6.
3. **Comment language** — `Русский` / `English` / `Другое` (free-text). Resolve
   the **default** for this question first, first match wins:
   1. `--lang <code>` in `$ARGUMENTS`.
   2. the `language` field of `.claude/code-review.json` in the repo:
      ```!
      cat .claude/code-review.json 2>/dev/null || echo "(no .claude/code-review.json)"
      ```
   3. English.
   Present that resolved value as the pre-selected default.
4. **Focus areas** — anything to pay special attention to in this review? A
   single-select **yes/no**, where "yes" is a free-text input:
   - `Нет` — nothing in particular; pre-select it as the default.
   - `Да` — the reviewer types **into the free-text field** exactly what to watch
     for (a file, a module, a risk — e.g. «таймзоны в billing», «не сломались ли
     ретраи»).
   The "yes" input is the built-in free-text / **Other** field: any text they
   enter **is** the focus areas. `Нет` (or empty) means none. If they pick `Да`
   but leave the field empty, ask once, in Russian, what exactly to watch. Carry
   whatever they type into Step 5 as elevated-priority areas.

**`--quick` bypass:** if `--quick` was passed, skip this prompt. Use style `сухо`,
no second pass, no special focus areas, and the comment language resolved by the
default chain above.

**Non-interactive bypass:** if you genuinely cannot ask (headless run), fall back
to the same defaults and say so in one Russian line.

State the resolved values (style, second pass, comment language, focus areas)
back to yourself before continuing.

---

## Step 2 — Get the diff (auto-detected source)

Run the bundled collector. It auto-detects the source and prints a header
(`### MODE: …`), the changed-file list, and the unified diff:

```
bash "${CLAUDE_SKILL_DIR}/scripts/collect-diff.sh" <pr-ref-if-any>
```

Pass the PR number/URL as the single argument **only** when the user asked to
review a PR; otherwise call it with no argument. Detection order (first match
wins), mirrored by the script:

1. **PR mode** — a PR number/URL was given. **Requires `gh`.**
2. **Working-tree mode** — the working tree has uncommitted changes → review
   those (staged + unstaged vs `HEAD`).
3. **Branch mode** — otherwise → review the current branch against its
   merge-base with the default branch (`origin/HEAD`, else `main`/`master`).

### `gh` gate (PR operations only)

Before **any** operation that needs `gh` (fetching or reviewing a PR, reading
the PR description/comments, posting), the collector verifies `gh` is
installed. If it is missing the script prints the install link and exits. When
that happens, **stop the entire workflow** and tell the user exactly this,
nothing more:

> GitHub CLI (`gh`) is required to review a pull request but was not found.
> Install it: https://cli.github.com/

Local branch and working-tree reviews do **not** require `gh` — never gate
those on it.

If the diff is empty, say so (in Russian) and stop — there is nothing to review.

---

## Step 3 — Build context (read files, not just hunks)

A hunk is not enough to judge a change. For every changed file:

- **Read the whole file** (`Read`), not only the changed lines, so you see the
  function/class the change lives in, the imports, and the existing patterns.
- If the collector printed an `### UNTRACKED FILES` section (new files that are
  not yet in the diff), `Read` each of those in full and review them too.
- Follow the change outward: `Grep`/`Glob` for **callers** of changed
  functions, the **types** involved, sibling modules, and existing tests.
- Pull the **intent / ТЗ** signals — you will need these both now and, if a
  second pass runs, to brief the sub-agent in Step 6:
  - For a PR (needs `gh`, gate from Step 2 applies):
    ```
    gh pr view <ref>            # title + description / linked issue
    gh pr view <ref> --comments # discussion so far
    ```
  - For a local review, infer intent from the branch name, recent commit
    messages (`git log`), and any linked issue or spec you can find.

Do not start writing findings until you understand what the change is *for*.
Capture the intent as a short written statement — it becomes the sub-agent's
brief in Step 6.

---

## Step 4 — Load the project conventions layer (if present)

This skill is **generic** and ships to every repo. A specific repo may add its
own conventions in a project skill at
`.claude/skills/code-review-conventions/SKILL.md` (this is **not** part of the
generic skill — it lives in the target repo). If it exists, read it and **fold
its rules into your review**:

```!
cat .claude/skills/code-review-conventions/SKILL.md 2>/dev/null || echo "(no project conventions layer)"
```

Composition rule: the generic passes below are the **base**; project
conventions **add to and override** them. On any direct conflict, the
project layer wins. Apply project rules within the relevant pass (e.g. a
naming convention belongs in the readability pass).

---

## Step 5 — Review pass 1 (ordered passes)

Work the passes **in this order**. Minor things come dead last so they never
crowd out substance.

If the reviewer named **focus areas** in Step 1, treat them as elevated priority:
scrutinize them hard and explicitly report what you found there — including a
plain "выглядит нормально" if it does. This raises attention; it does **not**
license inventing findings or skipping the other passes.

1. **Intent** — What is the change trying to do? Restate it from the PR
   description / linked issue / commits. Flag where the implementation does not
   match the stated intent, or where the intent itself is questionable.
2. **Correctness** — Logic errors, wrong conditions, off-by-one, edge cases
   (empty/null/overflow/concurrency), unhandled errors, broken invariants,
   resource leaks, security-sensitive mistakes. This is where most blockers
   live.
3. **Architecture & fit** — Does it match the patterns already used in this
   codebase (the ones you saw in Step 3)? Misplaced responsibility, leaky
   abstractions, duplication of something that already exists, coupling that
   will hurt later, public API/contract changes.
4. **Tests** — Are the changed behaviors covered? Are the tests meaningful
   (assert real behavior, not tautologies)? Missing edge-case tests, missing
   regression test for a fixed bug, brittle/over-mocked tests.
5. **Readability & naming** — Names that mislead or under-describe, unclear
   control flow, dead code, comments that lie, structure that is hard to
   follow. Apply project naming conventions from Step 4 here.
6. **Minor / nits** — Formatting, import order, typos, trivial style. Always
   last, always labeled `nit`.

### Frontend layer (apply within the passes above when the change touches FE)

- **React** — Rules of Hooks violations; missing/incorrect `useEffect`
  dependencies; effects that should be derived state or events; avoidable
  re-renders (unstable props/objects, missing `memo`/`useMemo`/`useCallback`
  where it actually matters); list `key` correctness (no array index when items
  reorder).
- **TypeScript** — `any` leaking into shared/public surfaces; weak typing of a
  public API (exported functions, props, return types); unsafe casts; missing
  discriminants on unions.
- **Accessibility (a11y)** — semantic elements vs `div` soup, labels for
  inputs, keyboard operability, focus management, ARIA misuse, color-only
  signaling.
- **Bundle / performance** — heavy or unnecessary imports, work that belongs
  behind memoization or out of render, large dependencies pulled in for a small
  need — only where it is actually relevant to the change.

### Severity and confidence (two axes)

Every finding gets **both** a severity and a confidence.

**Severity** — how much it blocks. Each label has a **fixed emoji** that rides
with it wherever the tag is shown (the Russian dump, the legend, and every posted
finding comment) — always emoji **then** the English term:

- `🔴 blocker` — must be fixed before merge (correctness/security/data loss).
- `🟠 should-fix` — real problem, fix it before or right after merge.
- `🔵 nit` — minor; author's discretion.
- `❓ question` — you need information to judge; not an assertion of a defect.

**Confidence** — how sure you are: `high` / `medium` / `low`.

- Rule: a **low-confidence** finding with high nominal severity must be demoted
  to `question` (or explicitly marked «гипотеза») — never post a shaky claim as a
  blocker.
- Confidence is a **working-layer** signal for triage. It appears in the Russian
  dump and drives sort order, but it is **not** included in posted comments.

Sort findings `blocker` → `should-fix` → `nit` (with `question` placed next to
what it concerns), and within a severity by confidence (high first).

---

## Step 6 — Optional independent second pass (sub-agent)

Only if the reviewer chose **`да`** in Step 1. Purpose: an independent opinion
that is **not anchored** to what pass 1 found.

Spawn a sub-agent with the `Task` tool. Give it **exactly** these inputs:

- the unified diff from Step 2 (and the untracked-file list, if any),
- the intent / ТЗ statement you wrote in Step 3,
- the project conventions layer text from Step 4 (if present),
- the ordered passes, the frontend layer, and the severity+confidence scheme
  from Step 5,
- the reviewer's focus areas from Step 1 (if any) — framed as elevated
  priorities to scrutinize, **not** as findings to confirm,
- instruction to read the full surrounding context of each changed file itself.

**Do NOT give it pass 1's findings.** The whole point is an uncontaminated look.
Ask it to return a plain list of findings, each with `file:line`, severity,
confidence, and a one-line rationale.

### Synthesis / dedup

Merge pass 1 and the sub-agent's list into one set:

- **Corroborated** — both passes flagged the same issue (same file, ~same line,
  same root cause): keep one entry, bump its confidence to `high`, and append the
  marker `✓✓ подтверждено обоими проходами`.
- **Singletons** — found by only one pass: keep it, but note which pass found it
  («только проход 1» / «только проход 2»). A singleton is a signal, not a verdict
  — it may be a real catch the other pass missed, or a false positive; judge it
  on its merits, do not auto-drop or auto-trust.

The merged set is what you dump in Step 7.

---

## Step 7 — Dump all findings (in Russian)

Present **all** findings **together, in one batch**, written in **Russian** — not
incrementally as you find them. This is the reviewer's triage surface. Number
every finding (1, 2, 3, …) — the numbers are how the reviewer curates in Step 8.

Begin the dump with:

```
🤖 **AI generated**
```

### Per-finding format (in the Russian dump)

```
N. **[<emoji> <severity> · conf:<high|medium|low>]** `path/to/file.ext:LINE` —
<проблема на русском>. <почему это важно>. <как чинить, если знаешь>. [✓✓ /
только проход N]
```

The `<emoji>` is the severity's fixed emoji: 🔴 `blocker` · 🟠 `should-fix` ·
🔵 `nit` · ❓ `question`.

Use a fenced code block for proposed code where it helps. Reference real
`file:line` locations from the diff.

### Tone of the dump (Russian, neutral working tone)

- **No filler praise.** Do not open with congratulations. If the change is
  genuinely solid, one honest line is enough; otherwise skip it.
- **No hedging.** Say what is actually wrong. If you are unsure, that is what
  `question` and the confidence axis are for — do not water down an assertion.
- One finding = one concrete, located, actionable point.

If after a real review you found nothing worth raising, say so plainly (one
Russian line) under the marker. Do not invent findings to look thorough.

**If `--quick`:** stop here. Do not run curation, do not post.

---

## Step 8 — Stop 2: curation (numbered reply) + review comment

Ask the reviewer, in Russian, to curate the dump by replying in free text.
Tell them the format explicitly, e.g.:

> Ответь, какие пункты идут в финальный батч: номера через запятую (или «все»).
> К любому пункту можешь добавить детали — например «4: добавь, что это ломает и
> мобилку». Что не выбрано — не постим.

Interpret their reply:

- keep only the selected finding numbers,
- apply any per-item additions/edits they gave,
- if they omit a finding, drop it from the batch (it is not posted).

Then handle the **top-level review comment** — the fixed AI-disclaimer + tag-legend
comment (see *The top-level review comment* section below). Ask, in Russian,
whether to include it; **default `да`**. It is the same
fixed template every run — the reviewer may decline it or tweak the wording, but
by default it goes in. There is **no** free-form "summary of the changes" anymore;
do not draft one.

Do not proceed to the final batch until they have answered the curation.

---

## The top-level review comment (disclaimer + legend)

When the final batch has **at least one** finding, it is accompanied by exactly
**one** top-level PR comment: a short fixed AI disclaimer plus the severity
legend, marked `🤖 AI generated` like every other posted comment. Rules:

- It is **fixed boilerplate**: the `🤖 AI generated` marker, the disclaimer, and
  the legend. It is **not** rephrased for the `сухо` / `вежливо` tone and does
  **not** summarize the changes. The disclaimer says the review was AI-assisted,
  that the reviewer validated every comment, and that all wording (even the
  reviewer's own findings) was written by the AI.
- It always lists **all four** severity terms, even if the batch used only some.
- If the final batch ends up with **zero** findings, skip this comment entirely —
  an empty legend helps no one.

**Language = the comment language resolved in Step 1:**

- **Русский** → post the RU template verbatim.
- **English** → post the EN template verbatim.
- **Anything else** → translate the **English** template faithfully into that
  language. Keep the `🤖` marker and the per-tag emoji (🔴 / 🟠 / 🔵 / ❓), keep
  the four severity terms (`blocker`, `should-fix`, `nit`, `question`) in English,
  keep the structure. Do not paraphrase it into the chosen tone — it is
  boilerplate, not a finding.

### RU template (verbatim)

```
🤖 **AI generated**

Это ревью сделано с использованием AI. Все замечания я провалидировал сам, но их формулировки составлены нейросетью — включая те, что я нашёл сам.

**Легенда по тегам**
- 🔴 **blocker** — нужно исправить до мержа.
- 🟠 **should-fix** — реальная проблема; стоит исправить до мержа или сразу после. Если сейчас не выходит — заведите, пожалуйста, issue и оставьте ссылку на него в комментарии.
- 🔵 **nit** — мелочь; на усмотрение автора.
- ❓ **question** — нужно больше контекста; не обязательно дефект.
```

### EN template (verbatim)

```
🤖 **AI generated**

This review was done with AI assistance. I validated every comment myself, but the wording — including the points I found myself — was written by the AI.

**Severity legend**
- 🔴 **blocker** — should be fixed before merge.
- 🟠 **should-fix** — a real problem; worth fixing before or right after merge. If you can't get to it now, please open an issue and leave a comment linking it.
- 🔵 **nit** — minor; author's discretion.
- ❓ **question** — I need more context; not necessarily a defect.
```

---

## Step 9 — Stop 3: show the final batch, then confirm or groom

Render the **final batch** the way it would actually be posted:

- prose in the **comment language** from Step 1,
- in the chosen **tone** (`сухо` / `вежливо`),
- severity labels kept as the fixed English terms, each with its emoji
  (🔴 / 🟠 / 🔵 / ❓),
- confidence and the `✓✓` corroboration marker **removed** (working-layer only),
- the `🤖 AI generated` marker on each posted comment — inline findings and the
  top-level legend comment alike,
- the top-level review comment (disclaimer + legend) included by default, unless
  the reviewer declined it in Step 8.

Then ask, in Russian: всё ок и постим — или ещё почитать и погрумить? If they
want to groom, loop back to Step 8 (re-curate) with their new input. Only move on
when they confirm.

---

## Step 10 — Posting to the PR (only with `--post`)

Only when `--post`/`--comment` was passed **and** you are in PR mode (so `gh`
is present) **and** the reviewer confirmed in Step 9: post the curated findings.
Because a batch may be split into separate comments, **every individual comment
must start with the `🤖 AI generated` marker** so it is never lost when detached
from the batch.

- Inline comments on specific lines are preferred where the finding maps to a
  line; prefix each one's body with `🤖 **AI generated**`.
- The top-level review comment (disclaimer + legend, Step 8) is a single top-level
  PR comment, prefixed with `🤖 **AI generated**` like the others. Post it by
  default — unless the reviewer declined it — and only when at least one finding
  is posted.
- Post in the resolved comment language and tone; keep severity labels in English,
  each prefixed with its emoji (🔴 `blocker` / 🟠 `should-fix` / 🔵 `nit` /
  ❓ `question`). The legend comment is the verbatim RU/EN template (or a faithful
  translation of the EN one) and is **not** tone-adjusted.
- After posting, confirm to the reviewer (in Russian) what was posted and where.

Never post when `--post` was not given, and never post in working-tree or
branch mode — there the final batch is simply printed.

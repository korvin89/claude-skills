---
name: code-review
description: >-
  Review a code change end to end. Pulls the diff itself (auto-detecting PR vs
  local branch vs working tree), reads the full surrounding context of each
  changed file rather than just the hunks, and reports findings in ordered
  passes — intent, correctness, architecture/fit, tests, readability, then minor
  nits last. Includes React / TypeScript / a11y / bundle-perf checks. The
  comment language is resolved at runtime (argument, then project config, then
  English). Use when asked to review a PR, review changes, review a diff, do a
  code review, or check code before merge.
argument-hint: "[pr-number | pr-url] [--post] [--lang <code>]"
allowed-tools: Read, Grep, Glob, Bash
---

# Code review

You are running a **workflow**, not reciting a checklist. You fetch the diff,
build real context around it, and produce a single batch of concrete findings.
Default to skepticism: only call something out when you can name the file, the
line, the concrete problem, and (where useful) the fix.

Arguments you may receive in `$ARGUMENTS`:

- A **PR number or URL** → review that pull request (requires `gh`, see Step 2).
- `--post` (or `--comment`) → after producing the batch, post it to the PR.
  Without this flag, **never** post anything; just print the batch in the chat.
- `--lang <code>` → force the comment language for this run (see Step 1).

---

## Step 1 — Resolve the comment language

The language of the **comment text** is resolved at runtime, never hard-coded.
Apply the **first match that succeeds**:

1. **Explicit argument** — `--lang <code>` in `$ARGUMENTS` (e.g. `--lang ru`,
   `--lang en`, `--lang "Brazilian Portuguese"`).
2. **Project config** — the `language` field of `.claude/code-review.json` in
   the repo being reviewed. Read it with:
   ```!
   cat .claude/code-review.json 2>/dev/null || echo "(no .claude/code-review.json)"
   ```
   Example config:
   ```json
   { "language": "ru" }
   ```
3. **Fallback** — **English**. (To make a repo always review in another
   language, commit a `.claude/code-review.json` with the `language` field, or
   pass `--lang` for a one-off.)

The resolved language applies **only to the prose of your findings**. It does
**not** change any of the following, which stay fixed regardless of language:

- the frontmatter `description` (always English),
- the severity labels `blocker` / `should-fix` / `nit` / `question` (kept as
  these exact English terms),
- the `🤖 AI generated` marker.

State the resolved language to yourself, then write every finding's prose in it.

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

If the diff is empty, say so and stop — there is nothing to review.

---

## Step 3 — Build context (read files, not just hunks)

A hunk is not enough to judge a change. For every changed file:

- **Read the whole file** (`Read`), not only the changed lines, so you see the
  function/class the change lives in, the imports, and the existing patterns.
- If the collector printed an `### UNTRACKED FILES` section (new files that are
  not yet in the diff), `Read` each of those in full and review them too.
- Follow the change outward: `Grep`/`Glob` for **callers** of changed
  functions, the **types** involved, sibling modules, and existing tests.
- For a PR, also pull the **intent** signals (these need `gh`, so the gate in
  Step 2 already applies):
  ```
  gh pr view <ref>            # title + description / linked issue
  gh pr view <ref> --comments # discussion so far
  ```
  For a local review, infer intent from the branch name, recent commit
  messages (`git log`), and any linked issue you can find.

Do not start writing findings until you understand what the change is *for*.

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

## Step 5 — Review in ordered passes

Work the passes **in this order**. Minor things come dead last so they never
crowd out substance.

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

---

## Step 6 — Output: one batch

Collect **all** findings and present them **together, in one batch** — not
incrementally as you find them. Order findings by pass (intent → … → minor),
and within a pass by severity (`blocker` first).

The batch **must** begin with this marker line:

```
🤖 **AI generated**
```

### Severity labels (fixed English terms)

- `blocker` — must be fixed before merge (correctness/security/data loss).
- `should-fix` — real problem, fix it before or right after merge.
- `nit` — minor; author's discretion.
- `question` — you need information to judge; not an assertion of a defect.

### Per-finding format

```
**[<severity>]** `path/to/file.ext:LINE` — <concrete problem, in the resolved
language>. <why it matters / consequence>. <suggested fix, when you have one.>
```

Use a fenced code block or `suggestion` snippet for proposed code where it
helps. Reference real `file:line` locations from the diff.

### Tone (in the resolved language)

- **No filler praise.** Do not open with congratulations or "great work". If
  the change is genuinely solid, a single honest line is enough; otherwise skip
  it.
- **No hedging.** Say what is actually wrong. Avoid "maybe", "perhaps", "you
  might possibly consider". If you are uncertain, make it a `question`, not a
  watered-down assertion.
- One finding = one concrete, located, actionable point.

If after a real review you found nothing worth raising, say so plainly (one
line) — still under the `🤖 **AI generated**` marker. Do not invent findings to
look thorough.

---

## Step 7 — Posting to the PR (only with `--post`)

Only when `--post`/`--comment` was passed **and** you are in PR mode (so `gh`
is present): post the findings as PR comments. Because a batch may be split
into separate comments, **every individual comment must also start with the
`🤖 AI generated` marker** so it is never lost when detached from the batch.

- Inline comments on specific lines are preferred where the finding maps to a
  line; a single summary comment is fine for cross-cutting points.
- Prefix each posted comment body with `🤖 **AI generated**`.
- After posting, confirm to the user what was posted and where.

Never post when `--post` was not given, and never post in working-tree or
branch mode.

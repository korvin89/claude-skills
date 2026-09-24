# Review rubric

The base rules for every review this skill runs. Pass 1 applies them directly;
the second-pass sub-agent reads this file and applies them independently. A
project conventions layer (`.claude/skills/code-review-conventions/SKILL.md` in
the reviewed repo) adds to and overrides these rules; on a direct conflict the
project layer wins.

## What counts as a finding

A finding names the file, the new-side line, the concrete problem, why it
matters, and (when you know it) the fix. Default to skepticism: an observation
without a location and a mechanism is not a finding; one with both but real
uncertainty is a `question`. One finding = one located, actionable point.

## Noise: what to skip

Skip generated and vendored content unless the change is about it: lockfiles,
snapshots, minified bundles, `dist/` and `build/` output, generated clients,
tool-written migrations. On a large change (roughly 30+ files) read the
risk-bearing files in full first — logic, data, auth, public API — and the rest
around their hunks.

## Ordered passes

Work them in this order. Minor things come last so they never crowd out
substance.

1. **Intent** — what the change is trying to do, restated from the PR
   description, linked issue, or commits. Flag where the implementation does
   not match the stated intent, or where the intent itself is questionable.
2. **Correctness** — logic errors, wrong conditions, off-by-one, edge cases
   (empty / null / overflow / concurrency), unhandled errors, broken
   invariants, resource leaks, security-sensitive mistakes. Most blockers live
   here.
3. **Architecture & fit** — does it follow the patterns the codebase already
   uses? Misplaced responsibility, leaky abstractions, duplication of something
   that exists, coupling that will hurt later, public API / contract changes.
4. **Tests** — are the changed behaviors covered, and do the tests assert real
   behavior rather than tautologies? Missing edge-case tests, missing
   regression test for a fixed bug, brittle or over-mocked tests.
5. **Readability & naming** — names that mislead or under-describe, unclear
   control flow, dead code, comments that lie, structure that is hard to
   follow. Project naming conventions apply here.
6. **Nits** — formatting, import order, typos, trivial style. Always last,
   always `nit`.

**Focus areas** named by the reviewer are elevated priority: scrutinize them
hard and report what you found there explicitly, including a plain «выглядит
нормально» when that is the truth. Elevated priority raises attention; the other
passes still run in full, and a focus area with nothing wrong yields no finding.

## Frontend layer (when the change touches FE)

Apply inside the passes above.

- **React** — Rules of Hooks; missing or wrong `useEffect` dependencies; effects
  that should be derived state or event handlers; avoidable re-renders
  (unstable props/objects, `memo` / `useMemo` / `useCallback` where it actually
  matters); list `key` correctness (no array index when items reorder).
- **TypeScript** — `any` leaking into shared or public surfaces; weak typing of
  a public API (exported functions, props, return types); unsafe casts; missing
  discriminants on unions.
- **Accessibility** — semantic elements over `div` soup, labels for inputs,
  keyboard operability, focus management, ARIA misuse, color-only signaling.
- **Bundle / performance** — heavy or unnecessary imports, work that belongs
  behind memoization or outside render, large dependencies pulled in for a
  small need — only where it is relevant to the change.

## Severity and confidence (two axes)

Every finding carries both.

**Severity** — how much it blocks. Emoji, then the English term, everywhere the
tag appears:

- `🔴 blocker` — must be fixed before merge (correctness / security / data loss).
- `🟠 should-fix` — real problem; fix before or right after merge.
- `🔵 nit` — minor; author's discretion.
- `❓ question` — information is needed to judge; not an assertion of a defect.

**Confidence** — how sure you are: `high` / `medium` / `low`. A low-confidence
finding with high nominal severity becomes a `question` (or is marked
«гипотеза»); a shaky claim is never posted as a blocker. Confidence is a triage
signal: it appears in the Russian dump and drives sort order, and it is left out
of posted comments.

**Order:** `blocker` → `should-fix` → `question` → `nit`; within a severity,
higher confidence first.

## Finding format (Russian dump)

```
N. **[<emoji> <severity> · conf:<high|medium|low>]** `path/to/file.ext:LINE` —
<проблема>. <почему это важно>. <как чинить, если знаешь>. [✓✓ подтверждено обоими проходами | только проход 1 | только проход 2]
```

`LINE` is the new-side line. Use a fenced code block for proposed code where it
helps. The `[✓✓ … | только проход N]` tail exists only after a second pass.

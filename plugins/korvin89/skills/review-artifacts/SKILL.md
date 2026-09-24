---
name: review-artifacts
description: Build and publish an artifact page with screenshot pairs (base vs PR) and their configs.
disable-model-invocation: true
argument-hint: "[what to compare]"
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion, Artifact
---

# Review artifacts

Produce comparison evidence for one review finding, or for `$ARGUMENTS` when
invoked by hand, and publish it as **one artifact page**: a short text on top, a
collapsed block of screenshot pairs (base vs head, side by side), a collapsed
block of the configs behind them. The deliverable is the artifact link.

Working language is Russian. Page text is in the comment language when called
from `code-review`, otherwise Russian. Style: dry, factual, no grading.

## Step 1 — Subject and refs

- **Subject**: the case the finding is about (file:line plus what to render),
  or `$ARGUMENTS`.
- **Refs**: in PR mode the PR head vs its base; otherwise the current branch vs
  `origin/<default>`. Label them for the page: `base_label` (`main`) and
  `head_label` (`PR #123`).
- **Pairs**: one per case that shows the difference the finding talks about
  (theme, size, data variant). Two to four pairs; a pair that shows no
  difference is left out.

## Step 2 — Stop: how are screenshots taken here (one prompt)

This skill does not know the repo's rendering setup. Ask the reviewer once, in
Russian, with `AskUserQuestion`, free text: how to render the case to a PNG in
this repo — the command, script, Storybook story or Playwright fixture to use,
the viewport and theme, and whether dependencies are installed. Reuse the
answer for every pair and every finding of this run; ask again only after a
failure you cannot fix from the error.

## Step 3 — Produce the files

Never switch the reviewer's checkout: one `git worktree add` per ref under
`/tmp/review-artifacts/<slug>/wt-<ref>`, removed with `git worktree remove` at
the end. Render each pair at the **same viewport and device scale factor** on
both sides; scale factor 1 unless detail needs 2 (the page limit is 16 MiB).
Write everything into `/tmp/review-artifacts/<slug>/`:

- `<pair>-base.png`, `<pair>-head.png`;
- `<pair>.json` — the config that produced the pair, verbatim;
- `manifest.json`:

```json
{
  "title": "Stacked bar, negative values",
  "text": "На PR исчезает нижняя граница отрицательных сегментов.",
  "base_label": "main",
  "head_label": "PR #123",
  "pairs": [
    { "label": "default theme", "base": "default-base.png", "head": "default-head.png", "config": "default.json" }
  ]
}
```

`text` is the finding's statement in one or two paragraphs; `config` is optional
per pair.

## Step 4 — Build and publish

```
bash "${CLAUDE_SKILL_DIR}/scripts/build-page.sh" /tmp/review-artifacts/<slug>
```

The script inlines the images and writes `index.html`; exit 7 means the page
is over the size limit: drop a pair or re-render at scale factor 1. Publish
`index.html` with the `Artifact` tool; the result is the link. The page is
private until the reviewer presses **Share** on it — say so once.

## Step 5 — Hand back

One Russian line per artifact: the link, the number of pairs, the size. When
called from `code-review`, the finding gets a final line `Артефакты: <link>`
(in the comment language, e.g. `Artifacts: <link>`).

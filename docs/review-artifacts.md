# korvin89:review-artifacts

[All skills](../README.md)

Builds one shareable artifact page for a review finding: a short text on top,
a collapsed block of screenshot pairs (base vs PR, side by side), a collapsed
block of the configs behind them. Publishes it with Claude Code's Artifact
tool and returns the link; the page stays private until you press **Share**.
User-invoked only, and read by [`code-review`](code-review.md) when you write
`artifacts` in a finding's thread:

```text
/korvin89:review-artifacts stacked bar with negative values, default and dark theme
```

The skill does not know how a given repo renders screenshots: it asks once
per run (command, story or fixture, viewport, theme), renders each pair in
separate `git worktree`s so your checkout is untouched, and assembles the page
with `scripts/build-page.sh` from a `manifest.json`. Its files and worktrees go
into the review's scratch dir (`.git/code-review/<pr-N | local>/artifacts/`),
which [`korvin89:cleanup`](cleanup.md) removes. Requires `jq`; the
Artifact tool needs a claude.ai login (CLI or desktop app).

---
name: cleanup
description: Remove the scratch that korvin89 review skills keep for one pull request.
disable-model-invocation: true
argument-hint: "<pr-number | pr-url | local>"
allowed-tools: Bash, AskUserQuestion
---

# Cleanup

Removes the scratch of one review: `<repo>/.git/code-review/<pr-N | local>/` —
the PR head worktree, the findings batch, and the screenshots, configs and
worktrees of `review-artifacts`. Published artifact pages and the draft review
are not touched. Working language is Russian.

1. **No PR named** (`$ARGUMENTS` is empty): never clean everything. Show what
   exists and ask which PR to clean, then stop:
   ```
   bash "${CLAUDE_SKILL_DIR}/scripts/cleanup.sh" list
   ```
2. **Run** for the named PR, `local` for a review without one:
   ```
   bash "${CLAUDE_SKILL_DIR}/scripts/cleanup.sh" $ARGUMENTS
   ```
3. **Exit 10** — the checks found something: the scratch may not be this PR's,
   holds uncommitted work, is the current directory, or a draft watcher still
   runs for it. Nothing was removed. Show each warning as one Russian line and
   ask with `AskUserQuestion` «Всё равно чистить?», options `Нет` first, then
   `Да, чистить`. Only on «Да, чистить» run the same command with `--yes`.
   Never add `--yes` on your own.
4. **Exit 0** — relay in one Russian line what was removed and its size, or
   that there was nothing to clean. Exit 2 / 4 — relay the message.

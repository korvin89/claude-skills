---
name: cleanup
description: Remove the scratch that korvin89 review skills keep for one pull request.
disable-model-invocation: true
argument-hint: "<pr-number | pr-url | local>"
allowed-tools: Bash, AskUserQuestion
---

# Cleanup

Removes the scratch of one review, `<repo>/.git/code-review/<pr-N | local-…>/`:
the PR head worktree, the findings batch, and the screenshots, configs and
worktrees of `review-artifacts`. Published artifact pages and the draft review
are never touched. Working language is Russian.

The invocation's argument is `$ARGUMENTS`.

1. **Exactly one argument** is accepted: a PR number, `#<number>`, `pr-<N>`
   (as `list` prints it), a PR URL, `local` (a review without a PR in this
   checkout) or `local-<id>`. Anything else — no argument, two words, a flag
   such as `--yes` — cleans nothing: run
   ```
   bash "${CLAUDE_SKILL_DIR}/scripts/cleanup.sh" list
   ```
   show the list in Russian (scratch, size, age, whose), tell the reviewer to
   run `/korvin89:cleanup <pr>` for the one to remove, and stop.
2. **Run** with the argument in single quotes (an unquoted `#12` would start a
   shell comment):
   ```
   bash "${CLAUDE_SKILL_DIR}/scripts/cleanup.sh" '<argument>'
   ```
3. **Exit 10.** The output is `CONFIRM <code>` followed by the warnings: the
   scratch may not be this PR's or this checkout's, holds uncommitted work or
   cannot be read by git, is the current directory, or a draft watcher still
   runs for it. Nothing was removed. Show each warning as one Russian line and
   ask with `AskUserQuestion` «Всё равно чистить?», options `Нет` first, then
   `Да, чистить`. Only on «Да, чистить» run the same command with
   `--yes=<code>` added, the code from that `CONFIRM` line. If it exits 10
   again, the warnings changed in the meantime: show the new ones and ask
   again. Never add `--yes` without the reviewer's answer to the warnings
   just shown.
4. **Exit 0** — relay in one Russian line what was removed and its size, or
   that there was nothing to clean. **Exit 1, 2 or 4** — relay the message;
   nothing more is removed.

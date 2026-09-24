---
name: herdr-tab
description: Rename the current Herdr tab.
disable-model-invocation: true
argument-hint: "<name>"
allowed-tools: Bash
---

# Herdr tab

Rename the current [Herdr](https://herdr.dev) tab to `$ARGUMENTS`:

```
bash "${CLAUDE_SKILL_DIR}/scripts/rename.sh" "$ARGUMENTS"
```

Outside Herdr (`HERDR_ENV` unset) the script is a silent no-op. When it fails
it prints one line on stderr; relay that line. Otherwise confirm the new name
in one line.

Other skills call the script directly by path,
`${CLAUDE_PLUGIN_ROOT}/skills/herdr-tab/scripts/rename.sh <name>`, and never
need this file.

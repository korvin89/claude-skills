# claude-skills

A Claude Code plugin marketplace. `.claude-plugin/marketplace.json` lists the
plugins; each plugin is `plugins/<name>/` with `.claude-plugin/plugin.json` and
`skills/<skill>/SKILL.md`, invoked as `<plugin>:<skill>`. `README.md` is for
consumers only: install, update, what each skill does. Publishing and
development notes live here.

## Release

Installed plugins are cached copies pinned by `version` in
`plugins/korvin89/.claude-plugin/plugin.json`; the catalog is a clone of `main`.
A change reaches users only when all three hold:

1. `version` is bumped (patch for fixes, minor for new flags, skills, or
   removed behaviour);
2. `claude plugin validate .` and `claude plugin validate ./plugins/korvin89`
   pass;
3. it is merged to `main` — release branches are invisible to the catalog.

Work happens on a `release/<version>` branch with a PR into `main`. Optional
after the merge: `claude plugin tag --push` creates the `korvin89--v<version>`
tag.

## Develop

- `claude --plugin-dir ./plugins/korvin89` loads the working tree for one
  session, overriding the installed copy; `/reload-plugins` picks up edits.
- A new skill in the namespace is `plugins/korvin89/skills/<name>/SKILL.md`,
  no manifest change. A separate plugin needs
  `plugins/<plugin>/.claude-plugin/plugin.json` and an entry in
  `marketplace.json`.
- Scripts are tested against throwaway git repos and a `gh` / `herdr` shim on
  `PATH`; nothing touches a live PR or Herdr session.

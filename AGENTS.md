# claude-skills

A Claude Code plugin marketplace. `.claude-plugin/marketplace.json` lists the
plugins; each plugin is `plugins/<name>/` with `.claude-plugin/plugin.json` and
`skills/<skill>/SKILL.md`, invoked as `<plugin>:<skill>`. `README.md` and
`docs/` are for consumers only: README is install, update and an overview of
the skills; `docs/<skill>.md` is one skill's full guide, kept outside the
plugin so it is not shipped. Publishing and development notes live here;
`CLAUDE.md` is a symlink to this file.

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

A change only to `README.md`, `docs/` or this file is not a release: no bump,
no `release/` branch. It takes effect on merge to `main`.

## Develop

- `claude --plugin-dir ./plugins/korvin89` loads the working tree for one
  session, overriding the installed copy; `/reload-plugins` picks up edits.
- A new skill in the namespace is `plugins/korvin89/skills/<name>/SKILL.md`,
  no manifest change. A separate plugin needs
  `plugins/<plugin>/.claude-plugin/plugin.json` and an entry in
  `marketplace.json`.
- Each skill has a guide, `docs/<skill>.md`, and a row in README's skills
  table. A new skill adds both; a change to a skill's user-facing behaviour
  updates its guide in the same PR.
- Scripts are tested against throwaway git repos and a `gh` shim on `PATH`;
  nothing touches a live PR.

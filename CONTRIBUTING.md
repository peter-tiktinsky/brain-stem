# Contributing

brain-stem is a personal project that may be useful to others. Contributions, bug reports, and feedback are welcome. There is no roadmap obligation, no SLA, and no guarantee a PR lands — but if you've found a bug or built something genuinely portable on top of this, please open an issue or PR.

## Get the code

```bash
git clone https://github.com/peter-tiktinsky/brain-stem.git
cd brain-stem
```

The repo contains no submodules and no committed binaries. Everything is plaintext: shell, JSON, Markdown.

## Repo layout

This is the source repo. The live install at `~/.claude/` is distributed FROM here via `install.sh`. Never hand-edit the live install during development; all changes flow through source → commit → release → `install.sh`.

- `governance/` — the foundation pillars + file-type contracts
- `hooks/` — lifecycle hook bodies (`hooks/lib/`, `hooks/config/`)
- `skills/` — slash-command skills, one level deep
- `schemas/` — JSON Schemas for adopter + repo-only artifacts
- `templates/` — render templates (launchd, settings fragments)
- `vault-init/` — the seed vault structure an adopter starts from
- `orchestrator/` — dispatch + plan-runner engine
- `installer/` — render-launchd / render-cron mechanics
- `git-hooks/` — author-side git hooks (not installed on adopter machines)
- `tools/` — release-time tooling (not installed)
- `internal/` — tests, docker, lima harnesses (GitHub-only, never shipped)

## Run the test harness

Tests live under `internal/tests/`. Run them in isolation — never against your live `~/.claude/` paths.

## Conventions

- macOS only, single-user, Apache-2.0.
- Plaintext everywhere; no generated binaries in history.
- Any foundation source edit requires a manifest regen before release (enforced by the author-side git hooks).

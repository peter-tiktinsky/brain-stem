# `~/.claude/rules/` — glob-scoped rule corpus

This directory is the documented scale-beyond surface for instructions that exceed the `MEMORY.md` 25KB / 200-line cap. Files placed here are loaded by the Claude Code harness using two activation modes:

1. **Unscoped (always-on)** — any `*.md` file in this directory without a `paths:` frontmatter key loads at session start, alongside `CLAUDE.md`.
2. **Glob-scoped (lazy)** — a `paths:` YAML frontmatter key restricts loading to sessions where Claude reads matching files. Use this to keep large rule sets out of the always-on context.

Reference: `code.claude.com/docs/en/memory` (auto-memory + `.claude/rules/` + `paths:` frontmatter).

---

## When to put something here vs in `MEMORY.md`

| Surface | When to use |
|---|---|
| `MEMORY.md` index + topic files at `memory/*.md` | Judgment-class memory (preferences, lessons, project state) under the 25KB cap. Always loaded. |
| `.claude/rules/*.md` (unscoped) | Cross-cutting rules that should fire every session (style guides, refusal patterns, universal conventions). |
| `.claude/rules/*.md` with `paths:` (glob-scoped) | Domain-specific rules that only apply when working in matching files (e.g., Python style for `**/*.py`, infra conventions for `infrastructure/**`). |

When in doubt, start in `MEMORY.md`. Promote to `.claude/rules/` when the index hits the cap or a rule is only relevant in a narrow file scope.

---

## Frontmatter shape (glob-scoped)

```yaml
---
description: One-line retrieval hook explaining when this rule applies.
paths:
  - "src/**/*.ts"
  - "src/**/*.tsx"
---

# TypeScript style rules

(rule body — markdown)
```

`description:` is read by the harness when scanning rules; keep it short (lead with the trigger, not a topic name).

`paths:` accepts an array of glob patterns. The rule loads whenever a session reads any file matching any pattern. Unscoped rules (no `paths:` key) load at every session start.

---

## Worked example

`infrastructure-edits.md`:

```yaml
---
description: Block live `aws` / `gcloud` / `terraform apply` calls; require dry-run + operator confirmation first.
paths:
  - "infrastructure/**/*.tf"
  - "infrastructure/**/*.yaml"
  - "scripts/deploy-*.sh"
---

# Live infrastructure mutation rules

- Never run `terraform apply` without first running `terraform plan` and presenting the diff.
- Never run `aws s3 rm` or `gcloud * delete` without explicit operator approval.
- Treat any prod environment variable (`PROD_*`, `*_PRODUCTION`) as read-only unless the operator says "live mutation OK".
```

This rule stays out of context until a session touches `infrastructure/**` or a `deploy-*.sh` script — keeping the always-on context budget small while the corpus scales.

---

## Hygiene

- Keep individual rule files under ~500 lines (industry convergence: Cursor `.mdc`, GitHub Copilot `applyTo:`).
- One concern per file; split when a file outgrows a single domain.
- Cross-link related rules and memory files via `[[wikilinks]]`.

See `docs/memory-architecture.md` (foundation reference) for the full two-surface model and per-type half-life table.

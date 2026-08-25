# `~/.claude/rules/` — glob-scoped rule corpus

This directory is the documented scale-beyond surface for instructions that exceed the `MEMORY.md` 25KB / 200-line cap. Files placed here are loaded by the Claude Code harness using two activation modes:

1. **Unscoped (always-on)** — any `*.md` file in this directory without a `paths:` frontmatter key loads at session start, alongside `CLAUDE.md`.
2. **Glob-scoped (lazy)** — a `paths:` YAML frontmatter key is intended to restrict loading to sessions where Claude reads matching files, keeping large rule sets out of the always-on context. **Caveat for user-scope `~/.claude/rules/`:** the `paths:` glob is silently ignored here today — see "Known limitation" below. Reserve glob-scoping for **project-scope** `.claude/rules/`, where it loads reliably; in user-scope, rely on the unscoped (always-on) mode.

Reference: `code.claude.com/docs/en/memory` (auto-memory + `.claude/rules/` + `paths:` frontmatter).

---

## When to put something here vs in `MEMORY.md`

| Surface | When to use |
|---|---|
| `MEMORY.md` index + topic files at `memory/*.md` | Judgment-class memory (preferences, lessons, project state) under the 25KB cap. Always loaded. |
| `.claude/rules/*.md` (unscoped) | Cross-cutting rules that should fire every session (style guides, refusal patterns, universal conventions). |
| `.claude/rules/*.md` with `paths:` (glob-scoped) | Domain-specific rules that only apply when working in matching files (e.g., Python style for `**/*.py`, infra conventions for `infrastructure/**`). **Reliable in project-scope `.claude/rules/` only** — the `paths:` glob is silently ignored in user-scope `~/.claude/rules/` (see "Known limitation"). |

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

`paths:` accepts an array of glob patterns. In **project-scope** `.claude/rules/` the rule loads whenever a session reads any file matching any pattern. In **user-scope** `~/.claude/rules/` the `paths:` glob is silently ignored (a known upstream limitation — see "Known limitation" below), so a user-scope rule effectively loads only via the unscoped (always-on) mode. Unscoped rules (no `paths:` key) load at every session start on both scopes.

---

## Vault path pointer shape

This is the `paths:`-frontmatter section's plain-text counterpart: when a rule **body** points the reader at a file outside this corpus — a plan under `~/.claude-plans/`, an Obsidian-vault note, or a state path — write the pointer in the canonical three-element shape so it stays trustworthy and machine-greppable. (This is distinct from the `paths:` glob above, which scopes *which sessions load the rule*; this shape governs *how a rule body cites an external file*.)

The three elements, in order:

1. **The absolute or `~`-prefixed path** — a bare path token, not a `[markdown](link)`. Begin the line with the path so it is unambiguous and tool-resolvable.
2. **An imperative read-instruction** — one of `Read` / `Consult` / `Load` / `See`, so the reader knows it is an action, not a mention.
3. **A decision-useful why** — what the file decides or unblocks, so a reader can tell whether to open it before acting.

Worked exemplar (note the bare-path start — no leading `- [`):

```
~/.claude-plans/payments-migration/spec.md — Consult BEFORE any dependency analysis; this is the binding spec, not the working notes.
```

The bare-path start is deliberate and load-bearing: a vault-pointer begins with a path token, whereas an index-style entry begins with `- [`. Keeping the two shapes visually distinct lets placement tooling key on the bare-path imperative shape without mistaking an ordinary `[name](path.md)` link for a vault-pointer.

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
- Cross-link related rules and memory files via `[[wikilink]]` cross-references. The
  memory/rules tier is EXEMPT from the corpus link-grammar conversion: a `[[name]]` here
  resolves against the enumerated memory/rules namespace, not the vault walk. This is a
  different shape from a vault-pointer, which stays a bare path token (see the pointer
  shape above) — the two never mix.

---

<!-- brain-stem: #21858-caveat -->
## Known limitation — user-scope `paths:` globs are silently ignored

In **user-scope** `~/.claude/rules/` (this directory), a `paths:` glob is **silently ignored**: a glob-scoped rule placed here does not lazy-load on matching files — it is simply not picked up by the glob, with no warning. This is a known upstream limitation, tracked in GitHub issues `#21858` and `#25562`.

Practical consequence and the reliable alternative:

- A user-scope rule that **must** fire should be **unscoped** (omit the `paths:` key) so it loads always-on at session start.
- Glob-scoped (`paths:`) rules load reliably only in **project-scope** `.claude/rules/` (inside a repo). Put domain-specific, file-matched rules there.
- Until the upstream behavior changes, treat a `paths:` key in user-scope as documentation of intent rather than an active loader, and do not rely on it to keep a rule out of the always-on context here.

See the public memory docs at `code.claude.com/docs/en/memory` for the full two-surface model and the auto-memory re-validation interval.

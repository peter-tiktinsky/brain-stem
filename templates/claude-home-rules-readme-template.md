# `~/.claude/rules/` — glob-scoped rule corpus

This directory is the documented scale-beyond surface for instructions that exceed the `MEMORY.md` 25KB / 200-line cap. Files placed here are loaded by the Claude Code harness using two activation modes:

1. **Unscoped (always-on)** — any `*.md` file in this directory without a `paths:` frontmatter key loads at session start, alongside `CLAUDE.md`.
2. **Glob-scoped (lazy)** — a `paths:` YAML frontmatter key restricts loading to sessions where Claude reads matching files, keeping large rule sets out of the always-on context. It is honored in both scopes on current binaries. **Caveat:** a `paths:` rule triggers on a READ of a matching file, never on file creation, and it does not survive compaction the way an unscoped rule does — see "Known limitation" below before you scope a rule that must fire on writes.

Reference: `code.claude.com/docs/en/memory` (auto-memory + `.claude/rules/` + `paths:` frontmatter).

---

## When to put something here vs in `MEMORY.md`

| Surface | When to use |
|---|---|
| `MEMORY.md` index + topic files at `memory/*.md` | Judgment-class memory (preferences, lessons, project state) under the 25KB cap. Always loaded. |
| `.claude/rules/*.md` (unscoped) | Cross-cutting rules that should fire every session (style guides, refusal patterns, universal conventions). |
| `.claude/rules/*.md` with `paths:` (glob-scoped) | Domain-specific rules that only apply when working in matching files (e.g., Python style for `**/*.py`, infra conventions for `infrastructure/**`). Loads on a READ of a matching file, not on creation (see "Known limitation"). |

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

`paths:` accepts an array of glob patterns. In both **project-scope** `.claude/rules/` and **user-scope** `~/.claude/rules/` the rule loads when the session READS a file matching any pattern (see "Known limitation" for what a read-only trigger means). Unscoped rules (no `paths:` key) load at every session start on both scopes.

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

- Keep individual rule files under 500 lines. Cursor's rules docs state 500 lines; GitHub Copilot's custom-instructions docs state ~1,000; brain-stem adopts 500 as its own ceiling.
- One concern per file; split when a file outgrows a single domain.
- Cross-link related rules and memory files via `[[wikilink]]` cross-references. The
  memory/rules tier is EXEMPT from the corpus link-grammar conversion: a `[[name]]` here
  resolves against the enumerated memory/rules namespace, not the vault walk. This is a
  different shape from a vault-pointer, which stays a bare path token (see the pointer
  shape above) — the two never mix.

---

## Maintenance

Three librarian capabilities keep this corpus honest; none of them rewrites a rule body.

- **`librarian rules-hygiene`** (weekly cron) — audits every file here for a valid frontmatter block, the 500-line ceiling and dead `paths:` globs, and carries an informational `hook-redundant` row for a rule whose instruction a registered hook already enforces mechanically. Propose-only: it reports, you decide.
- **`librarian memory-globalize`** (promotion, interactive) — elevates a project memory carrying `scope: global` into a rule file here, validated against the shipped rules schema before the write. It never overwrites an existing rule file.
- **`librarian context-budget-index`** (daily cron) — measures the always-on context budget and renders the `rules/` tier as one aggregate GREEN/YELLOW/RED band with a per-file contributor list, so growth here is visible before it crowds the session.

---

<!-- brain-stem: #21858-caveat -->
## Known limitation — a `paths:` rule triggers on READ, not on file creation

The two upstream issues that once made user-scope `paths:` globs unreliable are both closed:

- `#21858` — YAML-list `paths:` parsing in `~/.claude/rules/`; CLOSED 2026-03-24 (reporter-closed).
- `#25562` — a distinct claim: `paths:` rules matched only under the primary working directory; CLOSED.

On current binaries a `paths:` glob in **user-scope** `~/.claude/rules/` (this directory) is honored exactly as it is in project-scope.

The LIVE limitation is `#93248` (OPEN, filed 2026-09-10): a `paths:` rule triggers when Claude **reads** a file matching the glob, not when it **creates** one. Two consequences:

- A `paths:` rule cannot deliver write-time guidance. A rule that must fire before a matching file is written belongs in the unscoped (always-on) mode, or in a PreToolUse hook.
- After compaction, unscoped rules are re-injected from disk, but a `paths:` rule reloads only as matching files are read again. A `paths:` rule is therefore not a drop-in for an unscoped rule: it is strictly weaker post-compaction.

Verify the trigger on your own install: author a `paths:`-scoped rule here, READ a file matching its glob, then run `${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/rules-hygiene.sh --check-load <rule-name>`. It reads `$CLAUDE_STATE_ROOT/hooks-state/instructions-loaded.ndjson` and reports whether a row with `load_reason: path_glob_match` names the rule; it filters on rows that carry a `file_path` key, because the file mixes in a second record shape without it.

See the public memory docs at `code.claude.com/docs/en/memory` for the full two-surface model and the auto-memory re-validation interval.

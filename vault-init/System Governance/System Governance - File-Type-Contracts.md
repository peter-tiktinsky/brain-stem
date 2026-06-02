---
type: system-governance-spoke
title: System Governance - File-Type-Contracts
mirrors_pillar: file-type-contracts
description: How the system enforces body-structure rules — line caps, required sections, write shapes — on specific kinds of files. Covers the matcher/parameter split, the write-shape enum, and how your overlay extends or shadows foundation contracts.
updated: 2026-06-01
tags: ["#scope/reference"]
---

# File-Type-Contracts

Frontmatter governs the YAML at the top of a file (see [[System Governance - Frontmatter]]). File-type-contracts govern the **body** — how long the file may be, which sections must be present, and what the system is allowed to do at write time (replace it, append to it, refuse to overwrite). Each contract is the body-shape parameter for a specific file kind; the matcher that triggers the contract lives in a separate pillar so contracts and triggers can evolve independently.

The runtime contract is composed from the same two artifacts as every other pillar:

- **`foundation-master.json`** — ships the default body-structure rules for every file kind the foundation knows about.
- **`overlay-master.json`** — your extensions and overrides. Ships empty; populated over time by the `/govern register` flow.

The system reads both on every write and applies the union. Foundation provides the baseline; your overlay adds contracts for file kinds you've defined and shadows foundation defaults where you've registered an explicit override.

## The matcher / parameter split

A file-type-contract has two pieces that live in two different pillars:

- **Matcher** — declares *which writes trigger this contract*. The match condition lives in a sibling pillar (mandatory-files for vault-side mandates; plans for plan-tree files). The matcher names the contract it parameterises and any path-glob constraints.
- **Contract** — declares *what the body must look like*. The contract carries the body-structure parameters: `applies_to.path_glob`, `write_shape`, `size_limits`, `required_sections`, `prohibited_sections`, `frontmatter_required`, `frontmatter_enums`, and any `body_structure` rules (sentinel tables, columns, regex patterns).

The split lets a contract be reused across multiple matchers, and lets a matcher swap parameters between adopters without rewriting the contract itself. It's the same pattern Kubernetes uses for `ValidatingAdmissionPolicy` + `paramKind` — policy and parameters are separable.

## The write-shape enum

Every contract carries a `write_shape` declaring what kinds of writes the system permits to this file. Three values:

| Shape | What it permits | Default class of files |
|---|---|---|
| `create-only` | Initial write succeeds; subsequent overwrites of an existing file are denied at the hook. Edits go through the file's amender (where one exists). | Generated/system-emitted artifacts: meeting notes, spoke files, vault-writer descriptors, vault-root `CLAUDE.md`. |
| `replace` | Full-file replacement is permitted on every write. The system snapshots the prior content for diff-review. | Files that are regenerated as a unit: `_index.md`, `manifest.json`, `tasks.md`. |
| `append-template` | Writes must append a templated block to the existing content; the contract carries the template shape and any required sentinel markers. | Append-only logs and session records: `handoff.md`, `spec.md` (where new sub-sections append). |

If a write violates the declared shape — overwriting a `create-only` file, replacing an `append-template` file wholesale — the hook denies the write and surfaces the contract that would have been satisfied.

## The foundation contract set

Foundation ships body-structure contracts only for files the foundation itself emits or governs. Anything else is overlay territory.

| Contract | Type | Path glob | Write shape |
|---|---|---|---|
| `CLAUDE.md` | `CLAUDE.md` | `$VAULT_ROOT/CLAUDE.md` | create-only |
| `System Governance.md` | `system-governance-spoke` | `$VAULT_ROOT/System Governance/System Governance - *.md` | create-only |
| `_index.md` | `index` | every non-exempt folder | replace |
| `meeting-note.md` | `meeting-note` | `$VAULT_ROOT/Meetings/*.md` | create-only |
| `vault-writer.md` | `vault-writer` | `$VAULT_ROOT/Vault Writers/*.md` | create-only |
| `doc-amender-prompt.md` | `doc-amender-prompt` | `$VAULT_WRITER_STATE_ROOT/prompts/*.md` | create-only |
| `spec.md` | `spec` | plan-tree | append-template |
| `tasks.md` | `tasks` | plan-tree | replace |
| `handoff.md` | `handoff` | plan-tree | append-template |
| `ideation-brief.md` | `ideation-brief` | plan-tree | create-only |
| `manifest.json` | `manifest` | plan-tree | replace |
| `adr.md` | `adr` | plan-tree (`decisions/`) | create-only |

Each contract additionally declares per-file body rules — size caps where they apply, required and prohibited sections, frontmatter enums, sentinel-table columns where the body is structured. The full schema for each contract is in the bundle.

## Extending the contract set

When your vault accumulates a file kind that the foundation doesn't ship — a recurring running-updates body, a custom meeting-summary variant, any structured document you write enough of to benefit from body-shape enforcement — register it via `/govern register --kind file-type`. The registration writes a new entry to `overlay-master.json` under `file_type_contracts`, with the same shape as a foundation entry. The next write that matches the contract validates against the combined foundation + overlay set.

## Overlay collisions and the override discipline

The overlay union-read model means an adopter overlay can shadow a foundation contract — same key under `file_type_contracts`, different parameters. The system permits this, but every shadowing entry must carry an `_override_reason` field stating *why* the foundation default isn't acceptable for your vault.

On every overlay write the system runs a collision check. If an overlay entry would shadow a foundation entry **without** `_override_reason`, the write is denied with the shadowing entries enumerated. Add the reason inline on each one and re-write.

For a single ad-hoc write that legitimately can't carry the reason at registration time — bootstrapping a fresh overlay, importing a previous vault's contracts in bulk — the system provides a per-write escape hatch:

- `/govern register --force-override` bypasses the collision check for the current registration.
- Direct overlay writes (manual edits, test fixtures) can set `R52_FORCE_OVERRIDE=1` in the environment for a single invocation.

Both bypasses are per-write only; neither persists. The next overlay write goes back through the collision gate.

The override discipline serves two ends: the reason field travels with the divergence as a permanent audit trail, and the explicit bypass keeps casual overrides from accumulating silently.

## What happens on write

Order of checks the system runs when you write a file matched by a contract:

1. **Matcher resolution.** The system reads the matcher pillar to find which contract this path triggers. No matcher → no body-structure enforcement at this layer; the file still validates against `frontmatter.types`.
2. **Write-shape check.** The shape declared by the contract is enforced against the operation kind. `create-only` denies overwrites; `append-template` denies replacements; `replace` permits anything.
3. **Size limits.** If the contract declares `size_limits.max_lines`, the post-write content is line-counted. Over-cap writes are denied at hooks where the size guard runs synchronously and surface as advisory at audit time elsewhere.
4. **Required and prohibited sections.** Body must include all `required_sections` headers; must include none of the `prohibited_sections`. The hook surfaces the missing or forbidden section names verbatim.
5. **Frontmatter coupling.** Where the contract declares `frontmatter_required` or `frontmatter_enums`, those are layered on top of the type's universal requirements from the frontmatter pillar. Both layers must pass.

## Anti-patterns

| Anti-pattern | What goes wrong | Better path |
|---|---|---|
| Declaring body rules in the matcher pillar | The matcher pillar's job is "what triggers this contract"; mixing parameters in conflates concerns and breaks reuse. | Body parameters belong in the `file_type_contracts` entry; the matcher names the entry and any path-glob constraints. |
| Shadowing a foundation contract without `_override_reason` | The collision gate denies the write; the overlay never lands. | Add the reason inline. The audit trail benefits from the explicit divergence rationale. |
| Setting `R52_FORCE_OVERRIDE=1` in your shell rc | Turns the per-write escape into a silent always-bypass; overrides accumulate without justification. | Set it only for the specific command that needs it; let it expire when the command does. |
| Treating `create-only` as immutable | The shape governs raw overwrites; legitimate edits go through the file's amender, which has its own structured pipeline. | When you need to edit a `create-only` file, invoke the amender (or the writer that emitted it) rather than working around the gate. |
| Adding new sections to a contracted file without registering them | Body validation either silently passes (no rule for the new section) or denies (matches a prohibited pattern); future readers can't tell which sections were intentional. | Extend the contract via `/govern register` so the new section is declared and tooling can validate against it. |

## Where to learn more

- YAML frontmatter contract for the same files: [[System Governance - Frontmatter]]
- Which files are mandatory and where: [[System Governance - Mandatory-Files]]
- Slug grammar that contract path globs reference: [[System Governance - Naming]]
- How writes to a contracted file flag upstream consumers: [[System Governance - Doc-Dependencies]]
- Tag-side surface decoupled from body structure: [[System Governance - Tagging]]

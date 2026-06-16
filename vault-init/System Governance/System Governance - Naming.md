---
type: system-governance-spoke
title: System Governance - Naming
mirrors_pillar: naming
description: How the system enforces filename, slug, and path discipline — the documented vault-root structure, slug grammar, plan-tree naming conventions, gitignore at-depth, and the checklist for adding a new root.
updated: 2026-06-01
tags: ["#scope/reference"]
---

# Naming

Filenames and paths are part of the contract. The system reads them on every write — to decide whether a file belongs where it lives, to route plan-tree artifacts, and to keep operational artifacts from leaking into commit history. Naming rules are quiet most of the time; they fire at the moment a write would drift the structure, surfacing the drift before it lands.

The runtime contract is composed from the two artifacts that ship in `governance/`:

- **`foundation-master.json`** — the documented vault-root set, the single-file exemptions, the slug-grammar regex, the plan-tree conventions, and the gitignore depth rule.
- **`overlay-master.json`** — your registered top-level folders and any naming overrides. User-defined clusters live here as `frontmatter.path_routing` extensions; the system reads both pillars on every write.

## The vault-root structure

Files at the top of your vault must either live in a documented root folder or be one of a small set of exempt single files. The intent is to keep the vault's first-level shape readable and walker-discoverable.

**Foundation-shipped root folders.** Seven directories ship as documented roots:

| Folder | Purpose |
|---|---|
| `Archive/` | Past-tense content the active vault no longer needs in view. |
| `Daily/` | Daily-cadence notes if you keep that practice. |
| `Meetings/` | Meeting notes emitted by the meeting processor and manual capture. |
| `Plans/` | A window into your plan tree (`~/.claude-plans/`) — initiatives, backlog, and ideas. |
| `Skills/` | Adopter-authored skill content and assets. |
| `System Governance/` | The per-pillar spokes — including this one. |
| `Vault Writers/` | The catalog of systems that write into your vault — connectors, scheduled skills, and agentic flows. |

**User-created top-level folders.** Anything outside the foundation set — engagement folders, cluster folders, personal-initiative folders, any structural grouping your work needs — registers via `/govern register --kind folder`. The registration writes a `frontmatter.path_routing` rule into `overlay-master.json` declaring the folder's lineage fields, expected tags, and tier. Writes to the new folder then validate against the combined foundation + overlay allowlist.

**Single-file exemptions at vault root.** Exactly one foundation-shipped file is permitted as a bare file at the top of the vault:

- `CLAUDE.md` — the foundation-mandated vault-root contract (see [[System Governance - Mandatory-Files]]).

Any other vault-root file triggers a placement advisory at write time, naming the documented roots and prompting either a move or a new-root registration. (Your initiative backlog, its archive, and the idea inbox are *not* vault-root files — they live in the plans tree; see *The plans tree's own files* below.)

## Slug grammar

Every filename slug, folder slug, frontmatter `id` value, and plan-tree prefix follows the same shape: lowercase ASCII, digits, and hyphens — `[a-z0-9-]`. No spaces, no underscores in slugs, no mixed case. The convention is uniform so consumers (skills, hooks, librarian capabilities, search) can normalize identifiers without per-surface special casing.

The few places where this rule loosens are documented vault-root folders that carry multi-word human-readable names (`System Governance/`, `Vault Writers/`) and the foundation-mandated vault-root file `CLAUDE.md` — these are navigation surfaces, not slugs. Everything inside those folders follows kebab-case.

## Plan slug discipline

Plan-tree files live under `~/.claude-plans/` and carry the strictest naming contract in the vault. The plan-tree pillar enforces three rules at write time:

- **`NN-` numeric prefix.** Every plan-root folder slug starts with a creation-order numeric prefix (`38-foo`, `39-bar`). Prefixes are never backfilled — gaps from retired plans stay as gaps. The next new plan takes the integer one higher than the highest existing prefix.
- **Status marker.** Every plan's top-level doc carries one of three status surfaces: a `**Status:**` header bullet in `spec.md`, a `status:` field in YAML frontmatter, or a `status` top-level key in `manifest.json`. Files lacking a status are denied at write time; the plan-index walker would otherwise group them under "Unknown."
- **Shame-slug rejection.** Auto-generated adjective-verb-noun slugs (`async-wiggling-donut`) are denied. Plans need descriptive slugs that name the actual scope of work (`vault-system-hardening`, not the auto-generator's filler).

The system provides two sanctioned creation paths that handle all three rules in one flow:

- **`/new-plan <slug>`** — ad-hoc scaffolding. Renders the canonical quartet (`spec.md` + `tasks.md` + `handoff.md` + `00-ideation-brief.md`) and `manifest.json` from templates, assigns the next prefix, rejects shame slugs at the creation gate, and adds the backlog row.
- **`/backlog-research <item>`** — research-first creation. Same quartet, backed by triage research and feasibility analysis before the plan lands.

Bypassing both paths by hand-writing a plan directory typically fails one of the three rules. The pre-write guard exposes an explicit override (`PLAN_STATUS_OK=1`) for the rare hand-built case; the override is per-write and lands in the audit log.

## The plans tree's own files

Your vault's `Plans/` folder is a window into the plan tree at `~/.claude-plans/`. Three index files sit at the root of that tree, and the librarian maintains all three for you — you never hand-edit them:

- `_index.md` — every plan, grouped by status.
- `_backlog.md` — your unified initiative backlog (this is where the backlog lives; it is not a vault-root file).
- `_archive.md` — closed and retired initiatives.

These three are exempt from the plan-slug rules above. A half-formed idea is captured separately, in `_inbox/<slug>.md` with `type: idea` — it carries no numeric prefix (a prefix is assigned only if the idea graduates into a full plan) and a lightweight status of `new → triaged → briefed`. Running `/backlog-research` promotes an idea into a planned initiative.

## Sub-plan parent lineage

Sub-task files at depth ≥ 3 under `~/.claude-plans/` — files like `<plan>/01-<subplan>/spec.md` or any plan-state file inside an existing plan folder — carry a `parent_plan:` frontmatter field naming the top-level plan slug (no path, no extension). Plan-root files at depth 2, `handoff.md` at any depth, and files under `tests/` or `_orchestrator/` are exempt.

The convention lets plan-tree walkers resolve ancestry without parsing paths. Drift is surfaced by the librarian's plan-parent-resolve capability as a finding at audit time rather than blocked at write time, so an in-flight sub-plan reorganization isn't trapped by the gate.

## Gitignore at-depth

When you add a gitignore pattern matching a directory or filename that could appear at any depth — `Tags/`, `node_modules/`, `.DS_Store` — use the `**/` prefix (`**/Tags/`, `**/node_modules/`, `**/.DS_Store`). Bare-name patterns match only at repo root; deeper instances slip past.

The rule is documentary in the foundation today, surfaced via inline comments in the shipped `.gitignore`. The system promotes it to a pre-commit hook if drift recurs.

## Adding a new root

Adding a new documented vault-root folder is a deliberate, multi-surface change. The naming pillar carries a seven-item checklist:

1. Declare the folder's purpose (which archetype or content lives there).
2. Declare its consumer (which skill, hook, capability, or query reads this path).
3. Update the relevant `System Governance/` spoke to document the new structure.
4. Register the folder's type in `frontmatter.types` and, if it carries a foundation-shipped mandatory file, a `file_type_contracts` body-structure contract.
5. Add the folder to the naming pillar's known-roots set.
6. Add a librarian capability entry for placement-validation or walker coverage if the folder needs ongoing audit.
7. Land all the above in a single atomic commit so the surfaces don't drift.

For most adopters most of the time, a new top-level folder is a user-defined cluster that registers via `path_routing` (overlay-only) rather than a new foundation root. Foundation roots are the system substrate; user clusters are everything else.

## What happens on write

Order of checks the system runs when you write a vault file:

1. **Root-or-exempt.** A file at the top of the vault must be in a documented root folder or in the single-file exemption set. A new vault-root path surfaces a placement advisory naming the documented options.
2. **Slug grammar.** Slug-bearing path segments are checked against `[a-z0-9-]`. Mixed-case or space-bearing slugs surface an advisory.
3. **Plan-tree rules.** A write under `~/.claude-plans/` checks the `NN-` prefix, the status marker, the shame-slug regex, and (at depth ≥ 3) the `parent_plan:` lineage field. The first three deny at write time; lineage drift is librarian-audit only.
4. **Path-routing match.** A write to a user-defined folder validates against the overlay's `path_routing` rules (lineage fields, tags, tier) declared at registration time.

## Anti-patterns

| Anti-pattern | What goes wrong | Better path |
|---|---|---|
| Creating a new vault-root folder mid-session | The root is invisible to walkers, untyped, and the spoke gets stale. The placement check fires an advisory and the seven-item checklist surfaces. | Either register it as a user-defined cluster via `/govern register --kind folder` (overlay), or walk the checklist deliberately for a foundation root. |
| Hand-writing a plan directory | The write almost certainly fails one of the prefix / status / shame-slug rules; the create is denied. | Use `/new-plan` or `/backlog-research`. Both handle the prefix, the status header, the canonical quartet, and the backlog row in one flow. |
| Reusing or backfilling a plan prefix | The numeric prefix is creation-order, not execution-order. Backfilling renumbers history and breaks the plan-index's append-only audit trail. | Use the next integer above the highest existing prefix. Gaps from retired plans stay as gaps. |
| Bare-name gitignore for an at-depth directory | The pattern matches only at repo root; nested instances slip through. A production-scale gitignore bypass leaked ~100 files in a reference deployment. | Always prefix with `**/` for at-depth matching: `**/Tags/`, `**/node_modules/`. |
| Slugifying with underscores or mixed case | Consumers normalize on kebab-case; mixed-case slugs fail equality checks against frontmatter lookups; underscore slugs leak into URL-like surfaces and become ambiguous. | Use kebab-case `[a-z0-9-]` for every slug. The handful of human-readable folder names (`System Governance/`) are explicit exceptions, not a license to deviate elsewhere. |

## Where to learn more

- Frontmatter `type:` registry whose path conventions ride on this slug grammar: [[System Governance - Frontmatter]]
- Tag-grammar counterpart with the same kebab-case discipline: [[System Governance - Tagging]]
- Which files are mandatory at vault root: [[System Governance - Mandatory-Files]]
- Body-structure contracts that path globs reference: [[System Governance - File-Type-Contracts]]
- Dependency-entry `id` values that follow this slug grammar: [[System Governance - Doc-Dependencies]]

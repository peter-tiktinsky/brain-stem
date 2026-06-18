---
type: system-governance-spoke
title: System Governance - Frontmatter
mirrors_pillar: frontmatter
description: How the system reads YAML frontmatter on every vault file — the three compliance tiers, the foundation type registry, the folder-lineage convention, and how foundation defaults combine with your overlay at write time.
updated: 2026-06-12
tags: ["#scope/reference"]
---

# Frontmatter

Frontmatter is the YAML block at the top of every vault file. The system reads it on every write to decide whether the file is well-formed and where it belongs. Fields like `type`, `tags`, and `updated` are not decoration — they are the structured handles by which Claude routes, the librarian audits, and capture pipelines stay coherent. Tags are the user-side query surface (see [[System Governance - Tagging]]); frontmatter fields are the structured surface the system reads.

The runtime contract is composed from two artifacts that ship in `governance/`:

- **`foundation-master.json`** — the default rules, types, and field requirements every adopter receives.
- **`overlay-master.json`** — your extensions and overrides. Ships empty; populated over time by the `/govern register` flow.

At every write the system reads both, merges them, and applies the union as the live contract. Foundation defaults provide the baseline; your overlay extends the type registry, declares new folder-lineage rules, and shadows foundation defaults where you have registered an override.

## The three compliance tiers

Every file type carries a tier. The tier determines what the system does when a write fails its contract.

| Tier | Behavior on failure | Default class of files |
|---|---|---|
| **Strict** | Write is denied; the missing fields are reported back. | System-emitted files — scaffold output, captured content, scraper output, anything written by skills without a human in the loop. |
| **Standard** | Write proceeds; the system surfaces an advisory you can review at session close. | User-authored vault content — your own notes, references, planning docs. |
| **Minimal** | Write proceeds without validation. | Explicit opt-out for legacy imports, paste-buffer scratch, archived content outside the active lifecycle. |

Tier assignment is per-type, not per-file. Foundation types run at Strict — most because they're system-emitted (meeting notes from the meeting processor, log files from Claude scratch, mandatory spokes, etc.); the `deliverable` type is Strict because its lifecycle fields (`project`, `status`, `audience`) are load-bearing even though you author it by hand. User-authored types you register through your overlay typically run at Standard. To put a single file under Minimal validation, add `tier: minimal` to its frontmatter.

## The foundation type registry

Foundation ships a small set of types — only those that have a foundation consumer (a hook, a skill, a mandate, or a contract). Everything else is left to your overlay so you can shape your own vault vocabulary.

| Type | Tier | Required fields | Canonical home |
|---|---|---|---|
| `index` | Strict | `type`, `tags`, `updated` (+ `parent_folder` at folder depth ≥ 2) | every non-exempt folder's `_index.md` |
| `system-governance-spoke` | Strict | `type`, `title`, `mirrors_pillar` | `System Governance/` |
| `meeting-note` | Strict | `type`, `date`, `meeting_title`, `attendees`, `tags`, `processed`, `updated` | `Meetings/` |
| `vault-writer` | Strict | `type`, `writer_name`, `writer_kind`, `writer_skill`, `destinations`, `status`, `created`, `updated`, `tags` | `Vault Writers/` |
| `log` | Strict | `type`, `log-type`, `date`, `timestamp` | — (machine logs write off-vault to the XDG state tier) |
| `ideation-brief` | Strict | `type`, `title`, `created`, `updated` | plan-tree (`~/.claude-plans/<plan>/00-ideation-brief.md`) |
| `reference` | Strict | `type`, `tags`, `updated`, `routing`, `sources`, `originating_plan` | `_library/` |
| `deliverable` | Strict | `type`, `tags`, `updated`, `project`, `status`, `audience` | `Work/` |

Three fields are universal across every Strict type: `type`, `tags`, `updated`. The other entries declare additional required fields per their purpose (a meeting note needs attendees and a date; a writer descriptor declares its source and destinations; a log file declares its operational subtype; a reference article declares the `routing:` line that says when to read it, the `sources:` it was synthesized from, and the `originating_plan:` that promoted it; a deliverable declares the `project:` it belongs to, its `status:` in the draft→delivered→superseded lifecycle, and its `audience:`).

The `reference` type is the durable knowledge-library article — one concept per file, synthesized and kept current by the librarian, scrubbed of plan- and project-specific detail so it reads as universal. A reference article carries no leading in-document section index and no auto-generated table of contents; its body shape is checked by the librarian's library scans, not at write time.

The `deliverable` type is durable, human- or agent-authored work product under the `Work/` surface — the durable + human-authored context surface that the generated binder, the generated library, and the ephemeral workshop do not fill. Its contract is deliberately thin: it governs the lifecycle frontmatter only and leaves the body free-form, because deliverables are heterogeneous (a brief, a deck source, a memo, and a long report share no shape). You author deliverables from a work-spoke launch (`cd ~/work/<spoke>`), so they live outside the vault root and no write-time guard fires on them; the librarian audit suite enforces the type over the `Work/` symlink view instead. Per-deliverable-kind structure (a fixed report skeleton, say) is an archetype subtype you add through your overlay, not part of this base type.

Plan-tree files other than `ideation-brief` — `spec.md`, `tasks.md`, `handoff.md`, `manifest.json` — are governed by the plans pillar, not by this registry. They have their own body-structure contracts and write-time rules; the plans pillar's slice in `foundation-master.json` carries them.

## Extending the type registry

When your vault accumulates a kind of document the foundation doesn't ship a type for — a recurring document body your work produces, a domain-specific variant, anything you'd like the system to validate at write time — register it via `/govern register --kind file-type`. The registration writes a new entry into `overlay-master.json` under `frontmatter.types`, declaring its required fields and (optionally) a canonical folder pattern. The next write that uses the new type validates against the combined foundation + overlay registry.

To override a foundation default — for example, raising the `max_lines` cap on an `index` file — register the same type in your overlay with an `_override_reason` field stating why. The system denies overlay overrides that don't carry the reason, so every divergence travels with its rationale.

## The folder-lineage convention

Folders don't carry frontmatter, so any lineage that lives at folder level — *which cluster is this file part of, which sub-cluster within that cluster* — has to propagate down to the file's frontmatter. The convention: when a file lives inside a structural cluster folder, it carries both the matching frontmatter field and the matching tag.

Foundation ships the *shape* of folder-lineage rules but not the content. Your `path_routing` rules — declared in your overlay during onboarding — define the cluster grammar for your vault (which top-level folders, which sub-folders, which lineage fields). The system validates this on write: a file under a cluster path without matching lineage fields surfaces a placement advisory at write-time and audit-time.

The shape of a path-routing rule includes the path glob, the required lineage fields, the required tags, the tier (Strict deny / Standard warn), and any exempt sub-paths (a folder-level navigation or index file legitimately doesn't carry the lineage of a child file).

## What happens on write

The order of checks the system runs when you write a vault file:

1. **Type allowlist.** The `type:` value must be in the combined foundation + overlay registry. On a Strict-tier write, an unknown type is **denied** — the error names the allowed types and points you to `/govern register --kind file-type` to add a new one. A Standard-tier write proceeds with a warning instead (the tiers are explained above).
2. **Required fields.** Universal fields (`type`, `tags`, `updated`) plus the per-type required list must all be present. Missing fields on a Strict type are denied with the list of what to add.
3. **Folder placement.** If the type declares an expected folder pattern, the system checks whether the file matches it. If not, you get an advisory naming the expected folder — the write proceeds, because cross-folder reference docs and adopter-customized structures legitimately diverge.
4. **Folder-lineage fields.** If the file's path matches a folder-lineage rule from your overlay, the required lineage fields and tags must be present. Missing lineage is denied at Strict tier and surfaces an advisory at Standard.
5. **`provides:` presence.** Files over 200 lines that participate in the vault's canonical-scope should declare a `provides:` array naming the concepts the file is canonical for. Missing on a long canonical file surfaces an advisory.

The librarian's coverage audits walk the vault periodically and surface recurring drift — types whose required-field lists you've been declining to fill, folders accumulating placement-advisory files, capabilities that two canonical files both claim to provide. The advisories surface at session close; you triage.

## Anti-patterns

| Anti-pattern | What goes wrong | Better path |
|---|---|---|
| Treating frontmatter as decoration | The fields drive routing, lifecycle, and consumer queries. Without them the file is opaque to the system. | Run the routing skill on manual files; it infers and applies. For generated files, the writer applies frontmatter at capture time. |
| "I'll add frontmatter later" | Defers indefinitely; the file never gets it; the audit trail loses the lineage permanently. | The system writes frontmatter on every emission. Strict-tier writes are denied without it — the friction is at the moment of capture, where the cost to add fields is lowest. |
| Custom freeform fields per-file | `priority`, `urgency`, `client_facing` added ad-hoc; no consumer reads them; the field set fragments. | Frontmatter fields are a closed vocabulary per type. Adding a field requires registering the extension in your overlay so consumers can read it. |
| Skipping frontmatter on short files | A short note feels heavy with full frontmatter. | The Standard tier exists for user-authored content; the required fields are still `type`, `tags`, `updated`. If the file is genuinely outside the system, opt out to Minimal explicitly. |
| Bumping `updated:` by hand | A user touches the body but forgets to update the timestamp. | The post-write hook touches `updated:` automatically on every edit. Manual filesystem edits that bypass the hook surface as freshness drift at audit. |

## Where to learn more

- Tag-side counterpart of the field/tag dichotomy: [[System Governance - Tagging]]
- Slug grammar for field values: [[System Governance - Naming]]
- How `_index.md` and `CLAUDE.md` are mandated: [[System Governance - Mandatory-Files]]
- Per-file body-structure rules (sentinel tables, section requirements): [[System Governance - File-Type-Contracts]]
- How writes to one file flag updates to upstream consumers: [[System Governance - Doc-Dependencies]]

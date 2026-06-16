---
type: system-governance-spoke
title: System Governance - Tagging
mirrors_pillar: tagging
description: How tags work in your vault — the hierarchical grammar, the two classes of dimension (system-utility vs user-facing), the 25-value cap, and how foundation defaults combine with your overlay at write time.
updated: 2026-05-22
tags: ["#scope/reference"]
---

# Tagging

Tags are the user-side query surface of the vault. Where frontmatter fields are the structured handles the system reads (see [[System Governance - Frontmatter]]), tags drive the Obsidian graph view, the filter pane, and the maps-of-content patterns you use to navigate your own work. The two surfaces are decoupled by design — a file is legible to the system through its frontmatter even if it carries no tags, and a file is legible to you through its tags even if you read nothing else of its frontmatter.

The runtime tag contract is composed from the two artifacts that ship in `governance/`:

- **`foundation-master.json`** — the default tag grammar, the system-utility dimensions, and the 25-value cap.
- **`overlay-master.json`** — your registered dimensions and tag-cap overrides. Ships empty for user-facing dimensions; populated over time via `/govern register --kind tag-extension`.

At every write the system reads both, merges them, and applies the union as the live contract.

## The tag grammar

Every tag matches the hierarchical pattern `#dimension/value`:

- **Dimension** — a registered prefix in the runtime allowlist. The dimension declares the *kind* of metadata the tag carries.
- **Value** — a kebab-case slug matching `[a-z0-9-]`. The value is the specific term within the dimension.

The full grammar foundation ships is `^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$`. Tags that fail the regex, or that start with a dimension not in the runtime allowlist, are denied at write time. The denial enumerates the non-conforming tags so you can either pick from the registered vocabulary, omit the tag, or register the new dimension.

The system rejects flat freeform tags (`#urgent`, `#priority-high`) by construction. A flat namespace fragments within months at any scale; the dimension prefix keeps related values clustered and the taxonomy queryable.

## Two classes of dimension

The taxonomy distinguishes two kinds of dimension by who emits them.

| Class | What it is | Foundation ships |
|---|---|---|
| **System-utility** | Dimensions that machine-emitted writers populate. Their values are operational, not subjective. | `status`, `log` — used by skills, hooks, and cron-driven routines to mark file lifecycle and operational subtypes. |
| **User-facing** | Dimensions you populate as you author and curate vault content. Their values describe the shape of your work. | None. Foundation ships the shape and the cap; your overlay populates the concrete dimensions during onboarding. |

The split exists because the two classes have different stewardship and different drift modes. System-utility values come from skills with stable vocabularies — fragmenting them into near-match variants would split the operational graph. User-facing values come from you and grow with your work — locking them at install time would force the foundation to guess your domain.

## The system-utility dimensions and the log-subtype registry

Foundation ships two system-utility dimensions: `#log/*` for operational log artifacts and `#status/*` for lifecycle markers. Both are cap-exempt — they aren't part of the 25-value working-memory budget because their values are machine-emitted rather than recalled.

System-utility values are governed by the log-subtype registry. The registry carries the canonical value for each registered subtype, the owning skill or cron, and the date of first emission. Two protections apply:

1. **Near-match denial.** A write proposing a system-utility value within Levenshtein distance 2 (or a substring containment match) of an existing canonical value is denied with a `did you mean #<dim>/<canonical>?` suggestion. Two runs of the same routine cannot diverge into variant spellings.
2. **Explicit first-emission registration.** A genuinely new subtype lands through a prompt-and-commit at the moment a skill first emits it. The registry update is part of the same change that introduces the emission.

## User-facing dimensions and the 25-value cap

User-facing dimensions are declared in your overlay. The `/govern register --kind tag-extension` flow walks you through naming a dimension, declaring its purpose, and seeding canonical values. Onboarding seeds the initial set based on the shape of your work — the axes you slice by, the scopes that recur.

The total count of distinct values across all user-facing dimensions stays under **25**. The cap is structural, not aspirational:

- System-utility dimensions (`status`, `log`) are exempt — they don't count against the budget.
- An advisory fires at audit time when user-facing usage reaches 80% of the cap (≥ 20 active values), surfacing consolidation candidates so you can retire dead values before the cap binds.
- Raising the cap requires a deliberate `tagging_cap_override` entry in your overlay with a written rationale. The system denies silent widening — the override is visible in the audit trail.

The 25-value ceiling is the working-memory limit on faceted vocabularies: past it, decision fatigue produces variant-creation rather than canonical-term selection, the vocabulary fragments, and your own recall collapses.

## Extending the taxonomy

When you need a new user-facing dimension, run `/govern register --kind tag-extension`. The registration writes an entry to `overlay-master.json` under `tagging.taxonomy.dimension_prefixes` (and `tagging.taxonomy.user_facing_dimensions` for the user-facing list). The next write that uses the new dimension validates against the combined foundation + overlay allowlist.

To override a foundation default — for example, to raise the cap or to redirect a system-utility dimension to a custom registry — register the same key in your overlay with an `_override_reason` field stating why. The system denies overlay overrides that don't carry the reason.

## The folder-mirrors-tag invariant

The folder a file lives in and the tags it carries are coupled by convention. When a file sits in a structural cluster folder, its tag set carries the dimension/value pair corresponding to that cluster. A meeting note in `Meetings/` carries a meeting-scope tag; a file in a user-defined cluster folder carries the cluster's tag.

The invariant has two halves. The frontmatter pillar enforces the field side of the lineage (see [[System Governance - Frontmatter]] — the folder-lineage convention); the tagging pillar enforces the tag side. Together they keep the folder hierarchy and the tag taxonomy aligned: when you move a file across clusters, both the lineage fields and the lineage tags follow.

Files in foundation-exempt paths — archive surfaces and system infrastructure paths — are exempt from the tag-presence advisory by construction.

## What happens on write

The order of checks the system runs when you write any vault file:

1. **Grammar.** Every tag in the file's frontmatter must match the hierarchical regex. Failing tags are denied.
2. **Dimension allowlist.** Every tag's dimension must be in the runtime allowlist (foundation + overlay union). Unknown dimensions are denied with a registration suggestion.
3. **System-utility canonical-value check.** Tags under `#log/*` or `#status/*` must match a value in the log-subtype registry. Near-match writes are denied.
4. **Tag presence.** Non-exempt files without a tag surface a tag-presence advisory. The advisory never blocks the write — its job is to flag potential graph-view orphans at the moment of capture.
5. **Cap watch.** The librarian counts distinct user-facing values at audit time; usage at 80% of the cap surfaces a consolidation prompt.

## Anti-patterns

| Anti-pattern | What goes wrong | Better path |
|---|---|---|
| Using freeform tags (`#urgent`, `#priority-high`) | The grammar denies the write at hook time; the tag never lands. Even if it did, the flat namespace fragments and the graph degrades. | Register the dimension first via `/govern register --kind tag-extension`. The dimension/value structure keeps the vocabulary faceted. |
| Inventing new `#log/*` or `#status/*` values inline | The near-match check denies values within distance 2 of an existing canonical. Even fresh values are wrong here — system-utility dimensions are skill-owned, not user-authored. | Let the owning skill register the subtype at first emission. User-authored operational tags belong in a user-facing dimension. |
| Raising the 25-cap silently | The hook denies the override without `_override_reason`. The cap reflects working-memory research, not an arbitrary number. | Triage the existing dimensions first — the 80% advisory surfaces retire-candidates. If you genuinely need the cap raised, do it with a written rationale in the overlay. |
| Treating an empty tag set as failure rather than signal | A non-exempt file without tags isn't broken — it's surfacing that the file's routing wasn't deliberate. | Triage at the moment of capture: pick from the registered vocabulary, register a missing dimension, or relocate the file to an exempt path. |
| Tags carrying lifecycle that belongs in a frontmatter field | Tags duplicate `processed:` or `status:` field values for query convenience; the tag and the field drift. | Let the post-write hook mirror the canonical field into a tag (the convention for `#status/processed`). Don't dual-author. |

## Where to learn more

- Structured-field counterpart of the field/tag dichotomy: [[System Governance - Frontmatter]]
- Slug grammar that tag values follow: [[System Governance - Naming]]
- Folder mandates the tag invariant rides on: [[System Governance - Mandatory-Files]]
- File-body contracts that tags interact with at write time: [[System Governance - File-Type-Contracts]]
- Content-coupling registry decoupled from this tag surface: [[System Governance - Doc-Dependencies]]

---
type: system-governance-spoke
title: System Governance - Doc-Dependencies
mirrors_pillar: doc-dependencies
description: How the system tracks content that lives in more than one place — the three dependency classes, the upstream-consumer prompt at write time, and how foundation defaults combine with your overlay.
updated: 2026-05-22
tags: ["#scope/reference"]
---

# Doc-Dependencies

A doc-dependency is a registered relationship between two or more files whose content is coupled by design — a writer that emits to a shared destination, a hub whose spokes carry extracted sections, a folder whose membership is mirrored in an index. When you write to one side of a registered relationship, the system surfaces the others so you can keep them coherent in the same session instead of discovering the drift later.

The mechanism is a single advisory: at every write the system checks whether the target appears in any dependency entry. If it does, the hook injects "this write touches a registered dependency — here are the related files" alongside the write decision. The advisory never blocks the write. Its job is to put the dependency in front of you at the moment of edit, when the cost to keep both sides synchronized is lowest.

The runtime contract is composed from the two artifacts that ship in `governance/`:

- **`foundation-master.json`** — the default dependency registry every adopter receives.
- **`overlay-master.json`** — your registered extensions and overrides. Ships empty; populated over time via `/govern register --kind doc-dep`.

The system reads both on every write and applies the union. Foundation provides the minimum baseline; your overlay declares the dependencies that exist in your vault's particular structure.

## The three classes of dependency

Every entry declares a `kind`. Three classes cover the patterns the system recognises:

| Class | `kind` | What it captures | Default posture |
|---|---|---|---|
| **Writer fan-in** | `writer-fan-in` | A destination file is the convergence point of multiple writers. The destination's amendment is driven by the registered strategy (prompt-guided-amend, replace, append). | Actively leveraged by the doc-amender: when a writer emits, the amender consults the entry to decide how to merge. |
| **Cross-file mirror** | `hub-spoke-cascade`, `cross-file-type-union` | Two files (or a hub and N spokes) carry extracted sections of the same authoritative content. Editing one without the other creates drift. | Static advisory at write time. The hook surfaces the mirrors; you review and update them in the same session, or file a waiver via `cascade_waiver_write`. |
| **Directory listing** | `directory-membership-cascade`, `directory-listing-mirror` | A folder's children are enumerated in an index file at the folder root or in a parent catalog. Adding or removing a folder member should update the enumeration. | Mechanical advisory at write time. The hook flags the enumerating file as the mirror to review. |

The classes differ in how much the system can act for you. Writer fan-in is the strongest: the doc-amender carries enough structured intent to merge writes against the existing content. The mirror and listing classes are advisory only — the system can't know which lines of the spoke correspond to which lines of the hub, so it surfaces the relationship and lets you reconcile.

## The foundation entry set

Foundation ships dependencies only for relationships that exist in every adopter's vault by virtue of the system itself. Everything else is overlay territory.

| Entry | Class | Shape |
|---|---|---|
| `meetings-fan-in-reference` | writer-fan-in | `Meetings/<meeting-note>.md` is the destination of `meeting-processor` + `teams-scrape` + `gchat-scrape`; doc-amender applies `prompt-guided-amend`. |

That is the entire foundation set. Every other relationship in your vault — the spoke pairs you maintain, the cluster directories you enumerate in an index, the catalog rows that mirror a per-row history file — is registered in your overlay as you encounter the cases.

## Extending the registry

When you find yourself editing the same content in two places without the system reminding you, register the relationship via `/govern register --kind doc-dep`. The registration writes an entry to `overlay-master.json` under `doc_dependencies.entries[]`. The next write that matches the relationship surfaces the advisory.

To override a foundation entry — for example, to widen the amender strategy on `meetings-fan-in-reference` because your meeting note shape differs from the default — register the same `id` in your overlay with an `_override_reason` field stating why. The system denies overlay overrides that don't carry the reason.

The shape of an entry depends on its class. The shape table in foundation-author docs and the inline help on `/govern register` will walk you through which fields apply to which `kind`. The common contract: every entry declares an `id`, a `kind`, and one or more references to the files it relates. Some classes (`writer-fan-in`) also declare an amendment strategy; the mirror and listing classes declare which file plays which role.

## What happens on write

Order of checks the system runs when you write any file under the vault:

1. **Registry match.** The system reads `doc_dependencies.entries[]` from the union of foundation + overlay and checks whether the write target matches any entry — by `primary` path, by membership in a `mirrors[]` array, by membership in a `primary_dir` directory, or by being the `consumer` of a writer-fan-in entry.
2. **Class-specific routing.** A writer-fan-in match dispatches to the doc-amender, which reads the amendment strategy and merges accordingly. A mirror or listing match composes the advisory message naming the related files.
3. **Advisory emission.** If any match fired, the hook injects the advisory into the write decision. The decision itself proceeds (no block), but the related-files list now travels with the session.
4. **Session-close audit.** At session close the librarian re-checks every advisory the session surfaced. If a match fired and the related file was not edited in the same session, the librarian records a cascade-pending finding for review.

A cascade waiver lets you proceed without touching the related file when you have a reason: `source ~/.claude/hooks/cascade-waiver.sh && cascade_waiver_write <entry_id> "<reason>"`. The waiver lands in the run log so the audit trail carries why the divergence is intentional.

## Anti-patterns

| Anti-pattern | What goes wrong | Better path |
|---|---|---|
| Registering every duplicate as a dependency | The advisory feedback loop becomes noise; you train yourself to dismiss the prompts. | Register dependencies only when the content is authoritatively duplicated by design. Casual copy-paste that you wouldn't keep synchronized doesn't belong in the registry. |
| Hand-editing `overlay-master.json` for new dependencies | Direct overlay writes bypass the `_override_reason` collision check when shadowing a foundation entry; bookkeeping for the `id` namespace falls to you. | Use `/govern register --kind doc-dep`. The skill handles `id` uniqueness, the kind-specific schema, and the override-reason requirement. |
| Suppressing the cascade by deleting the entry instead of waiving | The registry now no longer reflects the relationship; future writes lose the advisory permanently; the audit trail of why the cascade was bypassed is gone. | File a waiver. The registry stays accurate, the waiver carries the explanation, and the next write that genuinely needs the cascade still gets the advisory. |
| Treating a directory-listing entry as a writer-fan-in | The doc-amender attempts to merge an index file as though it were a writer destination; the merge produces nonsense. | Match `kind` to the actual relationship. A folder enumerated in an index file is `directory-membership-cascade`; only a destination that receives structured emissions from named writers is `writer-fan-in`. |

## Where to learn more

- Frontmatter contract that flags `provides:` for canonical-scope coverage: [[System Governance - Frontmatter]]
- File-type contracts that govern the shape of a dependency's endpoints: [[System Governance - File-Type-Contracts]]
- Mandatory-files contract that requires certain mirrors (e.g., `_index.md` per folder): [[System Governance - Mandatory-Files]]
- Slug grammar that dependency-entry `id` values follow: [[System Governance - Naming]]
- Tag-side surface decoupled from this content-coupling registry: [[System Governance - Tagging]]

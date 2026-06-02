---
type: index
tags: ["#system-governance"]
updated: 2026-06-01
description: "Index of the System Governance cluster — the narrative mirror of the foundation governance pillars."
---

# System Governance

This folder is the human-readable narrative mirror of the foundation's governance pillars (frontmatter, tagging, naming, mandatory-files, file-type-contracts, doc-dependencies). The machine source of truth lives in `~/.claude/governance/*.json`; these spokes explain the rationale, edge cases, and conventions a reader needs to understand WHY each rule exists. This `_index.md` is the cluster's mandatory navigation entry-point and the idempotency marker the vault scaffolder (`build-brain-vault.sh`) checks to recognise a brain-stem-built vault.

<!-- contents-enum:start -->
| File | Lines | Type | Description |
|---|---|---|---|
| [[System Governance - Frontmatter.md]] | 92 | reference | How the system reads YAML frontmatter on every vault file — the three compliance tiers, the foundation type registry, the folder-lineage convention, and how foundation defaults combine with your overlay. |
| [[System Governance - Tagging.md]] | 104 | reference | How tags work in your vault — the hierarchical grammar, the two classes of dimension, the value cap, and how foundation defaults combine with your overlay. |
| [[System Governance - Naming.md]] | 126 | reference | How the system enforces filename, slug, and path discipline — the documented vault-root structure, slug grammar, the plans tree's own files, and the checklist for adding a new root. |
| [[System Governance - Mandatory-Files.md]] | 93 | reference | How the foundation mandates certain files exist — the vault-root CLAUDE.md, the per-folder _index.md, the two exemptions, and the maintenance architecture that keeps the mandates upheld. |
| [[System Governance - File-Type-Contracts.md]] | 108 | reference | How the system enforces body-structure rules — line caps, required sections, write shapes — on specific kinds of files, and how your overlay extends or shadows foundation contracts. |
| [[System Governance - Doc-Dependencies.md]] | 79 | reference | How the system tracks content that lives in more than one place — the dependency classes and the upstream-consumer prompt fired at write time. |
<!-- contents-enum:end -->

> These six narrative spokes mirror the six foundation governance pillars. The machine-readable rules they describe live in `~/.claude/governance/*.json`; the spokes are the human-readable companion that explains the reasoning behind each rule.

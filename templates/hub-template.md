---
type: index
parent_folder: _projects
tags: ["#projects/<spoke>"]
updated: <YYYY-MM-DD>
---

# <spoke> — Hub

<!--
SHAPE CONTRACT — governance/file-type-contracts/_index.md.json (C-IDX type: index)
+ C-HUB (R-BIND-1, the binder hub.md contract). Maintainer: librarian.

hub.md is the ONLY eager binder surface and the import TARGET — the spoke project
CLAUDE.md imports this file via its own import directive. That directive line lives
in the spoke CLAUDE.md, NEVER inside hub.md (an import directive here is a defect:
import is CLAUDE.md-only Claude Code behavior). hub.md is POINTER-ONLY and fits a
<=200-line budget (size_limits {max_lines: 200}, enforced by the librarian scan, not
write-time). EXCLUDED: inline research summaries, decision bodies, full task lists,
session history. Exactly 8 pointer-only blocks, in the order below (the Deliverables
block joins the binder to the spoke's work product; Import relationship stays last as
the structural meta-block). hub.md is template-scaffolded then hand-maintained — no
librarian capability generates it (the binder generators write research-index.md /
decision-log.md / handoff-chronicle.md, which this hub points at, never hub.md), so
this template is the propagation surface for the block set.
-->

## 1. Project identity

- **Spoke:** <spoke>
- **Plans:** <plan-id(s)>
- **Status:** <active | on-hold | closed>

## 2. Active research

- Research surface: [research-index.md](research-index.md)
- Active SoT: <pointer to the active research SoT, if any>

## 3. Decision log

- [decision-log.md](decision-log.md)

## 4. Handoff chronicle

- [handoff-chronicle.md](handoff-chronicle.md)

## 5. Library references

- [[<topic>/<article-one>]]
- [[<topic>/<article-two>]]
- [[<topic>/<article-three>]]

## 6. Global rules

- The two generic `rules/` entries (binder pointer + pre-research library-check fallback).

## 7. Deliverables

- Polished work product for this spoke: `~/work/<spoke>/deliverables/` (browsable in the vault as `Work/<spoke>/deliverables/`).
- Joined on `project:` — deliverables group by spoke and surface across every plan of that spoke, surviving any single plan's lifecycle. (Pointer-only; deliverable bodies are read on-demand, never inlined here.)

## 8. Import relationship

This file is the import target: the spoke CLAUDE.md imports it via its own import
directive. (That directive lives in the spoke CLAUDE.md, not here — import is
CLAUDE.md-only Claude Code behavior.)

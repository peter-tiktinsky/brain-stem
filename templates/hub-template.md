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

hub.md is the curated, pointer-only binder cover, read ON DEMAND — nothing imports it.
The eager binder orientation is the force-ingested situating card (_situating.md),
loaded automatically at session start; hub.md is the curated depth the reader opens
when they need it. No import directive belongs inside hub.md (it would be a defect:
import is CLAUDE.md-only Claude Code behavior, and nothing imports the binder hub). hub.md
is POINTER-ONLY and fits a
<=200-line budget (size_limits {max_lines: 200}, enforced by the librarian scan, not
write-time). EXCLUDED: inline research summaries, decision bodies, full task lists,
session history. Exactly 8 pointer-only blocks, in the order below (the Deliverables
block joins the binder to the spoke's work product; Import relationship stays last as
the structural meta-block, now documenting that the hub is read on-demand, not imported).
hub.md is template-scaffolded then hand-maintained — no
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

This file is read ON DEMAND — nothing imports it. The eager binder orientation is
the force-ingested situating card (`_situating.md`), loaded automatically at session
start; open this cover for the curated depth the card does not carry. On the work
side, the spoke's `CLAUDE.md` auto-loads its own "what lives where" directory map —
it does not import this binder hub.

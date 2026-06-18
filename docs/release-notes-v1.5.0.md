# Release notes — v1.5.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.5.0 is a feature release.** It adds a fourth first-class *context surface* — `work/` — for deliverable-centric work, alongside the surfaces you already have for projects, your wiki, and your plans. A "context surface" is just a top-level area of your vault that the assistant knows how to organize and reason about. The release also tidies the installed foundation by removing three unused placeholder files and an empty meeting folder.

---

## Why this matters

Not all knowledge work is code, and not all of it is a "project" in the software sense. A lot of it is **deliverables** — a brief, a memo, a report, a deck — produced for an audience, revised through a lifecycle, and eventually handed off. Until now brain-stem had no dedicated home for that kind of work. `work/` gives it one: a place where each piece of work is a *spoke* (its own folder) with the same governed-markdown discipline — frontmatter, indexing, a cover page — that the rest of your vault already enjoys, plus a clean path from markdown to a shareable `.docx` or PDF.

Crucially, `work/` is built as a **substrate you can extend.** A future "archetype" package — say a consulting work-structure with statements-of-work, correspondence, and per-client folders — can layer its own structure on top *without modifying anything brain-stem installs.* This release ships the generic base and the documented contract that makes such packages possible.

---

## Who this affects

- **People who produce deliverables** (consultants, analysts, writers, PMs) get a real home for that work, with markdown as the durable source of truth and one-command export to Word/PDF.
- **People who only write code** lose nothing: `work/` is a recommended convention for non-code work, not a requirement, and code stays under `~/Code/` as before.
- **People extending or evaluating brain-stem** get a documented extension-seam contract and a reference add-on showing how to build on the platform without forking it.

There is **one small thing to know** if you upgrade (see *Upgrading*, below): three placeholder template files and an empty `Meetings/` folder are no longer installed. If you never edited them, the upgrade removes them cleanly; if you did edit them, your edited copies are preserved.

---

## What changed

### Added

- **A `work/` context surface.** A new recommended parent for deliverable-heavy work. brain-stem resolves its location the same way it resolves every other root — an environment override first, then your manifest, then the `~/work` default — and surfaces it into your vault as a `Work/` view you can browse in Obsidian. Each spoke under `work/` automatically gets its own per-spoke memory, so the assistant keeps separate working context per piece of work.
- **A `deliverable` file type.** A universal vocabulary for deliverables. It is deliberately *thin*: it governs only the frontmatter lifecycle — `status` moves `draft → delivered → superseded`, and `audience` is `internal` or `external` — and leaves the body free-form, because a one-page brief and a forty-page report should not be forced into the same template.
- **A `deliver-export` skill.** Turns a markdown deliverable into a `.docx` or PDF using Pandoc, with an optional slot for a branded reference document. Your markdown stays the single source of truth; the exported file is a write-once artifact that is never committed to git or edited back into your notes. (For branded slide decks, the skill points you to the dedicated deck tooling rather than producing weak slides itself.)
- **A `Deliverables` block on each spoke's cover page (`hub.md`)**, joining the spoke to your plan binder on the shared `project:` slug, so deliverables surface across every plan of that project.
- **A documented extension-seam contract** (`extension-seams`) describing the four ways an archetype add-on package extends `work/` — folder scaffolding, overlay governance, starter templates, and recipe composition — without touching the foundation, plus a generic `project-workspace` add-on that proves the contract.

### Changed

- **The `audience` vocabulary is archetype-neutral.** The base type ships `internal | external`. Domain-specific values — for example `client` for consulting work — are added by an add-on package as an overlay refinement, so the foundation stays universal.

### Removed

- **Three unrendered placeholder templates** — `prd`, `context`, and `updates` — are no longer installed. They were placeholder files with no renderer behind them, so every install previously shipped three inert files. They now live in the `project-workspace` add-on, which can seed them as named starter files when you opt in.
- **The empty `Meetings/` seed folder and the meeting-note ingestor script** are removed from the installed foundation. **The `meeting-note` file type and its rules are unchanged and still ship** — only the empty seed folder and the ingestor are removed (and preserved for a future meeting-oriented add-on).

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow). The upgrade:

- **adds** the `work/` resolver, the `Work/` vault view, the `deliverable` type and its rules, and the `deliver-export` skill;
- **removes** the three placeholder templates and the empty `Meetings/` seed folder **only if you never edited them** — brain-stem fingerprints every file it installs, so a file you customized is left untouched and reported, never silently deleted;
- **does not touch** your existing notes, plans, projects, or wiki.

If you do not produce deliverables, you can upgrade and simply ignore `work/`; nothing about your current workflow changes.

---

## In one sentence

brain-stem now has a governed home for the deliverables you produce — not just the code you write and the projects you run — with markdown as the source of truth, one-command export, and a clean way for specialized add-ons to build on top.

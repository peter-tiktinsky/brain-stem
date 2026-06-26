# Release notes — v1.9.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.9.0 is a feature release about self-orientation.** When you open a session inside a project — whether that is a work project under `~/work/` or the *binder* that tracks one of your plans — brain-stem now hands the assistant a current, auto-generated **situating brief** the instant the session starts, instead of letting it begin cold. The brief is generated from what is actually on disk, force-fed into the session at startup, and kept current automatically. Alongside it, the per-project `CLAUDE.md` that brain-stem maintains for your work projects is now a thin identity file with an **auto-maintained map of the project** instead of something you keep up to date by hand, and the folders inside a work project grow their own indexes on their own. Everything in this release is additive and automatic: you hand-edit nothing, and nothing you already have is disturbed.

---

## Why this matters

brain-stem already governs your vault, your work projects, and your plans. But until now, *starting a session* in one of those places told the assistant almost nothing. Open a terminal inside a work project and the assistant saw a folder; open one against a plan and the binder page it was told to read had never actually been created, so every fresh session began with a guaranteed miss. The result was the same cold start every time: the assistant had to be re-told where it was, what the project contained, and what was in flight.

**v1.9.0 closes that gap.** The moment a session starts in a known project, brain-stem resolves where you are, regenerates a short situating brief from the current state on disk, and feeds it straight into the session — so the assistant self-orients before you type anything. The brief carries only the things a machine can derive correctly (what the project contains, what is active, the latest handoff headline, where to look next); the curated, judgement-bearing pages stay exactly where they were, read on demand. Nothing in the brief is something you write or maintain.

---

## What you get

- **A session that orients itself.** Launch a session inside a registered work project (`~/work/<project>`) or against a plan's binder, and a freshly generated situating brief is handed to the assistant at startup. It is regenerated from disk every time, so it is never stale, and it is deliberately small so it costs almost nothing to load.
- **A binder page that actually exists.** When you register a project or plan, brain-stem now creates its binder cover page at registration time. Previously the assistant was pointed at a page that was never minted; now the page is there from the start.
- **A work-project `CLAUDE.md` that maintains itself.** The per-project config brain-stem keeps for each work project is now a thin identity file plus an **auto-maintained map of the project's folders**, regenerated from what is actually on disk. You no longer keep a project map current by hand — and if you have added your own notes to that file, they are left in place.
- **Folders that index themselves.** Inside a work project, the `deliverables/` and `reference/` folders (and each sub-project's own folders, in a master project) now grow and keep their own `_index.md` listings automatically.
- **All of it stays current on its own.** The situating brief, the project map, and the folder indexes are refreshed automatically — when a session ends, when the next one starts, when you register or grow a project, and when a plan's tracking file is written. There is no command to remember and nothing to schedule.

---

## How it stays honest

There is no new governance engine here and no new thing for you to run. brain-stem distinguishes between two kinds of content and treats them differently: the parts a machine can derive correctly — a project's folder map, the situating brief, folder indexes — are **generated** and kept current for you; the parts that need judgement — your cover pages, your notes, your deliverables — are never machine-written and are only ever read on demand. The generated files are clearly marked as generated and are kept inside the project's own scaffolding; your authored content is never overwritten, and a project you have already set up keeps whatever you have already put in it.

---

## Who this affects

- **People who keep work under `~/work/`** get the self-orienting session start, the auto-maintained project map in each project's `CLAUDE.md`, and the self-maintaining folder indexes. All of it is automatic for any project you have registered.
- **People who work against plans** get a binder cover page that is actually created at registration and a situating brief when they start a session against it.
- **Everyone** benefits from the cold-start going away, with no action required: the new maintenance runs as part of the session-close and session-start work brain-stem already does.
- **Projects you set up before upgrading** are unaffected until you touch them: the new thin-`CLAUDE.md` shape applies to projects you register from here on, and an existing project's files are left exactly as they are (nothing is auto-rewritten).

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow).

**Everything in v1.9.0 is additive.** The upgrade adds the situating brief and its session-start delivery, the binder-page mint at registration, the two new maintenance capabilities (one keeps each work project's map current, the other keeps its folder indexes current), and the wiring that runs them automatically. None of it changes how your vault or your existing projects behave, and none of it writes into your authored content. A work project you registered under an earlier version keeps its current files untouched; register a new one to get the thin self-maintaining shape.

The upgrade does not touch your existing notes, plans, projects, or wiki.

---

## In one sentence

brain-stem now self-orients the instant you start a session in a work project or a plan binder — handing the assistant a current, auto-generated situating brief — and turns each work project's `CLAUDE.md` into a self-maintaining map with self-indexing folders, all automatic and all additive.

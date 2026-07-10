# Release notes — v1.11.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.11.0 is a hardening release.** brain-stem maintains your vault through a layer of auditors, write-time checks, and repair routines — the "self-maintenance layer". A systematic audit of that layer found 80 places where a capability existed but silently failed to reach a surface it was supposed to govern: a scan that did not follow the vault's symlinked views, a walk rooted at the wrong directory, an owner that was declared but never wired in. This release closes or explicitly dispositions every one of those gaps, and then makes the whole class self-detecting going forward with a standing **coverage guard**. Alongside the wave, note types you register yourself are now enforced at write time, and plan status has a single source of truth. **Nothing you author changes, and there is nothing to migrate.**

---

## What's new

- **A standing coverage guard.** The failure mode this release eliminates is *silent under-coverage*: a maintenance capability that runs green while never actually reaching part of the vault, so nothing looks wrong. To keep the fixed gaps fixed, the maintainer test suite now carries a *sentinel corpus* — a set of planted, deliberately-defective canary files, one per governed surface — and a new auditor, the coverage guard, verifies each maintenance capability still detects its sentinels. If a future change makes a capability go blind to a surface, the guard reports it — and that proof runs at every release, before a version reaches you. On your install the guard is wired into the full audit and session close (report-only, never blocking); the corpus itself is test infrastructure and does not ship, so there the guard reports the corpus as absent — a visible no-op rather than a silent pass.

- **Your own note types are enforced, not just accepted.** brain-stem lets you register custom note types for your vault (`/govern register --kind file-type`), each with a list of required frontmatter fields. Previously a registered type was *legal* — writes with that type were accepted — but its required fields were never actually checked. Now a registered type gets the same write-time enforcement as the built-in types: a new write missing a required field is blocked with a message naming what is missing. The schema that validates type contracts now ships with the foundation, so registration is checked locally too, and the "unknown type" message you see inside a work folder now explains exactly how to register a new type at the moment you need it.

- **Work spokes pick up write-time governance automatically.** If you organize work as a "spoke" under `~/work/`, any write inside a registered spoke now gains the full set of frontmatter and tagging rules with zero per-spoke setup. The universal `deliverable`/`reference` pair is unchanged.

- **Plans carry a machine-readable research record.** A plan's manifest now includes a `research_artifacts[]` field: new plans scaffold it empty, and session close fills it in, so the research behind a plan is discoverable without reading prose.

- **The plan tree's root is a closed namespace.** Files that land directly at the root of your plan tree (rather than inside a plan) are now flagged by a placement sweep and surfaced at the start of your next session, with durable artifacts routed to where they belong.

## What's fixed

- **The maintenance layer reaches everything it governs.** This is the bulk of the release. Audits and repair routines now traverse the vault's symlinked views through one shared walker instead of six divergent re-implementations; scans that were rooted at the wrong directory — including one that scanned zero files while reporting success — are re-rooted; rename detection and its cascade now reach `~/work` and `~/.claude`; missing owners were built for the project-binder, memory, and writer surfaces; integrations that were declared but never wired are wired; and the write-time hooks now also cover the binder, rules, and schema surfaces.

- **Correctness bugs that zeroed out coverage.** The generated plan index no longer drops real rows; backups no longer wipe the per-project memory tier, and the work tree is now included in the default backup targets; the session-close check that audits handoff follow-ups now receives the list of files it is supposed to scan; and the release gate's schema validators fail closed when their validator is missing, instead of passing silently.

- **Plan status has one source of truth.** A plan's status now lives only in its manifest. The spec, tasks, and brief files no longer carry their own status line, so the status you see can no longer drift out of sync depending on which file you read.

- **Multi-session coordination is liveness-accurate.** When several Claude sessions run against the same vault, each now maintains a heartbeat, and liveness is decided by whether the session's process actually exists — so exited sessions no longer linger as phantom peers. Separately, the checkpoint written before a long session compacts now attributes work to a plan your own session actually touched, not whichever plan was most recently touched by anyone.

- **Rendering and hygiene.** Generated index tables now render as valid Markdown tables everywhere (Obsidian and GitHub alike); reserved names are rejected at every folder-creation entry point; the human-authored header of a maintained index survives regeneration; and `--help` output was corrected across twenty-one librarian capabilities.

## What changed

- **The curated hub page is retired.** The per-project "binder" — the orientation surfaces brain-stem generates for each project — is now fully machine-derived: the situating card and the generated indexes carry everything. brain-stem no longer creates or maintains a `hub.md`, and its template no longer ships. Any hub files you already have are left where they are.

- **`git-hooks/` no longer ships.** The public repository no longer carries the author-side git hooks directory. It had been public since an early seeding accident; its contents could not run in a public clone and had no adopter-facing function.

- **If you previously registered a custom note type**, be aware its required fields now block an incomplete new write where they were previously accepted silently — this is the enforcement the registration always implied. Files already on disk are untouched; the check fires only when a file is written.

---

## Who this affects

- **Everyone gets the coverage-remediation and coordination fixes on upgrade**, with no action required and nothing to migrate.
- **Anyone who has registered (or wants to register) custom note types** gets real write-time enforcement for them, plus a discoverable registration path from the "unknown type" message.
- **Anyone running multiple Claude sessions against one vault** gets accurate peer detection and correctly-attributed checkpoints.

## What to do

- **Upgrade normally.** Everything above applies automatically.
- **If you use custom note types**, expect required-field checks on new writes from now on; backfill older files at your own pace, or not at all — nothing on disk is touched.

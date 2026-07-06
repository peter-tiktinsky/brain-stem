# Release notes — v1.10.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.10.0 introduces a typed "frontmatter substrate" — a small, consistent set of fields on your notes that makes the same vault navigable for you in Obsidian, legible to Claude, and portable to external AI tools — and rounds it out with a broad set of correctness fixes to brain-stem's internal machinery.** The frontmatter capability is **warn-by-default and opt-in**: nothing is forced on you, and there is nothing to migrate. Everything else in this release is internal hardening you get for free on upgrade.

---

## What's new

- **A typed universal frontmatter cohort.** "Frontmatter" is the small block of key-value fields at the top of a Markdown note. brain-stem now defines a consistent cohort of these for durable notes in your vault — `type`, `description`, `created`, `updated`, `tags`, `id`, and `schema_version`. The point is that one well-formed note then serves three audiences at once: you (navigating in Obsidian), Claude (reading the vault), and external AI tools such as retrieval or MCP servers (which need consistent structure to index a vault without a bespoke adapter per tool). Notes created *through* brain-stem — by Claude, the scaffolder, or the write-time hooks — are stamped automatically at creation.

- **An opt-in auto-fixer for existing notes.** Your existing files are left exactly as they are until you choose to backfill them. When you do, a shipped, adopter-runnable auto-fixer fills the cohort in for you: `created` is read from each file's first-commit date (never stamped as "today", so history stays honest), a stable `id` is generated, and a one-line `description` is drafted for you. The default posture across the vault is **warn, not block** — brain-stem points out a missing field but never stops your write. Once you have backfilled, you can dial your own vault to hard-enforce if you want that.

- **Obsidian Bases starter views.** Bases is Obsidian's built-in, table-driven way to browse notes by their frontmatter. brain-stem now seeds a set of starter Bases views, so a fresh vault has a native navigation surface out of the box rather than a blank slate.

- **Work-spoke folders beyond sub-projects.** If you organize a body of work as a "spoke" under `~/work/`, you can now add top-level folders inside it that are *not* sub-projects — a place for reference material or deliverables that do not belong to any single sub-project — with `--add-folder`.

## What's fixed

- **The per-project "binder" surfaces are correct and bounded.** brain-stem auto-generates several orientation surfaces per project: a *situating card* (an at-a-glance summary), a *handoff chronicle* (a newest-first log of work sessions), and a *decision log*. This release corrects a cluster of defects in them: the situating card is now length-bounded instead of occasionally including a whole file's contents; the handoff chronicle recognizes every legitimate session-heading shape, so a correctly-written entry is never silently dropped or mis-sorted; the decision log no longer links a decision to an identically-numbered decision in a *different* plan; and stale "latest handoff" pointers are refreshed as you write.

- **Plan lifecycle is enforced when you close a session.** If a parent project is marked finished while a child plan under it is left open, brain-stem now surfaces that lag at session close rather than letting it drift unnoticed.

- **Multi-session coordination is race-free.** If you run several Claude sessions against the same vault at once, brain-stem keeps a shared registry of them. Two of the routines that update that registry — the periodic cleanup of exited sessions and the recording of an active one — could previously overlap and overwrite each other. They now update the registry under a single lock, so that cannot happen.

- **Governance and install hygiene.** Several smaller correctness fixes: the vocabulary of plan statuses now has a single source of truth; an empty project-parent field no longer mis-flags a plan as misconfigured; the release-preparation cleaner no longer trims text adjacent to what it removes; launching brain-stem from your home directory — an unsupported pattern that collapses project boundaries — now warns you clearly; and several internal bookkeeping comments and file-manifest scans were corrected.

---

## Who this affects

- **Everyone gets the internal fixes on upgrade**, with no action required and nothing to migrate.
- **Anyone who wants a more structured, AI-ready vault** can adopt the frontmatter cohort at their own pace: new notes are stamped automatically, and you can run the auto-fixer over existing notes whenever you choose. Until you do, the default is a gentle warning, never a block.
- **Obsidian users** get the seeded Bases views immediately and can browse their vault by frontmatter without any setup.

## What to do

- **Upgrade normally.** The internal correctness fixes apply automatically.
- **Optionally, adopt the frontmatter cohort** when it suits you: let new files stamp themselves, and run the auto-fixer over existing files when you want them backfilled. There is no deadline and no forced migration.

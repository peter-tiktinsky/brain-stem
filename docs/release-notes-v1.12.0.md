# Release notes — v1.12.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.12.0 is a hardening release.** It closes a train of correctness defects across brain-stem's shipped parts — the write-time hooks, the librarian capabilities, and the installer — and activates one safeguard that was present but dormant in prior versions. Several things that were silently doing nothing now work: ending a session reliably records it as closed, the multi-session overlap warning fires, and the memory-maintenance checks run. The `install.sh --apply` upgrade preview now describes edge-case files the way the upgrade actually treats them. And the context-pressure Stop gate — the "save a checkpoint before you end a long session" safeguard — goes from inert to active. A few small conveniences ride along. **Nothing you author changes, and there is nothing to migrate.**

---

## What's new

- **Traceability matrices render automatically.** A plan in brain-stem carries a manifest (the machine-readable record of its tasks and the sources each traces to). brain-stem already renders that manifest into a human-readable task list; it now also renders a *traceability matrix* — the table mapping each build item to its source of truth — the same automatic way. You no longer hand-maintain that table; it stays in sync with the manifest.

- **The backlog shows last-updated dates, and surfaces broken plans instead of hiding them.** Your backlog is the manifest-derived view of every in-flight plan. It now shows when each plan was last touched, so staleness is visible at a glance. And if a plan's manifest is malformed (for example, an unparseable field), that plan now appears in the backlog as a *flagged finding* rather than silently dropping out of the list — a broken plan can no longer disappear. Newly created plans are stamped with a date at creation.

- **The plan index shows each plan's owning directory.** The plan index is the generated table of all your plans. It now carries a column naming which project or code tree each plan belongs to (for example, a `~/work` project versus a code repository), so you can see what lives where without opening each plan.

## What's fixed

- **The "checkpoint before you stop" safeguard is now active.** brain-stem watches how much context a session has accumulated, and when a long, high-context session is about to end it prompts you to save a *checkpoint* — a written snapshot of session state so work can resume cleanly. In prior versions this Stop-time check could not read the identifier it needed to know which session was ending, so it never actually fired: the safeguard was effectively inert. It now resolves the session identifier correctly and enforces. **Heads-up:** because this is the first version where the gate is live, after upgrading you may see the checkpoint prompt for the first time at the end of a heavy session. It is not an error — running `/session-checkpoint` writes the checkpoint and clears the prompt.

- **Ending a session reliably marks it closed.** brain-stem keeps a registry of active Claude sessions so that, when several run against the same vault, each can see the others. When a session ended, one internal path (a lock-protected re-run of the close routine) could silently fail to mark that session's row closed, leaving a stale "phantom" session lingering in the registry. Session close now marks the row closed correctly.

- **The multi-session overlap advisory fires.** Related to the above: when a second session starts editing a vault file that another session is already working on, brain-stem is meant to warn you. That advisory could not resolve the session identifier it needed and stayed silent. It now fires as intended.

- **Memory maintenance no longer silently skips.** brain-stem runs periodic checks over your memory files — a freshness check and a hygiene check. When these ran as a background job (rather than interactively), a broken internal reference could make them quietly do nothing while still reporting success. They now run correctly in that path, and a genuinely empty memory directory is reported loudly instead of being silently normalized into a meaningless scan.

- **The upgrade preview is accurate on edge cases.** When you upgrade brain-stem with `install.sh --apply`, it first shows a preview of what will change. For a few edge-case file types — files you have customized that get merged with an overlay, deferred "sidecar" files that hold a pending change, and files that happen to match an older shipped version — the preview previously classified them differently from how the upgrade actually treated them. The preview now matches the real outcome, so what you see is what you get.

- **Plan-manifest dates are validated.** A date field in a plan manifest that is badly formatted is now caught and flagged, rather than silently accepted as valid. This is forward-looking: it was verified against every existing plan manifest and flags none of them, and the date fields it checks are filled in automatically by the plan scaffolder — so a normal workflow never trips it. It exists to catch a malformed date before it can cause trouble downstream.

- **Binder research links resolve.** Each project gets a "binder" — a set of auto-generated orientation pages, including a research index that links to the project's research artifacts. Some of those links were dead, especially when research was stored in a sub-folder or when the project lived in a non-default location. Those links now resolve, and a file that gets misplaced inside the binder area is now caught by the placement sweep.

- **An internal robustness fallback works.** brain-stem's hooks share a small set of helper libraries (for resolving paths and dates). If the primary copy of one is missing, a fallback is supposed to reload it. That fallback was written in a way that could never be reached; it is now correct. You will not notice this in normal operation — it is a safety net that now actually functions if the primary copy is ever absent.

## What changed

- **Nothing you author changes, and there is nothing to migrate.** The new manifest fields introduced this release are optional — every existing manifest stays valid. The new date validation is prospective-only and matches nothing in your current plans. The scaffolder-template updates affect files brain-stem generates, not anything you type. The single behavior change to be aware of is the Stop-gate activation described above: a dormant safeguard becoming active, not a migration step.

---

## Who this affects

- **Everyone gets the correctness fixes on upgrade**, with no action required and nothing to migrate.
- **Anyone running long, high-context sessions** will meet the now-active checkpoint prompt at session end; `/session-checkpoint` satisfies it.
- **Anyone running multiple Claude sessions against one vault** gets accurate session-close and the overlap advisory that previously stayed silent.
- **Anyone who upgrades with `install.sh --apply`** gets a preview that matches the real outcome on edge-case files.

## What to do

- **Upgrade normally.** Everything above applies automatically.
- **If you run heavy sessions**, expect the checkpoint prompt at the end of a long session from now on; run `/session-checkpoint` to write the snapshot and clear it. Nothing on disk is touched, and nothing needs migrating.

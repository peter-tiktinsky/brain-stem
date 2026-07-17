# Release notes — v1.12.1

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.12.1 is a patch release with a single, important fix: it stops brain-stem from silently losing notes you have hand-written on completed tasks.** brain-stem regenerates each plan's task list from the plan's manifest (the machine-readable record of the plan's tasks), and it is meant to preserve any notes you add by hand to a task's row across every regeneration. A defect broke that guarantee for tasks marked done, and this release closes it. **Nothing you author changes, and there is nothing to migrate** — but if you keep notes on completed tasks, upgrading protects them from a loss that could otherwise happen the next time a plan's list is re-rendered.

---

## What's fixed

- **Hand-written notes on completed tasks are no longer lost when a task list is re-rendered.** In brain-stem, a plan's task list is a *generated* view: brain-stem rebuilds it from the plan's manifest, and it carries forward any notes you have typed into an individual task's row so your annotations survive the rebuild. When a task is marked done, brain-stem displays that row's identifier struck-through (crossed out). The renderer that reads back your existing notes did not recognize the struck-through form of the identifier, so it skipped that row — and the next time the list was regenerated, the note you had written on that completed task was dropped entirely. Because the regeneration otherwise succeeded and the file even grew, the loss was silent. This release adds handling for the struck-through form, so notes now carry forward on *every* row, including tasks that are done or struck through.

  **What to do:** if you annotate tasks after completing them, upgrade before the next time you regenerate a plan's task list. The fix is prospective — it prevents the loss going forward. A note that a prior version already dropped is recovered from your version history the same way any prior file content is; nothing about the upgrade itself deletes or rewrites existing content.

- **Empty placeholder cells are no longer copied forward as if they were real notes.** When brain-stem scaffolds a new task row, it fills the notes cell with placeholder text (a bracketed prompt for what to write there). The renderer previously mistook that whole-cell placeholder for a real note and re-emitted it on every subsequent rebuild, so the placeholder never went away on its own. A cell that contains *only* a placeholder is now treated as empty and dropped. A genuine note that happens to contain brackets in the middle of a sentence is unaffected and still preserved.

- **The matrix renderer got the same fix, for consistency.** Alongside the task list, brain-stem can render a plan's *traceability matrix* — the table mapping each task to the source it traces to — using the same note-preservation logic. That renderer is a declared mirror of the task-list renderer, so it received the identical fix to keep the two consistent. In practice this renderer does not strike task rows today, so the fix is preventive there rather than something you would have hit.

## What changed

- **Nothing you author changes, and there is nothing to migrate.** This release only corrects how the task-list and matrix renderers preserve your notes. No file format changes, no manifest field is added or altered, and the notes you already keep are handled exactly as before — except that they now survive on completed tasks, where before they could be lost.

---

## Who this affects

- **Anyone who hand-writes notes on tasks in a plan's task list** — especially notes kept on tasks after they are marked done — is the group this fix protects. On upgrade, those notes stop being at risk on the next regeneration.
- **Everyone else** gets the fix automatically with nothing to notice: if you do not annotate completed tasks, there was no loss to experience, and normal rendering is unchanged.

## What to do

- **Upgrade normally.** The fix applies automatically.
- **If you keep notes on completed tasks**, upgrading before your next task-list regeneration is worthwhile — it closes the window in which such a note could be dropped. Nothing needs migrating and nothing on disk is rewritten by the upgrade.

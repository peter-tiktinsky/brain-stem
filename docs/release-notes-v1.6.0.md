# Release notes — v1.6.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.6.0 is a maintenance release.** It does two things: it finishes removing the built-in *meeting-note* document type from the installed foundation, and it hardens the release pipeline so that files removed from the foundation actually disappear from what gets published.

---

## Why this matters

brain-stem ships a small set of built-in *file types* — document kinds it knows how to govern (an index page, a deliverable, a knowledge-library article, and so on). Each type carries a little rulebook: which frontmatter fields it requires, where it lives, how it's written.

`meeting-note` used to be one of those built-in types. But its natural home — a `Meetings/` folder — was already removed from the foundation in v1.5.0, which left the *type* governing a surface the foundation no longer ships. A built-in type whose home has been removed is half-finished work. It was also unusually specific: it carried fields tied to one particular meeting-transcription tool, which is exactly the kind of specialized vocabulary that belongs in an optional add-on, not in the universal base.

**v1.6.0 completes the removal.** The `meeting-note` type, its rulebook, and the leftover `Meetings/` exemptions all move out of the foundation. They are not deleted — they are *parked*, so a future meeting-oriented add-on package can re-introduce them as an overlay, the same way other specialized vocabularies are added on top of the base.

The second change is invisible to you but important for everyone: the tooling that publishes brain-stem now **removes** a file from the public release when it's dropped from the foundation. Previously the pipeline only ever *added or updated* files, so a removed file could silently linger in the published tree. A new completeness check now fails the release if anything is left behind. (This release is the first real exercise of that fix — parking `meeting-note` is exactly the kind of removal it now handles.)

---

## Who this affects

- **Almost everyone: no action needed.** If you never used a built-in `meeting-note` type, nothing in your vault changes.
- **If you kept date-named meeting notes**, you lose nothing important: the per-type rulebook is gone, but brain-stem's **universal historical-data warning** still fires before you overwrite any date-named note, so the write-safety that mattered is still there (slightly broader, if anything).
- **If you want structured meeting notes back**, that capability is destined for an optional meeting add-on built on the same overlay mechanism used for other specialized work — the parked contract is the starting point.

There is **one small upgrade detail** (see *Upgrading*, below): a leftover `meeting-note` contract file may remain in your installed governance folder after upgrade. It is inert and safe to delete.

---

## What changed

### Removed

- **The built-in `meeting-note` file type and its contract.** All of its governance leaves the foundation: the frontmatter type entry (including the tool-specific Granola fields), the body-shape contract, the `Meetings/**` folder exemptions, the `Meetings/` known-root, and the cross-document "meeting fan-in" dependency. The standalone contract is preserved outside the foundation as the seed for a future meeting add-on. This **supersedes the v1.5.0 note that the type "still ships."**

### Changed

- **More reliable required-field checking.** The librarian (the agent that audits your vault) now reads the live composed governance rules directly when it checks that a file has its required frontmatter fields, instead of consulting a hand-maintained copy that had drifted. In practice this means the `reference` (knowledge-library) type's required fields are now actually enforced, where before they were silently skipped.

### Fixed (maintainer-facing)

- **The publish pipeline now propagates deletions.** When a file is removed from the foundation, the dev→public transform prunes it from the published tree, and a new tree↔manifest completeness gate blocks the release if any shipped directory still carries a file the manifest doesn't list. This closes a durability gap that previously required manual cleanup during a release. It does not change anything you install — it changes how releases are built.

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow). The upgrade:

- **removes** the `meeting-note` type and its rules from your installed governance;
- **does not touch** your existing notes, plans, projects, wiki, or any meeting notes you've already written — those files remain exactly as they are;
- leaves the universal historical-data write warning in place for date-named notes.

**One known leftover:** the upgrade engine delivers and updates the files brain-stem manages, but it does not yet *prune* a file that was removed upstream. So after upgrading you may still find a `meeting-note.md.json` file under `~/.claude/governance/file-type-contracts/`. Nothing references it, so it does no harm; you can delete it. An automatic prune for removed files is a tracked follow-on.

---

## In one sentence

brain-stem finishes moving the specialized `meeting-note` type out of the universal foundation (parked for a future add-on, with no loss of write-safety), and its release pipeline now removes dropped files from the published tree instead of leaving them behind.

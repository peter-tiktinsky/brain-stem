# Release notes — v1.17.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.17.0 is a minor release with no migrations.** Upgrading is a file sync — nothing runs against your plan corpus or your configuration, and nothing needs doing by hand. Two changes lead: **upgrading is now one command** (`install.sh --upgrade` previews, `install.sh --upgrade --apply` performs — the installer detects your version and setup shape itself), and **your live install can no longer silently drift from the product** (an in-flight advisory when a managed file is edited in place, plus a daily census that hashes every managed file against the shipped manifest). Alongside: renderer improvements that existed only as live patches are shipped product, overlay collision checking covers the entity classes it silently skipped, and several vocabularies that had drifted into near-duplicates are consolidated to one declaration each.

---

## The headline — upgrading is one command

Until now, upgrading a live brain-stem install meant reconstructing a bespoke command sequence each release: which flags to pass, which overrides apply to your setup shape, what to back up. The sequence was documented, but it was documentation — a human had to re-derive it every cycle.

This release retires that. The installer itself now owns the whole decision:

1. **`install.sh --upgrade`** (from a fresh clone of the release) asserts an existing install is present, detects its version and setup shape, auto-resolves where your install lives, and prints exactly what an apply will do — including any overrides your particular shape requires. It writes nothing.
2. **`install.sh --upgrade --apply`** performs that plan.

The preview-then-apply split is deliberate: you always see the full plan before anything changes. In the same pass, every line the installer prints during install and upgrade was audited — stale advice removed, next-steps made actionable, diagnostics reworded to current fact.

---

## The second thread — a live install that cannot silently drift

brain-stem installs a set of managed files into your Claude Code home: hooks, skills, governance data. The product's rule has always been that changes flow through the release pipeline — change the source, ship it, upgrade — because a hand edit to an installed file silently forks your install from the product: the next upgrade overwrites it, or worse, preserves a divergence nobody remembers making.

Two layers now enforce what was previously a convention:

- **An in-flight advisory at write time.** Editing a managed file in your live install draws an immediate advisory naming the managed surface and the sanctioned route. A deliberate exception is acknowledged with an explicit environment variable, and every fire — including acknowledged ones — lands in a telemetry ledger, so the posture can later be tightened on evidence rather than assumption.
- **A standing daily census.** Divergence does not only arrive through an editor: a scheduled job, an outside tool, or an edit that predates the advisory can fork a file too. A daily census hashes every managed file against the shipped manifest and reports any mismatch as a finding — whatever the vector, drift surfaces within one cycle instead of accumulating unseen.

Neither layer blocks you. Both make the fork visible the moment it exists.

---

## What else is fixed

**Renderer output matches the schema everywhere.** The machinery that renders a plan's task ledger and traceability matrix now emits the complete frontmatter key set on the files it writes, landed in lockstep with the schema, the write-time gates, and every file-creation surface — a file is born conformant instead of healed later. (These improvements previously existed only as unshipped patches on one live install; they are now product.)

**Overlay collision checking covers every entity class.** Adopter overrides of shipped governance are collision-checked so an accidental shadow is caught. Two entity classes were silently skipped: entries living in array-valued slots, and entities with underscore-prefixed names. Overriding one of those succeeded without the explicit override reason that everything else already requires. The walk now gates them all, and the install lane probes for pre-existing violations at apply time — a warning, not a hard stop.

**Research artifacts survive a same-session close.** A plan reaching its terminal status in the very session that would first declare its research artifacts had those declarations suppressed — the close-out chain stamped the terminal state first and the declaration step then refused to touch a closed plan. The chain now declares before it stamps, and the closed-scope warning lands on a durable surface instead of vanishing with the session's transcript.

**Binder projection surfaces are ruled.** The per-project binder no longer carries a research symlink farm with no consumer, and decision-class artifacts route to the decision log by their declared kind.

**The crash-guard checker understands quotes.** The screen that keeps unguarded command substitutions off error-exit shell surfaces treated a quoted parenthesis as span syntax and produced false positives that had to be papered over with exemption markers. Quoted parentheses are now data, and the paper-over markers are gone.

---

## Smaller changes worth knowing

- **Project-container tags.** Automatic tag inference for files under the projects root now emits the project-scoped container form (`#project/<name>`).
- **One task-status vocabulary.** Every reader of a task-status field keys on the single declared list in the plan manifest schema; the private near-duplicate lists that had accumulated are deleted, and a standing check keeps a new one from appearing.
- **One surface roster.** Corpus-walking capabilities (link checking, enumeration, placement validation) consume one declared roster of live roots and retired surfaces instead of each hand-coding its own.
- **Advisory labels resolve uniquely.** A write-time advisory family that shared its label with two unrelated rule families is renamed to its registered identity.
- **Memory hygiene respects dotfiles.** Editor artifacts are excluded from memory-corpus hygiene scans, and deliberate exemptions are configurable.

---

## What to do

**Upgrade with the new lane.** From a fresh clone of this release: `install.sh --upgrade` to preview, then `install.sh --upgrade --apply` to perform. No migrations ship in this release — the upgrade is a file sync, and the census + advisory layers arm themselves on the schedule that ships with them.

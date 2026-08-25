# Release notes — v1.16.0

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.16.0 is a minor release with no migrations.** Upgrading is a file sync — nothing runs against your plan corpus or your configuration, and nothing needs doing by hand. The widest-reaching change: **every reference brain-stem writes for you is now a link that resolves.** The backlog, the plan indexes, the inbox, the library, decision logs and research indexes all convert from wiki-style references to plain relative markdown links that any editor, viewer, or agent can follow — and when files move, the links are repaired automatically. Alongside it: settled ideas move out of your inbox into their own folder, manual settlement gets a sanctioned command, the status-drift instrument reads the source of truth instead of a rendered copy, and several write-time gates now enforce what the contracts already claimed. **Upgrade normally with `install.sh --apply`.**

---

## The headline — links that resolve

brain-stem maintains a set of machine-written navigation surfaces: the backlog, the plan-tree index, the inbox index, the library index, per-plan decision logs and research indexes. Historically these mixed wiki-style links (`[[name]]`) and directory-style references — grammars that a plain markdown viewer cannot follow and a file-path resolver cannot act on. One measured class alone had 62 dead links live in a working corpus.

This release converts the whole surface to one ruled grammar — relative markdown links — and closes the loop end to end:

1. **Every machine emitter writes the ruled grammar.** The backlog's five link sites, the writers index, the index file columns, the library root, the decision log's path cell, and the research indexes all emit relative markdown links that resolve from the file they appear in.

2. **The rename watchers understand it.** The machinery that notices a file rename now recognizes markdown-link references in both grammars, so a rename is connected to the links that point at the old name.

3. **Repair is automatic again — and no longer expires.** The rename cascade rewrites markdown links when files move. Rename history is now persisted, so a repair opportunity no longer silently vanished if more than a day passed before the next pass.

4. **Templates stop reseeding the old grammar.** Shipped templates — including the one that seeded wiki-link content into every new library article — now seed the ruled grammar, so a new install or scaffold does not regress the conversion.

5. **Your own corpus can be converted.** The conversion pattern that was independently re-derived five times in live remediation work — its largest run covered 158 files — is now a shipped librarian capability rather than a recipe each session rebuilds.

---

## The idea funnel — settled means settled

Ideas are captured as notes in an inbox folder, and either graduate into plans or reach a terminal resolution. Three changes make that lifecycle honest:

- **Settled notes leave the inbox.** When a note reaches a terminal resolution, it now moves to a `_settled/` subfolder in the same run that stamps it. Your inbox folder holds live ideas only. Dry-run stamps nothing and moves nothing; a name collision leaves the note in place with a visible advisory rather than overwriting history. Notes settled before this release stay where they are — every index and ledger links both populations at their real locations.
- **Manual settlement has a sanctioned command.** A note with no plan target — resolved by judgment, not by machinery — previously could be settled by no code path at all. The new `inbox-settle` capability stamps and moves it under an explicit apply flag, enforces the strict resolution vocabulary, and refuses to settle a note twice.
- **Absorption is recorded from both sides.** When a plan absorbs several notes, the notes each point at the plan — but the plan had no record of the join. Plan manifests can now list their absorbed notes, and the settled ledger derives from all three sources (graduations, absorptions, terminally-resolved notes), with a note's own richer record winning when both exist.

**The plans index is also now one table** — plan, status, project directory, sub-plans — replacing two duplicated views. Every row carries its status and project directory; previously a whole class of rows silently dropped both.

---

## What else is fixed

**The status-drift instrument reads the source of truth.** Plan status lives in the manifest; the human-readable task ledger is a rendered copy. Both parsers that measured status drift read the copy, so the instrument could disagree with the thing it measured. Both now read the manifest directly — and a stale rendered ledger is itself a detected finding instead of a silent hazard.

**The vault's front-door files are governed.** Files at the vault root previously fell through the schema gate entirely. They now route to the standard three-tier gate, with creation-time advice scoped to genuine creation.

**Overlay collision checking matches its contract.** Registry-sourced entries are recognized as such, an empty container is no longer reported as a shadowing collision, and a false lockout on the overlay master clears with no configuration change on your side.

**Rendered task-ledger regions are protected at write time.** A hand edit that would silently diverge the machine-rendered region of a plan's task ledger is refused — with an explicit escape hatch for the renderer itself — while your narrative edits pass untouched.

**A checkpoint write can no longer hang forever.** The checkpoint guard bounds its read at the first byte, so a caller that inherits an open input stream no longer drains it indefinitely.

**A corpus census cannot be silently truncated.** Every shipped walker is screened against ignore-file-respecting search wrappers, so an ignore file sitting in your corpus can no longer hide files from an integrity pass without anyone noticing.

**Index and binder writers emit what their contracts declare.** One parent-folder shape across all index writers; healing of existing index frontmatter is bounded to exactly what the staleness flags name; writer-owned indexes in exempt paths are recognized instead of flagged; binder roots are now walked by placement validation (a retired hub file had quietly re-minted twice); research indexes emit canonical routes only.

---

## Smaller changes worth knowing

- **A declared home for the task-status vocabulary.** The per-task status values are machine-readably declared in the plan manifest schema; every consumer reads one declaration.
- **A thin universal note type ships.** Registered at the soft-warn tier — capturing a note is never blocked by governance; lineage fields are optional.
- **Plan markdown artifacts stop carrying a status line.** Status lives in the manifest; the four plan markdown artifact types no longer require a status field of their own.
- **Machine-generated files heal at their writer, not at your edit.** A file whose frontmatter names its generating writer is writer-owned: the gate stops denying your edits to it, and nonconformance heals the next time the writer runs.
- **Work reference folders are a free-form zone.** The tagging mandate is exempted there, so captured reference material is not nagged into a taxonomy.
- **One address for the plans tree.** Vault-view symlink spellings of the plans path canonicalize to the physical path, so governance applies identically at both addresses.
- **Self-descriptions state current fact.** A retired write-time line cap is no longer asserted; the transitional grandfather list is emptied; stale citation comments across the installer and governance surfaces are reworded to durable facts.

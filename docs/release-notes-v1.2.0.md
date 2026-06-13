# Release notes — v1.2.0

> **Audience:** adopters running brain-stem. This page explains, in plain language, what this feature release adds, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.2.0 is a feature release about context.** Most of what brain-stem helps you do — research, decisions, hand-offs — produces notes that, today, end up scattered across one project and are hard to reuse in the next. This release adds a **three-surface context library** that gathers those notes into readable, current pages and makes durable knowledge reusable across projects. Three things work together: a shared **library** of reusable articles, per-project **binders** that index a project's own research, decisions, and hand-offs, and a **workshop flow** that points you at the library before you start fresh research.

---

## Who this affects

Everyone running brain-stem. The new behavior is additive and mostly automatic: the librarian builds and refreshes the index pages from files that already exist, a one-line record is added when a session ends, and an advisory check runs before you begin new research. Nothing you have written is moved or rewritten without your say-so — the promotion step that lifts a note into the shared library is something you ask for, not something that happens behind your back. There is nothing you must do to benefit.

---

## What's new

- **A shared knowledge library.** A new `_library/` area holds durable, reusable articles: one concept per file, written in general terms so they apply across projects rather than to one piece of work. Each article opens with a one-line *"when to read this"* so you can tell at a glance whether it is relevant before opening it. A **library index** lists every article by topic, and a running **change log** records what was added or revised — so the library stays browsable as it grows rather than turning into a pile.

- **A file type for library articles.** Library articles have their own contract: one concept per file, the required *"when to read this"* line, and a size budget that keeps an article short enough to actually read. The index pages use that one-liner first when describing an article, so the index tells you *when* to open something rather than just restating its title. An article template and a topic-index template ship with the install.

- **Project binders.** Each project gets three living index pages — a **research index**, a **decision log**, and a **hand-off index** — that gather the project's scattered notes into one readable place per kind, with a **hub** page tying them together. The librarian rebuilds these from what is actually on disk, so a binder never drifts from the underlying files. Binder and index templates ship with the install.

- **Librarian capabilities that keep the surfaces current.** Six new librarian capabilities do the upkeep: a library-index builder, a **promotion** step that lifts a project note into a scrubbed, reusable library article (with the project-specific detail removed so it reads generally), a library change-log rotator, and the three binder builders. Each one regenerates from the files on disk and never invents content.

- **A workshop flow.** Three hooks wire it together. When a session ends, a one-row chronicle entry is appended for the session. The library change log is kept up to date as articles change. And before you start new research, an advisory check points you at any library article that already covers the ground — so you reuse what exists instead of redoing it. The pre-research check only advises; it never blocks you from proceeding.

---

## What was corrected

- **Light topics now read correctly.** A topic with only a couple of articles, or only one kind of article, is a "light" topic and is laid out a little differently. The contract behind the index pages now states that rule explicitly — fewer than three articles **and** fewer than three distinct types — so the generated pages and the rule that governs them agree.

- **A correct self-reference is no longer flagged as a loop.** A plan file that correctly points at its own top-level plan was being misread as a circular reference and reported as an error. The resolver now recognises a legitimate self-pointer and reports only genuine cross-plan loops.

---

## What to do

Nothing special. Upgrade the way you always do:

```bash
cd brain-stem
git pull
bash install.sh | jq .                                  # preview — writes nothing
export CLAUDE_HOME=~/.claude
bash install.sh --apply --backup-dir ~/.claude-upgrade-backup
```

The preview writes zero files and shows the full plan; `--apply` performs the upgrade and saves anything it replaces into the backup directory first. The new library and binder pages are built from your existing files the first time the librarian runs, so there is nothing to migrate by hand. The full walkthrough is the **[Upgrading an existing install](getting-started/index.md#upgrading-an-existing-install)** runbook.

# Release notes — v1.1.4

> **Audience:** adopters running brain-stem. This page explains, in plain language, what this feature release adds, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.1.4 is a feature release about memory.** brain-stem keeps a small file, `MEMORY.md`, that is loaded at the start of every session — it is the always-on index of what the assistant knows about you and your work. Two changes in this release keep that index small and useful as it grows: the assistant now keeps a **running chronicle of your sessions** in a separate file, and it adopts a consistent **pointer shape** for referencing large detail that lives elsewhere (a vault file, a chronicle) rather than pasting it into the index. Nothing about your vault, your settings, or your own edits changes.

---

## Who this affects

Everyone running brain-stem, but gently. The new behavior is automatic and additive: at the end of a session a one-line record is added to a chronicle file, and the memory index gains a single pointer to it. If you have been running brain-stem for a while and have old per-session memory files (`episode_*.md`), the upgrade tidies them away into a sub-folder for you. There is nothing you must do.

---

## What's new

- **A session chronicle.** When a session ends, brain-stem prepends one newest-first row to `memory/episodic-chronicle.md`: the session's anchor (what it was about), what files it touched, the pointers needed to resume it, and a one-line summary. This replaces the older approach of scattering a separate file per session. `MEMORY.md` now carries a single line pointing at the chronicle instead of a list that grew without bound.

  The chronicle is built without calling a model, so it adds no token cost when a session ends. It rotates into a dated archive file once it passes about 50 KB, and it never deletes a row — old rows move to the archive, they do not disappear. The one-line summary for the session you just finished is filled in at session-close from the hand-off note you wrote, so it reads in your words, not a guess.

- **A documented pointer shape for memory.** Large detail — a long reference document, a vault page — should be *pointed at* from `MEMORY.md`, not copied into it. This release writes that convention down: a pointer is an absolute path, an imperative instruction to read it, and a short note on why it is worth reading. The seeded `rules/` README carries the same shape. The result is that the always-loaded index stays lean while the full detail stays one click away.

- **A placement advisory.** `MEMORY.md` is read up to a fold — roughly the first 200 lines, or a byte cap. A pointer placed below that fold would never be seen on a normal read. The write-guard now warns when that is about to happen. It only warns; it never blocks a write.

- **A pointer-currency check at session-close.** A new librarian step reports any plain-text absolute-path pointer — in `MEMORY.md`, a memory topic-file, or a `rules/*.md` file — that no longer resolves to a file on disk (for example, after something was renamed or moved). It is advisory and propose-only: it never edits a file and never blocks. It is also **change-gated** — it stays silent unless one of those files actually changed since it last looked — so it does not become background noise you learn to ignore. Automatically fixing the stale pointers is planned for a later release.

---

## What was corrected

- **A known upstream limitation is now documented.** Glob patterns in a *user-scope* `~/.claude/rules/` file are silently ignored by the upstream tooling (tracked as GitHub issues `#21858` and `#25562`); *project-scope* `.claude/rules/` works reliably. The seeded `rules/` README now states this plainly, and a documentation link that pointed at a file not present in an install was repointed at the public memory documentation.

- **Two documentation inaccuracies.** The memory-model document cited a specific memory-decay percentage that was not supported by a source; it now states the supported signal-to-noise point instead. A librarian capability-status note that read as if more were wired than actually is was split into two accurate statements.

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

The preview writes zero files and shows the full plan; `--apply` performs the upgrade and saves anything it replaces into the backup directory first. If you have old `episode_*.md` files, the upgrade moves them into `memory/episodic-legacy/` for you — they are preserved, just out of the way. The full walkthrough is the **Upgrading an existing install** runbook.

# Changelog

All notable changes to brain-stem are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project follows semantic versioning.

For longer release narratives, see `docs/release-notes-v<version>.md`.

## [v1.3.0]

Maintenance release. brain-stem now writes **zero machine files into your vault**. The assistant's operational exhaust — run logs, the session-close receipt, the librarian's working manifest, and internal hook state — moves out of the vault (and out of the `~/.claude` config home) into the standard per-user **state directory**, `~/.local/state/brain-stem`, following the XDG Base Directory specification. The vault's `Logs/` folder is retired: your vault is now 100% human knowledge, with nothing machine-emitted leaking into Obsidian search or the local graph. See the [v1.3.0 release notes](docs/release-notes-v1.3.0.md).

### Changed

- **The vault holds only human knowledge.** brain-stem no longer ships or writes a `Logs/` folder into your vault. The session-close receipt, the librarian's working manifest, cron and orchestrator run-logs, and live hook state now resolve under `~/.local/state/brain-stem/` (in `logs/`, `manifests/`, `hooks-state/`, and `runtime/`). Obsidian search and the local graph now see only the notes you and the assistant write — never machine output.

- **Operational exhaust follows the XDG state convention.** Logs and persistent working state resolve under `$XDG_STATE_HOME` (default `~/.local/state`), the standard home for disposable per-tool state. The durable data tier (`~/.local/share/brain-stem`) and the install/uninstall record (`~/.claude/logs`) are unchanged.

### Fixed

- **Two internal path inconsistencies resolved.** The librarian's coordination lock and its working manifest now resolve to the same place its readers look, and the write-time audit log's writer and reader now agree on one location — closing two long-standing cases where a writer and a reader had drifted onto different paths.

## [v1.2.0]

Feature release. brain-stem now has a **three-surface context library**: a shared **library** of durable, reusable knowledge that any project can draw on; per-project **binders** that gather a project's research, decisions, and hand-offs into living index pages; and a **workshop flow** that nudges you to check the library before starting fresh research. The librarian gains the capabilities that keep all three surfaces current, and a new file type governs the library articles themselves. See the [v1.2.0 release notes](docs/release-notes-v1.2.0.md).

### Added

- **A shared knowledge library.** A new `_library/` area holds durable, reusable articles — one concept per file, written in general terms so they apply across projects rather than to a single piece of work. Each article carries a one-line "when to read this" so a reader can tell at a glance whether it is relevant. A library index lists every article by topic, and a running change log records what was added or revised, so the library stays browsable as it grows.

- **A new "reference" file type for library articles.** Library articles are governed by their own contract: one concept per file, a required routing one-liner, and a size budget that keeps an article readable. The index pages read that routing line first when deciding how to describe an article. Templates for an article and a topic index ship with the install.

- **Project binders.** Each project now gets three living index pages — a research index, a decision log, and a hand-off index — that gather the project's scattered notes into one readable place per kind. The librarian regenerates them from what is actually on disk, so they never drift from the underlying files, and a hub page ties them together. Binder and index templates ship with the install.

- **Librarian capabilities for the three surfaces.** Six new librarian capabilities keep the surfaces current: a library index builder, a promotion step that lifts a project note into a scrubbed, reusable library article, a library change-log rotator, and the three binder builders (research, decisions, hand-offs). They regenerate from disk and never invent content.

- **Workshop hooks.** Three hooks wire the flow together: a session-close step that appends a one-row chronicle entry for the session, a library change-log appender, and an advisory pre-research check that, before you start new research, points you at any library article that already covers the ground. The pre-research check only advises; it never blocks.

### Changed

- **The library index understands light topics.** A topic index page adapts its layout for a small or single-type topic, and the index contract now states that adaptation explicitly — fewer than three articles **and** fewer than three distinct types reads as a light topic — so the generated pages and the contract agree.

### Fixed

- **A parent-plan resolver no longer mistakes a correct self-reference for a loop.** A plan file that correctly points at its own top-level plan was being misread as a circular reference and flagged as an error. The resolver now recognises a legitimate self-pointer and only reports genuine cross-plan loops.

## [v1.1.4]

Feature release. brain-stem now keeps a running **episodic record of your sessions** and adopts a **pointer-based shape** for the long-lived memory that survives between sessions. The memory index stays small and readable; the bulky detail lives in a chronicle file and in your vault, referenced by a single line. See the [v1.1.4 release notes](docs/release-notes-v1.1.4.md).

### Added

- **A session chronicle.** When a session ends, brain-stem now prepends a one-row, newest-first entry to `memory/episodic-chronicle.md` — the session's anchor, what it touched, its hand-off and resume pointers, and a one-line summary. `MEMORY.md` carries a single pointer line to that chronicle instead of a growing pile of per-session files. The chronicle is harvested without calling a model (no token cost at session end), rotates to a dated archive when it crosses ~50 KB, and never deletes rows. The one-line summary is filled in at session-close from the hand-off you just wrote.

- **A pointer-currency check.** A new librarian capability runs at session-close and reports any plain-text absolute-path pointer — in `MEMORY.md`, a memory topic-file, or a `rules/*.md` file — that no longer resolves on disk. It is advisory and propose-only (it never edits or blocks), and it is change-gated: it stays silent unless one of those files actually changed since the last scan, so it does not train you to ignore an always-on "all clear."

- **A memory-pointer placement advisory.** The write-guard now warns (never blocks) when a pointer line in `MEMORY.md` would land below the read-fold — past line 200 or the byte cap — where the loader would not see it on a normal read.

### Changed

- **Memory uses a documented pointer shape.** `MEMORY.md` and the seeded `rules/` README now describe a "vault-pointer shape" — an absolute path, an imperative read-instruction, and a short why — for referencing a large external file instead of inlining it. This keeps the always-loaded index lean while still pointing at the full detail.

- **The rules README documents a known upstream limitation.** User-scope `~/.claude/rules/` glob scoping is silently non-functional upstream (GitHub `#21858` / `#25562`); project-scope `.claude/rules/` is reliable. The seeded README now says so, and a broken in-repo documentation link was repointed at the public memory docs.

- **Documentation corrected.** The memory-model doc no longer cites a fabricated decay statistic (it states the corroborated signal-to-noise point instead), and a librarian capability-status note that overstated what is wired was split into two accurate statements.

### Fixed

- **A legacy install's old episode files are migrated, not orphaned.** Upgrading moves any pre-existing `memory/episode_*.md` files into `memory/episodic-legacy/` so they leave the flat memory glob (and stop being re-indexed) without being deleted. A fresh install does nothing here; the migration is idempotent.

## [v1.1.3]

Maintenance release focused on the in-place upgrade path for existing adopters, plus the runtime-config and session-continuity fixes staged after v1.1.2. See the [v1.1.3 release notes](docs/release-notes-v1.1.3.md).

### Fixed

- **Upgrading over a `~/.claude/.gitignore` you already had no longer loops forever.** `.gitignore` is delivered by a three-way merge (your own ignore rules are preserved, the brain-stem block is appended), so on any home with a pre-existing `.gitignore` the merged file legitimately differs from the pristine template. The delivery-verification step treated that difference as an under-delivery, refused to stamp the install (exit 56), and — because the merge is idempotent — every re-run hit the same wall. Merge-delivered files are now exempt from that check, so the upgrade converges and stamps on the first pass.

- **Skipping a version on upgrade now delivers every prior-release floor.** Upgrading directly across a version (for example v1.1.1 → v1.1.3 without stopping at v1.1.2) left out the prior release's baseline record — a file the newer install references — which then tripped the same delivery-verification refusal (exit 56). The upgrade engine now enumerates everything the new version ships, not only what the older install already had, so a multi-version jump delivers the complete set and converges.

- **Session checkpoints are written and read from the same place.** The checkpoint writer and the hooks that read it resolved different default directories, which could fire a false "stale checkpoint" stop-block. Both now resolve the one canonical session-state root, and the missing checkpoint-pressure writer was added.

- **Dead and mislabeled configuration knobs cleaned up.** Several manifest settings were documented as live but read from nothing (or from environment variables never set); the genuinely-unused ones were removed and the rest are now actually wired (environment → manifest → default), so the documented knobs match what the code does. The user-manifest schema was also reconciled with what the path/vault/behavioral resolvers actually read, so a manifest that exercises those knobs no longer fails validation.

- **Fresh installs now deliver all 12 adopter schemas.** Three schemas (`memory-schema`, `rules-schema`, `review-queue-schema`) are resolved at runtime by installed helpers, but the installer's schema list had not grown to include them — so every fresh install since v1.1.2 was missing those three files. The affected helpers degrade gracefully when a schema is absent (falling back to built-in defaults), so this was a latent completeness gap rather than a failure; the installer now ships the full set, so the schema-driven validation paths are actually live.

### Changed

- **The upgrade dry-run shows every blocker in one pass.** Pre-flight gates that used to stop on the first problem now aggregate: a single `bash install.sh` preview lists every required override together, and the genuine must-stop safety conditions (an unset `CLAUDE_HOME`, or a vault symlinked under the install target) are surfaced in the same preview under a separate, non-waivable findings list — so you can see and resolve everything before committing to `--apply`.

- **The getting-started and upgrade runbook is now copy-paste runnable end to end.** The upgrade section now shows the required `export CLAUDE_HOME`, documents `--retrofit-existing` (for a home that already has plans) and `--backup-dir` (required on an upgrade that replaces your merged `settings.json`), adds a note for clones made before the one-time public-history rewrite (`git fetch origin && git reset --hard origin/main`, or re-clone), and links the current release notes.

- **The `/librarian full` sweep is documented honestly.** The skill doc now enumerates what `full` runs and states plainly that the plan-tree index files (`_index.md`, `_backlog.md`, `_archive.md`) are written lazily on the first relevant librarian run — they are not seeded at install — so a brand-new plans folder legitimately has none of them until then.

- **The release pipeline now produces a byte-reproducible manifest, and the baseline-freeze guard is stronger.** The shipped manifest's build tools are now propagated into the published tree so its `generated_at` is pinned to commit time (identical across rebuilds), and the guard that keeps every superseded release's baseline frozen now checks the complete expected set rather than only the files that happen to be present — so a deleted floor is caught instead of passing silently.

## [v1.1.2]

Maintenance release. Every functional governance value is byte-identical to v1.1.1 — but this release carries several install-correctness and data-safety fixes beyond the original executable-bit repair, and clears internal build-process shorthand out of the public governance artifacts. See the [v1.1.2 release notes](docs/release-notes-v1.1.2.md).

### Fixed

- **Core hooks and librarian capabilities now ship executable.** Two shipped scripts had lost their executable bit, so they silently failed to run after installation: the **governance write-guard hook** (`pre-write-guard`, which `settings.json` invokes by path — a non-executable hook fails outright, leaving writes unguarded) and the **note-placement checker** (`placement-validate`, which session-close skips when it is not executable). Both are restored; the installer now re-applies the executable bit to every hook and librarian capability after copying them; session-close now reports a shipped-but-non-executable capability as an **error** rather than silently treating it as "not installed"; and the pre-tag release gate asserts the executable bit across the whole managed set — so a hook or capability can no longer silently no-op on an install.

- **Librarian capabilities that read the plans and vault-writers governance rules now run on a standard install.** Several capabilities — including backlog indexing, plan archiving, task rendering, and vault-writer reconciliation — read values from governance pillars that are *composed into* the shipped governance master rather than delivered as separate files. On a normal install those separate files aren't present, so the capabilities exited early instead of running. They now resolve the effective values from the shipped governance master, so they work on a clean install.

- **Vault-writer reconciliation no longer risks dropping your edits.** A configuration-shape bug left the reconciler's survivorship setting empty, which silently bypassed the "your edits win" preservation step — so a reconciliation pass could overwrite manual edits. The setting is now read correctly and the preservation step always applies.

### Changed

- **The public governance artifacts read in plain product language.** The shipped governance schema, index, and composed master carried internal build-process shorthand in their descriptive text. Those descriptions now name the product directly — the per-pillar `_rules[]` register, the `home`/`category` rule model, and the v2 pillar structure. This is a description-only change: every functional governance value (types, exempt paths, tag cap, taxonomy) is byte-identical to v1.1.1.

- **Governance is now read through a single merged view.** Every hook and capability that reads governance now resolves it through one merged view — the shipped foundation values, with an optional per-vault overlay layered on top — instead of reading individual rule files directly. For a standard install with no overlay the effective values are identical to v1.1.1; the change makes resolution consistent across the whole system and lays the groundwork for per-vault governance overlays.

- **A post-write verification hook is now active, and the status line is recoverable.** A verify-after-write check that shipped in earlier releases but was registered nowhere is now wired to run after edits; and the installer's hook reconciler can now restore the status-line command if a local settings file had overridden it.

## [v1.1.1]

Patch release. Makes the in-place upgrade engine actually deliver its fixes to **legacy adopters** — every install made before v1.1.0 introduced the version stamp. In v1.1.0 the per-file delivery path covered the hook, schema, template, and governance-scalar files, but a second copy path that ships whole directories (skills, the orchestrator, the installer support files, and the vault seed) silently skipped any file that already existed on a legacy install. The result: 18 changed files stayed at their old version even after re-running the upgrade. v1.1.1 closes that gap. Re-run `install.sh` from the updated source — see the [upgrade runbook](docs/getting-started/index.md#upgrading-an-existing-install) and the [v1.1.1 release notes](docs/release-notes-v1.1.1.md).

### Fixed

- **The whole-directory copy path now delivers on a legacy install.** The install steps that ship the skills, orchestrator, installer support files, migrations, file-type contracts, and vault seed previously used a copy mode that skipped any file already present — so on an install made before the upgrade engine existed, those files never updated. They now route through the same per-file engine the rest of the upgrade uses, so every changed file is delivered (including the eleven managed files whose paths contain spaces, which the directory copy also dropped).
- **The upgrade refuses to declare success if delivery fell short.** Before writing its completion stamp, the installer now verifies that every managed file it shipped actually reached the new version. If any file is still stale, it stops with a non-zero exit, writes no completion stamp, and does not advance its baseline — so a half-delivered home is never recorded as a finished upgrade. Simply re-running converges it.
- **A home that already ran the broken v1.1.0 self-heals.** An install that ran v1.1.0 was stamped as up to date while 18 files were still stale underneath. On v1.1.1 those pristine-but-old files are recognized as a known prior release and updated cleanly, instead of being mistaken for files you had edited and set aside as `<file>.foundation-local`.
- **The upgrade preview tells a legacy adopter the truth.** Running `bash install.sh` over an existing install used to fail with an error and print no plan. It now exits cleanly and prints an honest, write-free preview of exactly which files the upgrade would change.

## [v1.1.0]

In-place upgrades. Re-running `install.sh` over an existing install now upgrades it — detecting the installed version, applying only what changed, preserving your edits, and rolling back atomically on failure. Previously brain-stem was fresh-install only; adopters whose files go through the per-file delivery path receive fixes by re-running the installer.

### Added

- **In-place upgrade engine.** `install.sh` detects an existing install via a version stamp and performs a per-file upgrade instead of refusing or clobbering. Files delivered through the per-file path — hooks, schemas, templates, and the individual governance rule files — are compared by content hash against both the previous release and the new upstream: unchanged files are skipped, genuinely-updated files are applied, and a file you edited is updated to the new version with your bytes preserved alongside as `<file>.foundation-local`. A second path ships whole directories (skills, the orchestrator, the installer support files, the vault seed); on an install made before this version stamp existed, that path skipped any already-present file — fixed in v1.1.1. `--upgrade` makes the intent explicit; a downgrade or major-version jump is refused.
- **Atomic apply with rollback.** Every upgrade stages and validates each file before an atomic rename and journals each change; any mid-apply failure restores every already-applied file in reverse order — the upgrade is all-or-nothing.
- **Dry-run upgrade preview.** Preview exactly which files an upgrade would add, replace, or leave untouched before applying.
- **Forward-only migrations.** An idempotent migration runner applies any version-to-version state transforms once, tracked by a high-water mark.
- **Per-release manifest archive** under `governance/baselines/` — the per-version file-hash floor the upgrade engine reconstructs from, minted at each release cut.

### Fixed

- A broad set of fresh-adopter defects surfaced by an end-to-end install audit, across onboarding capture, the governance and vault guards, session-close, backup secret-hygiene, and the uninstaller:
  - The write guard, frontmatter enforcement, and the placement/staleness checks no longer error or mis-fire on a fresh adopter who has not configured a vault.
  - On the per-file delivery path, upgrades apply files whose paths contain spaces. (The whole-directory copy path still skipped pre-existing files on a legacy install in this release — corrected in v1.1.1.)
  - Backups scan for and exclude credential-shaped secrets before committing, and report deletions and push failures honestly.
  - `uninstall.sh --force-remove` preserves your own content and tolerates install paths that contain spaces.
  - Onboarding identity discovery falls back across git config, environment, `gh`, and the OS instead of giving up when global git identity is unset.

## [v1.0.2]

The plan tree's home directory is now created at install time, so plan commands work immediately after install — before onboarding.

### Changed

- `install.sh` now creates the plan-tree home (`~/.claude-plans` by default) during `--apply`, instead of deferring it to first-run onboarding. The directory is created outside `~/.claude/` (clear of the sensitive-file gate) and is declared in the install preview.

### Fixed

- `/new-plan` and the inbox-promotion helper now create the plan-tree root if it is missing — and `/new-plan --dry-run` previews without writing — instead of erroring when the root does not yet exist.

## [v1.0.1]

Patch release. Fixes a critical fresh-install regression in the default-on hook set that made v1.0.0 unusable for new adopters.

### Fixed

- `pre-write-guard` denied **every** Edit/Write on a fresh install: an empty default for the dead-plans-path tripwire made the guard match every absolute path. The guard now activates only when that tripwire path is actually configured.
- `pre-write-guard` sourced its plan-path helper from a stale (pre-relocation) location, aborting the hook under `set -euo pipefail` on a fresh install.
- `stop-drift-scan` referenced an unresolved governance-bundle path under `set -u`, crashing the hook at session stop on a fresh install.

### Added

- A clean-room runtime smoke-test that fires every default-wired hook on a fresh install and asserts the write guard allows a benign write — wired into the install-verify gate so this class of regression is caught before release.

## [v1.0.0]

First tagged release of brain-stem: a macOS-only, single-user personalization layer for Claude Code. Consolidated governance substrate, default-on hook set, onboarding flow, and the install/uninstall machinery. Fresh-install only.

### Added

- Initial public release.

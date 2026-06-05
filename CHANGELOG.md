# Changelog

All notable changes to brain-stem are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project follows semantic versioning.

For longer release narratives, see `docs/release-notes-v<version>.md`.

## [v1.1.1]

Patch release. Makes the in-place upgrade engine actually deliver its fixes to **legacy adopters** — every install made before v1.1.0 introduced the version stamp. In v1.1.0 the per-file delivery path covered the hook, schema, template, and governance-scalar files, but a second copy path that ships whole directories (skills, the orchestrator, the installer support files, and the vault seed) silently skipped any file that already existed on a legacy install. The result: 18 changed files stayed at their old version even after re-running the upgrade. v1.1.1 closes that gap. Re-run `install.sh` from the updated source — see the [upgrade runbook](docs/getting-started/index.md#upgrading-an-existing-install) and the [v1.1.1 release notes](docs/release-notes-v1.1.1.md).

### Fixed

- **The whole-directory copy path now delivers on a legacy install.** The install steps that ship the skills, orchestrator, installer support files, migrations, file-type contracts, and vault seed previously used a copy mode that skipped any file already present — so on an install made before the upgrade engine existed, those files never updated. They now route through the same per-file engine the rest of the upgrade uses, so every changed file is delivered (including the eleven managed files whose paths contain spaces, which the directory copy also dropped).
- **The upgrade refuses to declare success if delivery fell short.** Before writing its completion stamp, the installer now verifies that every managed file it shipped actually reached the new version. If any file is still stale, it stops with a non-zero exit, writes no completion stamp, and does not advance its baseline — so a half-delivered home is never recorded as a finished upgrade. Simply re-running converges it.
- **A home carrying a v1.1.0 stamp self-heals (precautionary).** v1.1.0 was an internal release that was never published, so a public upgrade goes straight from v1.0.2 to v1.1.1 and never reaches this case. It is kept as cheap insurance: if an install ever does carry a v1.1.0 stamp while files underneath are still stale, v1.1.1 recognizes those pristine-but-old files as a known prior release and updates them cleanly, instead of mistaking them for files you had edited and set aside as `<file>.foundation-local`.
- **The upgrade preview tells a legacy adopter the truth.** Running `bash install.sh` over an existing install used to fail with an error and print no plan. It now exits cleanly and prints an honest, write-free preview of exactly which files the upgrade would change.

## [v1.1.0]

In-place upgrades. Re-running `install.sh` over an existing install now upgrades it — detecting the installed version, applying only what changed, preserving your edits, and rolling back atomically on failure. Previously brain-stem was fresh-install only; adopters whose files go through the per-file delivery path receive fixes by re-running the installer.

### Added

- **In-place upgrade engine.** `install.sh` detects an existing install via a version stamp and performs a per-file upgrade instead of refusing or clobbering. Files delivered through the per-file path — hooks, schemas, templates, and the individual governance rule files — are compared by content hash against both the previous release and the new upstream: unchanged files are skipped, genuinely-updated files are applied, and a file you edited is updated to the new version with your bytes preserved alongside as `<file>.foundation-local`. A second path ships whole directories (skills, the orchestrator, the installer support files, the vault seed); on an install made before this version stamp existed, that path skipped any already-present file — fixed in v1.1.1. `--upgrade` makes the intent explicit; a downgrade or major-version jump is refused.
- **Atomic apply with rollback.** Every upgrade stages and validates each file before an atomic rename and journals each change; any mid-apply failure restores every already-applied file in reverse order — the upgrade is all-or-nothing.
- **Dry-run upgrade preview.** Preview exactly which files an upgrade would add, replace, or leave untouched before applying.
- **Forward-only migrations.** An idempotent migration runner applies any version-to-version state transforms once, tracked by a high-water mark.
- **Per-release manifest archive** under `governance/baselines/` — the per-version file-hash floor the upgrade engine reconstructs from, minted at each release cut.
- **Foundation seed tags are exempt from taxonomy-membership enforcement.** The vault seed ships its governance spokes pre-tagged, to model good tagging for adopters. Because the foundation taxonomy ships with no user-facing dimensions of its own, those example tags would otherwise be flagged as taxonomy-membership violations on a day-one install. A dedicated exempt-list suppresses exactly those shipped seed paths from the tag-not-in-taxonomy check only — the seed files are unchanged, the tag-presence rule still applies to them, and tags you author on your own files are unaffected.

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

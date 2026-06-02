# Changelog

All notable changes to brain-stem are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project follows semantic versioning.

For longer release narratives, see `docs/release-notes-v<version>.md`.

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

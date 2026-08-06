# Release notes — v1.13.1

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.13.1 is a patch release with five correctness fixes, and one of them concerns the upgrade process itself: if you installed v1.13.0, the automatic migrations that release promised may never have run on your install — silently.** This release fixes the delivery defect and heals affected installs automatically on upgrade. The other four fixes: fresh plans no longer scaffold a permanent duplicate task-list section, the checkpoint safeguard no longer false-fires right after a context compaction, human annotation keys in plan manifests now pass validation (with schema-invalid masters loudly skipped instead of silently frozen), and installs stop creating a legacy state directory that nothing writes to. **Upgrade normally with `install.sh --apply`, then run the one-line self-check below.**

---

## The headline fix — upgrades now deliver a release's own migrations, and heal installs the defect bit

brain-stem ships *migrations*: small scripts that run once during an upgrade to bring your existing install and plan corpus in line with what the new release expects. v1.13.0 introduced three of them (numbered 0005, 0006, and 0007 — normalizing overlay prefix lists, converging plan statuses to the six-status vocabulary, and removing retired surfaces from your install).

The defect: the v1.13.0 upgrade lane assembled its list of migration files to deliver from the *previous* release's frozen file inventory — which, by construction, could never list the *new* release's own migrations. The result on a v1.13.0 upgrade: the preview correctly announced that 0005/0006/0007 would run, but nothing was delivered, nothing ran, and the installed version stamp advanced anyway. That last part made the defect self-masking — a later upgrade attempt would conclude those migrations belonged to an already-installed version and skip them forever.

Two repairs in v1.13.1 close both horns:

- **Delivery:** the upgrade lane now assembles the migration copy-set from the shipped *target* manifest — the new release's own inventory — so a release's new migrations are always delivered.
- **Selection:** the migration runner now selects what to run by *set-difference* — any migration whose id is not in your install's applied-ids record, up to the target version — instead of trusting the version stamp. An install whose stamp already advanced past an unapplied migration picks it up on the next `--apply`. All shipped migrations are idempotent, so this is safe on every install regardless of history.

### Verify after upgrading (one line)

Delivery and execution are separate from the version stamp, so a bumped version alone is not proof. After `install.sh --apply`, run:

```bash
jq -r '.migrations_applied[]' "$CLAUDE_HOME/governance/.installed-state.json"
```

The list should include `0005-dimension-prefixes-reconcile`, `0006-plan-status-vocabulary`, `0007-retired-surface-removal`, and `0008-retire-legacy-hooks-state`. If any is missing, run `install.sh --apply` once more — the runner selects anything not yet applied and heals the install. If one is still missing after that second run, that is a defect to report, not something for you to fix by hand.

## What else is fixed

- **Fresh plans no longer get a permanent duplicate task-list section.** A plan's task list is a generated region bounded by render markers; the scaffolders that create a new plan placed a `## Tasks` heading (and, for sub-plans, unfilled placeholder blocks) *outside* those markers. The renderer's contract is to preserve everything outside its markers, so that stray block survived every regeneration as a duplicate footer — and the renderer's own consistency check could not see it. Scaffolding now delegates the whole region to the renderer, the single writer of that section, so a fresh plan renders exactly one task list with no leftover placeholders. Plans scaffolded before the fix keep their existing footer: if you see a second `## Tasks` heading after the closing render marker in an older plan's task file, and it contains only scaffold placeholders, delete that trailing block and re-render — that is the entire cleanup, once per affected plan.
- **The checkpoint safeguard no longer false-fires right after a context compaction.** brain-stem watches a session's context pressure and asks for a session checkpoint when pressure runs high; the checkpoint is meant to survive a *compaction* (the point where a long session's context is summarized to make room). Two defects made the safeguard demand a fresh checkpoint on the first prompt after every compaction: the canonical checkpoint file was rotated away at the compaction boundary, and a stale pressure reading survived the boundary. Both are fixed at their data surfaces — the checkpoint survives, the gauge resets and the reset itself survives recomputation — so the safeguard now fires on genuinely high pressure only.
- **Human annotation keys in plan manifests now validate.** Plan manifests are validated against a schema whose strict closed-world objects reject unknown fields — a deliberate guard on the security-sensitive sections. That guard also rejected underscore-prefixed annotation keys (such as `_note`) that exist purely for human context. The schema now allows underscore-prefixed annotation keys everywhere while continuing to reject unknown real fields inside those strict objects. Related hardening: the three generators that refuse to regenerate a derived file when a master manifest fails schema — previously a *silent* refusal that left the derived file frozen at its last good state — now surface the skip: a visible finding at session close, and a clear "skipped — manifest invalid" message when invoked directly.
- **Installs stop creating a legacy hooks-state directory.** Every install created a `hooks/state/` directory under the install home, a leftover from before runtime state moved to the dedicated state root. Nothing in normal operation writes there anymore. Fresh installs no longer create it, the shipped docs no longer name it as live, and migration 0008 (new in this release) removes the empty leftover from existing installs at upgrade. A directory that still contains anything is preserved untouched — the migration only removes it when it is verifiably empty.

## What changes at upgrade

- **Migration 0008 runs automatically** during `install.sh --apply`: it removes the legacy `hooks/state/` directory if — and only if — it exists and is empty. It is idempotent and needs nothing from you.
- **If your install came through a bitten v1.13.0 upgrade,** migrations 0005/0006/0007 run now, delivering the corpus convergence v1.13.0 described (see the [v1.13.0 release notes](release-notes-v1.13.0.md) for what each does). They are idempotent and convergent; an install where they already ran is untouched.

## Who this affects

- **Anyone who upgraded to v1.13.0** should upgrade and run the self-check — this is the group the headline fix heals. Until then, the v1.13.0 migrations may not have run on your install even though the version says v1.13.0.
- **Everyone else** gets the four other fixes automatically. Nothing you author changes, and there is nothing to migrate by hand in any scenario.

## What to do

- **Upgrade normally** (`install.sh --apply` from a fresh clone of the release, per the install guide).
- **Run the one-line self-check above** and confirm the four migration ids are present.
- **Optionally**, clean up the duplicate task-list footer in plans scaffolded before this release, as described above.

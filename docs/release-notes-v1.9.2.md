# Release notes — v1.9.2

> **Audience:** adopters running brain-stem, and anyone evaluating it. This page explains, in plain language, what this release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.9.2 is a safety release — two fixes to the upgrade path, so upgrading can no longer quietly overwrite state you have built up.** Nothing about how you author your vault, projects, or plans changes, and there is nothing to migrate. Both fixes make the same guarantee stronger: when you upgrade, the things *you* populated stay yours.

---

## What's fixed

- **Upgrading preserves your registered projects.** brain-stem keeps a small registry of the projects — it calls them "spokes" — that you have registered (for example, a work project under `~/work/`). That registry is the record of what brain-stem knows about your projects. On an upgrade, brain-stem was replacing that registry with the empty default it ships, so your registered projects went inactive until you restored the file by hand. brain-stem now *seeds* that registry only once — when it is first installed — and never overwrites it on a later upgrade. Your registered projects survive the upgrade untouched, and a fresh install still gets the starter registry it needs.

- **The project-identity migration can no longer re-stamp a plan's project.** Every plan brain-stem tracks records which project it belongs to. brain-stem ships a one-time migration that reconciles older plans — created before the current project-identity scheme — to that scheme. Two things changed here. First, that migration is now actually included in the public release; it was missing before, so on a public install it silently did nothing. Second, it has been rewritten so that it can *only* rescue a plan's older-style title into the current field — it never rewrites which project a plan belongs to. The earlier version could, when run from an unexpected location, reassign correctly-labelled plans to the wrong project; that is now impossible by construction. As an added guard, if the migration is ever launched from a location brain-stem does not recognize, it now says so loudly instead of proceeding silently.

---

## Who this affects

- **Anyone who has registered a project** (a work project, or any spoke) and then upgrades: your registry is now preserved automatically. If you upgraded a populated install before this release and found your registered projects missing, this is the fix.
- **Anyone on the public release** now receives the project-identity migration as part of the install, in its safe, rescue-only form. On a standard install it either has nothing to do or performs only the harmless title rescue.
- **Everyone else:** no visible change. There is nothing to do and nothing to migrate.

---

## Upgrading

Upgrade the way you always do (`bash install.sh --apply` from your local clone, or your usual upgrade flow).

**Everything in v1.9.2 is a safety fix.** Nothing changes how your vault, projects, or plans behave, and there is nothing to migrate. The upgrade does not touch your existing notes, plans, projects, or wiki — and now it also leaves your registered-projects registry and every plan's project identity exactly as you left them.

---

## In one sentence

brain-stem v1.9.2 makes upgrading safe for the state you populate — your registered-projects registry is preserved across upgrades, and the newly-shipped project-identity migration can only rescue a legacy plan title, never re-stamp which project a plan belongs to.

# Release notes — v1.1.1

> **Audience:** adopters upgrading brain-stem. This page explains, in plain language, what this patch fixes, who it affects, and exactly what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.1.1 is the patch that makes the v1.1.0 in-place upgrade engine actually deliver its fixes to existing installs.** v1.1.0 introduced the ability to upgrade brain-stem in place — re-running the installer to update an existing setup instead of starting over. That feature worked for new installs, but it had a gap on **older installs**: re-running the upgrade left a chunk of files at their old version without telling you. This release closes that gap. If you installed brain-stem before v1.1.0, **this is the release that finally lets you receive every fix by re-running the installer.**

---

## Who this affects

This matters most if you are a **legacy adopter** — anyone who installed brain-stem before v1.1.0. (v1.1.0 was the first release to write a small version-stamp file into your install; if your install predates it, that stamp is absent, and that is what triggered the gap below.) A fresh v1.1.0 install, or an install you make today, was never affected. But if you have been running an early version and tried to upgrade, **some of your files almost certainly stayed out of date** — and v1.1.1 is what brings them current.

---

## What was broken

brain-stem updates your install file by file, but it does so along two different internal paths. One path handles individual files — hooks, rule files, templates — and that path always worked: it compared each file and delivered the new version.

The **second** path ships whole directories at once — your **skills** (the named commands like `/onboard` and `/librarian`), the **orchestrator** (the project runner), the **installer support files**, and the **vault seed** (the starting contents of your notes vault). On an older install, that second path used a copy mode that **skips any file that already exists.** Every file in those directories already existed from your earlier install — so the copy skipped all of them. They stayed frozen at their old version, silently, *even after you re-ran the upgrade.*

The concrete result: **18 changed files stayed at the old version** — 16 of your skills, the installer's schedule-rendering script, and one vault-seed index file — with no error and no warning. Worse, once a file had silently failed to update, the install still marked itself as finished and up to date, so nothing flagged that anything was wrong.

---

## What v1.1.1 fixes

Four changes, working together:

- **The whole-directory path now delivers every file.** The skills, orchestrator, installer support files, and vault seed now route through the same per-file engine the rest of the upgrade already used — so every changed file is actually compared and updated, including the eleven managed files whose names contain spaces (which the old directory copy also dropped). → [Packaging & runtime](architecture/packaging-runtime.md)

- **The upgrade refuses to claim success if delivery fell short.** Before recording an upgrade as finished, the installer now checks that every file it shipped actually reached the new version. If any file is still stale, it **stops with a clear error** (exit code **56**, "delivery shortfall"), writes no completion stamp, and does not advance its records — so a half-finished upgrade is never mistaken for a done one. Re-running simply finishes the job. → [Packaging & runtime](architecture/packaging-runtime.md)

- **An install that already ran the broken v1.1.0 heals itself.** If you upgraded to v1.1.0 and it marked you "up to date" while 18 files were quietly stale, v1.1.1 recognizes those old-but-pristine files as a known previous release and updates them cleanly — rather than mistaking them for files *you* had edited and shelving them aside as `<file>.foundation-local` copies. Your real edits are still always preserved; only genuinely-old files get refreshed. → [Packaging & runtime](architecture/packaging-runtime.md)

- **The upgrade preview now tells you the truth.** Running `bash install.sh` to preview an upgrade over an older install used to fail with an error and print no plan at all. It now exits cleanly and prints an honest, write-free list of exactly which files the upgrade would change — so you can see the plan before you commit. → [Getting started](getting-started/index.md)

---

## What you should do

Upgrading is the same three-step routine for everyone, run from the source folder you originally cloned:

```bash
cd brain-stem
git pull              # get the new version of the source
bash install.sh | jq .   # preview the upgrade — writes nothing
bash install.sh --apply  # apply it
```

The preview (`bash install.sh`) writes zero files and shows you the full plan; `--apply` performs the upgrade. If anything is interrupted, re-running `bash install.sh --apply` picks up where it left off and converges — there is nothing to clean up by hand.

> **If `git pull` reports "divergent branches" or a `(forced update)`:** clones made before 2026-06-05 cannot fast-forward, because the public history was rewritten once to purge an accidentally-committed personal path. Realign with `git fetch origin && git reset --hard origin/main` (or delete and re-clone). This is a one-time fixup and never touches your installed `~/.claude` or your vault. The `--apply` step also needs `CLAUDE_HOME` set explicitly (`export CLAUDE_HOME=~/.claude`) and, on an upgrade, `--backup-dir <path>`.

The full, step-by-step walkthrough — including how edited files are preserved and what the delivery-shortfall error means — is in the **[Upgrading an existing install](getting-started/index.md#upgrading-an-existing-install)** runbook.

---

## Platform & licensing

- **macOS only, single-user.** Unchanged from v1.0.0 — brain-stem targets one person's Mac.
- **Open source.** Source and install instructions live in the [project repository](https://github.com/peter-tiktinsky/brain-stem#readme), under the Apache-2.0 license.

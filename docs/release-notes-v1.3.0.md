# Release notes — v1.3.0

> **Audience:** adopters running brain-stem. This page explains, in plain language, what this maintenance release changes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.3.0 is a maintenance release about where brain-stem keeps its working files.** Until now, the assistant wrote some of its own machine output — run logs, a session-close receipt, an internal working manifest — into a `Logs/` folder inside your vault, and kept other working state inside the `~/.claude` config home. This release moves all of that out: the vault becomes 100% human knowledge, and the assistant's operational exhaust lives in the standard per-user **state directory**, `~/.local/state/brain-stem`.

---

## Why this matters

Your vault is meant to hold the things *you* and the assistant write — notes, plans, decisions. Machine output mixed in among them shows up in Obsidian's search results and in the local graph view, even when it is hidden from the file list. The only way to truly keep it out of search and the graph is to not put it in the vault at all. This release does exactly that: the vault's `Logs/` folder is retired, and nothing machine-emitted is written into the vault anymore.

At the same time, the working state that used to sit under `~/.claude` (the config home) moves to where the operating system expects disposable per-tool state to live — `~/.local/state` — following the **XDG Base Directory specification**, the cross-tool convention for separating configuration, durable data, and throwaway state.

---

## Who this affects

Everyone running brain-stem, but the change is almost entirely automatic.

- **New installs** get the new layout from the start — there is nothing to do.
- **Existing installs** pick up the new path defaults automatically the next time you upgrade. The data your install has already written can be relocated with a single operator-run command (described below). For one release, the assistant reads each relocated path "new location first, old location as a fallback," so nothing breaks in between.

Two things deliberately do **not** move: the durable data tier (`~/.local/share/brain-stem`, where the writer pipeline stages content) and the install/uninstall record (`~/.claude/logs`, which the uninstaller needs to find). Your curated assistant memory is also untouched.

---

## What changed

- **The `Logs/` folder is gone from the vault.** brain-stem no longer ships a `Logs/` folder, no longer treats it as a known vault location, and no longer writes anything into it. The session-close receipt, the librarian's working manifest, cron and background run-logs, and live hook state now land under `~/.local/state/brain-stem/` — in `logs/`, `manifests/`, `hooks-state/`, and `runtime/` respectively.

- **Everything follows one state root.** All of the assistant's disposable working state now resolves under `$XDG_STATE_HOME` (which defaults to `~/.local/state`). This is the same place your other command-line tools keep state they can safely throw away and rebuild.

- **Two internal inconsistencies were fixed.** In a couple of places, a part of the system that *wrote* a file and the part that *read* it had drifted onto different paths over time. Both are now reconciled onto a single location.

---

## What to do

When you upgrade, the path defaults flip automatically:

```bash
cd brain-stem
git pull
bash install.sh | jq .                                  # preview — writes nothing
export CLAUDE_HOME=~/.claude
bash install.sh --apply --backup-dir ~/.claude-upgrade-backup
```

Then relocate the working data your install already wrote. This step is **operator-run and gated** — it is kept out of the automatic install because it moves files that live outside the config home, so it always backs up everything it touches first:

```bash
bash installer/relocate-state.sh --dry-run                       # preview the move plan; changes nothing
bash installer/relocate-state.sh --backup-dir ~/.brain-stem-relocate-backup
```

The dry run lists exactly what will move. The real run moves your existing logs, receipts, manifest, and hook state into `~/.local/state/brain-stem`, re-points the two background jobs at the new log location, and records every move in a journal so it can be reversed or resumed. If it is interrupted, re-run it with the **same** `--backup-dir` and it picks up where it left off.

You do not have to run the mover immediately — the new-location-first / old-location-fallback reads keep an un-relocated install working through this release. A future release removes that fallback once every install has moved.

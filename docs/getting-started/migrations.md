# Version migrations

> **Audience:** anyone upgrading brain-stem from one version to a newer one who wants to know whether their existing data needs any hand-work — written for a reader with no technical background. For the step-by-step upgrade *commands*, see the runbook in **[Install & upgrade](index.md#upgrading-an-existing-install)**; this page is about what happens to your **data** when you upgrade.

## Upgrading, in a nutshell

You never uninstall to move up a version. You upgrade **in place**, with the same entrypoint you installed with — there is no separate upgrade command to learn:

- **Same command, preview first.** `git pull` to get the new source, run `bash install.sh` to preview the changes (it writes nothing), then re-run with `--apply` to perform them. The exact, copy-paste sequence is the [upgrade runbook](index.md#upgrading-an-existing-install).
- **Your edits are preserved.** Any shipped file you changed is updated to the new version with your copy saved alongside it as `<file>.foundation-local` — never silently overwritten.
- **It fails loud, not silent.** If an upgrade is interrupted or falls short, it stops with a clear error and writes no "finished" stamp; just re-run `bash install.sh --apply` and it converges.

## What an upgrade migrates for you

Some releases change *where* or *how* your data is stored. When they do, the upgrade **moves your existing data into the new shape automatically** — you do not hand-migrate anything, and nothing is deleted. Here is what each such release did, so an upgrade across any of them holds no surprises:

| Upgrading across | What moved | What you do |
|---|---|---|
| **v1.1.x** | Older episodic-memory files (`episode_*.md`) are moved aside into `memory/episodic-legacy/` — preserved, just out of the active set. | Nothing. The move happens during `--apply`. |
| **v1.2.0** | The new context **Library** and per-project **binders** are built from your existing files the first time the librarian runs after the upgrade. | Nothing to migrate by hand — it backfills itself. → [Context and memory](../architecture/context-and-memory.md) |
| **v1.3.0** | The assistant's machine output — run logs, the session-close receipt, internal working state — moves **out of your vault** (the old `Logs/` folder) and out of `~/.claude` into the standard per-user state directory, `~/.local/state/brain-stem`. Your vault becomes 100% human notes. | Nothing. After upgrading, your vault no longer shows machine files in Obsidian search or the graph. → [Packaging & runtime](../architecture/packaging-runtime.md) |

The general rule: **a migration preserves your data and moves it for you.** If a future release introduces one, its [release notes](../release-notes-v1.6.0.md) will say exactly what moved and the upgrade will carry it out during `--apply`.

## Special case: old clones that won't pull

If `git pull` reports *"divergent branches"* or a *"(forced update)"*, you cloned before the public history was rewritten once to purge an accidentally-committed personal path. Realign your clone to the published history — this never touches your installed `~/.claude` or your vault:

```bash
git fetch origin
git reset --hard origin/main
```

(Or simply delete the cloned folder and `git clone` again.) This is a one-time fixup; pulls after it are ordinary. The same note, in context, is in the [upgrade runbook](index.md#upgrading-an-existing-install).

## Where to go next

- **[Install & upgrade](index.md#upgrading-an-existing-install)** — the exact upgrade commands and every option.
- **[Release notes](../release-notes-v1.6.0.md)** — what changed in each version, and why.
- **[Uninstalling](uninstall.md)** — if you'd rather remove brain-stem than upgrade.

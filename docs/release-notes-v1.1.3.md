# Release notes — v1.1.3

> **Audience:** adopters running brain-stem. This page explains, in plain language, what this maintenance release fixes, who it affects, and what to do. No prior technical background is assumed; every term is explained the first time it appears.

**v1.1.3 is a maintenance release centered on upgrading an existing install.** The first real upgrade of an older, lived-in `~/.claude` surfaced a cluster of problems the earlier releases never hit — because every prior test ran against a *fresh* home. The headline is a hard one: an adopter whose `~/.claude` already had its own `.gitignore` could enter an **upgrade that never finishes** — it refused to record itself as complete, and every re-run hit the same wall. This release fixes that and several adjacent upgrade-path issues, and ships the runtime-config and session-continuity repairs that were staged after v1.1.2.

Your vault, your settings, and your own edits are never touched beyond the managed foundation files.

---

## Who this affects

This matters most if you are **upgrading an install you have been using for a while** — one where you have added your own files, your own `.gitignore` rules, or your own plans. A brand-new install was never affected. But an existing, customized `~/.claude` is exactly the case the earlier upgrade testing missed, and it is the case this release makes safe.

It also affects anyone whose clone of the source predates **2026-06-05**, when the public history was rewritten once to remove an accidentally-committed personal path. Those clones cannot fast-forward on `git pull`; see **What to do** below.

---

## What was broken

- **An upgrade over a pre-existing `.gitignore` looped forever.** brain-stem keeps a small list of secret-bearing paths out of version control by writing them into `~/.claude/.gitignore`. To avoid clobbering rules you wrote yourself, it *merges* its block into your existing file rather than overwriting it. But the install's final self-check expected that file to match a pristine template exactly — and a merged file never does. So the check declared the install "under-delivered," refused to stamp it as complete, and stopped (exit code 56). Because the merge is idempotent, re-running produced the identical un-matching file and the identical refusal: a loop with no exit.

- **Jumping across a version on upgrade left a file behind.** Each release records the *previous* release's fingerprint file (its "baseline") so future upgrades and a clean uninstall have a floor to work from. If you upgraded directly across a version — say from v1.1.1 to v1.1.3 without stopping at v1.1.2 — the upgrade delivered only the files your older install already knew about, and skipped the newly-referenced v1.1.2 baseline. The same completeness self-check then found that file missing and refused to finish (exit code 56).

- **Discovering upgrade blockers one at a time.** The preview is meant to show every prerequisite in a single pass. In practice a few pre-flight checks stopped on the first problem, so you found out about the next one only after fixing the last — turning a one-step preview into a guessing game.

- **The written upgrade steps didn't actually run.** The getting-started upgrade instructions omitted a required step (`export CLAUDE_HOME`) and two flags you need on a real, customized home, so following them literally failed.

- **Smaller, staged-in repairs.** Session checkpoints were written to one directory and read from another (occasionally firing a false "stale checkpoint" warning); a few configuration knobs were documented as live but wired to nothing; and the user-manifest schema rejected manifests that used settings the code actually supports.

---

## What v1.1.3 fixes

- **Merge-delivered files no longer trip the completeness check.** Files that are delivered by merging into your copy (your `.gitignore`, your governance overlay) are now recognized as such and exempted from the exact-match check — so an upgrade over a pre-existing `.gitignore` converges and stamps on the first pass. → Getting started

- **A version-skipping upgrade delivers the complete set.** The upgrade engine now delivers everything the new version ships — including baselines your older install never had — not only what was already on disk. A multi-version jump now converges. → Packaging & runtime

- **The preview shows every blocker together.** A single `bash install.sh` preview now lists every required override in one place, and surfaces the genuine must-stop safety conditions (an unset `CLAUDE_HOME`, or a vault folder symlinked under the install target) in the same preview under a separate, non-waivable list — so you resolve everything before you commit to `--apply`.

- **The upgrade runbook is copy-paste runnable.** The instructions now show the required `export CLAUDE_HOME`, document `--retrofit-existing` and `--backup-dir`, and add the divergent-branch fixup for old clones. → Getting started

- **Session continuity and config hygiene.** Checkpoints are written and read from one canonical place; dead configuration knobs were removed and the live ones correctly wired; and the schema now accepts the settings the resolvers actually read.

---

## What to do

The upgrade is the same three steps as always — get the new source, preview, apply — but on a real, customized home you must set the install target and (on an upgrade) name a backup directory:

```bash
cd brain-stem
git pull
bash install.sh | jq .                                  # preview — writes nothing
export CLAUDE_HOME=~/.claude
bash install.sh --apply --backup-dir ~/.claude-upgrade-backup
```

The preview writes zero files and shows the full plan; `--apply` performs the upgrade and saves anything it replaces into the backup directory first. If anything is interrupted, re-running `bash install.sh --apply` picks up where it left off and converges — there is nothing to clean up by hand. The full walkthrough is the **Upgrading an existing install** runbook.

> **If `git pull` reports "divergent branches" or a `(forced update)`:** clones made before 2026-06-05 cannot fast-forward, because the public history was rewritten once to purge an accidentally-committed personal path. Realign with `git fetch origin && git reset --hard origin/main` (or delete and re-clone) — a one-time fixup that never touches your installed `~/.claude` or your vault.

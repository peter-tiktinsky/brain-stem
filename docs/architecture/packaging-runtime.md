# Packaging & runtime: staging the foundation into ~/.claude

> **Audience:** zero-knowledge adopters installing this foundation for the first time, plus foundation authors who want to understand exactly HOW the foundation is staged onto a machine, what records the install, how it is reversed, and where its working data lives. No prior experience with Claude Code, command-line tools, or the idea of an "install" is assumed — every term is built up from scratch the first time it appears. **This is the UNDERSTAND surface.** The APPLY surfaces — the things a machine actually executes and reads — are the installed artifacts at their real paths: the installer's own behavior (`bash install.sh` then `bash install.sh --apply`) and the machine-generated receipt at `~/.claude/governance/foundation-manifest.json`. This document is what a human reads to understand them.

---

## What "the foundation" is, and why it has to be installed at all

Claude Code is a command-line program — a tool you run by typing into a terminal — that runs an AI assistant on your own machine. Out of the box, that assistant is a blank slate: it has no rules, no automations, no reusable procedures of its own.

This project — "the foundation" — is a curated bundle that turns that blank slate into a disciplined, opinionated workspace. The bundle contains four kinds of things:

| Ingredient | Plain meaning |
|---|---|
| **Settings** | A single configuration file that tells Claude Code how to behave. |
| **Hooks** | Small scripts the program runs automatically at moments in a session (for example, when a session starts). |
| **Skills** | Reusable, named procedures you invoke on demand (for example, `/onboard`, `/govern register`, `/librarian`). |
| **Rules** | Machine-readable rule files that encode the foundation's conventions. |

"Installing" the foundation means copying that bundle out of the downloaded source folder and into the one directory Claude Code reads from when it starts up. The honest takeaway, stated up front: **nothing here is magic.** Installation is, at heart, a careful, recorded file-copy from a source folder into a destination folder — with a great deal of safety wrapped around the moment files are written.

---

## ~/.claude — where Claude lives (and CLAUDE_HOME, the knob that picks it)

When Claude Code launches, it looks in **one folder** for everything it should load: its settings file, its automation scripts, its skills, and its rules. By long-standing convention that folder is `~/.claude` in your home directory. (The `~` is shorthand for your home folder; the leading dot in `.claude` just marks the folder as hidden so it does not clutter normal file listings.) That `~/.claude` is the single per-user location Claude Code reads from at startup — confirmed in Anthropic's documentation at `code.claude.com/docs` (the source for this and every harness-behavior claim below, as of this document's writing date).

The installer copies the foundation **into** that folder. There is one knob that changes the destination: an **environment variable** named `CLAUDE_HOME`. An environment variable is just a named value the shell hands to programs when they run — think of it as a sticky note the terminal passes along. Setting `CLAUDE_HOME` to a different path tells the installer "actually, put it over there instead," which is useful for testing an install in a throwaway location without disturbing your real setup.

If `CLAUDE_HOME` is left unset, the documented default is `~/.claude`. So the mental model is simple: **`~/.claude` is "where Claude lives," and `CLAUDE_HOME` is the override that says "put it somewhere else."**

---

## Dry-run by default: the installer shows you a plan before it touches anything

The riskiest moment in any install is the first time it writes files to your disk. The foundation installer is built so that the plain command — running the installer with no extra words —

```
bash install.sh
```

**does not install anything.** Instead it prints an **action plan**: a structured list, in a machine-readable format called JSON (just text organized as labeled fields), naming every folder it would create, every file it would copy, and a short reason for each step. Then it exits — having written **zero files**.

This is called a **dry run**: a rehearsal that changes nothing. The design is deliberate: the action plan is emitted only **after** every safety check has passed, but **before** the very first folder is created, so the preview reflects fully-validated state yet cannot accidentally mutate anything. An adopter can read, on their own machine, exactly what is about to happen — folder by folder, file by file — before committing to a single write.

The plan is printed to your terminal as plain text. To read it comfortably you can pipe it through `jq` — a small command-line tool that pretty-prints and lets you filter JSON — like this:

```
bash install.sh | jq .
```

That formats the plan into readable, indented sections so you can scan the list of folders, files, and reasons. (`jq` is one of the small helper programs the install checks for; see the gates section below.)

---

## --apply: the word that turns the rehearsal into the real install

To actually perform the copy, you re-run the **same** command with one word added:

```
bash install.sh --apply
```

`--apply` is the explicit opt-in that flips the installer from preview mode into do-it-for-real mode. The design deliberately makes the **safe** thing (preview) the default and the **consequential** thing (writing files) something you must ask for by name.

There is a small but important safety asymmetry between the two modes, and it is worth spelling out:

| Mode | If `CLAUDE_HOME` is **not** set | Why |
|---|---|---|
| **Dry run** (`bash install.sh`) | Quietly assumes `~/.claude` so it can render a plausible preview, and records a `claude_home_defaulted` flag in the plan to disclose that it guessed. | A preview writes nothing, so a sensible default is harmless and convenient. |
| **Apply** (`bash install.sh --apply`) | **Refuses** — it stops with an error and exits without writing. | Real files must never land in a folder you did not consciously choose. |

The principle: a preview may assume a target; a real write may not. Files only ever land where you deliberately pointed them.

---

## Pre-flight gates: the safety checks that run before any file is copied

Before the installer creates anything, it runs a sequence of quick safety checks, internally called **gates**. Each gate answers one yes/no question and refuses to proceed if the answer is dangerous. The installer is paranoid on purpose — most gates exist to stop you from clobbering something you care about.

| Gate (plain question it asks) | What happens if the answer is dangerous |
|---|---|
| Are you running this as the all-powerful **root/administrator** account? | Refused — too much blast radius for a personal install. |
| Does the **target folder already hold someone else's unrelated Claude setup**? | Refused, unless you explicitly force it with a confirmation flag. |
| Have the foundation's **own files in an existing target been secretly edited** (their fingerprints no longer match the receipt)? | Refused — the installer detects this "drift" and stops rather than overwrite changes you may have made on purpose, unless you force it and type a confirmation phrase by hand. |
| Does the target path **secretly tunnel into your synced notes vault** via a shortcut (symlink)? | Refused outright — that path is protected, with no override. |
| Does the **plan folder already contain an existing plan tree**? | Refused unless you pass an acknowledgement flag, so the installer never silently overlays existing plan-tracking files. |
| Would merging the new settings **silently delete keys** from your existing configuration? | Refused — your existing settings are never quietly discarded. |
| If the install needs to overwrite something, can it **first prove a backup will actually work**? | Refused — when a destructive step is pending, the installer demands a writable backup location and verifies it round-trips before proceeding; no provable backup means no install. |
| Do you have the small set of **helper programs** the install needs (for example `jq`, a tool for reading the JSON data files)? | Refused if any are missing. |

A symlink, used above, is just a directory shortcut: a file that points at another location so that opening one path actually opens another. The vault-protection gate exists because such a shortcut could otherwise let an install reach into your personal notes — so that path is fenced off entirely.

---

## The manifest (ship-list): the receipt of exactly what was installed

When you install the foundation, a record is kept of **every single file** that was laid down — its location, its size, the file's permission setting, and a **fingerprint**. A fingerprint here is a **content hash** (specifically SHA-256 — short for Secure Hash Algorithm, 256-bit): a short string mathematically derived from a file's exact contents, such that if even one character changes, the fingerprint changes too. It is a tamper-evident seal.

This record is the **manifest** (also called the **ship-list**), installed at `~/.claude/governance/foundation-manifest.json`. It is a list of per-file entries; each entry records:

| Field | Plain meaning |
|---|---|
| `path` | Where the file sits, relative to the install folder. |
| `sha256` | The content fingerprint — the tamper-evident seal. |
| `mode` | Who is allowed to read or run it, encoded as a short number (for example `0755`). |
| `size` | The file's size in bytes. |

The manifest does three jobs:

1. It is the **authoritative answer** to "what does a correct install look like?"
2. It lets a later check **detect tampering** — if any shipped file has been edited, its fingerprint no longer matches the manifest.
3. It tells the **uninstaller** precisely which files are safe to remove.

The manifest covers the full set of shipped subtrees — skills, hooks, templates, governance rules, the orchestrator, schemas, the vault seed, and the installer support files (the `installer/` subtree: the background-job wrappers and the schedule-rendering script). It deliberately does **not** fingerprint the install/uninstall scripts themselves or the manifest generator — those are the machinery that performs and records the install, not part of the shipped foundation it records.

---

## Why the manifest is generated, not written by hand

It would be tempting to maintain the list of installed files by editing a document by hand. That list **always drifts**: someone adds a file and forgets to list it, or removes one and leaves a stale entry behind. A receipt that lies is worse than no receipt.

Instead, a generator script walks the **actual** source tree and emits the manifest automatically, computing each file's fingerprint, permission setting, and size as it goes. Because the **same walk** defines both what the installer ships and what the manifest records, the two cannot silently disagree. A release-time check exists specifically to catch any divergence: it fails the build if a shipped file is missing from the manifest, or if the manifest lists a file that is not actually shipped (the standard it enforces: zero unrecorded files, zero stale entries).

The lesson for the reader: **the receipt is a photograph of the truth, taken automatically — not a list someone tried to keep up to date by hand.**

---

## Uninstall: reversing the install without destroying your own work

Removing the foundation is harder than it sounds, because over time **your** files end up living right next to the foundation's files in the same folders. A blunt "delete everything in `~/.claude`" would take your edits with it.

The uninstaller (`bash uninstall.sh`) solves this by reading the manifest and going **file by file**. For each file the foundation laid down, it re-computes the fingerprint and compares it to the manifest:

| Comparison result | What it means | What the uninstaller does |
|---|---|---|
| **Fingerprint matches** | Untouched, original foundation content. | Safely removes it. |
| **Fingerprint differs** | You edited this file. | **Preserves it and reports it** — never silently deleted. |
| **File the installer never created** | Your own content. | Left alone entirely. |

So your personal edits survive an uninstall **by default**. The uninstaller's safety net is a **mandatory backup taken first**: before removing anything, it copies the entire target folder into a timestamped backup (a folder named `.pre-uninstall-<timestamp>/`), so even an unexpected outcome is fully recoverable.

> **Accuracy note:** the uninstaller does **not** have a preview / dry-run mode — that capability is explicitly listed as deferred in the uninstaller's own header (a `--dry-run` flag appears under its DEFERRED section). The pre-uninstall backup IS the safety mechanism. Do not expect uninstall to "show you a plan first"; expect it to back everything up first.

---

## Background automations and how uninstall stops them

Part of what the foundation can set up is **scheduled background jobs** on macOS — small tasks the operating system runs on a timer (for example, periodically reconciling notes). On macOS these are managed by the system's service manager, **launchd**, and each job is identified by a unique name called a **label**. (This is operating-system behavior, not Claude Code behavior; the conventions are documented by Apple. Labels by convention use a **reverse-domain name** — a naming style that starts with a broad identifier and gets more specific, like `com.apple.finder`, which macOS uses so that every program's job labels stay distinct.)

The foundation reserves a **private name-space** for its labels: every one of its jobs is named starting with `com.brain-stem`. When you uninstall, the tool stops and removes **only** the background jobs whose labels live in that reserved name-space — and it actively **refuses** to touch any job whose name merely looks similar but sits outside the reserved prefix. If it encounters such an impersonating label during cleanup, it aborts (keeping the backup intact) rather than risk stopping something unrelated.

This is why uninstall **fully** reverses the install: it pulls down the timers, not just the files. The foundation cleans up after itself, and it is careful to clean up **only its own mess**.

---

## Where runtime state lives — and why it is kept OUT of ~/.claude

There is an important difference between the foundation's **program** and its **runtime state**:

- **The program** — the scripts, skills, settings, and rules — lives in `~/.claude`. It is what you installed.
- **The runtime state** — the working data those scripts produce as you use the foundation — is the notebook the program writes in: session bookmarks, processing records, temporary scratch files, and small coordination locks (used when two Claude windows run at once so they do not step on each other).

The foundation deliberately stores runtime state in **standard locations OUTSIDE `~/.claude`**. These locations follow a widely-used operating-system convention — the **XDG Base Directory specification** (XDG, short for the cross-desktop group that authored it; the standard that defines where applications should put their data — Linux enforces it, and many macOS tools, including this foundation, follow it by convention) — for where application data belongs when it lives apart from the program folder: `~/.local/share` for durable data, `~/.local/state` for ephemeral state.

Separating the installed program from the data it generates means **uninstalling or reinstalling the program never endangers your accumulated working data**, and your backup tools can treat the two appropriately. The mental image: **"the app" and "the app's notebook" are kept in different drawers on purpose.**

---

## Durable vs. ephemeral runtime state — the two-root split

The runtime state is split into two roots, sorted by how much you would care if it vanished:

| Root | Location | Holds | Why it lives here |
|---|---|---|---|
| **Durable** | `~/.local/share/brain-stem/vault-writers/` | The write-activity database (`manifest.sqlite` — a SQLite database, i.e. a single self-contained file that stores structured records, used here to track every file the foundation writes to your vault) and per-day processing records | Expensive or impossible to recreate; lands where backup software looks. |
| **Ephemeral** | `~/.local/state/brain-stem/` | Throwaway staging scratch (`vault-staging/_archive`), per-session checkpoint files under `sessions/<session-id>/`, and the `.coordination/` directory holding the small lock files that keep multiple Claude windows on one machine from colliding | Cheap to throw away and rebuild; safe to wipe without loss. |

Putting them in different homes lets standard system conventions do the right thing: durable data lands where backup tools expect it, and ephemeral data lands where it can be cleared without losing anything that mattered. (Note: the plan files you create live in a third, separate place — `~/.claude-plans/`, described below — which is neither the program folder nor a runtime-state root.)

> **Implementation caveat — per-session checkpoints:** the canonical location for a session's checkpoint file is the ephemeral root above, `~/.local/state/brain-stem/sessions/<session-id>/checkpoint.md` (this is the path the `/session-checkpoint` skill documents and writes through the XDG state root). Be aware, however, that two hook scripts in the same foundation (the session-registration and pre-compaction-checkpoint hooks) currently resolve their per-session directory through a different default — the install-folder path `~/.claude/hooks/state/sessions/<session-id>/` — when their state-override is unset. The two defaults do not yet agree; the skill's XDG path is the authoritative one. If you are hunting for a checkpoint file and do not find it under `~/.local/state`, check `~/.claude/hooks/state/sessions/` as well.

---

## The provenance log — proof an install happened, and the uninstaller's compass

Every **real** (applied) install writes a small dated log file into `~/.claude/logs/` — named `install-<timestamp>.log` — recording the facts of that install, including a header line naming which folder it targeted (`CLAUDE_HOME: <path>`). This **provenance log** serves two purposes a non-technical reader can appreciate:

1. It is **durable evidence** of what was done and when.
2. It is how the uninstaller **double-checks** it is pointed at a genuine foundation install before it removes anything. The uninstaller reads the most recent install log, confirms one exists, and cross-checks the folder recorded in the log against the folder you asked it to uninstall. If there is **no install log**, the uninstaller **refuses** — on the principle that you cannot safely reverse an install that was never recorded. The provenance log itself, and the rest of `~/.claude/logs/`, is preserved through an uninstall.

---

## The settings file and the deep-merge

Claude Code reads a single configuration file, `~/.claude/settings.json` (confirmed at `code.claude.com/docs`). An adopter may already have their own settings there before they ever install the foundation.

The installer therefore **merges** the foundation's settings **into** the existing file rather than overwriting it. The technical term is an **atomic deep-merge**: "deep" because it combines the two settings documents field by field, all the way down through nested sections, instead of replacing one wholesale with the other; "atomic" because it either fully succeeds or leaves the original untouched — there is no half-merged middle state. As part of this merge the installer registers the foundation's automation hook entries (the scripts that run at session events). Crucially, the merge **refuses to proceed if it would silently delete any of your existing keys** — so your own configuration is preserved while the foundation's behavior is added on top.

---

## The failure modes this packaging design defends against

Every safety property above exists because a simpler design fails in a concrete, recoverable-only-with-pain way. Stated plainly:

| Design choice | The failure it prevents |
|---|---|
| **Dry-run by default** | An installer that writes immediately gives you no chance to inspect what lands where. The preview exits before the first folder is even created — provably write-free — so inspecting the plan can never mutate anything. |
| **Apply refuses an unset target** | Real files never land in a folder you did not consciously choose. |
| **Drift detection on an existing install** | A reinstall blindly overwriting foundation files you (or something else) had since edited; the fingerprint check stops and demands an explicit, typed override first. |
| **Backup-proof-of-life before any destructive step** | A destructive overwrite running with no working backup; the install verifies a writable backup round-trips before it proceeds, so "no provable backup" means "no install." |
| **Generated (not hand-edited) manifest** | A hand-kept file list drifts; a release-gate parity check fails the build on any mismatch, so the receipt cannot quietly diverge from reality. |
| **Fingerprint walk on uninstall** | Blunt deletion would take your own edits with it; the fingerprint comparison preserves anything you changed and removes only untouched originals. |
| **Mandatory backup before uninstall** | An irreversible mistake — the whole target is copied to a timestamped backup first, so even a surprise is recoverable. |
| **`com.brain-stem.*` label fence** | A careless cleanup stopping unrelated background jobs; uninstall touches only its own reserved name-space and aborts on an impersonator. |
| **Two-root state split** | Program churn (uninstall/reinstall) endangering your accumulated working data; data lives in separate drawers from the program. |
| **Provenance-log check** | An uninstaller pointed at the wrong or never-installed folder; no recorded install means no removal. |
| **settings.json deep-merge** | Overwriting your existing configuration; the merge adds without silently discarding your keys. |

---

## References

- `~/.claude/governance/foundation-manifest.json` — **the manifest / ship-list.** The machine-generated receipt: one fingerprint entry per shipped file (`path`, `sha256`, `mode`, `size`), under the top-level fields `version`, `generated_at`, `generator_sha256`, and `files`. *This is an APPLY surface — the uninstaller and the installer's tamper check read it; this document is what humans read to understand it.*
- The installer — run as `bash install.sh` (dry-run preview; pipe to `jq .` to read the plan) then `bash install.sh --apply` (real install). Dry-run-default; `--apply` opt-in; `CLAUDE_HOME` selects the target (default `~/.claude`). Pre-flight gates include the drift detector (refuses on edited foundation files in an existing target without a typed override) and the backup-proof-of-life check (refuses a destructive step unless a writable backup location round-trips). Neither the installer script nor the uninstaller nor the manifest generator is itself fingerprinted in the manifest.
- `~/.claude/uninstall.sh` — the uninstaller. Confirms a real install via the provenance log, takes a `.pre-uninstall-<timestamp>/` backup first, stops only `com.brain-stem.*` background jobs, then walks file-by-file (fingerprint match → remove, mismatch → preserve and report). No preview mode (the `--dry-run` flag is listed as deferred in the script header); the backup is its safety net.
- `~/.claude/logs/install-<timestamp>.log` — the provenance log written by an applied install; records the install facts including the `CLAUDE_HOME:` target. Its absence makes the uninstaller refuse.
- `~/.claude/governance/governance-action-log.jsonl` — an example of foundation-generated runtime state that lives under `~/.claude` (created empty at install, not copied); removed by uninstall as part of full reversal.
- `~/.claude/hooks/lib/paths.sh` — the single source of path resolution shared by the foundation's scripts. Defines `CLAUDE_HOME` (default `~/.claude`), the ephemeral state root `CLAUDE_STATE_ROOT` (default `~/.local/state/brain-stem`), its coordination directory (the session registry + locks), and the plan tree `PLANS_DIR` (default `~/.claude-plans`).
- `~/.local/share/brain-stem/vault-writers/` — the **durable** runtime-state root (write-activity SQLite database + per-day records), kept outside the installed program folder.
- `~/.local/state/brain-stem/` — the **ephemeral** runtime-state root (staging scratch, per-session checkpoints, and the lock files that keep multiple Claude windows from colliding). The `/session-checkpoint` skill documents `sessions/<session-id>/checkpoint.md` under this root as the canonical checkpoint path; note that two hook scripts default instead to `~/.claude/hooks/state/sessions/<session-id>/` when their state-override is unset, an inconsistency not yet reconciled.
- `~/.claude/settings.json` — the one configuration file Claude Code reads; the install deep-merges the foundation's settings into it rather than overwriting, and registers the foundation's hook entries.
- `~/.claude-plans/` — the on-disk plan tree (default location resolved by `paths.sh`), distinct from `~/.claude`; the installer refuses to overlay a pre-existing plan tree without an explicit acknowledgement flag.
- Anthropic docs: `code.claude.com/docs` — the `~/.claude` startup directory, `settings.json` configuration and merge semantics, hooks, and skills. Cited as the source for harness-behavior claims as of this document's writing date; if the domain or path changes, treat it as the canonical location to re-confirm.
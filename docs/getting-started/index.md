# Getting started

> **Audience:** a brand-new adopter installing brain-stem for the first time — written for someone who has never used Claude Code and has no technical background. Every term is explained the first time it appears, and every command is shown exactly as you would type it.

This page takes you from nothing to a working brain-stem setup. There are three moves: **install** the foundation, run **`/onboard`** once, then **open your vault**. The whole thing takes a few minutes.

If you would rather understand the ideas before installing anything, read **[Core concepts](concepts.md)** first, then come back here.

---

## Before you begin

You need four things in place. Each is a one-time setup that lives outside brain-stem itself:

| You need | What it is | How to check you have it |
|---|---|---|
| **macOS** | brain-stem targets a personal Mac. It is not built for other operating systems. | You are on a Mac. |
| **Claude Code** | Anthropic's command-line program that runs the Claude assistant in your terminal (the plain text window where you type commands). brain-stem is a layer *on top of* it. | Typing `claude` in a terminal opens it. Install instructions live at [Anthropic's site](https://www.anthropic.com/claude-code). |
| **git** | The standard tool for downloading and version-tracking code. | `git --version` prints a version. |
| **jq** | A small tool for reading the structured data files the installer prints. The install checks for it and a few other small helpers, and refuses to proceed if any are missing. | `jq --version` prints a version. (`brew install jq` if not.) |

A **terminal** is the plain text window where you type commands. Everything below is typed there.

---

## Step 1 — Install the foundation

"Installing" means copying brain-stem out of its downloaded folder and into the one directory Claude Code reads from when it starts up — by convention `~/.claude` in your home folder. (The `~` is shorthand for your home folder; the leading dot just marks the folder as hidden.)

Download the project and run the installer:

```bash
git clone https://github.com/peter-tiktinsky/brain-stem.git
cd brain-stem
bash install.sh
```

Here is the important safety property: **`bash install.sh` on its own installs nothing.** Instead it prints an **action plan** — a structured list naming every folder it would create and every file it would copy, with a reason for each — and then exits, having written **zero files**. This is a **dry run**: a rehearsal that changes nothing. To read the plan comfortably, pipe it through `jq`:

```bash
bash install.sh | jq .
```

The dry run is **always safe to run — even on a home that already has an older brain-stem in it.** If you previously installed an earlier version, your existing files differ from the new ones; the dry run does **not** treat that as an error. It still exits cleanly (`rc 0`), still writes zero files, and the action plan's `file_dispositions` field lists each managed file it would update and how — `replace` (take the new version), `new-ship` (a file that did not exist yet), or `sidecar` (take the new version but first save a copy of your edited one alongside it). So a single dry run shows you exactly what an upgrade would do to *your* home before you commit to it. (If you are upgrading an existing install rather than setting one up fresh, jump to **[Upgrading an existing install](#upgrading-an-existing-install)** below — the same `bash install.sh` command does both.)

When you have read the plan and want to go ahead, name the install target and re-run the **same** command with one word added. **`--apply` requires you to set `CLAUDE_HOME` explicitly** — the installer refuses to guess where to write, and hard-stops (exit code 10) if it is unset. (The dry run defaults to `~/.claude` only for the preview; the real install never guesses.)

```bash
export CLAUDE_HOME=~/.claude
bash install.sh --apply
```

`--apply` is the explicit opt-in that turns the rehearsal into the real install. The design deliberately makes the safe thing (preview) the default and the consequential thing (writing files) something you have to ask for by name. As it copies, the installer also writes a **receipt** — a record of every file it laid down, with a tamper-evident fingerprint for each — to `~/.claude/governance/foundation-manifest.json`. That receipt is what later lets the system detect tampering and lets an uninstall remove only its own files.

> If you ever want to remove brain-stem, run `bash ~/.claude/uninstall.sh`. It backs everything up first, then removes only the untouched files it originally installed — **any file you edited is preserved, never silently deleted.** The full story is in [Packaging & runtime](../architecture/packaging-runtime.md).

### Installing into a folder that already has files

If `~/.claude` already contains content that did not come from brain-stem, the installer **stops and refuses** rather than overwrite it. The dry run tells you *everything* it would need from you in one pass — it lists each required override under a `required_overrides` field in the action plan, instead of failing on the first one and making you re-run to discover the next. Read that list with:

```bash
bash install.sh | jq '.required_overrides'
```

To actually proceed past those guards on a real install, add the overrides it named. The most common one is the **overwrite-risk acknowledgement**, which you pass as a flag (no typing prompt required — this is what lets the install run unattended, e.g. in a script):

```bash
export CLAUDE_HOME=~/.claude
bash install.sh --apply --force-install --i-understand-overwrite-risk --backup-dir <path>
```

`--i-understand-overwrite-risk` is the confirmation that you accept the overwrite. (You can also type the literal token `I-UNDERSTAND-OVERWRITE-RISK` when the installer prompts for it interactively, or pass that same bare token as an argument — all three forms are equivalent.) `--backup-dir <path>` names a folder where the installer first copies anything it is about to overwrite, so nothing is lost. If your plan directory (`~/.claude-plans`) already contains plans, the action plan will also ask for `--retrofit-existing` — a one-word acknowledgement that you know those plans are there. **The installer never touches your plans;** the flag just confirms you have seen them. These overrides apply only to the real `--apply` install; the dry run never needs them — it just reports them.

---

## Step 2 — Run `/onboard`

Installing put all the moving parts in place, but the system still does not know *you*. **Onboarding is the one-time guided setup that personalizes everything.**

Start a Claude Code session and type one command:

```
/onboard
```

A **skill** is a named capability you trigger by typing a slash and its name. `/onboard` runs a short, two-part interview:

- **Section A** is a confirmation card. The system has already looked up the obvious facts — your name and email from your git settings, your timezone from your operating system, and a proposed location for your vault — and just shows them to you to accept or correct. No typing required unless something is wrong.
- **Section B** is the only part in your own words: who you are, what you do, and how you want the assistant to communicate and collaborate with you. Write loosely; the system condenses your answer into a few labeled fields. Everything here is optional.

From your answers, onboarding produces three things: a small settings file that records who you are, a personal-preferences file the assistant reads at the start of every future session, and a **brain vault** — your new, pre-built notes folder.

The full walkthrough — what each output is, how your vault is built, the optional add-ons, and how setup protects your files from a careless second run — is in **[Onboarding](onboarding.md)**.

---

## Step 3 — Open your vault

When onboarding finishes building your vault, it does not just trail off silently. It prints a clear next action:

> Open it in Obsidian (Open folder as vault) → select your vault path. Confirm when done.

**Obsidian** is a free note-taking app that treats a folder of plain-text notes as a connected knowledge base; brain-stem uses it as the human-facing window into your vault. (You do not strictly need Obsidian — the vault is just plain files any editor can open — but it is the intended way to browse it.)

Open the folder onboarding built, and you are set up. From here on, every Claude Code session starts already knowing who you are, the assistant's writes into your vault are checked as they happen, and what matters is remembered between conversations.

---

## Upgrading an existing install

If brain-stem is already installed and a newer version has been released, you do **not** uninstall and start over. You upgrade in place — and you do it with the **same** entrypoint you used to install. There is no separate upgrade command to learn.

**1 — Get the new version of the source.** Go to the folder you cloned earlier and pull the latest code:

```bash
cd brain-stem
git pull
```

> **If `git pull` reports "divergent branches" or shows a `(forced update)`:** you cloned before 2026-06-05, when the public history was rewritten once to purge an accidentally-committed personal path. Your old clone can no longer fast-forward. Realign it to the published history — this discards any local commits on your clone (you have no reason to have any) but **never touches your installed `~/.claude` or your vault**:
>
> ```bash
> git fetch origin
> git reset --hard origin/main
> ```
>
> (Or simply delete the folder and `git clone` again.) This is a one-time fixup; pulls after it are ordinary fast-forwards.

**2 — Preview the upgrade (writes nothing).** Run the installer with no extra words, exactly as a dry run:

```bash
bash install.sh | jq .
```

On an existing install this prints a write-free **upgrade plan**: the `file_dispositions` field lists every managed file the upgrade would touch and what it would do to each — `replace` (take the new version), `new-ship` (a file that did not exist yet), or `sidecar` (take the new version, but first save a copy of any file you had edited alongside it as `<file>.foundation-local`). The preview exits cleanly (`rc 0`) and changes nothing — even if your current files are an older version than the new ones. It is the honest "here is exactly what will change" view, and it is always safe to run.

**3 — Apply the upgrade.** When the plan looks right, set the target and re-run the same command with `--apply`. As on a first install, `--apply` needs `CLAUDE_HOME` set explicitly; and because an upgrade replaces your merged `settings.json`, pass `--backup-dir` so the installer first saves whatever it is about to overwrite (it hard-stops with exit code 53 if a replace is pending and no backup directory is given):

```bash
export CLAUDE_HOME=~/.claude
bash install.sh --apply --backup-dir ~/.claude-upgrade-backup
```

This delivers **every** changed managed file to the new version — including the whole shipped directories (the skills, the orchestrator, the installer support files, and the vault seed), which earlier versions could miss on an older install. Files you edited yourself are never lost: each is updated to the new version with your copy saved alongside as `<file>.foundation-local`, so your changes are preserved and clearly flagged.

**If an upgrade is interrupted or falls short, it fails loudly — and re-running fixes it.** The installer verifies, before it records the upgrade as finished, that every managed file it shipped actually reached the new version. If any file is still stale, it stops with a non-zero exit code (**56** — "delivery shortfall"), writes no completion stamp, and leaves the upgrade marked unfinished. There is nothing to clean up: just run `bash install.sh --apply` again, and it picks up where it left off and converges. A short, recoverable failure is by design always preferred over a silent, incomplete "success."

> **One thing the preview does *not* override on a real apply.** The *preview* is relaxed about your files differing from the shipped version — that difference is the whole point of an upgrade, so the dry run reports it and moves on. A real `--apply` is stricter: if it detects that brain-stem's own files have been edited in place, it still refuses to overwrite them silently and asks you to confirm, by passing `--force-install` and typing the `I-UNDERSTAND-OVERWRITE-RISK` phrase (exactly as on a first install into a folder that already has files — see [the section above](#installing-into-a-folder-that-already-has-files)). The relaxed behavior is **preview-only**; an apply never quietly writes over edited files.

That is the whole upgrade: `git pull`, preview, `--apply`. The longer story — what changed in the latest release and why the in-place upgrade is built the way it is — lives in the [release notes](../release-notes-v1.1.3.md) and [Packaging & runtime](../architecture/packaging-runtime.md).

---

## Where to go next

- **[Core concepts](concepts.md)** — the mental model behind the vault, governance, memory, plans, and sessions. Read this to understand what you just set up.
- **[Onboarding](onboarding.md)** — the detailed `/onboard` walkthrough, including how to safely re-run it.
- **The [Architecture](../architecture/governance-engine.md) section** — the full, no-prior-knowledge explanation of how each part works under the hood.

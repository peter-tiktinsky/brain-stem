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

When you have read the plan and want to go ahead, re-run the **same** command with one word added:

```bash
bash install.sh --apply
```

`--apply` is the explicit opt-in that turns the rehearsal into the real install. The design deliberately makes the safe thing (preview) the default and the consequential thing (writing files) something you have to ask for by name. As it copies, the installer also writes a **receipt** — a record of every file it laid down, with a tamper-evident fingerprint for each — to `~/.claude/governance/foundation-manifest.json`. That receipt is what later lets the system detect tampering and lets an uninstall remove only its own files.

> If you ever want to remove brain-stem, run `bash ~/.claude/uninstall.sh`. It backs everything up first, then removes only the untouched files it originally installed — **any file you edited is preserved, never silently deleted.** The full story is in [Packaging & runtime](../architecture/packaging-runtime.md).

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

## Where to go next

- **[Core concepts](concepts.md)** — the mental model behind the vault, governance, memory, plans, and sessions. Read this to understand what you just set up.
- **[Onboarding](onboarding.md)** — the detailed `/onboard` walkthrough, including how to safely re-run it.
- **The [Architecture](../architecture/governance-engine.md) section** — the full, no-prior-knowledge explanation of how each part works under the hood.

# Quickstart

> **Audience:** someone who wants to install brain-stem right now and see it working, without reading the full reference first — written for a reader new to Claude Code. This is the **condensed happy path**: the four moves, the common case, nothing else. When you hit anything unusual — an existing install, an error, an upgrade — the full runbook in **[Install & upgrade](index.md)** is the canonical, complete version.

In about five minutes you will go from nothing to a working, personalized setup. Four moves: **preview**, **install**, **onboard**, **open**.

You need a Mac with [Claude Code](https://www.anthropic.com/claude-code), `git`, and `jq` already in place. (`jq` is a small tool for reading the installer's output — `brew install jq` if you don't have it.) Full prerequisites are in [Before you begin](index.md#before-you-begin).

---

## 1. Preview (writes nothing)

Download the project and run the installer with no flags. **On its own it installs nothing** — it prints an *action plan* listing every file it would copy, then exits having written zero files. This is always safe to run.

```bash
git clone https://github.com/peter-tiktinsky/brain-stem.git
cd brain-stem
bash install.sh | jq .
```

Skim the plan. This is exactly what the next step will do — no surprises.

## 2. Install

Name where it should install (it refuses to guess), then re-run the same command with `--apply`:

```bash
export CLAUDE_HOME=~/.claude
bash install.sh --apply
```

`--apply` is the explicit opt-in that turns the preview into the real install. It copies the foundation into `~/.claude` — the folder Claude Code reads on startup — and writes a receipt of everything it laid down.

## 3. Onboard

Installing put the parts in place; it does not yet know *you*. Start a Claude Code session and run the one-time setup:

```
/onboard
```

A short two-part interview follows: first a confirmation card of facts it already looked up (your name, email, timezone, a proposed vault location — just accept or correct), then a few questions in your own words about who you are and how you like to work. From your answers it writes your preferences and builds your **vault** — your new folder of notes.

## 4. Open your vault

When onboarding finishes, it prints the path to your new vault. Open that folder in [Obsidian](https://obsidian.md) (*Open folder as vault*) — or any editor; the vault is just plain files.

That's it. From now on, every Claude Code session starts already knowing who you are, the assistant's writes into your vault are checked as they happen, and what matters is remembered between conversations.

---

## What just happened

- You did a **dry run** first, so you saw the plan before anything changed.
- `--apply` installed the foundation into `~/.claude` and left a receipt that makes a later **uninstall** safe and reversible.
- `/onboard` turned a generic install into *your* setup and built your vault.

## Where to go next

- **[Core concepts](concepts.md)** — the mental model behind what you just set up.
- **[Why brain-stem](why-brain-stem.md)** — the one-page case for each piece being built the way it is.
- **[Install & upgrade](index.md)** — the complete runbook: existing installs, error recovery, and upgrading in place.
- **[Command reference](../reference/commands.md)** — every command brain-stem adds.

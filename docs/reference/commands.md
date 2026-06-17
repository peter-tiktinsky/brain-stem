# Command reference

> **Audience:** anyone using brain-stem day to day who wants a complete, scannable list of the commands it adds — written for someone new to Claude Code. Every command is shown exactly as you type it, with the one thing it does and when you would reach for it. For the *why* and the *how*, each entry links into the deeper documentation.

A **command** here is a **slash command**: you type a slash and a name into a running Claude Code session (the terminal chat with the assistant) and it runs a packaged capability called a **skill**. brain-stem ships the commands below; they appear alongside Claude Code's own built-in commands and any other skills you have installed.

These are the **nine commands brain-stem adds for you to run directly.** A handful of other skills it ships are internal machinery — event-driven runners and a large maintenance catalog — that you do not type yourself; they are listed under [Not in this reference](#not-in-this-reference) at the end.

---

## At a glance

| Command | What it does | When you'd use it |
|---|---|---|
| [`/onboard`](#onboard) | One-time guided setup: interviews you, writes your config, builds your vault | First thing, right after installing |
| [`/govern register`](#govern-register) | Register a new governed surface (folder, file type, tag, writer, amender prompt) in your vault | When you want to extend the rules to cover something new |
| [`/new-plan`](#new-plan) | Scaffold a new plan directory in one step | Starting a multi-step project |
| [`/backlog-triage`](#backlog-triage) | Capture a raw idea and classify it against what already exists | Jotting down a project idea for later |
| [`/backlog-research`](#backlog-research) | Research a triaged idea (or in-flight plan) into a brief plus a draft plan | Turning a promising idea into something planned |
| [`/backlog-hygiene`](#backlog-hygiene) | Review the backlog for staleness and missing decisions | Periodic backlog cleanup |
| [`/session-checkpoint`](#session-checkpoint) | Write a save-point of the current conversation's state | Before a long task, or when a session is getting full |
| [`/mem-promote`](#mem-promote) | Propose moving auto-captured observations into curated memory | If you use the optional claude-mem plugin |
| [`/librarian`](#librarian) | Audit and reconcile governance, plans, and vault indexes | End-of-session cleanup; regenerating derived files |

---

## Setup

### `/onboard`

The one-time guided setup that personalizes everything. It runs a short two-part interview — a confirmation card of facts it already looked up (name, email, timezone, a proposed vault location), then a few questions in your own words about who you are and how you want the assistant to work — and from your answers it writes a settings file (`user-manifest.json`), your personal `~/.claude/CLAUDE.md` preferences file, and a freshly built **vault** (your notes folder). It also records whether you want a couple of optional external integrations. It is safe to run more than once; it will not clobber what it already wrote.

→ Full walkthrough: [Onboarding](../getting-started/onboarding.md)

## Governance

### `/govern register`

The sanctioned way to **extend the rules** to cover something the foundation does not yet know about — without editing (and without forking) the shipped rule files. Each registration lands in your personal **overlay**, which sits on top of the foundation. It has five kinds, named with `--kind`:

| `--kind` | Registers | Example |
|---|---|---|
| `folder` | A new top-level folder in your vault, with its own conventions | A new `Clients/` area |
| `file-type` | A new kind of file (its required shape) within an existing folder | A `meeting-note` type |
| `tag-extension` | New allowed values for a tag dimension | Extra status tags |
| `writer` | A new automated system that writes into your vault, so it is catalogued and governed | A scheduled importer |
| `doc-amender-prompt` | The instructions used when an automated edit needs the assistant to reconcile a file | Custom merge guidance |

You type it directly — it is never run automatically on your behalf. A typical call:

```
/govern register --kind folder --target <vault-relative-path> [--inherit-from <parent-path>]
```

→ Why governance is extended this way: [The governance engine](../architecture/governance-engine.md) · [Vault governance](../architecture/vault-governance.md)

## Plans and backlog

These four commands support running multi-step projects on disk. They are only relevant if you use brain-stem's [plans](../architecture/plans.md) workflow; you can ignore them otherwise.

### `/new-plan`

Scaffolds a complete, rule-compliant plan directory in a single step — the standard set of files a plan needs (`spec.md`, `tasks.md`, `handoff.md`, `manifest.json`, plus a placeholder idea brief) — assigning the next available number prefix and rejecting low-information folder names. A `--master` mode scaffolds a larger multi-phase plan. Use it when you want a plan set up cleanly without doing the research-first route below.

### `/backlog-triage`

Captures a raw, pre-plan idea into your idea inbox and automatically classifies it as **new**, a **duplicate**, an **overlap** with something existing, or **deferred** — so the backlog does not accumulate near-identical entries. Use it the moment an idea occurs to you.

### `/backlog-research`

Does deep research on a triaged idea (or an in-flight plan): it reads your vault, your setup, and outside best practices, then writes an **ideation brief** and a **draft plan directory**. A `--promote` flag graduates a captured idea straight into a plan. Use it when an idea is promising enough to be worth investigating before committing to it.

### `/backlog-hygiene`

A review loop over the whole backlog. It scans your idea inbox and your in-flight plans for staleness and for items missing a decision about what happens next, and with `--fix` applies safe automatic maintenance (archiving finished items, flagging the ones that need a call). Use it periodically to keep the backlog honest.

→ How plans work end to end: [Plans](../architecture/plans.md)

## Sessions and memory

### `/session-checkpoint`

Writes a **save-point** of the current conversation — what you are working on, what is done, what is next — in a fixed structure, so a long session can survive its working memory being trimmed (which Claude Code does automatically when a conversation gets long). It is also fired automatically as a session fills up; you can run it yourself before a long task or when you want a clean handoff.

→ How sessions stay on-track: [Sessions](../architecture/sessions.md)

### `/mem-promote`

Proposes moving observations from the optional **claude-mem** plugin (which auto-captures notes about your sessions) into your curated, hand-trusted **file memory**. It gathers candidates, reshapes them, checks for conflicts, and then asks before writing — it **never** writes memory automatically. This command is only useful if you have installed claude-mem.

→ What memory is here and how it is curated: [The memory model](../architecture/memory-model.md) · [Memory management](../architecture/memory-management.md)

## Maintenance

### `/librarian`

The vault, plan, and governance **maintenance** entry point. It audits and reconciles the governance rules, plan status, and the vault's auto-generated index files, and regenerates derived files (tables of contents, task lists, rule indexes) so they cannot drift out of date. End-of-session reconciliation is one of its modes. You will mostly use it to tidy up at the end of a working session.

---

## Not in this reference

A few shipped skills are **internal machinery, not commands you type:**

- **The librarian's capability catalog** — the librarian routes to a large set of named maintenance routines internally. These are a maintainer-facing surface, reached through `/librarian`, not invoked directly.
- **Event-driven runners** — the automated edit reconciler and the writer/meeting ingestion scripts run when triggered by an event or another skill, not from a prompt you type.

These exist so the surfaces above work; you do not call them yourself.

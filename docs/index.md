# brain-stem

> **Audience:** anyone deciding whether to install brain-stem, or trying to understand what it is — written for someone who has never used Claude Code and has no technical background. Every term is explained the first time it appears.

**brain-stem is a personalization layer for [Claude Code](https://www.anthropic.com/claude-code).** Claude Code is Anthropic's command-line program — a tool you run by typing into a terminal — that runs the Claude AI assistant on your own machine, where it can read and write files for you. Out of the box that assistant is a blank slate: it does not know who you are, where you keep your notes, how you like to be spoken to, or what counts as a well-formed file. brain-stem fills those gaps and keeps them filled.

---

## The problem it solves

Two problems, really, and brain-stem exists to solve both.

**The assistant forgets you.** By default the assistant has no memory between conversations. The moment you close it, it forgets everything — who you are, what you decided, how you work — and the next conversation starts blank. You would re-explain yourself every single time.

**A shared notebook drifts.** brain-stem gives the assistant a **vault** — a folder of plain-text notes that *both* you and the assistant write into. Whenever two authors share one folder, things drift: a note lands with a malformed header, two automated systems overwrite each other, a folder's table-of-contents goes stale. Left alone, the notebook slowly rots.

brain-stem answers the first problem with **memory** that survives between sessions, and the second with a **governance engine** that checks every file the moment it is written. Around both it adds first-run setup, a structured way to run multi-step projects, and machinery that keeps a single long conversation on-track.

---

## What you get

Five capabilities, each explained in plain language in [Core concepts](getting-started/concepts.md) and in full in its own architecture page:

| Capability | In one sentence |
|---|---|
| **A governed vault** | A notes folder the assistant reads from and writes into, kept structurally consistent by a rulebook consulted at every save. |
| **Memory that lasts** | A small, curated set of on-disk notes the assistant reads back at the start of every session, so it remembers what matters before you type a word. |
| **Plans** | A way to store a multi-step project on disk and shepherd it from a raw idea to a finished, verified, signed-off plan. |
| **Sessions that stay on-track** | Automatic save-points that let one long conversation survive its own memory being trimmed, and keep several open conversations out of each other's way. |
| **One-time setup** | A short guided interview (`/onboard`) that learns who you are, writes your preferences down, and builds your vault for you. |

Everything is **advisory by default**: the system teaches and reminds far more often than it blocks. It earns the right to be strict only where letting a bad write through would quietly corrupt your work.

---

## Start here

If you want to install brain-stem and use it, go to **[Getting started](getting-started/index.md)**. It walks the whole path from nothing to a working setup:

1. **Install** the foundation (a recorded, preview-first file copy into the folder Claude Code reads from).
2. **Run `/onboard`** — answer a short interview once.
3. **Open your vault** and start working.

New to the ideas? Read **[Core concepts](getting-started/concepts.md)** first — it builds the mental model in plain language before you install anything.

---

## Understand the internals

The **Architecture** section is the long-form explanation of *why* the system is built the way it is. Each page assumes no prior knowledge and defines every term from scratch:

- **[The governance engine](architecture/governance-engine.md)** — how every write is allowed, denied, or advised.
- **[Vault governance](architecture/vault-governance.md)** — how a shared, AI-maintained notebook stays trustworthy for its whole life.
- **[The memory model](architecture/memory-model.md)** — what memory is here and how it is organized.
- **[Memory management](architecture/memory-management.md)** — the mechanics that keep the auto-loaded memory index small enough to load.
- **[Plans](architecture/plans.md)** — the plan tree, the idea funnel, and the human-gated runner that can execute a plan's tasks.
- **[Sessions](architecture/sessions.md)** — checkpoints, multi-session coordination, and end-of-session cleanup.
- **[Onboarding](architecture/onboarding-lifecycle.md)** — exactly what happens the first time you type `/onboard`.
- **[Packaging & runtime](architecture/packaging-runtime.md)** — how the foundation is installed, recorded, reversed, and where its working data lives.

---

## Good to know

- **macOS only, single-user.** brain-stem targets one person's machine; it is not built for shared servers or other operating systems.
- **Nothing here is magic.** Installation is a careful, recorded file copy. Every consequential action — installing, overwriting, removing — is preview-first or asks for an explicit confirmation, and your own edits are treated as sacred.
- **Open source.** The full source and install instructions live in the [project repository](https://github.com/peter-tiktinsky/brain-stem#readme).

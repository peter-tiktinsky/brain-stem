# brain-stem

[![Latest release](https://img.shields.io/github/v/release/peter-tiktinsky/brain-stem?label=release)](https://github.com/peter-tiktinsky/brain-stem/releases)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#what-it-is)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Claude Code gives you the slots; brain-stem fills them.**

[Claude Code](https://www.anthropic.com/claude-code) is Anthropic's command-line program for running the Claude AI assistant on your own machine, where it can read and write files for you. It is deliberately a near-blank platform: it exposes extension points — a startup folder it reads on launch, a small file it auto-loads into memory, scripts that run before a write or when a session starts, a place to drop commands you can invoke — but it leaves them empty. Out of the box the assistant does not know who you are, does not remember anything between sessions, and has no opinion about what a well-formed file looks like.

**brain-stem is the layer that wires those slots into a complete, opinionated, enforced setup.** You answer a short interview once (typed or spoken). It writes a single configuration file describing your role, where your notes live, and how you like to work — and ships a default-on set of runtime guards that keep your notes structurally consistent, remember what matters between sessions, and keep a long conversation on-track. You don't assemble a toolkit; you move into a furnished foundation and personalize it at known seams.

---

## What it is

brain-stem is a **personalization and governance layer for Claude Code** — a recorded, preview-first file install into the one folder Claude Code reads from (`~/.claude`), plus a guided first-run setup that builds you a **vault**: a folder of plain-text notes that you and the assistant share.

> macOS only. Single-user. Apache-2.0.

It is **advisory by default**: the system teaches and reminds far more often than it blocks, and earns the right to be strict only where letting a bad write through would quietly corrupt your work. Nothing phones home; everything runs on your machine.

---

## Plain-language vocabulary

A few terms used throughout. Skim past any that are already familiar.

- **Claude Code** — Anthropic's CLI for Claude. You type `claude` in a terminal and get a chat with the model that can run shell commands, edit files, and call tools. It reads `~/.claude/` for its configuration.
- **Vault** — your folder of markdown notes. The term comes from [Obsidian](https://obsidian.md), which treats a directory of `.md` files as a connected knowledge base. You don't need Obsidian itself; any editor works.
- **Manifest** — a single JSON file at `~/.claude/user-manifest.json` holding your name, vault path, role, and preferences. Skills read from it at invocation to personalize behavior — config, but generated for you and structured.
- **Foundation pillars** — eight governance registries under `governance/` that define what counts as a valid vault state (frontmatter shape, tag taxonomy, naming, mandatory files, document dependencies, file-type contracts, vault writers, and plans). They ship composed into `governance/foundation-master.json` and are read by hooks at write time.
- **Overlay** — per-adopter customization at `~/.claude/governance/overlay-master.json` that extends the foundation pillars without modifying them.
- **Hook** — a shell command Claude Code runs at a lifecycle event (before a write, on session start, and so on). brain-stem ships a default-on hook set that blocks dangerous writes and surfaces context.
- **Skill** — a slash command you type in Claude Code (e.g. `/onboard`, `/librarian`). Each is a directory under `~/.claude/skills/` with a `SKILL.md` body the assistant reads at invocation.
- **Frontmatter** — the YAML block at the top of a markdown file (`---` to `---`) that carries structured metadata (`type`, `tags`, and so on).

---

## Install

Download the project and run the installer. **On its own, `install.sh` installs nothing** — it prints an action plan naming every file it would copy, then exits having written zero files. That preview is always safe to run.

```bash
git clone https://github.com/peter-tiktinsky/brain-stem.git
cd brain-stem
bash install.sh
```

Pipe the preview through `jq` to read it. When the plan looks right, name the install target and re-run with `--apply` (it refuses to guess where to write, so `CLAUDE_HOME` must be set explicitly):

```bash
bash install.sh | jq .          # same preview, pretty-printed
export CLAUDE_HOME=~/.claude
bash install.sh --apply
```

The full walkthrough — upgrading in place, installing into a non-empty folder, and uninstalling cleanly — is in **[Getting started](https://peter-tiktinsky.github.io/brain-stem/getting-started/)**.

## First run

Installing puts the moving parts in place; it does not yet know *you*. Start a Claude Code session and run the one-time guided setup:

```
/onboard
```

It runs a short two-part interview — a confirmation card of facts it already looked up (name, email, timezone, a proposed vault location), then a few questions in your own words about who you are and how you want the assistant to work — and from your answers it writes your preferences and builds your vault. Full detail in **[Onboarding](https://peter-tiktinsky.github.io/brain-stem/getting-started/onboarding/)**.

---

## What you get

Six capabilities, each explained in plain language in the documentation:

| Capability | In one sentence | Learn more |
|---|---|---|
| **A governed vault** | A notes folder the assistant reads from and writes into, kept structurally consistent by a rulebook consulted at every save. | [Vault governance →](https://peter-tiktinsky.github.io/brain-stem/architecture/vault-governance/) |
| **Memory that lasts** | A small, curated set of on-disk notes the assistant reads back at the start of every session, so it remembers what matters before you type a word. | [The memory model →](https://peter-tiktinsky.github.io/brain-stem/architecture/memory-model/) |
| **A context library** | A universal shelf of reusable reference plus a per-project binder, so research and project state are framed and never lost. | [Context and memory →](https://peter-tiktinsky.github.io/brain-stem/architecture/context-and-memory/) |
| **Plans** | A way to store a multi-step project on disk and shepherd it from a raw idea to a finished, verified, signed-off plan. | [Plans →](https://peter-tiktinsky.github.io/brain-stem/architecture/plans/) |
| **Sessions that stay on-track** | Automatic save-points that let one long conversation survive its own memory being trimmed, and keep several open conversations out of each other's way. | [Sessions →](https://peter-tiktinsky.github.io/brain-stem/architecture/sessions/) |
| **One-time setup** | A short guided interview (`/onboard`) that learns who you are, writes your preferences down, and builds your vault for you. | [Onboarding →](https://peter-tiktinsky.github.io/brain-stem/getting-started/onboarding/) |

---

## Documentation

Full documentation is published at **<https://peter-tiktinsky.github.io/brain-stem/>**. Good places to start:

- **[Why brain-stem](https://peter-tiktinsky.github.io/brain-stem/getting-started/why-brain-stem/)** — the one-page case for adopting: what it completes in the native Claude Code harness, and why each piece is built the way it is.
- **[Getting started](https://peter-tiktinsky.github.io/brain-stem/getting-started/)** — the whole path from nothing to a working setup.
- **[Core concepts](https://peter-tiktinsky.github.io/brain-stem/getting-started/concepts/)** — the mental model in plain language before you install anything.
- **[Architecture](https://peter-tiktinsky.github.io/brain-stem/architecture/governance-engine/)** — the long-form explanation of how each part works, assuming no prior knowledge.

## Contributing

brain-stem is a personal project that may be useful to others. Bug reports, feedback, and portable contributions are welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)**. There is no roadmap obligation and no guarantee a PR lands, but if you've found a bug or built something genuinely reusable on top of this, please open an issue or PR.

## Security

brain-stem runs entirely on your machine, writes only to folders it records, and makes no automatic network calls — the only network activity is something you trigger (the backup capability, or onboarding's read-only GitHub check), always to a destination you control. The trust boundary, the install/overwrite surface, and how to report a vulnerability are documented in **[SECURITY.md](SECURITY.md)**.

## License

Apache-2.0. See **[LICENSE](LICENSE)**.

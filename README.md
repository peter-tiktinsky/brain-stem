# Brain Stem

[![Latest release](https://img.shields.io/github/v/release/peter-tiktinsky/brain-stem?label=release)](https://github.com/peter-tiktinsky/brain-stem/releases)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Brain Stem provides the foundations for a personalized Claude Code operating system at install. From the moment it lands, the assistant remembers your work, organizes what that work produces, and starts every session already oriented to your projects — so long-term memory, project planning, write-time governance, session management, and information capture run as one maintained whole instead of separate pieces you wire up and keep alive yourself. It is built for anyone who works with Claude Code regularly, coding or not.

Claude Code ships out of the box with powerful capabilities and configuration tools — but the configuration itself is left mostly to you. Without heavy lifting on your part, the result is a disjointed system that never quite leverages those capabilities in unison. Brain Stem supplies the connective tissue: the support and governance systems that turn the blank slate into an interconnected engine, so you spend more time executing work efficiently and less time organizing your projects and reminding Claude how to behave.

*This README is the on-ramp: the five-minute quickstart, what Brain Stem ships, and where to read more. The full documentation site is at <https://peter-tiktinsky.github.io/brain-stem-docs/>.*

## Quickstart — five minutes, four moves

### 1 — Preview (writes nothing)

Download the project and run the installer with no flags. **On its own it installs nothing** — it prints an *action plan* listing every operation it would perform, then exits having written zero files. Always safe to run.

```bash
git clone https://github.com/peter-tiktinsky/brain-stem.git
cd brain-stem
bash install.sh
```

### 2 — Install

Name where it should install (it refuses to guess), then re-run the same command with `--apply` — the explicit opt-in that turns the preview into the real install. It copies the foundation into `~/.claude` (the folder Claude Code reads on startup) and writes a receipt of everything it laid down.

```bash
export CLAUDE_HOME=~/.claude
bash install.sh --apply
```

### 3 — Onboard

Installing put the parts in place; it does not yet know *you*. Start a Claude Code session and run the one-time setup. A short two-part interview follows — a confirmation card of facts it already looked up, then a few questions in your own words — and from your answers it writes your preferences and builds your **context store**.

```
/onboard
```

### 4 — Open your brain

When onboarding finishes it prints the path to your new store. Open that folder in [Obsidian](https://obsidian.md) (*Open folder as vault*) — or any editor; it is just plain files. From now on, every session starts already knowing who you are, every file the assistant writes into your store is checked as it happens (a file put there by a shell command is not), and what matters is remembered between conversations.

> [!NOTE]
> **Need more than the happy path?** The [Install & upgrade guide](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html) covers prerequisites, installing into a folder that already has files, upgrading in place, and error recovery. If something refuses or exits with an error, [Troubleshooting](https://peter-tiktinsky.github.io/brain-stem-docs/troubleshooting.html) lists the common failures and their fixes, and the [FAQ](https://peter-tiktinsky.github.io/brain-stem-docs/faq.html) answers the questions most people hit first.

## What Brain Stem ships

Brain Stem ships a **comprehensive suite of capabilities, wired into how Claude Code loads and runs — most of them automatically, every session.** The capture lanes run on their own outside any session once you have run a render command the installer prints, and the personalization seam runs when you call it. Three pieces set the stage once; the rest run continuously.

### Set up once — your brain, and how you reach it

- **[A governed context store](https://peter-tiktinsky.github.io/brain-stem-docs/vault-explorer.html)** — *your "brain."* The plain-text store you and the assistant both write into. A rulebook consulted whenever the assistant writes keeps it structurally consistent (allow · advise · deny), so the one place everything is captured into never drifts or rots.
- **[Guided onboarding](https://peter-tiktinsky.github.io/brain-stem-docs/onboarding.html)** — *one-time setup.* A one-time-use onboarding skill that interviews you, documents who you are and your preferences, and builds your context store for you — so the foundation starts already personalized to you.
- **[One canonical home](https://peter-tiktinsky.github.io/brain-stem-docs/vault-explorer.html)** — *optional interface · portable.* Shortcuts gather every place your context lives — plans, the Library, project binders, your work area — into a single folder, tagging already wired. Open it in Obsidian to navigate your whole knowledge graph from one place, or point any other tool at it. It is plain files; nothing is locked in.

### The capability suite — wired into how your system runs

#### [Self-organizing memory & knowledge](https://peter-tiktinsky.github.io/brain-stem-docs/context-and-memory.html)
*Context & memory.* Claude organizes its own memory and knowledge — and weaves them into each other automatically, instead of leaving them as separate piles.
- **Memory that survives, split three ways** — semantic, procedural, and episodic notes, at project and universal scope, read back at the start of every session.
- **A context library** — reusable reference plus per-project binders that frame the work and never go stale.
- **Operational and contextual, kept connected** — how Claude should act and what the work is, distinct but woven together rather than dumped in one bucket.
- **Lessons across arenas** — a lesson learned in one project is promoted into universal rules and reference, so learning transfers to every future project.

#### [Idea capture to autonomous execution](https://peter-tiktinsky.github.io/brain-stem-docs/project-management.html)
*Project management.* Set up and run multi-step work on the most optimal, research-backed conventions — with every piece of context it produces captured, organized, and kept as living reference.
- **Cheap idea capture** — jot any initiative down for almost nothing; it's triaged, stored, and maintained, then promotable into a full plan on demand.
- **Research-backed plans** — ideas become well-formed plans whose research, decisions, and materials are organized so you can thoughtfully one-shot the work.
- **Autonomous orchestration & scheduling** — ready plans run through a propose-and-gate orchestrator and scheduled skill runs, with human gates on anything irreversible.
- **A project binder that compounds** — Claude indexes every plan in a project and rolls its key materials into persistent context that grows on its own; the more you work in a directory, the better its output gets. Universal materials promote up for reuse anywhere.

#### [A doorman at every write](https://peter-tiktinsky.github.io/brain-stem-docs/write-time-governance.html)
*Write-time governance.* Every file and folder the assistant creates is checked the moment it's written, so your store stays discoverable and trustworthy without anyone remembering to be careful.
- **Allow · advise · deny** — most policy teaches with a reminder; hard blocks are reserved for writes that would corrupt structure.
- **Conventions enforced at write time** — frontmatter, naming, folder layout, and required indexes, applied by machinery rather than left to discipline.
- **Cross-document consistency** — paired documents are flagged when one drifts out of sync with another.
- **Structural, not disciplinary** — the check fires deterministically on every write it governs, regardless of whether the assistant remembers the rule.

#### [Conscious, durable sessions](https://peter-tiktinsky.github.io/brain-stem-docs/sessions.html)
*Session management.* Claude keeps one long conversation alive, coordinates several at once, and cleans up after itself on the way out.
- **Autosave for your train of thought** — checkpoints and a context-pressure ladder let a session survive its own memory being trimmed, or cold-start the next morning.
- **Multi-session coordination** — concurrent windows track who's touching what and warn before two edit the same file.
- **Conscious hand-offs** — Claude knows when to hand off to a fresh session, and reconciles what it changed before it does.
- **Decision quality** — a consequential fork is held until the assistant has researched the options.

#### [Outside information, brought in structured](https://peter-tiktinsky.github.io/brain-stem-docs/automated-capture.html)
*Automated capture.* Connectors and a single-writer pipeline turn the information you already deal with into reusable, structured assets — without re-pasting it into every session.
- **Deterministic by default** — parse, transform, write once; repeated processing stays cheap and trustworthy, with an opt-in AI lane for genuine judgment calls.
- **One reconciler, many sources** — emails, transcripts, calendar data, scrapes — all routed through a single governed writer that never collides with your edits.
- **Local and permanent** — raw source, processed outputs, and a queryable record stay on your machine, so you're never taxed for changing your mind.

#### [Built to be bent to you](https://peter-tiktinsky.github.io/brain-stem-docs/system-personalization.html)
*System personalization.* The whole foundation is made to be extended at designed seams — so you personalize it without forking it or losing your changes on an update.
- **A governed overlay** — register your own file types, folders, tags, and writers on top of the sealed rulebook; your additions survive every upgrade.
- **The work-folder guidebook** — a scaffolded home for any non-coding work, with flat and master layouts and worked examples.
- **The friction inversion** — the most universal pieces are the most customizable, so you reshape exactly what's safe to reshape.

## Documentation

The full documentation site is at <https://peter-tiktinsky.github.io/brain-stem-docs/>: an orientation, the adoption guides, one in-depth section for each capability above, and reference look-ups. Good places to start:

- [Quickstart](https://peter-tiktinsky.github.io/brain-stem-docs/getting-started.html) — the four moves above, on the site.
- [Install & upgrade guide](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html) — the complete install, upgrade, and migration runbook.
- [Onboarding](https://peter-tiktinsky.github.io/brain-stem-docs/onboarding.html) — what `/onboard` does, and how to safely re-run it.
- [Troubleshooting](https://peter-tiktinsky.github.io/brain-stem-docs/troubleshooting.html) — the common failures and their fixes.
- [Commands](https://peter-tiktinsky.github.io/brain-stem-docs/commands.html) — every command Brain Stem adds, categorized by activity.
- [Glossary](https://peter-tiktinsky.github.io/brain-stem-docs/glossary.html) — every coined term in one place.

## Optional: the claude-mem plugin

Running the optional claude-mem plugin? Turn off the context index it injects at session start. In `~/.claude-mem/settings.json` (or its Context Settings modal at `http://localhost:37777`), set both counts to 0 and every `CLAUDE_MEM_CONTEXT_SHOW_*` flag to false:

```
CLAUDE_MEM_CONTEXT_OBSERVATIONS=0
CLAUDE_MEM_CONTEXT_SESSION_COUNT=0
CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY=false
CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE=false
CLAUDE_MEM_CONTEXT_SHOW_READ_TOKENS=false
CLAUDE_MEM_CONTEXT_SHOW_WORK_TOKENS=false
CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_AMOUNT=false
CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_PERCENT=false
CLAUDE_MEM_CONTEXT_SHOW_TERMINAL_OUTPUT=false
```

Hook output is capped at 10,000 characters and, once you have real history, that index runs well past it — so the harness spills it to a `hook-*-additionalContext.txt` file in the session directory and the model receives only a preview of legend and column-key boilerplate: you pay for it every session and get almost nothing back. The trap: do not shrink it to sit just under 10,000 characters, because under the cap nothing is spilled and the whole payload is delivered in full, which costs far more than the preview does; go to zero or leave the defaults alone. Capture is untouched — the plugin's PostToolUse, Stop and SessionEnd hooks keep recording, and Brain Stem's own SessionEnd memory hook is untouched — so recall stays available on demand through the plugin's MCP search tools and its mem-search skill.

## Contributing

Brain Stem is a personal project that may be useful to others. Bug reports, feedback, and portable contributions are welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)**. There is no roadmap obligation and no guarantee a PR lands, but if you've found a bug or built something genuinely reusable on top of this, please open an issue or PR.

## Security

Brain Stem runs entirely on your machine and makes no automatic network calls. It writes to the folders listed in SECURITY.md (your Claude home, your vault, its state folders, your plan tree, the launchd job definitions under `~/.claude/Library/LaunchAgents.staging` or `~/Library/LaunchAgents`, and the project folders you register), and it can run background work: two small launchd jobs, once you run a render command the installer prints; short detached jobs at session start and end; and, when you dispatch orchestrator work with a delay, a waiting background process or, for a delay of four hours or more, a one-shot launchd job. The only network activity, and the only way a model is called, is something you trigger or explicitly configure (the backup capability, onboarding's read-only GitHub check, a writer you have routed to the assistant-mediated document amender, opt-in library promotion, model-written note descriptions when you set `DERIVE_DESC_MODEL=1`, or work you dispatch through the orchestrator, which runs Claude Code with `--permission-mode bypassPermissions`, meaning it does not stop to ask before acting), always to a destination you control or a service you already use. The trust boundary, the install/overwrite surface, what the uninstaller removes, and how to report a vulnerability are documented in **[SECURITY.md](SECURITY.md)**.

## License

Apache-2.0. See **[LICENSE](LICENSE)**.

# brain-stem

[![Latest release](https://img.shields.io/github/v/release/peter-tiktinsky/brain-stem?label=release)](https://github.com/peter-tiktinsky/brain-stem/releases)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**The nervous system for Claude Code.**

brain-stem provides Claude Code with a **brain** (a governed context & memory layer), optimizes its **body** (Claude Code's native planning, session management, and orchestration capabilities), and grows the **stem** that connects these surfaces. At install, brain-stem replaces separate, bolted-on tools with a **single integrated system** wired into how Claude runs every session — turning a generic Claude Code setup into **a truly personal AI that understands and evolves with you**.

Most "second brain" setups sit a knowledge store beside the assistant and trust discipline to keep it alive — so it *drifts*, and the assistant rarely reads it. But the store is only half the gap: Claude Code's other faculties — planning, project management, sessions, orchestration — ship just as siloed, each left for you to wire up by hand, if at all. **brain-stem closes both.** It makes the knowledge store part of how Claude works — most capture automatic, every manual write governed, what matters reloaded each session — and it tunes each native faculty to what research and practice show actually works, then connects them to the context/memory layer and to one another. You don't just get an optimized brain attached to the same unimproved tools; you get every component a **personal AI operating system** needs, each tuned to best practice and integrated with the rest.

*This README is the on-ramp: the five-minute quickstart, the full stack of capabilities brain-stem ships, and a map of the documentation. The full documentation site is at <https://peter-tiktinsky.github.io/brain-stem-docs/>.*

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

When onboarding finishes it prints the path to your new store. Open that folder in [Obsidian](https://obsidian.md) (*Open folder as vault*) — or any editor; it is just plain files. From now on, every session starts already knowing who you are, every write into your store is checked as it happens, and what matters is remembered between conversations.

> [!NOTE]
> **Need more than the happy path?** The [Install & upgrade guide](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html) covers prerequisites, installing into a folder that already has files, upgrading in place, and error recovery. The full `/onboard` walkthrough is on [Onboarding](https://peter-tiktinsky.github.io/brain-stem-docs/onboarding.html).

## What brain-stem ships

brain-stem ships a **comprehensive suite of capabilities, each wired into how Claude Code loads and runs — automatically, every session.** Two pieces set the stage once; the rest run continuously.

### Set up once — your brain, and how you reach it

- **[A governed context store](https://peter-tiktinsky.github.io/brain-stem-docs/vault-explorer.html)** — *your "brain."* The plain-text store you and the assistant both write into. A rulebook consulted at every save keeps it structurally consistent (allow · advise · deny), so the one place everything is captured into never drifts or rots.
- **[Guided onboarding](https://peter-tiktinsky.github.io/brain-stem-docs/onboarding.html)** — *one-time setup.* A one-time-use onboarding skill that interviews you, documents who you are and your preferences, and builds your context store for you — so the foundation starts already personalized to you.
- **[One canonical home](https://peter-tiktinsky.github.io/brain-stem-docs/index.html)** — *optional interface · portable.* Shortcuts gather every place your context lives — plans, the Library, project binders, your work area — into a single folder, tagging already wired. Open it in Obsidian to navigate your whole knowledge graph from one place, or point any other tool at it. It is plain files; nothing is locked in.

### The capability suite — wired into every session

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

*Write-time governance.* Every file and folder is checked the moment it's created, so your store stays discoverable and trustworthy without anyone remembering to be careful.

- **Allow · advise · deny** — most policy teaches with a reminder; hard blocks are reserved for writes that would corrupt structure.
- **Conventions enforced at write time** — frontmatter, naming, folder layout, and required indexes, applied by machinery rather than left to discipline.
- **Cross-document consistency** — paired documents are flagged when one drifts out of sync with another.
- **Structural, not disciplinary** — the check fires deterministically every time, regardless of whether the assistant remembers the rule.

#### [Conscious, durable sessions](https://peter-tiktinsky.github.io/brain-stem-docs/sessions.html)

*Session management.* Claude keeps one long conversation alive, coordinates several at once, and cleans up after itself on the way out.

- **Autosave for your train of thought** — checkpoints and a context-pressure ladder let a session survive its own memory being trimmed, or cold-start the next morning.
- **Multi-session coordination** — concurrent windows track who's touching what and warn before two edit the same file.
- **Conscious hand-offs** — Claude knows when to hand off to a fresh session, and reconciles what it changed before it does.
- **Decision quality** — a nudge to research the options before committing to a consequential fork.

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

**Getting started** covers adoption and **Reference** is for look-ups. In between sits the heart of the site: **Orientation** is your gateway into the six **Architecture & capabilities** sections — the in-depth documentation of everything brain-stem provides. Every page is listed below. The full site is at <https://peter-tiktinsky.github.io/brain-stem-docs/>.

### Getting started

*What brain-stem is, and how to adopt it — install, onboard, upgrade, and uninstall.*

- [Getting started](https://peter-tiktinsky.github.io/brain-stem-docs/getting-started.html) — this on-ramp: the quickstart, the capability suite, and this table of contents.
- [Install & upgrade guide](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html) — the complete install, upgrade, and migration runbook.
- [Onboarding](https://peter-tiktinsky.github.io/brain-stem-docs/onboarding.html) — what `/onboard` does, and how to safely re-run it.
- [Uninstalling](https://peter-tiktinsky.github.io/brain-stem-docs/uninstalling.html) — removing brain-stem cleanly and reversibly.
- [Packaging & runtime](https://peter-tiktinsky.github.io/brain-stem-docs/packaging-runtime.html) — how the install is staged, recorded, reversed, and where its data lives.

### Orientation

*Your gateway into the architecture sections below — start here to see the whole system.*

- [Introduction](https://peter-tiktinsky.github.io/brain-stem-docs/index.html) — what brain-stem is, the second-brain thesis, and the whole system in one picture.
- [Explore your brain](https://peter-tiktinsky.github.io/brain-stem-docs/vault-explorer.html) — a click-through map of everything in your store on day one.
- [Why brain-stem](https://peter-tiktinsky.github.io/brain-stem-docs/value-add.html) — the case for adopting, pillar by pillar.
- [The research rationale](https://peter-tiktinsky.github.io/brain-stem-docs/research-rationale.html) — the evidence base behind the design.

**Architecture & capabilities** — *in-depth documentation on each capability brain-stem ships; Orientation is the gateway in.*

### Context & memory

- [Context & memory](https://peter-tiktinsky.github.io/brain-stem-docs/context-and-memory.html) — the map: operational vs. contextual knowledge, at project or universal scope.
- [Dual context layers](https://peter-tiktinsky.github.io/brain-stem-docs/context-library.html) — the Workshop, the Library, and how content promotes between them.
- [The memory model](https://peter-tiktinsky.github.io/brain-stem-docs/memory-model.html) — three kinds of memory, two scopes, and the hot index under a hard cap.
- [What loads each session](https://peter-tiktinsky.github.io/brain-stem-docs/session-loading.html) — exactly what context assembles at session start, and what stays on-demand.
- [Why: context & memory](https://peter-tiktinsky.github.io/brain-stem-docs/context-memory-rationale.html) — the rationale behind the memory split and the load tiers.
- Running the optional `claude-mem` plugin? Turn off the context index it injects at session start: in `~/.claude-mem/settings.json` (or its Context Settings modal at `http://localhost:37777`) set `CLAUDE_MEM_CONTEXT_OBSERVATIONS=0`, `CLAUDE_MEM_CONTEXT_SESSION_COUNT=0` and every `CLAUDE_MEM_CONTEXT_SHOW_*` flag to `false` — including `CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY`, `CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE`, `CLAUDE_MEM_CONTEXT_SHOW_READ_TOKENS`, `CLAUDE_MEM_CONTEXT_SHOW_WORK_TOKENS`, `CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_AMOUNT`, `CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_PERCENT` and `CLAUDE_MEM_CONTEXT_SHOW_TERMINAL_OUTPUT`. Hook output is capped at 10,000 characters and, once you have real history, that index runs well past it — so the harness spills it to a `hook-*-additionalContext.txt` file in the session directory and the model receives only a preview of legend and column-key boilerplate, meaning you pay for it every session and get almost nothing back. The trap: do not shrink it to sit just under 10,000 characters, because under the cap nothing is spilled and the whole payload is delivered in full, which costs far more than the preview does; go to zero or leave the defaults alone. Capture is untouched — the plugin's PostToolUse, Stop and SessionEnd hooks keep recording, and brain-stem's own SessionEnd memory hook is untouched — so recall stays available on demand through the plugin's MCP search tools and its mem-search skill.

### Project management

- [Project management](https://peter-tiktinsky.github.io/brain-stem-docs/project-management.html) — the operational side of getting work done.
- [Project organization](https://peter-tiktinsky.github.io/brain-stem-docs/work-surface.html) — code repositories and Work folders, and how each rolls up into the binder.
- [Plans](https://peter-tiktinsky.github.io/brain-stem-docs/plans.html) — the plan lifecycle from idea to machine-verified result.
- [Orchestration & scheduling](https://peter-tiktinsky.github.io/brain-stem-docs/orchestration.html) — the propose-and-gate runner and the scheduling substrate.
- [The project binder](https://peter-tiktinsky.github.io/brain-stem-docs/project-binder.html) — the per-project roll-up loaded at session start.
- [Why: project management](https://peter-tiktinsky.github.io/brain-stem-docs/project-management-rationale.html) — the design decisions behind the section.

### Write-time governance

- [Write-time governance](https://peter-tiktinsky.github.io/brain-stem-docs/write-time-governance.html) — conventions enforced at the moment of every write.
- [The governance engine](https://peter-tiktinsky.github.io/brain-stem-docs/governance-engine.html) — the doorman (allow, advise, deny) and its eight pillars.
- [The single document](https://peter-tiktinsky.github.io/brain-stem-docs/single-document.html) — the rules that govern one file in isolation.
- [Across documents & folders](https://peter-tiktinsky.github.io/brain-stem-docs/across-documents.html) — the rules that cross file boundaries.
- [Why: write-time governance](https://peter-tiktinsky.github.io/brain-stem-docs/governance-rationale.html) — the reasoning behind the enforcement model.

### Session management

- [Session management](https://peter-tiktinsky.github.io/brain-stem-docs/sessions.html) — the session lifecycle, from start to close.
- [Checkpoints](https://peter-tiktinsky.github.io/brain-stem-docs/checkpoints.html) — the context-pressure ladder and the Continuity Block.
- [Multi-session coordination](https://peter-tiktinsky.github.io/brain-stem-docs/multi-session.html) — the shared registry and same-file warnings.
- [Session close](https://peter-tiktinsky.github.io/brain-stem-docs/session-close.html) — deregistration, reconciliation, and the cleanup chain.
- [The decision-quality protocol](https://peter-tiktinsky.github.io/brain-stem-docs/decision-quality.html) — research before you commit to a fork.
- [Why: session management](https://peter-tiktinsky.github.io/brain-stem-docs/session-management-rationale.html) — the rationale behind checkpoints and the registry.

### Automated capture

- [Automated capture](https://peter-tiktinsky.github.io/brain-stem-docs/automated-capture.html) — connectors and writers that bring outside information in.
- [The vault-writer system](https://peter-tiktinsky.github.io/brain-stem-docs/vault-writers.html) — the capture pipeline end to end.
- [Why: automated capture](https://peter-tiktinsky.github.io/brain-stem-docs/automated-capture-rationale.html) — the design decisions behind the pipeline.

### System personalization

- [System personalization](https://peter-tiktinsky.github.io/brain-stem-docs/system-personalization.html) — the operational foundation for a personalized setup.
- [Governance personalization](https://peter-tiktinsky.github.io/brain-stem-docs/governance-personalization.html) — the governed overlay seam for extending the rules.
- [The work-folder guidebook](https://peter-tiktinsky.github.io/brain-stem-docs/work-folder-guidebook.html) — setting up and running any non-coding work.
- [Why: system personalization](https://peter-tiktinsky.github.io/brain-stem-docs/personalization-rationale.html) — the reasoning behind the personalization model.

### Reference

*General look-ups for day-to-day use.*

- [Commands](https://peter-tiktinsky.github.io/brain-stem-docs/commands.html) — every command brain-stem adds, categorized by activity.
- [Glossary](https://peter-tiktinsky.github.io/brain-stem-docs/glossary.html) — every coined term in one place.
- [FAQ](https://peter-tiktinsky.github.io/brain-stem-docs/faq.html) — short answers to the most common questions.

## Contributing

brain-stem is a personal project that may be useful to others. Bug reports, feedback, and portable contributions are welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)**. There is no roadmap obligation and no guarantee a PR lands, but if you've found a bug or built something genuinely reusable on top of this, please open an issue or PR.

## Security

brain-stem runs entirely on your machine, writes only to folders it records, and makes no automatic network calls — the only network activity is something you trigger or explicitly configure (the backup capability, onboarding's read-only GitHub check, or a writer you have routed to the assistant-mediated document amender), always to a destination you control or a service you already use. The trust boundary, the install/overwrite surface, and how to report a vulnerability are documented in **[SECURITY.md](SECURITY.md)**.

## License

Apache-2.0. See **[LICENSE](LICENSE)**.

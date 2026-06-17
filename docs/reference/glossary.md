# Glossary

> **Audience:** anyone reading the brain-stem documentation who hits a term they don't recognize. Every entry is defined in plain language with no assumed background. Terms are also glossed inline the first time they appear on each page; this is the one place they all live together.

### Action plan
The structured list the installer prints during a [dry run](#dry-run) — every folder it would create and every file it would copy, each with a reason. Printing it changes nothing.

### Advisory
One of the three answers the [governance engine](#governance-engine) can give a write: allow, **advise** (let it through but attach a warning), or deny. brain-stem is *advisory by default* — it warns far more often than it blocks.

### Atomic write
Writing to a temporary file and then renaming it into place in a single step, so a reader never sees a half-written file.

### Claude Code
Anthropic's command-line program for running the Claude AI assistant on your own machine, where it can read and write files. You start it by typing `claude` in a terminal. It reads the folder `~/.claude/` for its configuration. brain-stem is a layer on top of it.

### CLAUDE_HOME
The directory brain-stem installs into — the folder Claude Code reads on startup, by convention `~/.claude`. The installer refuses to write unless you set this explicitly.

### Content hash (fingerprint)
A fixed-length signature computed from a file's exact bytes; the same bytes always produce the same hash. brain-stem uses hashes to tell a file you edited apart from an untouched shipped one.

### Context library
The three places framed reference and project material live: the universal **Library** (reusable across any project), a per-project **binder** (everything about one project), and an ephemeral **Workshop** (a staging area that feeds the other two). Distinct from [memory](#memory). → [Context and memory](../architecture/context-and-memory.md)

### Dry run
Running the installer with no flags: it prints the [action plan](#action-plan) and exits having written **zero files**. A rehearsal that changes nothing, and always safe to run.

### Fan-in
Several [writers](#writer) targeting one destination file. The [reconciler](#reconciler) serializes them so they don't overwrite each other.

### Foundation pillars
The governance registries under `governance/` that define what counts as a valid vault state — frontmatter shape, tag taxonomy, naming, mandatory files, document dependencies, file-type contracts, vault writers, and plans. They ship composed into a single bundle read by [hooks](#hook) at write time.

### Foundation-master.json
The composed governance bundle — all the [foundation pillars](#foundation-pillars) merged into one file — that the write-time guards actually read. It is generated from the source pillars, never hand-edited.

### Frontmatter
The YAML metadata block at the top of a markdown file, fenced by `---`. It carries structured fields like `type` and `tags`. Governance reads it to decide whether a file is well-formed.

### Governance engine
The machinery that inspects every write the assistant makes and answers allow / [advise](#advisory) / deny, by consulting the [foundation pillars](#foundation-pillars) plus your [overlay](#overlay). → [The governance engine](../architecture/governance-engine.md)

### Hook
A shell command Claude Code runs automatically at a fixed lifecycle moment — before a write, when a session starts, and so on. brain-stem ships a default-on set that blocks dangerous writes and surfaces context.

### Manifest
Two different files share this word. **`user-manifest.json`** holds your identity and preferences, generated for you at onboarding and read by skills. **`foundation-manifest.json`** is the install *receipt* — the list of every file the installer laid down, each with a [content hash](#content-hash-fingerprint), used to detect tampering and to drive a safe uninstall.

### Memory
The small, curated set of on-disk notes the assistant reads back at the start of every session. It comes in two scopes — **global** (true everywhere) and **project** (specific to one working directory) — and is distinct from the [context library](#context-library). → [The memory model](../architecture/memory-model.md)

### Onboarding
The one-time guided setup, run by typing `/onboard`, that interviews you, writes your configuration, and builds your vault. → [Onboarding](../getting-started/onboarding.md)

### Overlay
Your per-adopter customization layer (`overlay-master.json`) that extends the [foundation pillars](#foundation-pillars) without modifying them. It is empty on a fresh install; your additions win on a collision only when you record a reason.

### Packet
The small, [content-hash](#content-hash-fingerprint)-named data file a [writer](#writer) drops into a staging area to describe one intended write, when a destination uses the staged pipeline rather than writing directly.

### Plan
A multi-step project stored on disk as a small set of files (a spec, a task list, a handoff note, and a machine-readable control file). The plan tree shepherds it from a raw idea to a finished, verified, signed-off state. → [Plans](../architecture/plans.md)

### Posture
The per-destination choice between the **direct** write path (the default) and the **staged** pipeline (opt-in), which decides how writes to that file are handled.

### Reconciler
The single mechanical program that is the sole writer of any destination opted into the staged pipeline — it applies [packets](#packet) one at a time with [survivorship](#survivorship) and an [atomic write](#atomic-write).

### Sentinel
An invisible HTML-comment marker bracketing a machine-owned region of a file, so an automated update edits only inside that region and leaves your prose alone.

### Session
One continuous conversation with the assistant. A long session is **compacted** (lossily summarized) by Claude Code when its working window fills; brain-stem adds automatic **checkpoints** — save-points of the session's state — so it survives that trimming. → [Sessions](../architecture/sessions.md)

### Skill (slash command)
A packaged capability you trigger by typing a slash and its name (e.g. `/onboard`). Each is a directory under `~/.claude/skills/` with a `SKILL.md` body the assistant reads at invocation. → [Command reference](commands.md)

### Survivorship
The design rule that a human's hand-edit always wins over an automated regeneration. Your edits are preserved, never silently overwritten.

### Vault
Your folder of plain-text markdown notes that you and the assistant share. The term comes from [Obsidian](https://obsidian.md); you don't need Obsidian itself — any editor works.

### Write-time
Checked at the instant a file is about to be saved, before it lands on disk — as opposed to a later scan that finds problems after the fact.

### Writer
Any system that produces vault content — the assistant itself, a scheduled importer, or an automated flow. brain-stem keeps a catalogue of every writer so each one is governed.

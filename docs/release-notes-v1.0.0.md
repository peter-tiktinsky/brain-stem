# Release notes — v1.0.0

> **Audience:** adopters installing or upgrading brain-stem. This page summarizes what the first stable release delivers, in plain language; every capability links to the documentation that explains it in full.

**v1.0.0 is the first stable release of brain-stem** — a personalization layer for [Claude Code](https://www.anthropic.com/claude-code) that turns a blank-slate AI assistant into one that remembers who you are, keeps a shared notes vault trustworthy, and helps you run multi-step projects. This release is feature-complete for daily single-user use on macOS. Everything below ships in the install.

---

## Installation & packaging

- **Preview-first installer.** Running `bash install.sh` prints a complete action plan and writes **zero files**; you opt in to the real install with `bash install.sh --apply`. The safe thing is the default; the consequential thing you ask for by name.
- **A tamper-evident receipt.** Every applied install writes a generated manifest to `~/.claude/governance/foundation-manifest.json` recording every file laid down, each with a content fingerprint. The receipt is generated from the actual files, never hand-kept, so it cannot quietly drift from reality.
- **Safe, reversible uninstall.** `bash ~/.claude/uninstall.sh` backs the whole target up first, then removes only the untouched files it originally installed — **any file you edited is preserved and reported, never silently deleted.** It also stops only its own scheduled background jobs, leaving anything unrelated alone.
- **Your existing configuration is preserved.** The install merges its settings into your existing Claude Code configuration field by field, and refuses to proceed if it would silently drop any of your keys.

→ Packaging & runtime

## First-run setup

- **One-command onboarding.** `/onboard` runs a short two-part interview — a confirmation card of facts the system already knows, plus a free-form description in your own words — and produces your settings file, your personal-preferences file, and a pre-built **brain vault**, then points you to open it in Obsidian.
- **Run-once safety.** Onboarding refuses to run a second time by accident; redoing it takes an explicit `--force`, and even then your edited files are preserved rather than overwritten.

→ Getting started · Onboarding

## The governed vault & the governance engine

- **A rulebook at every write.** A write-time guard checks every file the assistant is about to create or edit and returns one of three answers — allow, advise, or deny. Most policy is *advisory*: the system teaches and reminds far more than it blocks, reserving hard denial for writes that would corrupt structure.
- **Shipped rules plus your overlay.** The governance rules ship composed into a single bundle, combined at write-time with an **overlay** for your own additions — laid on top like a transparent sheet, so you extend the system without ever editing the shipped rules and can take future updates without losing your customizations. The overlay starts empty.
- **A guided way to extend it.** `/govern register` adds a new folder, document type, tag dimension, or automated writer through a propose-then-confirm conversation — never a hand-edited file — and records every change in an audit log.
- **Per-document contracts.** Specific document types (meeting notes, plan files, decision records, and more) each carry a small rulebook stating what they must contain, all enforced through the same guard.
- **A safe pipeline for automated writers.** Systems that write into your vault can funnel through a single coordinating program — the *reconciler* — that performs every write in one all-or-nothing step (so a file is never caught half-written), and **your hand-edits always win** over an automated regeneration.

→ The governance engine · Vault governance

## Memory

- **Knowledge that survives sessions.** A small, curated set of on-disk notes — split into timeless facts, how-to knowledge with its reasoning, and dated session records — is read back automatically at the start of every session, so the assistant remembers what matters before you type a word.
- **Two scopes, with a promotion path.** Per-project memory and global memory live side by side; a fact that proves universal can be promoted up into your global rules (propose-by-default, never touching your personal-preferences file).
- **A recommended optional plugin.** brain-stem works fully on its own curated memory; an optional recall plugin can be added during setup for broader automatic recall.

→ The memory model · Memory management

## Plans & the orchestrator

- **A plan tree on disk.** Each project is a small folder whose machine-readable control file is the real record of status and tasks; the human-readable to-do list is a generated copy kept in sync.
- **An earned "done."** A plan moves through a fixed lifecycle in which a person can *claim* completion but the verified stage is stamped only by an actual automated check — and a plan cannot be signed off until it is verified.
- **A cheap idea funnel.** Capture any idea without burning a project number; numbers are assigned only when an idea graduates into a real plan. `/new-plan`, `/backlog-triage`, `/backlog-research`, and `/backlog-hygiene` drive the funnel.
- **A human-gated runner.** The orchestrator can execute a plan's tasks automatically, but proposes and waits for your go-ahead on anything risky — it is not an unattended daemon.

→ Plans

## Sessions & continuity

- **Autosave for your train of thought.** A per-session checkpoint continuously captures where you are, so a long conversation survives its working memory being trimmed and a fresh session can be cold-started cleanly. Pressure on the working memory escalates the reminder to save your place.
- **Multi-session coordination.** Several open conversations stay out of each other's way through a shared list (a *registry*), including a warning when another session has touched a file you are about to edit.
- **One-command close-out.** `/librarian session-close` runs the end-of-session housekeeping — refreshing indexes, reconciling plans, and writing a short receipt — as an advisory routine that never blocks you.

→ Sessions

## Vault maintenance

- **The librarian.** `/librarian` bundles the vault-health sweeps that keep folder indexes current, regenerate the automated-writer catalogs, and flag tag and staleness drift — catching accumulated drift across the whole vault that the one-file-at-a-time write guard cannot see.

→ Vault governance

## Documentation

- **This site.** A complete, zero-prior-knowledge documentation set: a getting-started path for new adopters and a full architecture section explaining *why* each part is built the way it is.

---

## Deliberately deferred in v1.0.0

A few capabilities are intentionally left for a later release, and the system is honest about them rather than implying they exist:

- **Uninstall has no preview mode.** Unlike install, the uninstaller does not print a dry-run plan; its safety mechanism is the mandatory backup it takes first.
- **Automatic memory overflow is not built yet.** The rule for relocating the coldest memory entries out of the auto-loaded index is documented and its structure is in place, but the automatic spill itself is gated on real usage demand and ships disabled.
- **Voice onboarding is not in the shipped flow.** Onboarding captures your written answers today; a spoken-voice option is a possible future addition.

---

## Platform & licensing

- **macOS only, single-user.** brain-stem targets one person's Mac; it is not built for shared servers or other operating systems.
- **Open source.** Source and install instructions live in the [project repository](https://github.com/peter-tiktinsky/brain-stem#readme), under the Apache-2.0 license.

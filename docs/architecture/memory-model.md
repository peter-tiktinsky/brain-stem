# The memory model — how the assistant remembers across sessions

> **Audience:** anyone who wants to understand WHAT memory is in brain-stem and HOW it is organized — written for a reader who has never used Claude Code and has no technical background; every term is glossed on first use. **This doc is canonical for:** the meaning of memory here, the Semantic/Procedural/Episodic retrieval triad and why it exists, the project-vs-global memory scopes and the promotion pipeline that feeds global memory, the memory-vs-context distinction, the three accessibility layers, and the other mineable runtime surfaces. **This is the structure-first LEAD doc;** the mechanical size-limit detail lives in the companion `memory-management.md`, pointed to at the end.

---

## What "memory" means here

**Claude Code** is a tool that runs an AI assistant inside your terminal. (The *assistant* is the AI you talk to; a *terminal* is the plain text window where you type commands.) A unit of work with the assistant — one continuous conversation, from when you open it to when you close it — is called a **session**.

By default the assistant has no memory at all. The moment a session ends, it forgets everything: every new session starts blank, with no recollection of who you are, what you decided last time, or how you like to work. You would have to re-explain yourself from scratch, every single time.

**Memory** is the fix. It is the set of small plain-text notes the system keeps **on disk** — saved as files on your computer, so they survive the session ending — so that the assistant remembers what matters *before you type a word*. At the start of each new session the system reads those notes back in, and the assistant picks up where it left off.

Two plain analogies make the rest of this doc easier:

- Memory is a **filing cabinet** that stays full between meetings.
- The assistant's live, in-session attention is a **whiteboard** that gets wiped clean at the end of each meeting.

The whole point of memory is to move what matters off the whiteboard and into the cabinet before it gets erased. The rest of this document explains how those notes are *structured*, *scoped*, and *reached*.

---

## Structure first — the retrieval triad and why it exists

Memory is not one undifferentiated pile of notes. It is split into **three kinds**, because not all durable knowledge is the same kind of thing. This split is the spine of the whole model — understand it first, and everything else falls into place.

| Kind of memory | Plain meaning | Example |
|---|---|---|
| **Semantic** | Timeless facts, preferences, identity, and naming conventions — the assistant's *standing knowledge* of who you are and how your world is named. | "The user prefers direct, unhedged writing." "The client's project is named Acme." |
| **Procedural** | How-to knowledge: workflow rules **plus the reasoning behind them**, including lessons learned from past mistakes. | "Always run the tests after writing code — because a silent failure last time shipped a broken file." |
| **Episodic** | Dated records of what happened in **one specific work session** — a time-anchored account of events. | "On 2026-05-29, fixed the seed hook; the marker file was missing." |

A quick gloss on the word **retrieval**: it just means *getting a fact back out when you need it*. These three are called the *retrieval triad* because they are the three categories the assistant pulls knowledge from.

### Why these three, and not some other split

This is not an arbitrary choice. The three-way division is the long-standing consensus from the study of human memory, carried forward into the design of AI agents:

- The distinction between **episodic** memory (specific dated events) and **semantic** memory (general timeless facts) was drawn by the psychologist Endel Tulving in 1972 — the original split that separates "what happened to me" from "what I know."
- The distinction between **declarative** knowledge ("knowing that" — facts and events) and **procedural** knowledge ("knowing how" — skills and workflows) was established by Cohen and Squire in 1980.
- The **CoALA** framework (a 2023 research paper, *Cognitive Architectures for Language Agents*) is the work that explicitly maps these same three memory types onto AI assistants built on language models — exactly the kind of assistant Claude Code runs.
- **MemGPT** (a 2023 research paper) contributed the *tiering* idea this model leans on: a small, always-present **core** of the highest-value knowledge, separate from a large **archive** that is searched only when something specific is needed. The triad above is the small always-present core.

A fourth candidate type — **"reflective"** memory — was deliberately **not** added. Reflection is a *process*, not a thing you store: it is the act of turning episodes into durable facts and rules ("we kept hitting this bug, so the rule is now X"). The *output* of reflection is a fact or a workflow rule, which already belongs in the Semantic or Procedural tier. So reflection rides on top of the existing three rather than becoming a fourth box.

### Why the highest-signal facts must be pinned in a small curated set

The triad is small and curated **on purpose**. The temptation is always to catch *everything* — to log every observation just in case. The problem is that a catch-everything store degrades fast: the directional finding from the memory-systems literature (mem0.ai, 2026) is that fewer than a quarter of automatically-captured items are still relevant to any given future question after roughly a month — and it worsens with every new write. A pile that keeps everything quickly becomes mostly noise, and noise drowns the few facts that genuinely matter.

So the design pins the highest-signal knowledge — the facts, rules, and identity that stay true — in a small, deliberately maintained set, and keeps the noisy, time-decaying material in separate, additive layers (described later in this doc). The triad is the signal; the wider layers are the safety net.

---

## Project vs global memory — two scopes

Memory comes in **two scopes**, and they live in different places. A *scope* is simply *how widely something applies* — to one project, or to everything you do.

| Scope | What it is | Where it lives | Loaded when |
|---|---|---|---|
| **Project memory** | Per-project notes, organized internally by the Semantic/Procedural/Episodic triad. One note-file per topic, plus a single index file. | `~/.claude/projects/<project>/memory/` — a separate folder for **each** project you work in. | The start of every session in **that** project. |
| **Global memory** | Knowledge that applies to *all* your work, regardless of project. Two surfaces. | `~/.claude/CLAUDE.md` and `~/.claude/rules/` | The start of **every** session, in every project. |

The plain analogy: **project memory is the notebook for one job** — it travels with that job and nobody else's. **Global memory is the standing instructions pinned to the assistant's desk** — they apply to every job that crosses the desk.

### Project memory in detail

Project memory is a folder containing:

- **`MEMORY.md`** — the **index** (a single file that lists and points to all the others, like a table of contents). This one file is *auto-loaded* — read in automatically by the tool — at the start of every session in that project. It is organized into the three triad sections in a fixed order: Semantic, then Procedural, then Episodic.
- **`*.md` topic files** — one short note per topic, holding the actual detail. Each declares, in its header, which retrieval type it is (semantic, procedural, or episodic). These are read *on demand* — only when the assistant actually needs that topic — not all at once at startup.

The first time a project needs project memory, the system **seeds** it automatically — it creates a starter `MEMORY.md` from a shipped template — so you never have to set it up by hand.

### Global memory in detail

Global memory is **two** surfaces, both loaded in every session:

1. **`~/.claude/CLAUDE.md`** — your **personal-preferences file**: an always-on operating framework describing how you want the assistant to communicate, your working patterns, and your standing preferences. It is authored once, during first-run setup, and from then on it is **yours to hand-edit**. No automated process is ever allowed to write to it.
2. **`~/.claude/rules/`** — the **rules folder**: a place for global directives that should apply across all your work. This is a **native Claude Code surface** — meaning a folder the tool itself knows to read at startup, not something brain-stem invented. The tool loads it every session. It starts **empty** (apart from a short README explaining how it works) and fills up only as you populate it.

> When more than one preferences file is in play — for example, a global one and a project-specific one — the tool **combines them by stacking, broadest first, then more specific**, rather than one silently overriding the other. The harness loading behavior is documented at `code.claude.com/docs/en/memory`.

### The globalize promotion pipeline — feeding global memory from project memory

Global memory does not have to be written by hand. It is **fed by a promotion pipeline**: when a fact that was written into *project* memory turns out to be **universal** — true across all your work, not just this one project — it can be **promoted up** into the global rules folder.

The signal that starts a promotion is the operator (you) marking a memory as **global in scope**. From there, installed machinery carries it:

- A **librarian capability** (`memory-globalize.sh`) is the promotion transport. By default it **proposes** the promotion and waits for your confirmation (a `--apply` step is the confirm gate); an opt-in toggle can make it fully automatic.
- A **write-time hook** (`memory-globalize-auto.sh`) can perform the promotion at the *exact moment* a global-scoped memory is saved — but **only** when you have opted into the automatic toggle. By default it does nothing (propose-only).
- A **hygiene checker** (`rules-hygiene.sh`) keeps the promoted directives in the rules folder tidy and conformant — flagging oversized rule files, malformed headers, and `paths:` globs that match nothing.

**One guardrail matters above all the others, stated plainly:** promotion targets the **rules folder only**. It **never** edits your personal `CLAUDE.md`. That file is authored once at setup and is yours alone to change by hand; an automated writer must never touch it. The promotion transport is hard-wired to write only to `~/.claude/rules/`.

There is a **second, separate promotion that runs in the opposite direction.** A skill (`mem-promote`) proposes pulling facts *into* project memory from the optional external recall plugin (described under the accessibility layers below). This one is **propose-then-confirm only** — it *never* auto-writes, under any toggle. Keep the two directions distinct:

| Pipeline | Direction | Auto-write? |
|---|---|---|
| **globalize** | project memory → global rules folder | Propose by default; an opt-in toggle can make it automatic. Writes to `rules/` only, never `CLAUDE.md`. |
| **mem-promote** | external recall plugin → project memory | Propose-then-confirm **only**. Never automatic. |

---

## How a memory gets classified and placed

A natural question follows from the triad: when a fact is worth keeping, *who* decides whether it is Semantic, Procedural, or Episodic — and how does it reach the right place? The load-bearing choice of this whole layer is that **classification is *declared* by the author at the moment of writing, never guessed afterward by a separate program.** There is no hidden classifier whose judgment you would have to second-guess.

### Two labels, fixed when the note is written

Every memory note carries **two** independent labels, set the instant it is saved:

1. **A provenance prefix on the filename** — *where the fact came from*. The standard prefixes are `user_` (your identity and preferences), `feedback_` (a lesson learned or a workflow rule), `project_` (context about one specific project), `reference_` (a pointer to an outside system), and `episode_` (a record of one work session). A "prefix" is simply the first word of the filename, before the underscore.
2. **A retrieval `type:` in the header** — *which of the three triad kinds it is*: `semantic`, `procedural`, or `episodic`. This is a required field, and the write-time guard checks memory notes for it; a note that omits it, or names a type outside those three, is flagged.

The two are paired so the choice is nearly mechanical: **each provenance prefix carries a default retrieval type.** A `user_` or `reference_` note defaults to *semantic*; a `feedback_` note defaults to *procedural*; an `episode_` note is *always episodic*. In practice the author picks the prefix that fits the fact's origin, and the type follows. When a fact genuinely spans two kinds, the rule is simple — the declared `type:` wins, and the note is filed under that one dominant kind.

> **Why declared, not inferred?** Here the author and the writer are the *same* agent: the assistant that just learned the fact is the one saving it, so it can state the fact's kind directly rather than write raw text for a second program to classify after the fact. Declaring up front is more transparent, and it removes a whole class of silent misclassification. It is the same instinct behind the rest of this layer: the assistant authors its own memories, and the moves that carry more weight — promoting a fact to apply everywhere, or pulling one in from an outside store — are *proposed for your confirmation* rather than done unattended. A deliberately conservative stance for a system whose memory shapes how the assistant acts.

### Who places it, and who only checks

The auto-loaded index, `MEMORY.md`, is organized into the three triad sections in a fixed order — Semantic, then Procedural, then Episodic. Two mechanisms keep a memory in its right section, and the split between them is the point:

- **The assistant places the pointer.** When it writes a new memory note, it adds that note's one-line entry under the section matching the declared type. Placement is an authoring step, done at write time.
- **The librarian only validates.** The memory-hygiene sweep (run with `/librarian`) *checks* the index against reality — flagging a note on disk that no entry points to, and an entry that points at a file no longer there — but it never re-sorts the sections or re-derives a note's type.

The **one fully automatic** tier is **episodic**. At the close of a work session, a hook writes the session's outcome record itself — filename `episode_…`, `type: episodic` locked in, in a fixed four-part shape (situation, thought, action, result), with no model call and no human step. Session records are the one thing produced *for* you rather than *by* you, because they describe events the system already witnessed.

The whole picture in one line: **classification is authored (you declare it), structurally guided (the prefix implies the type, the index sections are fixed), and machine-checked (the librarian flags drift) — and only session records are filed for you, end to end.**

---

## Memory vs context — the core distinction

These two words are easy to confuse, and the whole model hinges on telling them apart.

- **Context** is the assistant's finite **in-session working window** — everything it is currently "holding in its head" during one conversation. It has a fixed size, and it is **lost completely** the moment the session ends. This is the whiteboard.
- **Memory** is the set of **on-disk surfaces that survive** the session ending and get reloaded next time. This is the filing cabinet.

The relationship between them is a cycle:

1. At the **start** of a session, the system loads memory — the project `MEMORY.md` index, your `CLAUDE.md`, and the `rules/` folder — **into context**. The cabinet is opened and the relevant folders are spread on the whiteboard.
2. **During and after** the session, durable facts worth keeping are written back **out** to memory. What was learned on the whiteboard is filed back into the cabinet before it is wiped.

This distinction is *why the on-disk surfaces exist at all.* Without them, the whiteboard is erased at the end of every meeting and nothing carries forward. Memory is the only thing that makes the assistant accumulate knowledge instead of resetting to zero each time.

---

## The three accessibility layers

The assistant can reach durable knowledge through three layers, ordered here by **how little effort each costs the assistant** — from "it just has it" to "it has to go digging."

### Layer 1 — always-present, zero effort

`MEMORY.md`, the `rules/` folder, and `CLAUDE.md` are **loaded automatically at session start**. The assistant simply *has* them the moment the conversation begins — no searching, no asking. This is the curated core: the triad and the global directives.

**The foundation is fully functional on Layer 1 alone.** Layers 2 and 3 are additive — nice to have, not required.

### Layer 2 — the claude-mem plugin (recommended, optional)

A **plugin** is an add-on capability you install separately to extend the tool; a **marketplace** is a catalog the tool reads to find and install plugins. `claude-mem` is one such plugin: a **recommended-but-optional** add-on installed from a plugin marketplace. It is **not** part of the brain-stem install — it is offered during first-run setup as an optional extra.

When present, it does two things: it **automatically injects recent observations** into context at session start, and it acts as a **searchable record of past sessions** the assistant can query. It widens the net beyond the curated core — which is exactly why its contents are *proposed into* the curated memory through the `mem-promote` pipeline rather than trusted blindly.

### Layer 3 — raw session transcripts

The complete, word-for-word record of past conversations is the **most granular** source — but the **least accessible**. The assistant reaches into raw transcripts only when **you explicitly ask** it to. They are the bottom-of-the-drawer archive: everything is there, but you have to go get it.

| Layer | What it is | Effort for the assistant |
|---|---|---|
| **1** | `MEMORY.md` + `rules/` + `CLAUDE.md` | Zero — auto-loaded at session start |
| **2** | the `claude-mem` plugin (optional) | Low — auto-injects recent observations; searchable on request |
| **3** | raw session transcripts | High — only when you explicitly ask |

---

## Other mineable surfaces

Beyond the curated memory tiers, several **runtime-generated** surfaces — files the system writes as it operates — also carry durable, searchable signal worth knowing about. These are not part of the curated triad, but they are legitimate places to mine for *what happened* and *why*:

- **The governance action log** (`~/.claude/governance/governance-action-log.jsonl`) — a machine-readable record with one entry per governance action the system takes, appended over time. A running ledger of what the governance engine did and when.
- **The vault session-close logs** — the running record written when a work session is reconciled and formally closed out.
- **Each plan's `handoff.md`** (`~/.claude-plans/<plan>/handoff.md`) — an append-only, newest-first work journal: both a searchable ledger of everything done on that plan and the carrier that hands the next session enough context to continue.

When you need to reconstruct a history the curated memory does not hold, these are where to look.

---

## See also — the mechanics doc

This document is the **structure-first lead**: it explains *what* memory is and *how* it is organized — the triad, the two scopes, the promotion pipeline, the memory-vs-context distinction, and the accessibility layers.

The **mechanical** detail of how the auto-loaded index is kept small enough to load — the size limit on `MEMORY.md`, the load guard that warns at write-time, the rule for counting the file's size, the overflow seam that keeps the index bounded, and the fixed section order — lives in the companion mechanics doc, **`memory-management.md`**. Read that doc for the size-limit detail.

---

## References

Each item below is **adopter-present** — it ships with the install or is generated at runtime once the system is used. The frontmatter *contract* for memory files — **frontmatter** is the small block of header fields at the very top of a memory file, governing its required fields and its three-value retrieval type — is enforced **inline by the write-time guard**, not by a separate schema file on disk; the capabilities degrade gracefully to structural validation when no schema is present, which is the intended adopter behavior.

- `~/.claude/projects/<project>/memory/MEMORY.md` — the single auto-loaded per-project memory **index**, organized by the Semantic → Procedural → Episodic triad (three fixed sections in that order). Seeded lazily from the template on first need; the hot-loaded entrypoint.
- `~/.claude/projects/<project>/memory/*.md` — the per-topic memory files the index points to, each declaring its retrieval type in its header; written as the assistant captures durable facts.
- `~/.claude/CLAUDE.md` — the global personal-preferences file, loaded every session. Authored once at setup; hand-edited by the adopter; automated promotion **never** writes here.
- `~/.claude/rules/` — the global rules folder (a native Claude Code surface), loaded every session, empty until populated; no aggregate folder cap (individual rule files carry an advisory per-file line ceiling). The promotion destination for global-scoped project memories; created at install and seeded with a `README.md`.
- `~/.claude/templates/MEMORY.md.template` — the shipped index template carrying the fixed `## Semantic → ## Procedural → ## Episodic` section order; copied by the seed hook into a new project's memory folder.
- `~/.claude/templates/claude-home-rules-readme-template.md` — the shipped README for the `rules/` folder, explaining its two activation modes (always-on vs. file-pattern-scoped) and when to put a rule here versus in `MEMORY.md`.
- `~/.claude/hooks/memory-seed.sh` — the session-start hook that lazily creates a starter `MEMORY.md` from the template the first time a project needs one (no-clobber; always exits 0).
- `~/.claude/hooks/session-episode-write.sh` — the session-end hook that authors the episodic-tier record at the close of a session (graceful no-op when there is no session context or no resolvable memory dir); the producer of the Episodic section.
- `~/.claude/hooks/memory-auto-stamp.sh` — auto-stamps the freshness fields (`updated`, and `created`/`last_validated` when absent) on memory topic-file writes, so fresh installs are conformant with no migration.
- `~/.claude/hooks/memory-globalize-auto.sh` — the write-time hook that performs the project→rules promotion at the moment a global-scoped memory is saved, **only** when the auto toggle is on; default is propose-only (no-op).
- `~/.claude/skills/librarian/capabilities/memory-globalize.sh` — the promotion transport: promotes a global-scoped project memory up into `rules/`. Propose by default (`--apply` is the confirm gate); writes **only** to `rules/`, never to `CLAUDE.md`.
- `~/.claude/skills/librarian/capabilities/rules-hygiene.sh` — the lifecycle/hygiene auditor for the `~/.claude/rules/` folder: propose-only, flagging oversized rule files, malformed headers, and `paths:` globs that match nothing.
- `~/.claude/skills/librarian/capabilities/rules-index.sh` — regenerates a human-readable index of the system's built-in governance rules (a derived read-replica grouped by category, with a retired-rules section); never hand-edited, regenerated on demand. Distinct from `rules-hygiene.sh` — it does not touch the `~/.claude/rules/` folder.
- `~/.claude/skills/librarian/capabilities/memory-staleness.sh` — flags non-episodic memories past their re-validation interval and emits a re-validation finding (never a deletion).
- `~/.claude/skills/librarian/capabilities/memory-hygiene.sh` — the memory-index health sweep: flags notes on disk with no index pointer, index entries whose target file is missing, staleness, and index-size budget. Validates the index against the topic files; never re-sorts the sections or re-derives a note's declared type.
- `~/.claude/skills/mem-promote/SKILL.md` — the other-direction bridge: proposes promoting observations from the optional external recall plugin into curated project memory. Propose-then-confirm only; never auto-writes; degrades to a clean no-op when the plugin's database is absent.
- `~/.claude/skills/mem-promote/scripts/prefilter.sh` — the de-confliction prefilter inside the `mem-promote` pipeline (returns zero candidates when no plugin database exists).
- `~/.claude/hooks/memory-review-banner.sh` — the session-start banner naming how many memory-review items are pending and pointing to `/librarian review` (advisory; always exits 0).
- `~/.claude/hooks/lib/review-queue.sh` — the mechanical writer of the memory review queue; items clear only on explicit confirm or reject-with-reason.
- `~/.claude/hooks/prompt-context.sh` — the re-firing review reminder for aged or high-severity queue items; yields to the session-continuity checkpoint and the high-context-pressure safety valve.
- `~/.claude/governance/governance-action-log.jsonl` — runtime-generated, append-only; one machine-readable record per governance action.
- `~/.claude-plans/<plan>/handoff.md` — runtime-generated, append-only, newest-first work journal per plan; a mineable "what happened / why" surface and the resume-carrier for the next session.
- The companion mechanics doc: `memory-management.md` — the size-limit, load-guard, and overflow detail.
- Anthropic docs for the harness loading behavior: `code.claude.com/docs/en/memory`.
- The decay finding (the highest-signal facts must be pinned because auto-captured memories lose relevance over time): mem0.ai (2026).
- Research grounding the triad: Tulving (1972), *Episodic and Semantic Memory*; Cohen & Squire (1980), *Preserved Learning and Retention of Pattern-Analyzing Skill in Amnesia* (Science 210:207–210); the CoALA framework, *Cognitive Architectures for Language Agents* (arXiv:2309.02427); and MemGPT, *Towards LLMs as Operating Systems* (arXiv:2310.08560).
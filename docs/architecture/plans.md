---
title: "Plans"
description: "How a structured, multi-step project is stored on disk and shepherded from a raw idea through to a finished, verified, signed-off plan — the plan tree, the four-file quartet, the status lifecycle, the idea funnel and its skills, the append-only handoff journal, and the human-gated orchestrator."
audience: "foundation authors + adopters"
---

# Plans

> **Audience:** foundation authors and adopters who want to understand how a structured, multi-step project is stored on disk and shepherded from a raw idea all the way to a finished, signed-off plan — written for someone who has never used Claude Code and has no technical background. Every term is explained from scratch the first time it appears.
>
> **What this doc covers:** the plan tree at `~/.claude-plans/` (the four-file plan layout, the status lifecycle, master and sub-plans), the idea funnel that feeds it and the three skills that drive that funnel, the append-only handoff journal, and the human-gated orchestrator that can run a plan's tasks for you.
>
> **A note on two surfaces.** This system keeps its rules in two parallel forms. One is *machine-readable* — a structured rulebook the software reads at the exact moment it is about to save a file, so it can act. The other is *human-readable* — pages like this one, written so a person can follow the reasoning. The team calls the machine form the **APPLY surface** (the AI applies it) and the human form the **UNDERSTAND surface** (a person understands it). **This page is the UNDERSTAND surface.** The matching APPLY surface — the rulebook the AI consults at the moment of a write to the plan tree — is the `plans` section inside the composed bundle `~/.claude/governance/foundation-master.json`, merged with any local overrides in `~/.claude/governance/overlay-master.json`. This page exists so a human can follow *why* the system behaves the way it does; the bundle exists so the software can act on it.

---

## What a plan is (and where it lives)

A **plan** is a small folder of plain-text files that describes one project: its goal, its task list, and a running diary of progress. The important thing to grasp up front is that a plan is *not* a single document — it is a small set of files that work together.

Every plan lives under one home folder, `~/.claude-plans/`. The `~` (tilde) is shorthand for your **home folder** — the top-level personal folder the operating system gives you. The leading dot in `.claude-plans` makes the folder **hidden** by default (a long-standing convention for folders meant for software rather than everyday browsing). Think of `~/.claude-plans/` as a filing cabinet where each drawer is one project.

The files inside are ordinary text. There is no database, no proprietary format, nothing locked away — you can open any of them yourself in any editor. If you keep an Obsidian vault (a folder of notes you browse in the Obsidian app), its `Plans/` folder is a **symlink** into here. A symlink is a shortcut: the `Plans/` folder you see in the vault is just a signpost pointing back to `~/.claude-plans/`. The files themselves live in only one place; you are never keeping two copies in sync.

## The four-file quartet

Every plan folder holds the same four core files, together called the **quartet**:

| File | What it is | Who owns it |
|---|---|---|
| `spec.md` | The goal and constraints — the north star. Fixed once it is set. | Human-authored |
| `tasks.md` | The human-readable to-do list. A **generated copy** — see below. | Machine-rendered |
| `handoff.md` | An append-only progress diary. | Appended each session |
| `manifest.json` | The machine-readable control file — the real **source of truth** for status and the structured task list. | Machine-validated |

A **manifest** is simply a structured control file the software reads to know the plan's current state. ("Manifest" is the same word a ship uses for its cargo list — a precise, machine-checkable inventory.) There is also an optional fifth file, `00-ideation-brief.md`, which records *why* the project was decided on in the first place.

The subtle point worth internalizing: two of these files appear to hold the task list, but they are not equal. **The manifest is the spreadsheet; `tasks.md` is a PDF export of it.** You mark a task done by changing the manifest, and the system re-prints `tasks.md` to match.

`tasks.md` is rewritten between two invisible marker lines called **sentinels** — start-here and stop-here signposts the automation writes into the file so it knows which region it owns. Any hand-edit you make *inside* those markers is silently overwritten the next time `tasks.md` is rendered. So completion only counts when it is recorded where the truth lives: in the manifest. Done is recorded in the spreadsheet, not penciled onto the printout.

## The status lifecycle

A plan has exactly **one status at any moment**, and it moves through a fixed sequence of eight named stages:

```
researching → planned → in-progress ⇄ paused → completed → verified → closed → archived
```

with one side exit, `superseded`, reachable from any non-archived state and final once reached (used when a plan is replaced by a newer one rather than finished).

Who sets each status matters:

| Status | Meaning | Who sets it |
|---|---|---|
| `researching` | Feasibility is still being worked out | Human |
| `planned` | Scoped and ready to start | Human |
| `in-progress` / `paused` | Actively worked / temporarily on hold | Human |
| `completed` | A human's **claim** that the work is done | Human |
| `verified` | **Earned** through an actual machine validation pass | Machine-stamped |
| `closed` | Signed off and put to rest | Human |
| `archived` | Filed away out of the active list | Automation |
| `superseded` | Replaced by a newer plan | Human |

The load-bearing distinction here is the whole point of the lifecycle, so it is worth stating plainly. **`completed` is only a claim** — a person saying "I think this is done." **`verified` is earned** — it is set only by an actual automated check that confirms the work, and it is stamped by that check, never typed in by a human. Backing this up is a guard rail enforced at the moment of writing: a plan **cannot be flipped to `closed` unless it is already `verified`.** The system refuses the write otherwise. In plain terms: done is not something you get to declare.

One further note: the move from `closed` to `archived` is gated by a volume-and-cooldown threshold rather than a calendar date — a plan is archived once enough has accumulated and it has rested long enough, not on a fixed "30 days later" rule.

## Master and sub-plans

The default shape for a plan is **flat**: one folder, one quartet. Most projects should stay flat. You split a plan only when a project is genuinely multi-phase or simply too large for a single task list.

When that happens, a project can become a **master plan** that coordinates several **sub-plans**, each a real project with its own quartet. A master is **opt-in** — it is never created automatically, and a flat plan does not silently grow into one.

The strict rule, and it is strict: **sub-plans never talk to each other.** They report only *up* to the master. The mental model is a manager and workers — the workers report to the manager, not to one another. A sub-plan that tries to declare a direct dependency on a sibling sub-plan recreates exactly the tangled all-to-all web the design rejects; the system surfaces this as an advisory warning rather than silently allowing it.

The master's rolled-up summary of each sub-plan's status is **always regenerated automatically** from the sub-plans themselves. A human never hand-types it, which is precisely why it can never quietly go stale: the overview is computed from the truth, not transcribed from memory.

## The idea funnel — capture is cheap, the system sorts

Not every idea deserves a full plan the moment you think of it. So there is a **funnel** — a narrowing pipeline — that makes capturing an idea effortless and lets the system do the sorting later.

The user-facing beat is simple: you **ask Claude to jot an idea down** — for example, "capture this idea: a skill that summarizes my meetings." Claude invokes `/backlog-triage` (the funnel's capture front door), which **drops a lightweight note** into a holding area called the **inbox** at `~/.claude-plans/_inbox/<slug>.md`. A **slug** here just means a short, lowercase, hyphenated name (like `meeting-summarizer`). Crucially, **no project number is burned yet** — numbers are handed out only when an idea graduates into a real plan, so the dozens of ideas you discard never consume a number.

Two surfaces hold the funnel together:

- **`_inbox/`** is the cheap-capture surface — one note per raw idea, the slug carrying no number prefix, the body growing in place as the idea is refined.
- **`_backlog.md`** is a single auto-generated table that lists every inbox idea *plus* every plan still in its early `researching` or `planned` stages — one scannable view of everything in flight. It is never hand-edited; it is regenerated by a librarian capability (the **librarian** is the system's set of housekeeping scripts) when that capability runs.

That last point carries an important operational fact: **there is no scheduled backlog sweep.** No background timer periodically scans or tidies the backlog. The backlog skills run only when invoked, and `_backlog.md` is regenerated when the librarian's backlog-index capability runs — on demand, or as part of the end-of-session tidy-up. (The system ships only two scheduled background jobs at all, and neither touches the backlog.)

The funnel's stages, condensed, run: **capture** (a note lands in the inbox) → **triage** (the idea is classified) → **research** (deep feasibility is assessed) → **graduate** (the idea becomes a numbered plan) → **hygiene** (a recurring review loop keeps the backlog honest).

## The three skills and how they relate

Three **skills** drive the funnel. A skill is a packaged capability you invoke by typing a **slash command** — a short instruction starting with `/`, like `/backlog-triage`. You can type the command yourself, and the assistant can also fire a skill on its own when it judges it relevant, unless that skill is configured not to. (The slash-command-and-skill model is documented by Anthropic at [code.claude.com/docs](https://code.claude.com/docs).)

The three divide the labor cleanly:

| Skill | Role | What it does — and does NOT do |
|---|---|---|
| `/backlog-triage` | Capture front door + cheap **classifier** | Drops the inbox note **and** labels the idea as one of NOVEL, DUPLICATE, OVERLAP, or DEFERRED, checked against everything already in flight. Promotes the idea at most to `triaged`. Does **no** feasibility work and creates **no** plan. |
| `/backlog-research` | **Deep feasibility** | Reads your vault, your existing tools, and outside best practices; assesses feasibility; **writes the ideation brief**; and **scaffolds the draft plan** (sets up the quartet) when the recommendation is to proceed. |
| `/new-plan` | The **research-skip** mode of the same builder | Scaffolds the quartet straight from a slug when you already know what you want — no research pass (the ideation brief is left as a placeholder stub). Also offers opt-in `--master` (create a master plus its first sub-plan) and `--add-subplan` modes, rejects junk auto-generated names ("shame slugs"), and assigns the next project number. |

The connective tissue is the most important detail: **`/new-plan` and `/backlog-research` both hand the mechanical scaffolding job to one shared helper script** — `~/.claude/skills/new-plan/lib/promote-from-inbox.sh`. There is exactly one copy of that builder. Research-backed and research-skip are simply two front doors into the same construction crew.

So the one-line mental model worth keeping:

> **Triage classifies. Research = feasibility + brief + scaffold. New-plan = scaffold without research. Both creation doors share the same builder.**

A boundary worth drawing explicitly: creating a plan is **not** a job for the vault's structure-governance command (which governs new vault *folders* and the systems that write into the vault — a separate concern). For that, see the governance and onboarding docs rather than reaching for a plan skill.

Finally, a **fifth** funnel skill completes the loop without being one of "the three": `/backlog-hygiene` is the recurring review pass that flags stale rows, oversized rows, and rows missing a clear what-happens-next signal, and auto-files items that are actually done. Like the others, it runs only when invoked — there is no timer behind it.

## The handoff journal — write once per session, resume on read

`handoff.md` is an **append-only, newest-first** diary. "Append-only" means you only ever *add* to it; "newest-first" means the most recent entry sits at the top. Each working session **prepends** one fresh block to the top of the file and **never edits an older block**. If an earlier note turns out to have been wrong, you do not rewrite history — you add a *new* block at the top that corrects it.

The file does two jobs at once:

1. **A searchable ledger** — an in-order record of everything ever done on the plan, which stays trustworthy precisely because old entries are never quietly altered.
2. **The resume-carrier** — a brand-new session reads only the *top* block to pick up exactly where the last one left off. The load-bearing line in that block is the **"Next session:"** pointer, which names the very next task to tackle.

That second job matters most when the AI's working memory has been **compacted**. The AI works inside a finite **context window** — the working memory that holds everything it knows about the current conversation. When that window fills, the conversation is **summarized-and-trimmed** (compaction) to free space, and the moment-to-moment detail is condensed away. A session restarted after compaction has lost its in-the-moment thread — but the handoff journal is on disk, so reading the top block gives it a clean cold start. (The finite-context-window-and-compaction behavior is documented at [code.claude.com/docs](https://code.claude.com/docs).)

## The orchestrator — running a plan's tasks for you, with a human in the loop

The **orchestrator** is a set of scripts that can take a plan's task list and execute the tasks *automatically*. It does this by launching the AI in **headless mode** for each task. Headless mode is the opposite of a normal conversation: instead of a back-and-forth chat, you hand the AI a single written instruction, it does that one job with no conversation, and it reports the result. It is started with the command `claude -p` (the `-p`, for *print*, runs one instruction non-interactively and prints the answer). The orchestrator uses one headless run per task, so it can work through a plan without a person typing each step. (Headless / print mode is documented at [code.claude.com/docs](https://code.claude.com/docs).)

The orchestrator uses the same **master/worker** shape as sub-plans: a *manager* run (the master) and *worker* runs (one per task), and the workers report only *up* to the manager, never to each other — the same no-sibling-chatter rule.

Here is the single most important property, and it is the line to remember:

> **The orchestrator is human-gated. It is a propose-and-gate system, not an autonomous daemon.** No task fires without a human approval or reasoning point.

A **daemon** is a program that runs unattended in the background; this is deliberately *not* that. The human gate is what keeps a person in or on the loop, and it is also the thing that makes risky work safe to attempt: nothing irreversible happens until a person has approved it. There are two gate modes:

- For **risky or irreversible** work, the orchestrator **halts and waits for an explicit human go-ahead** before acting (approve-before-act). Because nothing is done until you nod, the step is, in effect, undoable up to that point — you can simply decline.
- For **reversible** work, it **proposes the step and proceeds under human supervision** (a person is watching and can stop it).

The framing that captures the design choice: the difference between a robot that does the dishes only after you nod, and one that empties your whole kitchen unattended. This system ships the first.

Separately from the gate, each headless task is wrapped in a safety check: just before the task runs, the orchestrator takes a snapshot of the relevant code's state, takes another the moment the task finishes, and compares the two. This does **not** undo anything — its job is to detect whether the task *actually changed anything*, so a run that reports success but quietly did no work is caught and flagged rather than trusted. Reversibility, where the design offers it, comes from the human gate above (you can decline before anything irreversible runs), not from this snapshot.

The pieces:

| Script | Role |
|---|---|
| `~/.claude/orchestrator/dispatch.sh` | The entry point. `--plan <slug>` walks a whole plan; `--job <name>` runs one task. Routes to the two runners below. |
| `~/.claude/orchestrator/plan-runner.sh` | Walks a master plan's sub-plans and their tasks in dependency order, applying the human gate before each task. |
| `~/.claude/orchestrator/job-runner.sh` | The engine that runs one headless `claude -p` task with a timeout watchdog and budget caps, plus a before/after snapshot that detects whether any work actually landed. |

## The governance engine behind it all

Every write the AI makes to the plan tree is checked against the system's rulebook before it is allowed. That rulebook is the merged view of two files: the composed bundle `~/.claude/governance/foundation-master.json` — specifically its `plans` section, which is the APPLY surface for the quartet requirement, the slug and numbering rules, the eight-state lifecycle and its guards (including closed-requires-verified), the inbox and backlog conventions, and the master/sub coordination contract — deep-merged with any local overrides in `~/.claude/governance/overlay-master.json`. On a collision the override wins, and any override must carry a stated reason. Plan manifests are *additionally* validated against the plan-manifest schema before they are written.

This page does not re-explain that engine end to end; the governance doc is the full picture. The takeaway here is only that the behavior described above — the quartet, the lifecycle, the guards, the funnel conventions — is not enforced by goodwill. It is enforced structurally, at the moment of every write.

## References

These are the installed artifacts that implement and back this document. Anything under `~/.claude-plans/` is your plan data; anything under `~/.claude/` is installed system code or rules.

**The plan tree and its auto-generated indexes**

- `~/.claude-plans/` — the plan tree: one sub-folder per project, each holding the quartet. An Obsidian vault's `Plans/` folder, if present, is a symlink into here.
- `~/.claude-plans/_inbox/<slug>.md` — pre-plan idea capture; one lightweight note per raw idea, with no project number until it graduates.
- `~/.claude-plans/_backlog.md` — the auto-generated backlog table (inbox ideas plus early-stage plans). Never hand-edited; no scheduled sweep regenerates it.
- `~/.claude-plans/_index.md` — the auto-generated, status-grouped index of all plans.
- `~/.claude-plans/_archive.md` — the auto-generated record of plans that have moved to `archived`.

**A single plan's files**

- `~/.claude-plans/<NN>-<slug>/{spec.md,tasks.md,handoff.md,manifest.json}` (plus optional `00-ideation-brief.md`) — a plan's quartet. `manifest.json` is the source of truth for status and the structured task list; `tasks.md` is a generated copy; `spec.md` is the fixed goal; `handoff.md` is the append-only journal.

**The rules (APPLY surface)**

- `~/.claude/governance/foundation-master.json` — the composed governance bundle the AI reads at write-time. Its `plans` section is the APPLY surface for the quartet requirement, the slug and numbering rules, the eight-state lifecycle and its closed-requires-verified guard, the inbox funnel and backlog conventions, and the master/sub coordination contract.
- `~/.claude/governance/overlay-master.json` — local overrides deep-merged over the bundle (an override wins on a collision and must carry a stated reason). Ships empty.
- `~/.claude/schemas/plan-manifest-schema.json` — the blueprint each plan manifest is validated against before it is written.

**The creation and funnel skills**

- `~/.claude/skills/new-plan/SKILL.md` — `/new-plan`, the research-skip creation door (plus opt-in `--master` and `--add-subplan` modes).
- `~/.claude/skills/new-plan/lib/promote-from-inbox.sh` — the one shared mechanical scaffold/graduation helper that both `/new-plan` and `/backlog-research` delegate to.
- `~/.claude/skills/new-plan/templates/` — the master and sub-plan quartet templates plus the placeholder ideation-brief stub template (`00-ideation-brief.md.tmpl`) the scaffolder renders for the brief.
- `~/.claude/skills/backlog-triage/SKILL.md` — `/backlog-triage`, capture-and-classify (NOVEL / DUPLICATE / OVERLAP / DEFERRED).
- `~/.claude/skills/backlog-research/SKILL.md` — `/backlog-research`, research-then-scaffold (reads vault + tools + external practice, writes the ideation brief, scaffolds the draft plan).
- `~/.claude/skills/backlog-hygiene/SKILL.md` — `/backlog-hygiene`, the recurring review loop that completes the funnel.

**The librarian capabilities that regenerate the auto-generated files**

- `~/.claude/skills/librarian/capabilities/backlog-index.sh` — regenerates `_backlog.md`.
- `~/.claude/skills/librarian/capabilities/plan-index.sh` — regenerates `_index.md`.
- `~/.claude/skills/librarian/capabilities/plan-archive.sh` — regenerates `_archive.md`.
- `~/.claude/skills/librarian/capabilities/tasks-render.sh` — regenerates `tasks.md` from the manifest, inside the sentinel markers.
- `~/.claude/skills/librarian/capabilities/subplan-aggregate.sh` — regenerates each master plan's rolled-up summary of its sub-plans' statuses.

**The orchestrator**

- `~/.claude/orchestrator/dispatch.sh` — the orchestrator entry point (`--plan` / `--job`); the human-gated, propose-and-gate front end, not an autonomous daemon.
- `~/.claude/orchestrator/plan-runner.sh` — walks a master's sub-plans and tasks in dependency order, gating before each task.
- `~/.claude/orchestrator/job-runner.sh` — runs one headless `claude -p` task with a timeout watchdog and budget caps, plus a before/after snapshot that detects whether any work actually landed.

**The starting-point templates**

- `~/.claude/templates/spec-template.md` — the reference template documenting the `spec.md` shape.
- `~/.claude/templates/tasks-template.md` — the reference template documenting the `tasks.md` shape (with its sentinel-bounded generated region).
- `~/.claude/templates/handoff-template.md` — the reference template documenting the `handoff.md` shape, carrying the append-only, newest-first form.
- `~/.claude/templates/idea-note-template.md` — the reference template documenting the inbox idea-note shape.
- `~/.claude/templates/ideation-brief-template.md` — the full research-brief template `/backlog-research` renders and fills during its research pass. (This is distinct from the placeholder stub `/new-plan` leaves behind, which is `~/.claude/skills/new-plan/templates/00-ideation-brief.md.tmpl`.)

**External documentation**

- [code.claude.com/docs](https://code.claude.com/docs) — Anthropic's documentation for Claude Code, including headless / print mode (`claude -p`), the slash-command and skill model, and the context-window and compaction behavior referenced above.
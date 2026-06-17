---
title: "Sessions"
description: "How a single working conversation with the AI is kept on-track from the moment it opens to the moment it closes — checkpoints, multi-session coordination, and end-of-session reconciliation."
audience: "foundation authors + adopters"
---

# Sessions

> **Audience:** foundation authors and adopters who want to understand how a single working conversation with the AI is kept on-track — from the moment it opens to the moment it closes. **What this doc covers:** the **checkpoint** (the per-session snapshot that lets a conversation survive its own memory being trimmed), **multi-session coordination** (how several open conversations stay out of each other's way), and **session-close** (the end-of-conversation tidy-up). **This is the UNDERSTAND surface** — the human-readable explanation of *why* the system behaves this way. The APPLY surface — the structured rules the automation actually reads, and the exact list of scripts that fire at each moment — lives in the installed settings file `~/.claude/templates/settings.json` and the installed governance JSON. Read this to understand; read those to see exactly what runs.
>
> **Out of scope here:** the plan tree itself — the project folders, the four-file plan layout, the status lifecycle, master and sub-plans, and the idea funnel — lives in the companion doc, `docs/architecture/plans.md`. This doc references plans only where the close routine touches them.

---

## What Claude Code gives you — and what's missing

**Natively,** the assistant has a fixed-size working window, and when a long session fills it the platform *compacts* the conversation — replacing the verbatim history with a summary, after which the full detail is gone. The platform exposes lifecycle moments (session start, just-before-compaction, stop, session end) where a script can run.

**The gap:** a long session silently loses its own working state at the moment of compaction.

**What brain-stem adds:** a structured checkpoint of where you are, a context-pressure ladder that escalates from a silent autosave to a firm stop-gate as the window fills, machine-local multi-session coordination with peer-overlap warnings, and an end-of-session reconciliation. None of this is decorative: every element is a forced response to a documented platform fact — optimal not because it is clever but because the constraints leave no other shape. The clearest case is the split between *saving* and *restoring*: the save must happen at compaction-time, because that is the last moment before detail is trimmed, and the restore must happen at session-start, because the platform does **not** allow a script to inject context back into the conversation at the compaction moment. The rest of this doc walks through each piece; each section ends by naming the platform fact it answers.

---

## What a session is

Claude Code is a command-line program: you open it inside a folder on your computer and have one continuous, typed conversation with an AI assistant (Claude). That conversation — from the moment you open it to the moment you close it — is a **session**. You start it, you do some work, you end it. That is the whole unit.

Everything else in this document exists for one reason: a session has a finite, perishable memory. The machinery below is what keeps a long conversation — or a brand-new one the next morning — from losing the thread.

---

## Why a session needs help: the context window and compaction

The AI has a fixed-size working memory called the **context window** — everything it can "see" at once: the recent conversation, the files it has read, the instructions it was given. As a session runs long, that space fills up.

When it gets too full, the Claude Code program performs **compaction**: it summarizes the older parts of the conversation and discards the originals to make room. Compaction is **lossy by design** — the verbatim early detail is gone, replaced by a shorter summary. Anthropic describes this plainly: a compaction "replaces the verbatim conversation" and "full tool outputs and intermediate reasoning are gone" — the assistant can still reference the work but no longer has the exact text it read earlier (`code.claude.com/docs/en/context-window`).

This single fact — *memory is finite and gets trimmed* — is the reason the checkpoint and close machinery exists. Without help, a long session that hits compaction can lose track of which project it was working on and what it was about to do next; a fresh session the following day starts from nothing.

A word that appears throughout this doc is **hook**. A hook is a small script the Claude Code program runs *automatically* at a specific moment — a session starting, you sending a message, the AI about to stop, memory about to compact, the session ending. You never call a hook yourself; the harness (the Claude Code program itself) fires it for you, like a doormat sensor that turns on the porch light when someone arrives. Hooks are how this system stays automatic instead of relying on anyone — you or the AI — to remember the chores. Anthropic documents the hook mechanism and the named moments hooks fire at, and that one moment can list several hooks configured to run in a declared order (`code.claude.com/docs/en/hooks`).

---

## The session-lifecycle map: what fires when

At each named moment in a session's life, the harness fires a declared, ordered list of hooks. The table below is taken **verbatim from the shipped settings file** (`~/.claude/templates/settings.json`), which is the authoritative wiring; the lines that matter for *this* doc are explained in the sections that follow.

| Moment (event) | Hooks, in declared order | Why it matters here |
|---|---|---|
| **SessionStart** — a session opens | `session-register.sh` → `cron-health-banner.sh` → `memory-review-banner.sh` → `spec-context-inject.sh` → `session-start.sh` → `memory-seed.sh` | The first hook registers the session for coordination and, after a compaction, restores the saved checkpoint. |
| **UserPromptSubmit** — you send a message | `prompt-context.sh` → `spec-context-inject.sh` → `pre-research-check.sh` | The first hook emits the context-pressure nudges and the peer-session awareness. |
| **Stop** — the AI is about to stop | `stop-checkpoint-check.sh` → `stop-drift-scan.sh` | The first hook is the checkpoint "stop-gate." |
| **PreCompact** — just before memory compacts | `pre-compact-checkpoint.sh` | Writes a fallback checkpoint before detail is trimmed. |
| **SessionEnd** — the session closes | `session-deregister.sh` → `session-episode-write.sh` | The first hook marks the session closed and triggers shared cleanup; the second writes an episodic memory record. |
| **InstructionsLoaded** — the instruction files are (re)loaded | `instructions-loaded-log.sh` | A diagnostic log entry recording that the instruction set loaded; not load-bearing for this doc. |

A note on "order": within a single event the hooks are configured as an ordered array, but the harness may run matching hooks in parallel and de-duplicate identical ones (`code.claude.com/docs/en/hooks`). "Declared order" above describes how the list is written in the settings file, not a guarantee that each finishes before the next begins. The hooks in this system are written so they do not depend on each other's timing.

A handful of the hooks above belong to other surfaces and are listed only so the lifecycle map is complete: `cron-health-banner.sh` (a one-line health banner for scheduled background jobs), `memory-review-banner.sh` (surfaces memory items waiting for review), `spec-context-inject.sh` (re-shows the AI the active plan's goal so it does not drift after a long conversation — owned by the plans surface), `session-start.sh` (shows a resume-onboarding banner until first-run setup is done), `memory-seed.sh` (lazily creates an empty memory file the first time), `stop-drift-scan.sh` (the other Stop-time check), `pre-research-check.sh` (a UserPromptSubmit signal that flags when a research request has no matching library coverage — owned by the plans/library surface), `session-episode-write.sh` (writes a short outcome record into memory — the deep memory story lives in `docs/architecture/memory-management.md`), and `instructions-loaded-log.sh` (a diagnostic that records when the instruction set is loaded). The rest of this doc focuses on the load-bearing ones.

---

## The checkpoint: autosave for your train of thought

Because the AI's working memory gets summarized-and-trimmed when it fills, the system continuously saves a **checkpoint** — a short, structured snapshot of exactly where you are. Think of it as **autosave for your train of thought**: a single file that captures enough that a fresh session, or a session continuing after a compaction, can be cold-started from it alone.

The checkpoint lives in a per-session state folder on your machine, at:

```
$CLAUDE_STATE_ROOT/sessions/<session-id>/checkpoint.md
```

where `<session-id>` is the identifier of the current conversation and `$CLAUDE_STATE_ROOT` is the machine-local state root — an environment-resolved location (it defaults to a hidden per-machine state directory under your home folder), *not* a fixed literal path you should hand-type. It is **one file per session** — sessions never share a checkpoint, so two conversations can never overwrite each other's place.

It captures about ten fields: which plan you are on, which phase, which task, what you completed this session, the files you touched, the key decisions you made, what to do next, the acceptance-criteria status, any current blocker, and the context-pressure percent at the moment it was written.

### The Session Continuity Block

The checkpoint's content follows a fixed shape called the **Session Continuity Block**. The richest writer — the `/session-checkpoint` skill (a skill is a named capability you trigger by typing a slash and its name) — emits ten fields:

| Field | Shape | What it records |
|---|---|---|
| `plan_id` | flat `key: value` line | the active plan |
| `phase` | flat `key: value` line | the current phase |
| `task_id` | flat `key: value` line | the current task and its status |
| `completed_steps` | markdown section | what got done this session |
| `files_modified` | markdown section | the files touched |
| `key_decisions` | markdown section | design/architecture choices made |
| `next_steps` | markdown section | what to do next |
| `ac_status` | markdown section | acceptance-criteria checklist (done/pending) |
| `current_blocker` | markdown section | the current error or blocker, if any |
| `context_pct_at_checkpoint` | header value | how full memory was at write time |

A note on that last field's shape: `context_pct_at_checkpoint` is written as a header line near the top of the file (the skill emits it as a `**context_pct_at_checkpoint:**` line in the block's header), kept deliberately separate from the three flat `plan_id`/`phase`/`task_id` lines below it — which is why the table calls its shape a `header value` rather than a flat field.

Two rules keep the block honest:

- **Nothing is silently skipped.** A field that cannot be determined is written as the literal string `[MISSING]` — never left blank and never quietly dropped. The one exception is `current_blocker`, which is an **empty string** when there genuinely is no blocker.
- **The first three flat lines are a binding invariant.** `plan_id`, `phase`, and `task_id` are written as plain single-line `key: value` entries. This is not cosmetic: the pre-compaction hook *counts* them (a header line plus at least three flat `key: value` lines) to recognize a freshly written rich checkpoint and avoid clobbering it. That structure is the signal that says "a good snapshot already exists here."

---

## Context pressure as a fuel gauge

**Context pressure** is just how full the AI's working memory is, expressed as a percent. The fuller the tank, the more urgently the system insists you save your place. Think of it as a fuel gauge: nothing happens while the tank is full of room, the warnings get firmer as it drains, and there is a hard line you cannot cross with a stale snapshot.

The thresholds below are the shipped defaults. The two nudge bands emitted on each message — the gentle nudge and the immediate-action mandate — are adjustable in your settings (the user-manifest's `hooks.context_pressure` block, whose `warn_pct` and `mandate_pct` fields the per-message hook reads at runtime). The **stop-gate's own thresholds** — the ~48% lower bound of the stale-checkpoint band and the ~80% line where it switches from "must be fresh" to "must merely exist" — are **fixed in the stop-gate's hook code, not settings-driven**: the stop-gate reads neither field. (The user-manifest also carries a `hard_pct` field for schema parity, but the stop-gate does not consult it.) The two outer thresholds — the ~35% background autosave trigger and the ~90% safety valve — are likewise fixed in the hook code and are not settings-driven.

| Pressure | What the system does |
|---|---|
| below ~35% | Nothing. You work undisturbed. |
| ~35% (fixed) | A **silent** lightweight autosave begins in the background — and only when no checkpoint has been written in roughly the last 10 minutes. (This is a plain file-age check, not a comparison of contents.) |
| ~45% (`warn_pct`, settings-driven) | A gentle nudge: "checkpoint at your next natural break." |
| ~48% (`mandate_pct`, settings-driven) | An "immediate action — checkpoint now" mandate that **re-fires on every message** until a fresh checkpoint exists. |
| ~48%–80% (both bounds fixed in hook code) | The **stop-gate** refuses to let the session stop while the checkpoint is **stale** (older than 10 minutes). |
| ~80%–90% (fixed) | The stop-gate refuses to stop unless a checkpoint **exists at all**. |
| above ~90% (fixed) | A **safety valve** always allows stopping — the window is too full to keep working productively. |

The ~35% autosave and the higher-pressure nudges are emitted by `prompt-context.sh`, the hook that runs each time you send a message; it is the one that reads `warn_pct` and `mandate_pct` from the user-manifest. The stop-gate is enforced separately, by `stop-checkpoint-check.sh`, which hardcodes its ~48% and ~80% band boundaries; it is described next.

---

## The stop-gate and exit code 2

The stop-gate is built on a documented harness behavior. When any script finishes, it reports an **exit code** — a small number where `0` conventionally means "all good" and any other number signals a problem or a special instruction. Anthropic documents that a **Stop hook finishing with exit code 2** tells the harness to make the conversation *continue* rather than stop (`code.claude.com/docs/en/hooks`).

The system uses exactly that lever. When context is in the ~48%–80% band and the checkpoint is stale (older than 10 minutes), `stop-checkpoint-check.sh` prints `Cannot stop — checkpoint stale` and exits 2; the conversation keeps going until `/session-checkpoint` refreshes the file. In the ~80%–90% band it does the same unless a checkpoint exists at all. And above ~90% the same hook steps aside — it exits 0 and lets you stop, because at that point the window is too full to keep working anyway. The gate is not there to trap you; it is there to make sure your place is saved before the conversation ends. Note that these band boundaries — 48%, 80%, and 90% — are constants written into this hook's own code; unlike the per-message nudge thresholds, they are not read from your settings.

---

## Three writers, one precedence rule

Three things can write the checkpoint, with a clear precedence so they never fight — **the freshest, richest snapshot always wins**:

1. **`/session-checkpoint`** — the skill. Invoked by you manually, *or* fired automatically by the pressure mandates above. It writes the richest snapshot.
2. **`prompt-context.sh`** — the per-message hook. It writes a lightweight checkpoint silently as pressure rises (the ~35% background autosave). It only writes when no fresh rich one already exists.
3. **`pre-compact-checkpoint.sh`** — the pre-compaction hook. Just before memory compacts, it mechanically extracts a fallback snapshot with **no AI cost** — but **only** when no fresh rich checkpoint already exists. If a fresh skill-written one exists, it preserves that verbatim.

That last hook decides what to do with a freshness-and-structure guard: if the existing checkpoint is under 10 minutes old, has the Session Continuity Block header, and has at least three flat `key: value` lines, it is left untouched. Otherwise the hook does its cheap mechanical extraction, marking any field it cannot read as `[MISSING]`.

All three writers target the same per-session `$CLAUDE_STATE_ROOT/sessions/<session-id>/checkpoint.md` file — that shared target is what makes the freshness precedence a real contest rather than three files in three places.

### Why save and restore are split across two hooks

There is one subtlety worth understanding. The pre-compaction hook **cannot inject context back into the model itself** — the moment of compaction is not one of the events allowed to hand context to the AI. Anthropic documents that context injection is available at session start and on message submit, but **not** at PreCompact (`code.claude.com/docs/en/hooks`). So the pre-compaction hook only *writes the file* and exits silently.

The **restore happens on the next session start.** After a compaction, the harness restarts the session and marks it with a "source" of `compact` — a label hooks can read (`code.claude.com/docs/en/hooks`). When `session-register.sh` sees `source=compact`, it reads the saved checkpoint back in, re-injects it verbatim as text so the AI picks up exactly where it left off, and **rotates** the old checkpoint to a dated archive file — a *move*, not a delete, so the prior state is preserved as history.

This save-here / restore-there split is a direct consequence of which moments are allowed to inject context. The payoff, for you, is that after a compaction the continuing session is cold-started cleanly from that one checkpoint file alone.

---

## The `/session-checkpoint` skill

`/session-checkpoint` is the one continuity surface the pressure hooks name directly — both the per-message nudge and the stop-gate tell you to "invoke `/session-checkpoint`." Because its skill definition leaves auto-firing enabled (the `disable-model-invocation` setting is `false`, the documented default that lets the assistant invoke a skill on its own — `code.claude.com/docs/en/skills`), the pressure mandates can fire it for you; you can also type it any time you want a clean handoff snapshot.

Its scope is deliberately narrow:

- It writes **only the live checkpoint file** — never the dated archives (rotation belongs to `session-register.sh`).
- It **never touches** plan files, the project memory, or handoff diaries, and it **never forces** a compaction.
- Its failure mode is **block-and-log**: every required field must be populated or marked `[MISSING]`, the write is **atomic** (it writes to a temporary file, then moves it into place so a half-written file can never appear), and the skill verifies the file's freshness afterward.

---

## The session registry: multi-session coordination

You can have more than one Claude Code session open at once — say, two terminal windows working on different parts of the same vault. When that happens, the sessions coordinate through a shared **session registry**: a single machine-readable file that lists every open session, its process id, its status, a heartbeat timestamp, and the files it has touched. A session's status is `active`, `closed`, or `closed-pending-reconciliation`; a fourth value, `closing`, is recognized by the peer-counting logic but is not set anywhere in the shipped system, so in practice you will never see it on a row — treat it as reserved.

Think of the registry as a **shared whiteboard** the open sessions read to stay out of each other's way.

- `session-register.sh` writes a session's row when it starts.
- `track-vault-write.sh` records each file a session touches (it runs right after any edit).
- A **lock** guards the file — a simple "one writer at a time" mechanism that ensures two sessions can never corrupt the registry by writing it at the same instant.

The registry is **machine-local and ephemeral.** Its exact path is `$CLAUDE_STATE_ROOT/.coordination/session-registry.json` — a hidden `.coordination/` folder under the machine-local state root, **not** in your notes vault. It is bookkeeping for the running program, not part of your knowledge base. When all sessions are closed it serves no further purpose.

### Peer-session awareness and same-file warnings

On each message you send, `prompt-context.sh` reads the registry and surfaces what the other open sessions are doing:

- a short **summary** of the other active sessions,
- — load-bearing — a **warning** when another open session has touched the **same file** you are about to edit: `Overlapping files with peer sessions: … Re-read before editing.`,
- a note of who left work pending, and
- when you mention closing, a recommended **close mode** (explained below).

Why does a plain per-message hook do this, rather than something more elaborate? Because surfacing context on message-submit is the moment the harness actually lets a hook hand information to the AI. The registry-feeds-`prompt-context` indirection is the deliberate workaround for that constraint: the registry collects the facts, and the message-submit hook is the one allowed to speak them into the conversation.

---

## Closing reconciliation and who runs it

**Reconciliation** is the registry cleanup that reaps sessions which have ended or gone stale, so that peer-awareness stays accurate and the whiteboard never fills with ghosts. It is effectively **always-on**:

- `session-deregister.sh` always fires when a session ends. It marks your row closed and — whenever a `closed-pending-reconciliation` peer exists — spawns the reconciler (`reconcile-sessions.sh`) in the background, detached and non-blocking.
- The close capability (next section) also calls the reconciler as part of its sweep.

The reconciler itself (`reconcile-sessions.sh`) reaps the stale rows (dead process or stale heartbeat), the closed rows, and the closed-pending rows — all under a lock — then clears the pending flag and stamps the time of last reconciliation. It is idempotent: running it twice changes nothing the second time.

The discipline is **"last session out does the shared cleanup."** If peers are still active when you close, your close does only your own part and **defers** the shared sweep to whoever closes last. That is why two closing sessions never trample each other or run the global cleanup twice.

---

## Session-close is a `/librarian` capability, not a standalone skill

`/librarian` is a single slash command with many named sub-jobs, called **capabilities**. End-of-session reconciliation is one of those capabilities — you run it as **`/librarian session-close`**, *not* as a separate `/session-close` skill. This distinction matters for accuracy: the close logic is a capability script that lives inside the librarian skill, at `~/.claude/skills/librarian/capabilities/session-close.sh`.

When you declare you are done, the close capability runs a whole checklist of cleanup chores in the right order, so you do not have to remember a dozen housekeeping steps yourself.

### What happens at close-out

The close capability first **auto-detects its scope** from the registry — `solo` (you are the only session), `scoped` (peers are still active, so do only your own part), or `reconciler` (you are the last one out, so do the shared sweep too). Then it chains a fixed sequence of chores:

- **Re-check conventions** — that files still follow their naming and structural rules (frontmatter, cross-references, placement, staleness, and that any plan handoff diaries have a clear disposition).
- **Refresh the auto-generated indexes** — the plan list and the vault-writer catalogs.
- **Re-sync master plans** — every master plan's rolled-up summary is reconciled against its sub-plans' real statuses. (The master/sub-plan structure itself is covered in the companion plans doc.)
- **Cascade renames** — files renamed during the session are detected and the change is *dry-run* cascaded (proposed, not silently applied).
- **Run the pending-reconciliation sweep** — the registry cleanup above. In `scoped` mode this step is **skipped** and deferred to the reconciler.
- **Detect plan-trinity drift** — after the reconciliation sweep, walk the plan directories for drift between each plan's spec, manifest, and tasks ledger. This is a read-only, advisory check, so it runs in every scope (even `scoped`).
- **Commit a backup** — also deferred in `scoped` mode.

The whole flow is **advisory**: an individual chore that fails is logged and the flow continues, and the close **always exits cleanly**. It never blocks you, and it never leaves the session wedged. Whichever scope it runs in, it writes **one** short, aggregated log of what it did.

The point, again, is that the system carries the discipline. You declare you are done; the close routine makes "done" actually tidy.

---

## The session-close log: the librarian's receipt

Every close writes one aggregated **session-close log** — the librarian's notes on what the close actually did. Frame it as the **always-there receipt** of the close: a record exists even when the cleanup ran quietly in the background.

The log is a dated markdown note named `session-close-YYYYMMDD-HHMMSS.md` and it **lands in brain-stem's machine-local state log directory** (`~/.local/state/brain-stem/logs/`) — outside the vault, so this machine exhaust never enters your indexed knowledge. It carries structured frontmatter and a chore-by-chore chain:

| In the log | Contents |
|---|---|
| Frontmatter | `type: log`, `log-type: session-close`, the `scope` it ran in, the dates, the finding and error counts, and a `#log/session-close` tag |
| Capability chain | each chore listed with its outcome — `ok`, `skip`, or `error` |
| Summary | how many chores ran, how many errored, the scope |
| Error section | present only if a chore failed, pointing back to the chain for detail |

Because the log is a plain, dated markdown note, it is a mineable record: you can scan past closes to see what was touched, what was skipped, and what went wrong — without re-running anything. It is written to brain-stem's machine-local state log directory, NOT into your vault — machine exhaust stays out of your indexed knowledge. (The session registry is likewise machine-local. Keep the two roles separate in your head: the **log** is the human-readable receipt; the **registry** is the running program's machine-local whiteboard.)

---

## A note for multi-session power users

The session registry described above ships **on by default** — `session-register.sh` on every session start and `session-deregister.sh` on every session end are already wired into the standard settings. You do not turn coordination on; it is the baseline.

For setups that run *many* concurrent sessions, there is an **opt-in** extra: a small settings fragment (`~/.claude/templates/settings-fragments/multi-session.json`) that, when the multi-session flag is set in your settings, wires one additional diagnostic check at session start. It is a belt-and-suspenders convenience for power users — **not** the only coordination path, and not something most adopters ever need to enable.

---

## Why this design — evidence & alternatives

Each of the four load-bearing choices in this doc had a tempting alternative that was tried-on and rejected for a concrete reason. Reading the rejections is the fastest way to see *why* the system has the shape it does — and to notice that the shape is mostly forced, not invented.

| Choice | Rejected alternative | Why it was rejected |
|---|---|---|
| Save the checkpoint **before** compaction, restore it **at session start** | Inject the saved state back in at the compaction moment itself | The platform offers no way to hand context back into the conversation at that moment, so the save-here / restore-there split is **forced, not chosen.** This is the classic *checkpoint-then-resume* shape from database recovery — write a durable record at the safe moment, replay it when the system comes back up (the write-ahead-logging discipline behind ARIES; Mohan et al.). Agent frameworks reach the same answer when a run is interrupted and later resumed — for example, LangGraph's persisted-state model — which is a sign the shape is convergent, not idiosyncratic. |
| Coordinate sessions through a **machine-local registry** | Keep the coordination file inside the synced notes vault, for "cross-machine" safety | The cross-machine guarantee is a **phantom**: the liveness checks (is this process still alive?) and the write lock are physically local to one machine and mean nothing on another. Worse, a hot, frequently rewritten file living in a synced folder invites conflict-copies and torn reads. So coordination stays local, the registry is written atomically (temp file, then rename — the POSIX-atomic replacement guarantee), and concurrent writers are serialized with an advisory file lock (`lockf`). |
| **No** checkpoint schema — the block is re-injected verbatim as text | Define a strict schema and a parser for the continuity block | The only consumer re-injects the block as **plain text**, with no parser in the loop. A formal schema would create a *second* source of truth — the schema and the text could drift apart — for zero practical benefit, so the design keeps one plain-text shape and a light freshness-and-structure guard instead of a parser. |
| A **pressure ladder** that escalates to a stop-gate | Rely on the person to remember to save | A long session fills its window **silently** — there is no felt warning at the moment detail is about to be summarized away. Leaning on memory means the save lands too late or not at all; the ladder forces a rich save *before* the detail is lost, which is the whole point. |

The throughline is that **the constraints did most of the designing.** Where the platform forbids a thing (injecting context at compaction) the shape is forced; where physics forbids a thing (a "cross-machine" lock that is really local) the honest version is the local one; and where a richer mechanism would buy nothing (a schema for text nobody parses) the system declines it. That several of these answers also show up independently in database recovery and in agent-framework persistence is reassurance that the shape is the well-trodden one, not a local invention.

---

## References

All paths below are **installed** surfaces on an adopter's machine.

**The checkpoint surface**

- `$CLAUDE_STATE_ROOT/sessions/<session-id>/checkpoint.md` — the per-session checkpoint file (the Session Continuity Block); one per session, overwritten atomically, rotated to a dated archive after a compaction restore. `$CLAUDE_STATE_ROOT` is the machine-local state root resolved at runtime (a hidden per-machine state directory by default), not a fixed literal path.
- `~/.claude/skills/session-checkpoint/SKILL.md` — `/session-checkpoint`, the skill that writes the ~10-field continuity block (block-and-log; atomic; writes only the live checkpoint).

**The session-lifecycle hooks**

- `~/.claude/hooks/session-register.sh` — SessionStart hook (#1): registers the session in the coordination registry, and on a `source=compact` restart re-injects the saved checkpoint verbatim and rotates the old one to a dated archive.
- `~/.claude/hooks/prompt-context.sh` — per-message hook: emits the escalating context-pressure nudges/mandates (reading `warn_pct`/`mandate_pct` from the user-manifest at runtime) and the peer-session awareness (summaries, same-file overlap warnings, pending-reconciliation notices, recommended close mode).
- `~/.claude/hooks/stop-checkpoint-check.sh` — the Stop-hook checkpoint gate (finishes with exit code 2 to keep the conversation going while the checkpoint is stale or missing in the pressure bands; safety valve above ~90%). Its ~48% and ~80% band boundaries are constants in the hook code, not settings-driven.
- `~/.claude/hooks/pre-compact-checkpoint.sh` — writes a fallback checkpoint just before compaction; cannot inject context itself, so the restore happens at the next session start.
- `~/.claude/hooks/session-deregister.sh` — SessionEnd hook (#1): marks the session's registry row closed and spawns the reconciler in the background when a pending peer exists.
- `~/.claude/hooks/reconcile-sessions.sh` — the registry reconciler: reaps stale/closed/pending rows under a lock; idempotent.
- `~/.claude/hooks/lib/registry.sh` — the shared library defining the registry path (`$CLAUDE_STATE_ROOT/.coordination/session-registry.json`), its locks, and the peer-awareness helpers.

**Listed for lifecycle completeness (owned by other surfaces)**

- `~/.claude/hooks/spec-context-inject.sh` — re-shows the active plan's goal at session start and on message submit.
- `~/.claude/hooks/cron-health-banner.sh`, `~/.claude/hooks/memory-review-banner.sh`, `~/.claude/hooks/session-start.sh`, `~/.claude/hooks/memory-seed.sh` — the other SessionStart slots.
- `~/.claude/hooks/stop-drift-scan.sh` — the other Stop-time check.
- `~/.claude/hooks/session-episode-write.sh` — SessionEnd hook (#2): writes an episodic memory record (see `docs/architecture/memory-management.md`).
- `~/.claude/hooks/track-vault-write.sh` — records each touched file into the registry after an edit.

**The close surface**

- `~/.claude/skills/librarian/SKILL.md` — `/librarian`; session-close is one of its named capabilities, not a standalone skill.
- `~/.claude/skills/librarian/capabilities/session-close.sh` — the `/librarian session-close` orchestrator that auto-detects scope and chains the end-of-session cleanup chores.
- `~/.claude/skills/librarian/capabilities/trinity-drift-detect.sh` — the read-only plan spec/manifest/tasks-ledger drift check chained near the end of the close (advisory; runs in every scope).
- `~/.local/state/brain-stem/logs/session-close-YYYYMMDD-HHMMSS.md` — the aggregated session-close log (the librarian's receipt), written to brain-stem's machine-local state log directory (never the vault).

**Settings**

- `~/.claude/templates/settings.json` — the authoritative wiring for every lifecycle slot and its hook order (the source for the lifecycle-map table above).
- `~/.claude/templates/settings-fragments/multi-session.json` — the opt-in power-user fragment that wires one extra diagnostic check at session start.

**Companion documentation**

- `docs/architecture/plans.md` — the plan-tree half: the project folders, the four-file plan layout, the status lifecycle, master/sub-plans, and the idea funnel.

**Anthropic documentation**

- `code.claude.com/docs/en/context-window` — the finite context window and lossy compaction.
- `code.claude.com/docs/en/hooks` — the hook mechanism, the named events, exit-code-2 semantics for Stop, context-injection availability per event, and the SessionStart `source` field.
- `code.claude.com/docs/en/settings` — the settings file and its `hooks` wiring.
- `code.claude.com/docs/en/skills` — the slash-command skill model and the `disable-model-invocation` auto-fire setting.
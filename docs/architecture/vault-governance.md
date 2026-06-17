# Vault governance — keeping a shared, AI-maintained notebook trustworthy for life

> **Audience:** foundation adopters, and anyone who wants to understand how a knowledge base that an AI assistant reads from *and* writes into stays trustworthy over its whole life — from the day it is first created, through every save, to periodic cleanup. No prior experience with the assistant, with "hooks," or with any of the machinery below is assumed; every term used here is defined plainly in the glossary at the end, and glossed inline the first time it matters. **This is the UNDERSTAND surface** — it explains *why* the system is built the way it is. **The APPLY surfaces** — what the assistant actually consults on every save — are the governance settings under `~/.claude/governance/` and the write-time gate at `~/.claude/hooks/pre-write-guard.sh`. **This document is canonical for:** the end-to-end vault-governance lifecycle — scaffolding, the two write-time guards, the opt-in writer pipeline, the writer catalog, and the periodic health sweeps.

---

**In one sentence:** the *vault* is a shared notes folder that both a human and an automated AI assistant write into, and *vault governance* is the small set of rules and programs that keeps that shared folder trustworthy for its entire life.

The rest of this document expands that sentence. The complication governance solves is simple to state: two different authors share one folder. A human types and edits notes by hand; the assistant creates and updates notes on its own. When two authors write into the same place, things drift — a note lands with a malformed header, two automated systems overwrite each other on one file, or a folder's table-of-contents goes stale. Governance is the machinery that catches each of those, either the instant a file is saved or in a periodic cleanup sweep. The lifecycle below walks it in order: how a vault is first **scaffolded**, the two checks that run **at every save**, the **pipeline** that lets automated systems write in safely, how you **register** such a system, and the periodic **sweeps** that catch accumulated drift.

---

## What Claude Code gives you — and what's missing

**Natively,** Claude Code auto-loads a `CLAUDE.md` of conventions at the start of every session, so a folder can carry its own house rules; its write-time hook can wave a save through, attach an advisory note, or deny it with a reason; and macOS `launchd` can wake a background job on either a file-change event or a timer.

**The gap:** those are general-purpose levers — they give you a place to write rules and a moment to enforce them, but no machinery that actually keeps a *shared, co-authored* folder consistent. And every brain-stem adopter has an AI co-author by definition; any folder two authors share drifts. This is a structural need, not a power-user preference — there is no adopter setup in which zero automated writes ever occur.

**What brain-stem adds:** the consistency machinery those levers were missing — a seeded folder scaffold with index-file discipline; two write-time guards (an advisory "spell-checker" and a blocking writer-reference "bouncer"); an opt-in staging pipeline that serializes competing writes through a single reconciler and lets a human edit always win; a catalog of every automated writer; and periodic drift sweeps. The shape is not arbitrary. The platform's hook can only allow-with-a-note *or* block, which is exactly why the guards split into one advisory and one blocking check; the platform offers no shared-write coordinator, so a single-writer funnel is forced rather than chosen. And where the design had latitude, it lands on patterns the wider software world arrived at independently — the Single Writer Principle, content-addressable storage, atomic file rename — so the same answer is reached twice, from constraint and from convergence.

---

## Scaffolding — a furnished show-home plus two address-specific fixtures

When someone first sets up the assistant, they get a starter vault built from two things bolted together.

The first is a **seed** — a frozen, identical set of folders and files installed at `~/.claude/vault-init/`. Think of it as a furnished show-home: every adopter gets exactly the same rooms on day one. The seed ships:

- **`System Governance/`** — the governance cluster folder, seeded with its own **`_index.md`** *and* six short, pre-written human-readable explainer notes (one each for Frontmatter, Tagging, Naming, Mandatory-Files, File-Type-Contracts, and Doc-Dependencies). The `_index.md` is the cluster's navigation note and also does double duty as the marker that proves "this is a vault we built." Each explainer note is the narrative companion to one machine-readable governance rule — it explains *why* that rule exists, in plain language, rather than restating the rule itself. All six ship in the seed already authored; the scaffolder lays down both the room and its furnishings.
- **`Vault Writers/`** — the catalog folder (covered in detail below), shipped with a mandatory `_index.md`.
- **`Meetings/`** — meeting notes.

The second is a pair of **address-specific fixtures** that *cannot* be pre-baked into the seed, because they depend on where you installed everything — so the scaffolder fits them once the install location is known:

1. A vault-root **`CLAUDE.md`** instructions file, rendered fresh from a template. (Claude Code auto-loads a project's `CLAUDE.md` at the start of every session, so the vault picks up its own conventions from the first session; this auto-load is documented at `code.claude.com/docs`.)
2. Four **shortcuts** — `Plans/` (your plans area), `Skills/` (`~/.claude/skills/`), `Wiki/` (the universal Library at `~/.claude-plans/_library`), and `Projects/` (the project binders at `~/.claude-plans/_projects`).

The scaffolder is `~/.claude/skills/onboarder/scripts/build-brain-vault.sh`. The copy is gentle and idempotent: it walks the seed file by file and **skips anything already present**, so re-running setup never clobbers your edits.

> This section is deliberately short. The full first-run story — the interview, the manifest, and adopt-by-default — lives in the onboarding documentation. Here it only matters as the structural shape of *what governance later operates on.*

---

## The two write-time guards — a spell-checker and a bouncer

Before any note is saved or edited, a single gate runs. Claude Code supports **PreToolUse hooks** — small programs that run *before* a tool executes, matched to specific tools (here the file-saving tools, Edit and Write). A PreToolUse hook can wave a save through, **allow it while attaching an advisory** (a reminder injected into the assistant's context), or **deny it** with a reason surfaced to the user that blocks the save. (Both outcomes — allow-with-context and deny-with-reason — are documented at `code.claude.com/docs`.)

The vault's gate is `~/.claude/hooks/pre-write-guard.sh`. It runs two vault-specific checks, and the *contrast between them* is the whole lesson.

**(1) The historical-data warning is the spell-checker — advisory.** If you are about to edit a note whose filename starts with a *past* date, the gate attaches a gentle reminder — *"this is dated in the past; are you sure you want to change history?"* — and **always lets the write through.** It is date-aware, not filename-blind: it parses the leading `YYYY-MM-DD` and warns *only* when that date is earlier than today. A note dated in the *future* passes silently (a meeting agenda or a planned entry should not nag you). The "today" comparison uses a configured time zone (default `America/New_York`) so a save at the day boundary is judged consistently.

**(2) The writer-reference check is the bouncer — blocking.** If a note inside the `Vault Writers/` catalog is about to be saved with a malformed header, the gate **refuses the write outright**, lists exactly which required fields are missing or wrong, and points you at `/govern register --kind writer`.

| Guard | Posture | Why this posture |
|---|---|---|
| Historical-data warning | Advisory — nudges, never blocks | Editing an old note is sometimes a legitimate human judgment call. A hard block would be wrong. |
| Writer-reference check | Blocking — refuses the write | Other automated systems depend on the `Vault Writers/` catalog being well-formed; a malformed entry would silently break a downstream sweep or the pipeline. |

The bouncer validates each catalog note against a contract (detailed later) rather than carrying its own idea of "well-formed." The catalog's two generated files — `_index.md` and `_overlap-matrix.md` — are *excluded* from the bouncer, because they are owned by the maintenance sweeps, not hand-authored.

---

## Direct write is the default; the pipeline is opt-in

This is the load-bearing fact, and it comes *before* the pipeline mechanics: **by default, a system writing into the vault simply writes the file directly.** The staging pipeline described in the next section is **not** used in that default path.

The staging pipeline is the heavyweight option you turn on only where a particular file actually needs the protection — when multiple systems fight over one file, or when a human's hand-edits must always win over an automated regeneration. It is engaged **per destination**, not vault-wide. A destination opts in by declaring its **posture** as `staged`; the default posture is `direct`. (The opt-in is declared either by a folder-level `_processing-rules.json` carrying `posture: staged`, or by setting `posture: staged` on that destination's entry in the writer's own catalog note.)

So as you read the pipeline below, hold this framing: it is the deliberate, turned-on-where-needed write path, not the universal one.

---

## The Vault Writers pipeline — many cooks, one expediter

When a destination *is* opted into staging, the pipeline governs every write to it.

A **writer** is any system that produces vault content — an email or calendar connector, a meeting-transcript importer, an agentic research flow. The governing rule of the whole pipeline is one sentence:

> **Writers never write the destination themselves.**

Instead, each writer drops a small data file — a **packet** — into a private staging area, and **one single program**, the **reconciler**, is the only thing that actually writes the destination.

The kitchen pass holds the picture together. Many cooks plate dishes — the packets — onto the pass; one **expediter** — the reconciler — is the only person allowed to send a plate to the table. Without this, ten writers editing one file directly would overwrite each other and corrupt it. Funneling every write through a single expediter makes the outcome predictable and lets the system record exactly what changed.

### Emitting a packet — the entry point

A writer never hand-composes a packet. It calls the shared library `~/.claude/hooks/lib/staging-emit.sh`, which drops **one packet per intended write**. The library:

- computes a **content hash** (a fingerprint of the packet body's exact bytes) and **names the packet after that hash**,
- writes it **atomically** (temp file, then rename) into the per-writer staging subfolder, and
- validates its own inputs first — the output type must be one of `markdown`, `json`, `sqlite`, `db`, or `opaque`; the writer's id must be filename-safe; the body file must be readable; any metadata must be valid JSON; and its tools (`jq`, `shasum`) must be present.

Naming packets by content hash gives **automatic de-duplication**: a writer that fires twice with identical content produces the *same* packet name both times, so it collapses to one — one packet, not two writes. The library's failure mode is **block-and-log**: on any problem it exits with a diagnostic and leaves nothing partial behind (the temp file is cleaned up). It also serializes per-writer using the standard macOS single-instance lock (`/usr/bin/lockf -k -t 0` — a macOS-shipped binary; see the macOS `lockf` man page).

### The sole writer — the reconciler

`~/.claude/skills/writer-reconciler/process.sh` is the *only* program that writes destination files. For each waiting packet it composes the effective rules (a folder's `_processing-rules.json` overrides the universal defaults), honors survivorship (next), writes the destination **atomically**, removes the processed packet, and records the write to a manifest — an audit trail of exactly what changed. An empty run (no packets waiting) is a cheap, immediate no-op.

One reconciler by *design* is not enough on its own. It is woken by events that can arrive in bursts, so two copies could start almost simultaneously and race — both writing the same destination, both deleting the same packet — producing a double-write or a corrupted file. So the reconciler grabs an **exclusive lock for the whole batch** before doing any work. A second copy that finds the lock held simply backs off, and the operating system releases the lock automatically if the program dies (no stale lock can ever wedge the pipeline). "Sole writer" is therefore enforced by an actual lock, not merely by intent.

### Survivorship — the person always wins

Survivorship is a **behavior of the reconciler**, not a separate machine. The rule: if a writer regenerates a note the human has since hand-edited, **the human's edit wins** and the reconciler *skips* the write, recording the outcome as preserved.

The reconciler detects a hand-edit by two signals — either is enough:

1. a `last_user_edit` timestamp in the note's header that is *newer* than the writer's emitted-at time, or
2. a content-hash mismatch — the fingerprint of the file on disk no longer matches what the writer last produced.

Either signal means a human touched it. This is the mechanism that makes the promise "the operator always wins" reliable, and it depends on nothing being remembered.

### How the reconciler wakes up

The reconciler's scheduler template, `~/.claude/templates/launchd/writer-reconciler.plist.tmpl`, wires it belt-and-suspenders: a **folder watcher** that fires within seconds of a new packet landing, *plus* a **relaxed timer** (about hourly by default) as a backstop. A dropped watch event would otherwise leave a packet unprocessed forever — an invisible silent miss; the timer is the insurance, and because an empty tick exits immediately, the insurance costs almost nothing. (macOS `launchd` supports both a file-change trigger and a timed trigger in one job; see Apple's `launchd.plist` documentation.)

---

## The AI lane — a corollary that still never writes the destination

The reconciler is purely mechanical. There is one optional, more intelligent lane alongside it.

`~/.claude/skills/doc-amender/process.sh` is the AI-merge lane. For destinations the user has explicitly opted into, it runs an operator-authored instruction through the AI model — via `claude -p`, the headless, no-chat-window mode that returns a single response (documented at `code.claude.com/docs`) — to *intelligently* merge new content into an existing note (for example, upserting one row into a table the note already contains).

The crucial discipline:

> Even the AI lane **does not write the destination.** It produces a new packet and drops it **back into staging**, so the single mechanical reconciler still performs the final write.

This is structural, not convention. The doc-amender emits through the very same `staging-emit.sh` library every writer uses, and it **self-excludes its own packet kinds** (the replacement and conflict packets) so it can never re-trigger itself in a loop on the staging watcher. Before it even calls the model, it honors a paused flag and a "reviewed" checkpoint on the destination, and it runs the same operator-edit-wins survivorship check. The principle: **the AI may compose content, but it is never the final writer of record** — which keeps one chokepoint, the reconciler, accountable for every actual change.

The AI lane's scheduler template, `~/.claude/templates/launchd/doc-amender.plist.tmpl`, is wired **watcher-only — no timer**. The model is invoked only when there is genuinely a new packet to consider, so AI cost stays proportional to real volume rather than ticking on a clock.

---

## Fan-in — several writers, one destination

The pipeline expressly handles **fan-in**: multiple writers targeting the *same* destination. The reconciler merges and orders their packets onto that one file — the expediter receiving plates from several cooks bound for one table.

The AI lane's eligibility check is itself fan-in-shaped. It reads *writer-fan-in* entries from the doc-dependencies registry, where a consumer destination declares which upstream writers feed it. The doc-amender only amends a packet when **both** are true: the packet's destination matches a fan-in consumer pattern, *and* the packet's writer is listed among that entry's declared upstream writers.

Fan-in is exactly what one of the periodic sweeps exists to surface: `writers-overlap-refresh` clusters writers that aim at the same destination pattern and flags collisions and incompatible write shapes (more below).

---

## The writer catalog, and how you grant create/modify rights

`Vault Writers/` is a **human-readable catalog**: one small note per registered writer (a *writer-reference* note) declaring what kind of writer it is, which skill runs it, where it writes, and its status. Anyone — human or AI — can open the folder and see every system that touches the vault.

**Granting write rights is a guided, validated path — never hand-editing.** You run `/govern register --kind writer`. It interviews you and composes a contract-compliant `Vault Writers/<slug>.md` note for you, then the blocking write-time guard validates the result on save. Registering *declares the writer's destinations* — each destination is a **path + an output type + a posture** (`direct` | `staged`; default `direct`) — plus its write shape. By default the command lays down a single direct-posture destination that you extend for your flow. Writer-reference notes are create-only registration records, not files that get rewritten repeatedly.

The required shape of these notes is the contract at `~/.claude/governance/file-type-contracts/vault-writer.md.json`. It specifies:

- **Mandatory header fields:** `type`, `writer_name`, `writer_kind`, `writer_skill`, `destinations`, `status`, `created`, `updated`, `tags`.
- **Allowed values** for the categorical fields — for example `writer_kind` is one of `connector`, `agentic-flow`, `auto-research`, `scheduled-skill`, or `custom`; `status` is one of `active`, `paused`, or `retired`.
- **Conditionally-required fields per kind** — a `connector`, for instance, must also declare its subtype, source, authentication, and schedule, which a `custom` writer need not.
- **The shape of each destination** — path plus output type, plus an optional posture (`direct` is the default).
- **A create-only write shape** — these are registration records.

`/govern register` is one command family with a small fixed set of modes — `writer`, `folder`, `file-type`, `tag-extension`, and `doc-amender-prompt` — so that *every* governance addition flows through a validated command rather than a hand-edited file. (Creating a plan is deliberately *not* one of these modes; plans are scaffolded by a separate command family.) The skill definition lives at `~/.claude/skills/govern/SKILL.md`; the writer handler is `~/.claude/skills/govern/modes/writer.sh`.

---

## What the guards consult — the merged governance view

It is worth one short note on *what* the write-time guards read. At save time the assistant consults a **merged view**: the foundation bundle `~/.claude/governance/foundation-master.json` (which carries the governance rules as slots inside one file) **unioned with** the adopter's overlay `~/.claude/governance/overlay-master.json`, deep-merged by `~/.claude/hooks/lib/foundation-overlay-load.sh`.

The overlay is the adopter's own customizations; it is empty on a fresh install. On a collision the **overlay wins** — but only if the overriding entry carries an `_override_reason` (a mandatory free-text justification), so customizations are never silent. The adopter has the composed bundle, the overlay, the per-file-type contracts under `~/.claude/governance/file-type-contracts/`, and the log-subtype registry. Think of the bundle as a database **read replica / materialized view** — one consolidated copy that many readers consult. The full detail belongs to the governance-engine documentation; here it only matters that the guards read this one merged surface.

---

## `_index.md` and the librarian's vault-health sweeps

Each user-facing folder carries an **`_index.md`** — a small navigation note listing the folder's files in a table — so a folder is never an unlabelled leaf and any reader, human or AI, can orient at a glance.

The guarantee that every such index stays current is **structural, not disciplinary**. The **librarian** is a maintenance skill, invoked as `/librarian <check>` (skills are invoked as slash commands; documented at `code.claude.com/docs`). It bundles several vault-health sweeps:

| Sweep | What it keeps current |
|---|---|
| `~/.claude/skills/librarian/capabilities/writers-index-refresh.sh` | Regenerates `Vault Writers/_index.md` (the catalog table) from the writer-reference notes, validating each against the contract first. |
| `~/.claude/skills/librarian/capabilities/writers-overlap-refresh.sh` | Regenerates `Vault Writers/_overlap-matrix.md` — the **fan-in view**: clusters writers aimed at the same destination pattern and flags collisions and incompatible write shapes. |
| `~/.claude/skills/librarian/capabilities/writers-health-audit.sh` | **Read-only:** flags dormant or never-observed writers, destinations that resolve to no folder, and a `writer_skill` pointing at a skill that does not exist. Emits findings only — never writes vault content. |
| `~/.claude/skills/librarian/capabilities/index-maintain.sh` | Reconciles every non-exempt folder's `_index.md` against the files that actually exist; auto-creates a missing index and auto-corrects mechanical drift, but only *flags* — never overwrites — human-authored descriptions and ordering. |
| `~/.claude/skills/librarian/capabilities/tag-coverage-audit.sh` | **Read-only:** flags notes missing a tags field or carrying tag prefixes outside the allowed taxonomy. |

The division of labor is the takeaway:

> **The write-time guards catch problems one file at a time, as they happen. The librarian sweeps catch accumulated drift across the whole vault, periodically.**

### How a sweep edits a file without eating human prose

When a sweep regenerates a table inside a note, it must not erase the paragraphs a human wrote around it. It uses **sentinels** — invisible HTML-comment markers (for example `<!-- writers-index:start -->` and `<!-- writers-index:end -->`) that bracket the machine-owned region. The sweep replaces *only* the text between the markers, copies everything outside them through verbatim, writes the result atomically, and — for an in-note table regeneration — **refuses to write at all if the sentinels are missing.** (Creating a brand-new index from scratch is a separate path: the index sweep will bootstrap a missing `_index.md` outright. The refusal applies specifically to regenerating a fenced region inside a note that should already contain it.) Generated content and human content coexist in one file, and the machine only ever touches its own fenced-off region.

---

## The lifecycle, end to end

| Stage | What happens | Where it lives |
|---|---|---|
| **Scaffold** | The seed tree is copied (including the six `System Governance/` explainer notes); the vault-root `CLAUDE.md` and the `Plans/`/`Skills/`/`Wiki/`/`Projects/` shortcuts are generated on top | `~/.claude/vault-init/`, `~/.claude/skills/onboarder/scripts/build-brain-vault.sh` |
| **Every save — advisory** | A past-dated note edit gets a non-blocking reminder | `~/.claude/hooks/pre-write-guard.sh` |
| **Every save — block** | A malformed `Vault Writers/` note is refused | same gate, against `vault-writer.md.json` |
| **Writer content in** | Writer → packet in staging → sole reconciler writes the destination (with survivorship + lock); optional AI lane composes a packet but never writes | `staging-emit.sh`, `writer-reconciler/process.sh`, `doc-amender/process.sh` |
| **Periodic sweep** | Catalog table, overlap/fan-in matrix, health audit, index reconciliation, tag coverage | the librarian capabilities |

Two notes on timing. `~/.claude/hooks/post-write-verify.sh` is a **PostToolUse hook** — one that runs *after* a tool executes (it cannot block, since the tool already ran; documented at `code.claude.com/docs`); it exposes an on-demand index-regeneration entry point the session-close sweep invokes. And the only two **scheduled** background jobs that ship are the reconciler and the doc-amender — there is no scheduled vault-cleanup job; the librarian sweeps run on `/librarian` invocation (and at session-close).

---

## Why this design — evidence & alternatives

Each governance choice below is the one left standing after a simpler-looking alternative was tried and found to break the "trustworthy for life" promise.

| Choice | Rejected alternative | Why it was rejected |
|---|---|---|
| One sole-writer reconciler serializes every staged write | Every writer writes the destination file directly | With many writers aimed at one file, two saves overlap and silently clobber each other; funneling all writes through a single program — the **Single Writer Principle** from concurrency design — makes the outcome ordered and recordable. |
| Two-signal survivorship — a hand-edit always wins | Let the last writer (or the AI lane) be the final writer, no survivorship check | A routine regeneration would silently overwrite a human's edit. Detecting the edit by *either* a newer edit-timestamp *or* a content-hash mismatch — the last-writer / merge discipline studied in operational-transformation and CRDT literature — guarantees the person wins. |
| Historical-data check is advisory; writer-registry check is blocking | Hard-block every imperfect note the same way | Editing an old note is sometimes a legitimate human call, so a block there is hostile — a nudge is right. A malformed writer-registry entry, by contrast, silently breaks a downstream sweep, so it must be refused. The platform's allow-with-note-or-block hook is *exactly* this two-way split. |
| File-watch event trigger plus a relaxed timer backstop | Pure timer-poll (or pure event-watch) | Blind polling adds minutes of latency; pure event-watch silently loses a dropped event forever. A `launchd` job carrying both — fire-on-change for seconds-level latency, timer as insurance — gets responsiveness without missed work. |
| Content-hash-named packets written by atomic rename | Hand-composed packets written in place | Naming a packet by the fingerprint of its bytes makes a duplicate write collapse to one file for free; a temp-file-then-rename keeps a reader from ever seeing a half-written packet. This is content-addressable storage plus POSIX atomic rename — the model Git uses for its objects, the familiar example. |
| Machine-written logs relocated out of the vault entirely | Keep machine exhaust in the vault and "exclude from search" | A notes app's exclude-from-search only *hides* a file; it still leaks into the search index and the graph view. The only reliable fix is to keep machine exhaust out of the notes folder in the first place. |

These choices are optimal on two independent grounds. Some are **forced by the platform**: Claude Code's write-time hook can only allow-with-a-note or block, which is precisely why the guards split into one advisory and one blocking check, and it offers no built-in coordinator for concurrent writers, so a single-writer funnel is required rather than preferred. The rest are **optimal by convergence** — the same answers the broader software world reached independently: the Single Writer Principle (concurrency design), content-addressable storage and POSIX atomic `rename(2)` (Git's object model is the everyday example), and last-writer / merge survivorship (the operational-transformation and CRDT literature on concurrent editing). When a design is reached twice — once because the platform forces it, once because the field converged on it — that is the strongest available signal it is the right shape.

---

## Glossary

- **Frontmatter** — the small block of metadata at the top of a note, fenced by `---`. The printed label on a filing folder; governance reads it to decide whether a file is well-formed.
- **Hook** — a small program the assistant runs automatically at a fixed moment. It can wave a save through, attach an advisory, or refuse it.
- **Write-time** — checked at the instant a file is about to be saved, before it lands on disk.
- **Content hash** — a fixed-length fingerprint of a file's exact bytes; the same bytes always produce the same hash.
- **Atomic write** — write to a temp file, then rename it into place in one step, so a reader never catches a half-written file.
- **Sentinel** — an invisible HTML-comment marker bracketing a machine-owned region, so an automated update touches only that region.
- **Packet** — the small, content-hash-named data file a writer drops into staging describing one intended write.
- **Writer** — any system that produces vault content.
- **Reconciler** — the single mechanical program that is the sole writer of opted-in destinations.
- **Survivorship** — the rule that a human's hand-edit always wins over an automated regeneration.
- **Fan-in** — several writers targeting one destination.
- **Posture** — the per-destination choice between the direct write path and the staged pipeline.
- **Vault** — the user's notes folder the assistant reads from and writes into.

---

## References

*All paths below are what an adopter has installed; this document explains the "why" behind them.*

- `~/.claude/vault-init/` — the seed tree copied into a new vault at setup (`System Governance/` with its `_index.md` plus the six explainer notes, `Vault Writers/` with its `_index.md`, and `Meetings/`).
- `~/.claude/skills/onboarder/scripts/build-brain-vault.sh` — the idempotent scaffolder (seed copy + `CLAUDE.md` render + `Plans/`/`Skills/`/`Wiki/`/`Projects/` shortcuts).
- `~/.claude/hooks/pre-write-guard.sh` — the write-time gate carrying both vault guards (advisory historical-data warning; blocking writer-reference check).
- `~/.claude/hooks/post-write-verify.sh` — the after-write hook that exposes the on-demand index-regeneration entry point (invoked by the session-close sweep). It never denies a write.
- `~/.claude/hooks/lib/staging-emit.sh` — the shared library a writer calls (only when a destination is opted into staging) to drop one content-hash-named packet.
- `~/.claude/skills/writer-reconciler/process.sh` — the sole destination writer (atomic write, two-signal survivorship, single-writer lock).
- `~/.claude/skills/doc-amender/process.sh` — the optional AI-merge lane (emits a packet back to staging; never writes the destination).
- `~/.claude/governance/foundation-master.json` — the composed governance bundle the write-time guards read.
- `~/.claude/governance/overlay-master.json` — the adopter's customization layer (empty on a fresh install; overlay wins on collision only with an `_override_reason`).
- `~/.claude/hooks/lib/foundation-overlay-load.sh` — the union-load helper that deep-merges bundle + overlay into the single merged view the guards consult.
- `~/.claude/governance/file-type-contracts/vault-writer.md.json` — the contract the blocking guard (and the writer sweeps) validate every `Vault Writers/<writer>.md` note against.
- `~/.claude/skills/govern/SKILL.md` — the `/govern register` command family (modes: `writer`, `folder`, `file-type`, `tag-extension`, `doc-amender-prompt`).
- `~/.claude/skills/govern/modes/writer.sh` — the `--kind writer` handler that composes a contract-compliant writer-reference note.
- `~/.claude/skills/librarian/capabilities/writers-index-refresh.sh`, `writers-overlap-refresh.sh`, `writers-health-audit.sh`, `index-maintain.sh`, `tag-coverage-audit.sh` — the vault-health sweeps.
- `~/.claude/templates/launchd/writer-reconciler.plist.tmpl` — reconciler scheduler (folder watcher + timer backstop).
- `~/.claude/templates/launchd/doc-amender.plist.tmpl` — AI-lane scheduler (watcher-only).
- The six `System Governance/` explainer notes (Frontmatter, Tagging, Naming, Mandatory-Files, File-Type-Contracts, Doc-Dependencies) — shipped pre-authored in the seed under `~/.claude/vault-init/System Governance/`, alongside the cluster's `_index.md`. Each mirrors one machine-readable governance rule with a plain-language explanation of why it exists.
- Commands: `/govern register`, `/librarian <capability>`.
- Anthropic docs: `code.claude.com/docs` (PreToolUse/PostToolUse hooks, allow-with-context / deny-with-reason, `claude -p`, `CLAUDE.md` auto-load, slash-command skills).
- macOS documentation: `launchd.plist` (folder-watch + timed triggers) and `lockf` (single-instance lock) man pages.
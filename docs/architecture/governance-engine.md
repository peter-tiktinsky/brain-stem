# The governance engine: how writes are allowed, denied, and advised

> **Audience:** adopters and curious users who want to understand *why* this system checks every file it is about to create or change — written for someone who has never used Claude Code and has no technical background. Every term is explained from scratch the first time it appears.
>
> **A note on two surfaces.** This system keeps its rules in two parallel forms. One is *machine-readable* — a structured rulebook the software reads at the exact moment it is about to save a file, so it can act. The other is *human-readable* — pages like this one, written so a person can follow the reasoning. The team calls the machine form the **APPLY surface** (the AI applies it) and the human form the **UNDERSTAND surface** (a person understands it). **This page is the UNDERSTAND surface.** The matching APPLY surface — the rulebook the AI actually consults at the moment of a write — is **not a single file but a *merged view*:** the shipped foundation bundle (`~/.claude/governance/foundation-master.json`) combined with the adopter's own additions (`~/.claude/governance/overlay-master.json`) laid on top, stitched together by a small helper (`~/.claude/hooks/lib/foundation-overlay-load.sh`) the instant a write is attempted. This page exists so a human can follow the reasoning; that merged view exists so the software can act on it. The two pieces — and exactly how they combine — are explained below.

---

## What Claude Code gives you — and what's missing

**Natively,** Claude Code exposes a single place to intervene before a file is written — a hook called `PreToolUse` that fires the instant the AI is about to save, and can answer *allow* or *deny*. That is the whole native surface: one interception point, and no opinion about what a good write looks like. There is no rulebook, no way to combine your own rules with shipped ones, and no sanctioned path to extend either.

**The gap:** a write-interception point with nothing to consult.

**What brain-stem adds:** the rulebook the platform leaves empty; a third verdict the platform lacks (*advise* — allow, but attach a reminder — not just allow/deny); a merge model that lays your rules over the shipped ones without conflict; and a guided way to register extensions. It is built *on* that one native interception point rather than beside it — which is exactly why it can mediate every write, and why this is the only shape the platform permits.

---

## What the governance engine is

Claude Code is a command-line program — a piece of software you run in a terminal — that wraps a Claude AI model and lets it read and write files on your machine. Because the AI can write files, something has to decide whether each write is a good idea. That something is the **governance engine**: a rulebook that is consulted *every single time* the AI is about to create or edit a file, and that returns one of three answers — allow it, block it, or allow it but attach a reminder.

The simplest way to picture the engine is a **doorman standing at the moment of every write**. The doorman consults one *merged* rulebook — the shipped foundation with the adopter's own additions laid on top (we will build up exactly what that means below). When the AI walks up carrying a file it wants to save, the doorman checks that merged rulebook and says one of:

- **"Go ahead."** (allow — nothing is said)
- **"Stop, fix this first."** (deny — the write is blocked and the reason is returned)
- **"Go ahead, but you forgot something."** (advise — the write proceeds and a plain-English note is handed back)

The engine is **not** specific to any one kind of content. The same doorman governs personal notes, project plan files, and configuration alike. It is general-purpose machinery for keeping a body of files structurally consistent.

---

## Hooks 101 — the moment-of-write trigger

To make the doorman fire automatically, the engine uses **hooks**. A hook is just a small shell script — a list of commands saved in a file — that the Claude Code program runs *for you* at a specific moment in its lifecycle. You do not invoke a hook by hand; the program runs it automatically. Think of a hook as an automatic checkpoint, not a button a person presses.

The program runs hooks at defined moments. Two of those moments matter most here:

| Moment | Official event name | What the engine does there |
|---|---|---|
| Right **before** a file is written | `PreToolUse` | The doorman decides allow / deny / advise |
| Right **after** a file is written | `PostToolUse` | A safety net runs — it can warn, but cannot undo the write |

When a hook fires, the program hands it a small bundle of information as text (which file, and for a new file the content being written) and then listens for the script's answer. A hook reads that bundle from its standard input (the channel a program reads from) and may print a small piece of structured data to its standard output (the channel a program writes to) to give its verdict back. We will return to exactly what that verdict looks like further down.

These hooks are wired up in a settings file that Claude Code loads automatically when it starts, so the checks fire without any per-session setup. You will sometimes see a **tool matcher** like `Edit|Write` in that wiring. That vertical-bar character `|` between two names simply means "either one" — `Edit|Write` reads as *"run this hook whether the AI used the Edit tool or the Write tool."* Editing an existing file and creating a new file are two different tools; the matcher catches both.

---

## The eight pillars — split by topic, shipped as slots

The rules are **not** written in one giant file. They are organized into eight topic areas called **pillars**, each owning exactly one slice of policy. Organizing by topic means each rule has one obvious home, so a second copy can never quietly drift out of sync.

Here is the load-bearing thing to understand up front: **on an adopter's machine the eight pillars do not arrive as eight separate files.** They arrive as eight **slots** inside one shipped bundle, `~/.claude/governance/foundation-master.json` (the next section explains that bundle). Picture a **furnished show-home with eight rooms**: the rooms are the pillars, the house is the bundle, and the adopter is handed the whole furnished house — not a stack of room blueprints. The third column below names the *slot* you would find inside the bundle, not a file you would find on disk.

| Pillar | Plain-language scope | Slot inside the bundle |
|---|---|---|
| Frontmatter | The small block of labelled metadata at the top of a note — which document types exist and what fields each requires | `foundation-master.frontmatter` |
| Tagging | The controlled vocabulary of hashtags, and the rule that notes should carry findability tags | `foundation-master.tagging` |
| Naming | What folders and files may be called, plus the list of known top-level folders | `foundation-master.naming` |
| Mandatory files | Which folders must contain a required file (such as an index page) | `foundation-master.mandatory_files` |
| Doc-dependencies | Which documents must be updated together so paired docs do not drift apart | `foundation-master.doc_dependencies` |
| File-type contracts | The per-document-type rulebooks — e.g. what a meeting note must contain | `foundation-master.file_type_contracts` |
| Vault-writers | The registry of automated systems that write into the vault | `foundation-master.vault_writers` |
| Plans | The lifecycle rules for project plan folders | `foundation-master.plans` |

The same eight names show up one more time, in the adopter's own additions file: **the overlay (covered two sections down) mirrors these exact eight pillar slots, plus one extra `system` slot** for machine-wide settings such as a timezone — and on a fresh install every one of those slots is empty. Keep that picture in mind; it is the symmetry that makes the whole engine simple to reason about.

> The pillars also have human-readable companion pages that ship in the vault under `System Governance/` — one narrative spoke per pillar. Those spokes explain a single pillar in everyday language; this architecture page explains how all eight compose into one working engine.

---

## Composition into a single shipped bundle

So where do those eight slots come from? They are built, once, before anything ships. In a separate **build workshop** — a place off the adopter's machine entirely — authors maintain eight topic source files (one per pillar) and the per-document-type contracts. At release time a build tool stitches all of that together into one composed file, `~/.claude/governance/foundation-master.json`, and *that single composed bundle is the only thing that ships.* The source files and the stitching tool stay behind in the workshop; they never land on an adopter's disk.

The plain analogy: the source files are the **recipe cards** and the stitching tool is the **kitchen** — both stay in the restaurant's back room. What gets delivered to the table is the **finished, sealed meal**: `foundation-master.json`. The adopter receives only the meal. There are no recipe cards to carve up on the adopter's machine, and nothing to rebuild.

A few properties make this trustworthy:

- **It is a single composed bundle.** It carries one slot per pillar — `frontmatter`, `tagging`, `naming`, `mandatory_files`, `doc_dependencies`, `file_type_contracts`, `vault_writers`, `plans` — plus some pre-computed runtime slices the guard needs and a small `_meta` block describing the build.
- **It is treated as immutable shipped state.** Adopters never rebuild it, and it is never hand-edited.
- **The build is reproducible.** The same inputs always produce the same bundle, identified by a **content fingerprint**. A content fingerprint is a short code — technically a *hash*, a fixed-length string mechanically computed from the bundle's exact contents — such that identical content always yields the same code, and any change yields a different one. In this bundle the fingerprint is stored as `_meta.bundle_version`. The build deliberately leaves the build timestamp out of the input it fingerprints, precisely so a rebuild of unchanged content does not look like a new version. (This is not a guess: the bundle's own `_meta` block records that `built_at` and the source-file modification times are intentionally excluded from the `bundle_version` hash, "so identical content rebuilt at different times produces stable version.")

---

## The adopter overlay and the deep-merge

The shipped foundation bundle is the **same for everyone**, and it must not be edited locally. But every adopter needs to add their own folders, document types, tags, and automated writers — without touching the sealed foundation. That is what the **overlay** is for.

`~/.claude/governance/overlay-master.json` ships as an **empty skeleton that mirrors the bundle's eight pillar slots exactly** — `frontmatter`, `tagging`, `naming`, `mandatory_files`, `doc_dependencies`, `file_type_contracts`, `vault_writers`, `plans` — **plus one extra `system` slot** for machine-wide settings such as a timezone. On a fresh install all nine slots are empty; the overlay is never shipped pre-populated. (Verified on disk: nine empty slots in exactly that order.)

When the doorman needs the full ruleset, a small helper, `~/.claude/hooks/lib/foundation-overlay-load.sh`, reads the foundation bundle *and* the overlay and combines them with a **deep-merge**. "Deep-merge" means it walks *both* trees of settings from top to bottom and, wherever they cover the same spot, the adopter's overlay value wins; everywhere else, *both* contributions are kept. The single combined result — the foundation with the overlay laid on top — is the view the guard actually reads.

> **Picture the overlay as a transparent sheet laid over the master copy.** Wherever the sheet has writing, you read the sheet; everywhere else you read the master straight through it. The adopter extends the system without ever modifying the shipped foundation.

### Why the adopter never edits the foundation directly

Keeping the shipped foundation untouched, and putting *all* local additions in a separate overlay, is what makes two things possible at once:

1. An adopter can take a **new release** of the foundation without losing their customizations.
2. The system can tell **adopter-added** rules apart from **shipped** rules.

If everyone hand-edited the master, every upgrade would overwrite local work, and no one could reason about what was standard versus custom. The two-file split — sealed master plus transparent overlay — is the structural guarantee behind safe upgrades. And because the overlay mirrors the bundle's slots one-for-one, an adopter always knows exactly where their addition goes: into the slot for the matching pillar.

---

## The collision rule — you may overrule, but you must sign your name

Because the overlay *wins* on a deep-merge, an adopter could accidentally (or silently) override a shipped rule. The engine refuses to let that happen quietly.

When an overlay entry would **shadow** a foundation entry of the same identity — sit on top of it and replace it — the adopter must attach a short written justification, an **`_override_reason`**, directly to that specific entry. The merge helper checks this *before* it merges. With no reason attached, it treats the silent shadowing as an error and **blocks the merge**, printing a message that names each offending entry and spells out the two ways to fix it: either add the `_override_reason` inline on that entry, or pass the single-use bypass flag (`--force-override`) for the one write that genuinely needs it.

> Plain framing: you are allowed to overrule the shipped policy — but you have to **sign your name and say why, on that exact line.** There is a single-use bypass for one specific write, but there is **no permanent off-switch.**

This closes a concrete failure mode: an adopter's overlay silently overriding shipped policy and no one noticing until something downstream breaks.

---

## The write-time guard: allow, deny, advise

`~/.claude/hooks/pre-write-guard.sh` is the doorman. It fires **before** any file is created or edited (it is wired to the `PreToolUse` event with the `Edit|Write` matcher). On each invocation it reads the merged foundation-plus-overlay view once (via the merge helper above), works out *what kind* of file is being written and *where*, and then does exactly one of three things.

Before the table, a word on the field names that appear in it. Claude Code defines a small, published contract for how a hook reports its verdict: the hook prints a structured object whose fields have fixed names. The four names below — `hookSpecificOutput`, `permissionDecision`, `additionalContext`, and `permissionDecisionReason` — are those published field names, documented by Anthropic (see References). You do not need to memorize them; they are shown here only so the mechanism is verifiable against the official documentation rather than asserted on faith.

| Verdict | What the user experiences | How the guard says it |
|---|---|---|
| **Allow** | The write proceeds; nothing is said | Returns permission `allow` with no note |
| **Advise** | The write proceeds, with a plain-English reminder attached to the conversation | Returns permission `allow` *plus* an `additionalContext` note the AI sees and can act on |
| **Deny** | The write is blocked; the AI must fix the problem and retry | Returns permission `deny` *plus* a reason |

Concretely: the guard prints a small piece of structured data (a `hookSpecificOutput` object) carrying a `permissionDecision`. On an *allow* it may attach `additionalContext` — free text that gets fed back into the conversation so the AI reads it. On a *deny* it attaches a `permissionDecisionReason`. In both cases the script exits cleanly. An advisory is therefore literally *"allow, and here is a note"* — the write is **not** stopped.

Three concrete examples make the contract tangible:

- **Deny.** Writing a note whose `type` field is not in the allowed list of document types is **blocked**, with a reason telling the author exactly how to add a new type the right way. An unknown type would slip past every downstream type-specific check, so this one is worth blocking.
- **Advise.** Writing a note with **no tags** produces an *allow-with-advisory* reminder ("add tags per the taxonomy; tags are load-bearing for graph health and cross-folder retrieval"). The write is **not** blocked — blocking someone from saving their work over a missing tag is hostile, and would only train people to disable the guard.
- **Advise (cascade).** Editing one document that belongs to a registered dependency group triggers an advisory naming the **mirror documents** to review in the same session — catching the failure where one half of a paired doc is updated and the other silently rots.

The guard also carries a few specialist behaviours on top of the three-verdict core: the overlay-collision deny described above; a live-mutation safety gate; and a *propose-and-validate* notice that suggests running `/govern register` when it spots an extension that is not yet known to the rulebook (more on that below).

> The takeaway: **advise is the workhorse.** Most policy is *taught*, not enforced by blocking.

---

## Tiered enforcement — most rules teach before they block

The engine deliberately runs rules at **different strengths**.

- **Advisory by design.** Many checks nudge but never block. Blocking a person from saving their work over a missing tag would be hostile and counterproductive.
- **Hard denial, reserved.** A smaller set of checks *do* block — but only where allowing the write would **corrupt the structure**: an unknown document type, a malformed required field, a plan folder with a broken status.
- **Promotable, but earned.** Some advisory rules are written so they *can* be promoted to blocking later — but only once real usage data shows the rule is right and rarely raises a false alarm. As one example, the plan-status advisory explicitly states that it is advisory only and that promotion to a hard block is gated on adoption data, so it does not retroactively deny older plans.

> The plain principle: the system starts gentle and **earns the right** to get strict. It never asserts strictness on a hunch.

---

## File-type contracts — a small rulebook per document kind

Beyond the broad pillars, the engine carries a small rulebook for each *specific* kind of document — a meeting note, a plan spec, a decision record, the vault's own governance summary page, and more. These live under `~/.claude/governance/file-type-contracts/`, and each contract states what that document type must contain: which metadata fields are required, which values are allowed, and sometimes a size limit. All of them are folded into the composed bundle, so the guard can check, for example, that a meeting note actually carries a date.

The **size-limit** case is a clean illustration of a rule realized through *data* rather than through code. The vault's System Governance hub page is navigational — a short index, not a place for long content — so its contract (`~/.claude/governance/file-type-contracts/System Governance.md.json`) declares a maximum line count. The guard reads that limit *from the contract* (via the bundle) and **denies an over-length write**. The limit lives in the contract, not hardcoded in the script — so adjusting it is a data change, not a code change.

---

## Plans is a bundle slot — and plan manifests get a second check

The plan lifecycle rules are **not** a separate system bolted on beside the engine. **`plans` is one of the eight slots inside the composed bundle** (`foundation-master.plans`). When the doorman needs to know the rules for a project plan folder — what its status values may be, what files it must contain — it reads them straight from that slot, exactly the way it reads the other seven. No special path; same bundle.

On top of that, project plan folders carry a structured status file — a **manifest** — that other tools rely on to track the state of a project (a plan index, a project task-walk, the status guards). A malformed manifest would break those tools **silently**, and the breakage would only surface later, when one of them fell over. So plan manifests get a *second, separate* check: they are additionally validated against their own strict blueprint, the **plan-manifest schema** at `~/.claude/schemas/plan-manifest-schema.json`. (A "schema" is a blueprint that says exactly which fields a file must have and what shape each one takes.) This is a distinct check from the eight pillar slots — the slots govern the plan *folder*; the schema governs the *manifest file* inside it.

The pre-write guard already does part of this work at write-time: when the file being saved is a plan manifest, it runs a **substance check** — verifying the manifest's facts line up before the write lands. The deeper, full-shape conformance check against the plan-manifest schema is the job of a separate **after-the-write verifier**, `~/.claude/hooks/post-tool-use-manifest.sh`. This verifier ships with the system; like a handful of other shipped-but-not-default hooks, it runs once you wire it into the after-write (`PostToolUse`) step. When it runs, it re-reads the manifest from disk and confirms two things: that it is still well-formed data, and that it conforms to the plan-manifest schema's expected shape. Because it runs *after* the write, it **cannot undo it** — it is therefore purely **advisory**: it surfaces a warning so a malformed manifest is caught immediately rather than discovered later, when the plan index, the orchestrator's task-walk, or the status guards quietly fail.

This is the division of labour to hold onto:

- The **pre-write guard** prevents bad writes where it can — it sees the content *before* it lands, reads the plan-folder rules from the bundle's `plans` slot, and runs the write-time manifest substance check.
- The **post-write manifest verifier** is a **safety net** for the manifest file specifically, where silent corruption is most expensive — and, once wired, it validates against the plan-manifest schema, catching what slipped through.

---

## The three-tier convention: schema, guard, safety-net

The plan-manifest example above is a specific instance of a convention that holds **system-wide** across every place a JSON schema and the write-time guard both have a say. It is worth stating plainly because it is easy to mis-read a schema as "the thing that gets enforced at write-time" — it is not. Three tiers, with deliberately different breadth:

1. **The JSON schema is the authoring *contract* — the full vocabulary.** It is the broadest accept-set: every field a file *may* carry and the shape each takes. It documents the surface for authors and tools. Two consequences follow from "contract, not gate": a schema is permissive where the readers are permissive, and — except for the one write-side validator noted below — **no live consumer validates an instance against it at runtime**; readers pull fields with `jq '<path> // default'` and degrade gracefully when a field is absent. The `user-manifest.json` schema is the clearest case: its `paths` / `vault` / `behavioral` / `system` blocks are `additionalProperties: true` precisely so that a knob a reader supports (a path override, a librarian vault-customization field) never gets *rejected* by the one write-side validator (`onboarder/scripts/bootstrap-user-manifest.sh`). The schema's job there is to *describe and type the known surface*, not to fence it.

2. **The pre-write guard is the blocking *subset* — narrow and unforgeable.** `pre-write-guard.sh` enforces only what is both cheap to check before the write lands and genuinely worth *blocking* on: structural presence (a required field exists), the depth-3 status enum, and unforgeable transition facts (a plan cannot be marked `closed` without a `verified` predecessor; `verified` requires a fresh verdict). It is intentionally **narrower than the schema** — it does not re-implement full-shape conformance, and blocking a save over every schema nicety would be hostile (see *Tiered enforcement*, above). Where the guard is *stricter* than the schema, that is a custom rule layered on top (for example, the overlay `_override_reason` deny), not the schema talking.

3. **The PostToolUse verifier is the advisory *completeness* net.** `post-tool-use-manifest.sh` runs the full Draft-2020-12 schema validation **after** the write — so it cannot undo, only warn. It catches the long tail the guard does not block, surfacing it immediately rather than letting a malformed file fail silently downstream.

The shape to remember: **schema = permissive contract; guard = authoritative but narrow; safety-net = advisory but complete.** When you add a field to a schema, do not assume the guard now enforces it — it does not, unless you also add a guard clause. (This pairs with the release hard-rule that every hand-curated enforcement list needs a gate-independent completeness backstop.)

### Two known R-27 documentation gaps

R-27 is the plan-structure rule the guard enforces. Two places where the guard is deliberately **looser than the schema**, recorded here so they read as design choices rather than oversights:

- **Depth-2 status is checked for *presence* only, not vocabulary.** At the plan-root level the guard confirms a `status` field exists; it does not re-validate the value against the 9-token enum (the schema and the depth-3 guard clause do that). Presence-at-depth-2 is the cheap structural floor; full-enum conformance is the schema's job and the PostToolUse net's.
- **Sub-plan `parent_plan` / `sub_plan_id` requiredness is not pre-write-blocked.** The schema makes these conditionally required (an `if/then` on sub-plan files), but the guard does not deny a sub-plan write that omits them — that conformance is caught only by the PostToolUse advisory. Promotion to a write-time deny is a future call, gated on adoption data (the same "earned, not assumed" promotion bar the plan-status advisory uses).

---

## Extending the system the sanctioned way

When an adopter wants to add a new top-level folder, a new document type, a new tag dimension, or a new automated writer, they do **not** hand-edit the overlay file. They run the `/govern register` skill (a *skill* is a capability you invoke with a slash command). The skill walks a **propose-then-confirm** conversation: it drafts the exact settings, lets the adopter accept or edit each field, and only then writes them into the overlay.

Every overlay write flows through a single, locked, validated mutation path (`~/.claude/hooks/lib/overlay-master-mutate.sh`) that also records the action in an append-only audit log (`~/.claude/governance/governance-action-log.jsonl`). No skill writes the overlay file directly.

The skill registers exactly five kinds of thing:

| `--kind` | Use it to register |
|---|---|
| `folder` | A new top-level vault folder |
| `file-type` | A new document type in an existing folder |
| `tag-extension` | A new tag dimension |
| `writer` | A new automated vault-writing system |
| `doc-amender-prompt` | A new guided document-amendment prompt asset |

It deliberately **declines one kind — `plan`** — because creating a project plan is a separate workflow (`/new-plan` or `/backlog-research`), not a governance registration. Ask for `--kind plan` and the skill recognizes the request only to redirect you to the right door.

> The relationship to remember: **hook proposes, skill registers.** The pre-write guard can *notice* an unregistered extension and *suggest* registering it (it pauses and proposes, but lets you skip frictionlessly, logging the skip); the `/govern register` skill is what actually performs the registration.

### Convention versus registration

Not everything needs to be formally registered. The engine distinguishes:

- **Conventions** — lightweight documented patterns the guard treats as harmless and leaves alone.
- **Registrations** — structural extensions the guard would otherwise flag or block, which must enter the overlay through the five modes above.

When the guard sees a new extension that the rulebook does not yet know, it **pauses and proposes** registering it — but lets the person **skip frictionlessly** (the skip is simply logged). This is the design principle in action: the foundation mandates the core *system* folders, while the adopter defines their *own* cluster names and document types through registration, on their own terms.

A note on the limits of write-time enforcement: a pre-write hook sees **exactly one file per call**, so it cannot inspect a multi-file change set. The "these files must change together" rule is therefore *documentary* at write-time and is actually caught later — at the commit boundary and by the session-close audit `~/.claude/skills/librarian/capabilities/governance-parity-audit.sh`, which is the audit-time backstop to the write-time guard.

---

## Graceful degradation — the engine fails open

A governance system that **locked people out** when *it itself* was misconfigured would be worse than no governance at all. So the engine's defaults lean toward letting work continue while surfacing the problem.

- **Missing bundle → allow.** If the composed `foundation-master.json` is absent, the guard **fails open** — it allows the write rather than blocking everything.
- **Corrupt overlay → foundation-only view.** If the overlay file is broken, the merge helper falls back to a *foundation-only* view: degraded, but safe.
- **Missing machine identity → quiet exit.** Hooks that depend on machine-specific identity simply exit cleanly when that information is absent.

The plain principle: **safe defaults let work continue, and the problem is surfaced, not buried.**

---

## Why this design — evidence & alternatives

The engine's two load-bearing choices — **advise before you deny**, and a **sealed master with a transparent overlay** — are each the answer to a documented failure of the obvious alternative.

| Choice | Rejected alternative | Why it was rejected |
|---|---|---|
| **Advise is the workhorse; deny is reserved** | Block on every imperfection (deny-first) | Blocking a save over a missing tag is hostile and trains people to switch the guard off — and a disabled guard enforces nothing. Independent policy systems converged on the same gentler ladder: warn before you enforce. |
| **A third verdict — *advise*** | The platform's two-way allow/deny only | Allow-or-block alone has no way to *teach*; most policy should be taught, not enforced. The advisory carries a plain-English reminder the assistant can act on, with the write never stopped. |
| **A sealed master plus your overlay on top** | One rulebook everyone hand-edits | If everyone edits the master, every upgrade overwrites local work and no one can tell custom rules from shipped ones. The two-surface split is the structural guarantee behind taking an update *without* losing your customizations. |
| **A signed reason to overrule a shipped rule** | Silently letting the local rule win (the way `git config` shadows) | A silent override goes unnoticed until something downstream breaks. brain-stem blocks the merge until the override is signed with a reason — deliberately stricter than its analogs. |
| **Enforcement in a hook, at write-time** | A standing rule written into a prose preferences file | Prose rules degrade over a handful of sessions and get rationalized away under pressure (Claude Code issues [#33603](https://github.com/anthropics/claude-code/issues/33603), [#56393](https://github.com/anthropics/claude-code/issues/56393)). The hook fires deterministically on every write, regardless of the assistant's cooperation. |
| **Intercept *before* the write (`PreToolUse`)** | Check *after* the write (`PostToolUse`) | An after-the-fact check cannot prevent the bad write, and the after-write channel cannot even inject a correction back into the conversation ([#18427](https://github.com/anthropics/claude-code/issues/18427)). The pre-write hook is the only point that can actually mediate. |

Two of these are optimal *by constraint*: the pre-write hook is the only interception point the platform exposes, so building the doorman there is the one shape that works — it realizes the **complete-mediation** principle of Saltzer & Schroeder (1975), that every access must be checked. The advise-then-deny posture is optimal *by convergence*: independent policy systems — Open Policy Agent's Gatekeeper (`dryrun → warn → deny`), the Kubernetes Pod Security Standards (`enforce / audit / warn`), code linters, and progressive-delivery rollouts — all arrived at the same gentle-by-default, strict-where-it-counts ladder without coordinating. When that many independent designs rediscover one shape, it is not a matter of taste.

---

## References

Everything below is an **installed artifact** — a file that lands on an adopter's own machine when the system is installed, under their home directory at `~/.claude/`. These are the paths you would actually find on a running install; this page does not point at any build or source repository. (In particular, the eight per-pillar source files and the stitching tool are **not** listed here, because they stay in the build workshop and never reach an adopter — their eight pillars arrive as *slots inside* `foundation-master.json`.)

**The composed contract and the overlay (`~/.claude/governance/`)**

- `foundation-master.json` — **the APPLY surface** (read together with the overlay; see the merge helper). The single composed, shipped, immutable bundle the write-time guard reads at every write. Carries one slot per pillar — `frontmatter`, `tagging`, `naming`, `mandatory_files`, `doc_dependencies`, `file_type_contracts`, `vault_writers`, `plans` — plus pre-computed runtime slices and a `_meta` block. Stitched in the build workshop; never hand-edited, never rebuilt by adopters. Carries the content fingerprint at `_meta.bundle_version`.
- `overlay-master.json` — the adopter-local overlay. Ships as an empty skeleton that mirrors the bundle's eight pillar slots plus one `system` slot (for machine-wide settings such as a timezone) — every slot empty until the adopter registers an extension. Deep-merged on top of the foundation, overlay wins, with a mandatory `_override_reason` on any shadowing entry.
- `file-type-contracts/` — the per-document-type rulebooks, all folded into the bundle (meeting notes, plan specs, decision records, the governance hub page, and more).
- `file-type-contracts/System Governance.md.json` — the contract carrying the line-count limit; the worked example of a size guard living in data, not in code.
- `log-subtype-registry.json` — the shipped registry of log subtypes (consumed by the log-archive retention capability).
- `governance-action-log.jsonl` — the append-only audit log of every `/govern register` action and every frictionless skip (created empty at install time; mineable once used).

**The write-time and after-write hooks (`~/.claude/hooks/`)**

- `pre-write-guard.sh` — the write-time doorman. Reads the merged foundation-plus-overlay view, returns allow / allow-with-advisory / deny; carries the System Governance size-cap deny (reading the limit from the bundle, failing open if the bundle is missing), the overlay-collision deny, the live-mutation safety gate, the cross-document cascade advisory, the write-time plan-manifest substance check, and the `/govern register` suggestion.
- `post-write-verify.sh` — fires after a write; exposes an on-demand index-regeneration entry point (invoked by the session-close sweep). Never denies; always exits cleanly. Wired into the after-write step by default.
- `post-tool-use-manifest.sh` — the after-write plan-manifest verifier; re-reads a just-written plan manifest, confirms it is well-formed and conforms to the plan-manifest schema, and warns. The safety net for files where silent corruption is most expensive. Ships with the system as a shipped-but-not-default hook — wire it into the after-write step to activate it.
- `lib/foundation-overlay-load.sh` — the merge helper. Runs the `_override_reason` collision check, emits the deep-merged view the guard reads, and falls back to a foundation-only view if the overlay is corrupt.
- `lib/overlay-master-mutate.sh` — the single locked, validated path through which all overlay writes flow, validating against the overlay schema and appending the audit-log row.
- `lib/paths.sh` — the path-resolution helper every hook sources so no install path is hardcoded in a hook body.

**The schemas (`~/.claude/schemas/`)**

- `plan-manifest-schema.json` — the strict blueprint plan manifests are additionally validated against (a separate check from the eight pillar slots). Read by `post-tool-use-manifest.sh`.
- `overlay-master-schema.json` — the blueprint the overlay is validated against before any overlay write (the eight pillar slots plus the `system` slot, including `system.timezone`).

**The sanctioned extension and audit paths (`~/.claude/skills/`)**

- `govern/` — the `/govern register` skill: `SKILL.md`, `process.sh` (the orchestrator), and `modes/` (one handler per registering kind — `folder`, `file-type`, `tag-extension`, `writer`, `doc-amender-prompt`). Recognizes `--kind plan` only to redirect to `/new-plan` or `/backlog-research`.
- `librarian/capabilities/governance-parity-audit.sh` — the session-close backstop that catches multi-file drift the single-file write-time guard structurally cannot see.

**Companion narrative pages**

- The vault's `System Governance/` folder — one human-readable spoke per pillar; the everyday-language companions to this engine-level overview.

**External**

- Anthropic's official Claude Code documentation at `code.claude.com/docs` — the authority for the hook lifecycle (`PreToolUse` / `PostToolUse`), the `Edit|Write` tool matcher, the standard-input event payload, and the `hookSpecificOutput` / `permissionDecision` / `additionalContext` / `permissionDecisionReason` decision contract this page describes.
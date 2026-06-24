# Onboarding — the first-run setup

> **Audience:** foundation authors who maintain the onboarding skill, plus adopters who want to understand WHAT happens the first time they type `/onboard`. **This doc is canonical for:** the `/onboard` first-run flow, the user-manifest it produces, the adopt-by-default copy of the starter vault into your own vault, and how the two `CLAUDE.md` files (the global personal-preferences one and the vault-root one) get authored at setup. **This is the UNDERSTAND surface** — the human-readable explanation of how setup works. **The APPLY surface** — the runtime logic that actually runs when you type `/onboard` — is the installed skill scripts under `~/.claude/skills/onboarder/`. Read this to understand; read those to see exactly what executes.

---

## What Claude Code gives you — and what's missing

**Natively,** Claude Code provides the raw ingredients of a first-run flow but no first-run step itself: a documented setting that makes a command human-invoked-only (never model-fired), the fact that it *concatenates* (not overrides) the global and project preferences files, comment syntax that costs zero context, and a session-start channel that can inject a reminder without blocking. A bare install has no equivalent first-run step at all.

**The gap:** the identical install is not yet *your* system — without a first-run step you would hand-write your preferences file, learn its schema, and build your vault tree by hand.

**What brain-stem adds:** a one-time guided interview that turns the identical install into your system — a mechanical confirmation card pre-filled from your environment, a short free-form section condensed into structured fields, producing a validated preferences record, your personal preferences file, and a seeded vault — with placeholder-residue checks, no-clobber diffs, and a soft "you can do this later" gate. The point of all of it: onboarding *is* the personalization seam. Its mechanism matches established first-run/setup-wizard practice (optimal-by-convergence), built on the platform's own human-invoked-only and concatenation facts (optimal-by-constraint).

---

## What onboarding is

When someone installs brain-stem, they have all the moving parts but nothing personalized. The system does not yet know who they are, where they want their notes kept, or how they like to be talked to. **Onboarding is the one-time guided setup that fills those gaps.**

You type one command — `/onboard` — answer a short two-part interview, and the system produces three things:

| Output | What it is | Where it lands |
|---|---|---|
| **A settings file** | A small machine-readable record of your answers (name, email, timezone, vault location, role, preferences) | `~/.claude/user-manifest.json` |
| **A personal preferences file** | A plain instructions file the assistant reads at the start of every session | `~/.claude/CLAUDE.md` |
| **A "brain" vault** | A fresh notes folder, pre-built and wired, ready to open in the Obsidian note-taking app | a folder on your computer (default under `Documents/`) |

The whole thing is a short, guided pass and is meant to be done **exactly once**.

Think of it as the setup wizard a new app shows you the first time you open it — except this one also builds your filing cabinet and writes down your preferences so the assistant remembers them across every future conversation.

A few terms you will meet below, glossed once:

- **Claude Code** — the command-line tool that runs the AI assistant on your machine.
- **AI model (also called an "LLM," large language model)** — the underlying engine that reads plain-language input and writes plain-language output. One step of onboarding asks this engine to summarize what you typed.
- **A "skill"** — a named capability you trigger by typing a slash and its name (for example, `/onboard`). The slash-command invocation model is documented at `code.claude.com/docs`.
- **A "hook"** — a small script the system runs automatically at a set moment (for example, when a session starts), without you asking.
- **JSON** — a plain-text format computers read reliably; the settings file is written in it.
- **A "schema"** — a strict blueprint that says exactly which fields a JSON file is allowed to contain and which are required.

---

## `/onboard` is a skill, and you must type it

`/onboard` is a skill. Most skills can be triggered two ways — you type them, **or** the assistant decides on its own that the moment calls for it and fires them automatically. Onboarding is deliberately set so the assistant can **never** fire it on its own. Only a human typing `/onboard` starts it.

The reason is safety. Onboarding writes your personal files and builds your vault. It must never surprise you by running unprompted in the middle of unrelated work.

The skill stays fully visible and discoverable in the menu — it is just muted from auto-firing. Underneath, the skill's definition carries one setting:

```
disable-model-invocation: true
```

In plain English: *the assistant is not allowed to start this by itself.* The exact name and meaning of this setting are documented at `code.claude.com/docs`.

This setting lives in the skill's definition file, `~/.claude/skills/onboarder/SKILL.md`.

---

## The single-use lifecycle — why it refuses to run twice

Onboarding is designed to run once and then get out of the way.

The moment setup completes, the system records a small true/false marker — call it the **"onboarding finished" flag** — inside the settings file. After that, typing a plain `/onboard` again does **nothing**: the system sees the flag is set, prints `Onboarding already complete — nothing to do`, and exits without touching anything.

This protects your personalized files from being accidentally wiped by a careless second run.

If you genuinely want to start over — new identity, new vault — you have to ask for it explicitly:

| You type | What happens |
|---|---|
| `/onboard` (after setup finished) | No-op. Prints "already complete," exits. Nothing is touched. |
| `/onboard --force` | The deliberate "yes, I really mean redo this" override. Re-runs the full chain. |

The lesson: a setup step that writes irreplaceable personal content should never be cheap to repeat by accident. It should require an explicit, conscious choice to redo.

---

## The two-part interview

The interview has two short parts.

### Section A — the confirmation card

The system has already looked up the obvious facts and simply shows them to you to confirm or correct:

| Field | Where it comes from |
|---|---|
| Name | Your git settings (`git config --global user.name`) |
| Email | Your git settings (`git config --global user.email`) |
| Timezone | Your operating system (reading `/etc/localtime`) |
| Brain vault location | A proposed default location for your new vault |

You press Enter to accept everything, or a number to edit a single field. No typing is required unless something is wrong. This is mechanical fact-gathering the computer can do for you, so it does not waste your time. Section A uses no AI and records no free text.

### Section B — the free-form part

This is the only part where you describe, in your own words, **who you are and how you work**:

- Your role and organization
- How you want the assistant to communicate with you
- How you want it to collaborate
- Your tooling and field of work

You can write loosely and at length; the system condenses your answer into a few labeled fields. Everything in Section B is **optional** — skip anything that does not apply.

This split matters because Section A is fact-gathering a probe can do, while Section B is the genuinely human input no probe can guess. Section B is the only place you actually have to think.

> **A note on voice.** Section B is written to be "spoken or typed." In the shipped general-availability flow, the path that runs is the **typed/staged** one: your written answer is captured and staged, then handed to the assistant for the extraction step (below). A spoken-voice recorder is an optional future add-on, not part of the shipped flow today.

---

## Turning free-form answers into structured fields — the extraction step

Your Section B answer is long and conversational; the files the system needs to fill are tight and specific. Bridging that gap is the **one** step in onboarding that uses the AI model to read and summarize. The system does it in two stages — call them two "passes," where each pass is one trip through the work:

1. **Pass 1** captures your transcript and writes out a fixed instruction sheet (the "extraction prompt") that wraps your words. The script then pauses and hands control back, signaling it is waiting for the AI model to do the summarizing.
2. **Pass 2** runs the assistant on that instruction sheet. The assistant returns a small, labeled summary — your role, your organization, and three short preference blocks (communication style, working patterns, tooling and domain). The script then checks that the summary contains only the expected fields (role and organization under "identity," the three preference blocks under "behavioral," and an optional free-text "notes") and, if so, wraps it for the next step.

This is what lets you write naturally while the system ends up with crisp, reusable settings. Think of it as a note-taker who listens to your introduction and writes down the handful of bullet points that fit the slots the rest of the system expects. The check above confirms the summary lands in the right slots; it does not grade how well-phrased the summary is, so the more clearly you describe yourself, the better the result.

---

## The user-manifest — the system of record for who you are

The **user-manifest** is the small structured settings file that holds everything the interview gathered: name, email, timezone, vault location, role, organization, and the three distilled preference blocks. It is written in JSON and lives at `~/.claude/user-manifest.json`.

It is the single **system of record** for your identity. Every other piece of setup — and every later session — reads your details from here rather than re-asking you. The manifest is like the read replica of a database: one authoritative copy of your details that many readers consult, kept consistent so they all agree.

Two guarantees protect it before it is ever saved:

- **It is validated against a strict blueprint.** Before the manifest is written, the system checks it against `~/.claude/schemas/user-manifest-schema.json`, which declares exactly which fields are allowed and which are required (name is required; role, organization, and the preference blocks may be empty). If the data does not fit the blueprint, the write is **refused** rather than saved broken.
- **It is written atomically.** The new version is staged off to the side and swapped into place in one instant. You never end up with a half-written, corrupted file if something fails mid-write.

The manifest builder also adds three fields you did not enter — the schema version, the creation date, and the "onboarding finished" flag set to true — because those are owned by the system, not the interview.

---

## Adopt-by-default — copying the vault seed into your own vault

brain-stem ships a **seed**: a small starter folder tree with the standard folders every brain vault has. The seed lives in one protected home at `~/.claude/vault-init/`:

| Seeded folder | What it is for |
|---|---|
| `Vault Writers/` | A catalog of any system that writes into your vault |

Onboarding **copies that seed into the location you chose and turns it into your working vault.** This is called *adopt-by-default*: you do not opt in to the standard structure as an extra step; you get it automatically as part of setup.

The copy is gentle. It walks the seed file by file and **skips anything already present**, so re-running is safe and never overwrites your work. The contents (the seed) and the copier (the onboarding skill) live in separate homes, so the standard structure can evolve without rewriting the setup logic. The skill carries its own build logic, but reads the shared, integrity-protected seed and templates from the install.

The seed is the blank, pre-labeled filing cabinet everyone starts with. Adopt-by-default means you walk away with the cabinet assembled, not a flat-pack box.

> **Build-history aside (safe to skip).** An earlier seed shipped only empty placeholder files. The result: nothing was copied, the marker file that proves "this is a vault we built" was never created, and a re-run was wrongly refused as if the folder belonged to someone else. The fix was to ship a real committed index file (`Vault Writers/_index.md`) so the marker exists from the first build. The `Vault Writers/_index.md` file doubles as that marker. This is fixed history, not current behavior — included only for authors tracing why the marker convention exists.

---

## The brain vault and the Obsidian-open beat

The **"brain" vault** is just a folder on your computer — by default at a sensible spot under your `Documents/` — that holds all your notes, plans, meetings, and the assistant's working files.

**Obsidian** is a free note-taking app that treats a folder of plain markdown files as a connected knowledge base. brain-stem uses it as the human-facing window into your vault.

When the vault builder finishes, it also wires five convenience links into the vault:

- `Plans/` → points to your plans home at `~/.claude-plans/`
- `Skills/` → points to your installed skills at `~/.claude/skills/`
- `Wiki/` → points to the universal Library at `~/.claude-plans/_library`
- `Projects/` → points to the project binders at `~/.claude-plans/_projects`
- `Work/` → points to your deliverable work area at `~/work`

(These are *symlinks* — folder shortcuts that make one location appear inside another without copying anything.)

After building the folder, onboarding does **not** silently finish. It prints a clear instruction:

> Open it in Obsidian (Open folder as vault) → select your vault path. Confirm when done.

This **confirm beat** exists because building the folder is invisible. The adopter needs an explicit, concrete next action so the setup does not just trail off. The system makes the filing cabinet, then explicitly hands you the key and tells you which drawer to open first.

---

## Two `CLAUDE.md` files get authored at setup

A `CLAUDE.md` file is a plain instructions file the assistant reads **automatically** when it starts working — think of it as a standing note pinned to the assistant's desk that it re-reads every session. Claude Code auto-loads these files at session start; this behavior is documented at `code.claude.com/docs`.

Onboarding authors two different ones, with different jobs:

| File | Location | What it holds | What it is about |
|---|---|---|---|
| **The global file** | `~/.claude/CLAUDE.md` | Your identity line plus three preference blocks (communication, working style, tooling & domain) | **You as a person**, across all your work |
| **The vault file** | the top of your new vault | A map of the vault's folder structure so the assistant knows where things live | **The layout** of one notebook |

When you have more than one such file in play, Claude Code combines them by concatenating them into context — the broader (global) instructions load first, then the more specific (project or vault) ones — rather than one silently overriding another. The combine behavior is documented at `code.claude.com/docs`.

Onboarding is the **authoritative author** of the global file. If you skip onboarding, you get **no** global preferences file at all — which is cleaner than getting a broken, half-filled one.

---

## Template substitution and the no-residue guarantee

Both `CLAUDE.md` files start life as **templates** — finished documents with blanks in them. The blanks are written as double-curly-brace placeholders like `{{IDENTITY_NAME}}` or `{{VAULT_ROOT}}`. The templates ship at `~/.claude/templates/claude-home-claude-md-template.md` (global) and `~/.claude/templates/vault-claude-md-template.md` (vault).

**Authoring means reading your manifest and filling every blank with your real values** — your name, your role, your vault path.

The system assembles these gracefully. If you are independent with no organization, it does not leave a dangling "at .". It adapts the identity line to whatever you provided:

| You provided | The identity line reads |
|---|---|
| Role and organization | `Jane Doe, Designer at Acme.` |
| Role only | `Jane Doe, Designer.` |
| Organization only | `Jane Doe (Acme).` |
| Neither | `Jane Doe.` |

It even normalizes the final punctuation, so an organization that already ends in a period (`Inc.`, `LLC.`) does not produce a double period.

Crucially, **before either file is saved, the system scans the finished text for any leftover blank of the `{{...}}` shape and refuses to write the file if even one remains.** This zero-residue check guarantees you never end up with a `CLAUDE.md` that literally says `{{IDENTITY_NAME}}` to the assistant.

It is the difference between a mail-merge letter that says "Dear Jane" and one that embarrassingly still says "Dear `[FIRST NAME]`". The system blocks the second outcome by construction.

> **On the HTML comments inside these files.** Both templates carry `<!-- -->` comment blocks with guidance for you, the human reader. Per Anthropic's documentation at `code.claude.com/docs`, Claude Code strips block-level HTML comments out of `CLAUDE.md` before injecting the file into the assistant's context — so, per that documented behavior, these blocks leave notes for you without spending the assistant's attention. The templates rely on this: their own author-guidance comments are written assuming they will be stripped before the assistant ever reads the file.

---

## No-clobber (never silently overwriting your edits) — how your edits survive a re-run

"No-clobber" means the system will not overwrite a file you may have personalized. Both `CLAUDE.md` files are meant to be edited by **you** after setup — that is the whole point of the `<USER: ...>` sections inviting you to add your own preferences and rules.

So onboarding promises not to silently overwrite them. If you re-run setup and a `CLAUDE.md` already exists and differs from what would be freshly generated, the system does **not** overwrite it. Instead it:

1. Writes the proposed new version off to the side, in a file ending in `.new`.
2. Shows you the differences.
3. Leaves your real file untouched until you decide.

Overwriting happens **only** if you explicitly pass `--force`.

The same protection covers your vault files: the seed copy skips anything already present, and the vault's own `CLAUDE.md` is preserved on a re-run unless you force it. The system treats anything you might have personalized as sacred, and makes destroying it require an explicit choice — never a side effect.

---

## The external-setup gate — a soft recommendation, never a wall

The last step offers two optional add-ons and recommends them honestly without ever blocking you:

| Add-on | What it does | Why it is recommended |
|---|---|---|
| **claude-mem** | An optional plugin (installed from a plugin marketplace) that gives the assistant broad automatic recall on top of brain-stem's own curated memory | The system is fully functional without it; the recommendation says so plainly |
| **GitHub** | A backup service that gives your vault full version history and lets you recover or sync across machines | Protects your work from any mistake |

For each, the system first checks — read-only — whether you already have it. If not, it presents:

- A strong recommendation,
- The honest reason,
- The exact command to set it up (for example, `npx claude-mem install` for claude-mem, or `gh auth login` followed by `gh auth setup-git` for GitHub — the latter wires git's HTTPS credential helper so backup pushes work),
- And a frictionless "skip and do it later — the rest of your setup still works."

It records your choice but never forces it. This is the **soft-mandate** pattern: a strong nudge with a real, complete path on either side. Set up both, neither, or one, and your setup still works coherently.

It is the difference between a checkout page that demands you create an account before buying, and one that says "an account saves your history — or check out as guest."

---

## Block-and-log — the failure philosophy of every writing step

Every step that writes a real file follows one rule: **if anything goes wrong — bad data, a failed validation, a disk error — it stops and reports the failure instead of saving something broken.** It never writes a half-finished or invalid file and hopes it works.

This is enforced two ways:

- **Atomic writes.** The staged-then-swapped write means a live file is never caught mid-edit.
- **Pre-write validation.** A check runs *before* the write, so malformed data is caught at the gate. The manifest is validated against its schema; both `CLAUDE.md` files are scanned for leftover placeholders.

The **one** deliberate exception is the external-setup recommendations, which by design never block you — they are advice, not a requirement.

"Block-and-log" is the safety principle of a good ATM: if the transaction cannot complete cleanly, it gives you your card back and tells you why, rather than dispensing half the cash and corrupting your balance.

---

## The SessionStart resume reminder

If onboarding has not been completed — no manifest, or the "onboarding finished" flag is not set — the assistant gently reminds you at the start of every session.

A small startup script (`~/.claude/hooks/session-start.sh`) runs when a session begins, reads the manifest, and:

- **If setup is unfinished**, surfaces a one-line banner inviting you to run `/onboard --resume` to pick up where you left off.
- **Once setup completes and the flag flips to true**, the banner disappears silently.

This startup-script-surfaces-a-message mechanism is the `SessionStart` hook event, which can attach extra context to the start of a session; it is documented at `code.claude.com/docs`. The reminder never blocks you from working and never forces the command — it only offers.

This is the "finish setting up your account" nudge a well-designed app shows until you complete onboarding, then stops bothering you forever once you do.

---

## What onboarding does NOT do — memory

Onboarding seeds **no memory.** Your identity lands in `CLAUDE.md`, not in any memory file.

Memory bootstrap is handled by a **separate** startup script — `~/.claude/hooks/memory-seed.sh` — which lazily creates the per-project memory index (`MEMORY.md`) on its own schedule, never overwriting an existing one. Keeping memory setup out of onboarding's scope means each seam can evolve independently, and a re-run of onboarding never touches your accumulated memory.

---

## Why this design — evidence & alternatives

Each load-bearing choice in onboarding has a rejected alternative behind it. The table below records what was *not* done and why — so the design reads as deliberate rather than arbitrary. (Several of these — block-and-log, the two `CLAUDE.md` files, the single-use guard — are explained in full above; here they are summarized only as the *reason* a different shape was passed over.)

| Choice | Rejected alternative | Why it was rejected |
|---|---|---|
| Run-once, guarded three ways — the assistant can't auto-fire it, a sentinel marker makes a re-run a no-op, and an explicit `--force` is required to truly redo | Letting setup re-run freely, or self-deleting after a successful use | A step that writes irreplaceable personal content must never be cheap to repeat by accident; self-deletion mid-run is racy and breaks the resume path. |
| Onboarding renders your global preferences file fresh; a user who skips setup simply has none | Shipping a pre-seeded placeholder preferences file in the install | A file full of unfilled `{{tokens}}` looks broken to a reader and blocks the genuine first-run fill. |
| A self-contained setup skill that owns its producers | A thin entry-point plus a scattered top-level bucket of loose scripts | That layout is the lone outlier among the system's skills, and it breeds brittle relative-path coupling between the entry-point and its helpers. |
| Block-and-log on any malformed write | Write-and-hope | A setup step that writes personal files must fail loudly and leave no half-written state — never silently "succeed" on broken data. |

Read together, the table shows two forces at work. Smart-default pre-fill, single-use with an explicit redo flag, schema-validated atomic writes, no-clobber diffing, and progressive disclosure are the **convergent practice** of mature first-run and setup-wizard UX — arrived at independently because they are simply what a good first-run flow does. The remaining shape is fixed by **constraint**: the human-invoked-only guard rests on the platform's documented `disable-model-invocation` setting, and rendering one global preferences file fresh rests on Claude Code's documented `CLAUDE.md` concatenation behavior. Convergence chose the pattern; the platform's own facts chose the mechanics.

---

## References

These are the installed artifacts that implement and back this document. The skill scripts under `~/.claude/skills/onboarder/` are the **APPLY surface** — what actually runs when you type `/onboard`.

**The skill definition + orchestrator**

- `~/.claude/skills/onboarder/SKILL.md` — the definition of `/onboard`: its description, its argument flags, the muted-auto-fire setting, and its Output Contract.
- `~/.claude/skills/onboarder/onboard.sh` — the orchestrator that chains the six producers in order, enforces the single-use "onboarding finished" guard on a bare invoke, and honors `--force`, `--dry-run`, `--resume`, and the vault/plans/skills path overrides.

**The six producers**

- `~/.claude/skills/onboarder/scripts/section-a-slim.sh` — Section A: the read-only discovery-confirmation card (name, email, timezone, proposed vault location).
- `~/.claude/skills/onboarder/scripts/section-b-slim.sh` — Section B: the free-form interview and the two-pass AI extraction into role/organization plus three preference blocks.
- `~/.claude/skills/onboarder/scripts/bootstrap-user-manifest.sh` — merges the Section-A and Section-B fragments, injects system fields, validates against the schema, and atomically writes the user-manifest.
- `~/.claude/skills/onboarder/scripts/author-claude-home.sh` — the authoritative author of the global `~/.claude/CLAUDE.md`; asserts zero leftover placeholders; no-clobber-without-force.
- `~/.claude/skills/onboarder/scripts/build-brain-vault.sh` — copies the seed into your vault, wires the Plans/Skills/Wiki/Projects/Work links, authors the vault-root `CLAUDE.md`, refuses to scaffold into a non-empty foreign folder without `--force`, and prints the Obsidian-open message.
- `~/.claude/skills/onboarder/scripts/external-setup-gate.sh` — the soft-mandate gate over claude-mem and GitHub; read-only probes, honest recommendations, frictionless skip; never blocks.

**The shared, integrity-protected assets**

- `~/.claude/templates/claude-home-claude-md-template.md` — the template for the global personal-preferences `CLAUDE.md`.
- `~/.claude/templates/vault-claude-md-template.md` — the template for the vault-root `CLAUDE.md` (folder-structure map).
- `~/.claude/schemas/user-manifest-schema.json` — the blueprint the manifest is validated against before it is saved.
- `~/.claude/vault-init/` — the seed folder tree that adopt-by-default copies into your vault (`Vault Writers/` with its `_index.md`).

**The outputs onboarding writes**

- `~/.claude/user-manifest.json` — the single system-of-record file for your identity. Every other part of the system reads identity from here.
- `~/.claude/CLAUDE.md` — your global personal-preferences file, read by the assistant at the start of every session. Yours to edit; never silently overwritten.
- Your **brain vault** — the folder tree plus its own `CLAUDE.md`, at the location you chose.

**The startup hooks**

- `~/.claude/hooks/session-start.sh` — surfaces the `/onboard --resume` banner while onboarding is unfinished; goes silent once it completes. Never blocks.
- `~/.claude/hooks/memory-seed.sh` — the separate hook that lazily creates `MEMORY.md` (no-clobber); confirms memory bootstrap is out of onboarding's scope.

**External documentation**

- Anthropic docs: `code.claude.com/docs` — for the skill / slash-command model, the `disable-model-invocation` setting, `CLAUDE.md` auto-load and combine behavior, HTML-comment stripping, the `SessionStart` hook event, and the plugin-install command form.
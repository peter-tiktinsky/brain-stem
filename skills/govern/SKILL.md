---
name: govern register
description: >
  Canonical /govern register skill family. 6 modes (folder / file-type /
  tag-extension / writer / doc-amender-prompt / project): the 4th class is the
  Class D writer mode; the 5th class is doc-amender-prompt Layer-3 authoring; the
  6th class is project (the ~/work/<spoke> on-ramp). Orchestrates the 6-step propose-and-validate
  protocol per canonical +: CONFIRM INTENT → PROPOSE per-pillar
  rules → USER VALIDATE PER-FIELD (full draft + per-field redline per
  lock) → MUTATE OVERLAY-MASTER + APPEND ACTION-LOG (atomic via
  `hooks/lib/overlay-master-mutate.sh`) → VAULT-ROOT CLAUDE.md tree self-update
  (Class A folder mode only; no `[F]` marker per T-13 v3.1 template).
  Authored under Batch H T-10 (2026-05-19).
disable-model-invocation: true
argument-hint: "--kind <folder|file-type|tag-extension|writer|doc-amender-prompt|project> --target <T> [...]"
---

# /govern register

Skill body for the canonical adopter-side governance-mutation entry point.
Both hook-invocation (via additionalContext from `pre-write-guard.sh` branch
#1 detection Classes A/B/C/D) and direct user invocation share a single
code path. Plans-tree creation is ORTHOGONAL — use `/new-plan` or
`/backlog-research`; never `/govern register`.

## Invocation contracts (per)

```sh
# Class A — new top-level vault folder
/govern register --kind folder --target <vault-relative-path> [--inherit-from <parent-path>]

# Class B/C — new vault-root file or new file-type within existing folder
/govern register --kind file-type --name <type-slug> --contract <path-to-file-type-contract.json>

# Tag-dimension extension (operator-driven; no hook auto-fire)
/govern register --kind tag-extension --dimension <prefix> --values <comma-list>

# Class D — new vault-writer registration (hook auto-fire OR wizard OR direct)
/govern register --kind writer --writer-name <name> --writer-kind <connector|agentic-flow|auto-research|scheduled-skill|custom> [--writer-subtype <s>] [--writer-skill <skill-slug>]

# Class E (5th) — doc-amender prompt-authoring (Layer-3 guided flow; T-04)
/govern register --kind doc-amender-prompt --prompt-id <id> --destination-glob <glob> --merge-intent <table-upsert|decision-log|free-form> [--upstream-writers <csv>] [--goal <text>]
# commit with --with-fan-in to also append the writer-fan-in doc-deps entry.

# Class F (6th) — new ~/work/<spoke> project workspace (b)
# Run from the new project's launch dir (~/work/<spoke>/, EXACTLY one level under ~/work).
/govern register --kind project --layout flat
/govern register --kind project --layout master --first-sub <name>
# Grow later (sub-modes — no new --kind):
/govern register --kind project --under <spoke> --add-sub <name>   # add a sub-project to an existing spoke
/govern register --kind project --adopt                           # promote a sub to a top-level spoke (post operator git mv)
```

### `project` mode (the C1/C5 work-project on-ramp — Class F)

`project` mints a `~/work/<spoke>/` project workspace (surfaced in the vault as
`Work/<spoke>/`). It is structurally distinct from `folder` mode: it patches the
standalone `anchored-spoke-registry.json` (the identity SoT — NOT overlay-mutable;
atomic temp+rename), invokes the project-workspace scaffolder
(`skills/govern/lib/project-workspace/scaffold.sh`), AND emits the vault-view
`path_routing` overlay rule in the `{rules:[...]}` object shape (routed
through `hooks/lib/overlay-master-mutate.sh` with `--kind folder` — a routing-rule
mutation is folder-class). It NEVER appends to the vault-root `CLAUDE.md` tree
(the FIX#3 carve-out — a project's identity lives in its own work `CLAUDE.md`;
cross-plan state lives in the binder hub at `~/.claude-plans/_projects/<spoke>/hub.md`).

**Two create shapes ():**

- `--layout flat` (default) — the flat MVP (CLAUDE.md + README + updates.md +
  `deliverables/` + `reference/`); overlay rule `Work/<spoke>/**`.
- `--layout master --first-sub <name>` — a master top (CLAUDE.md + README +
  updates.md, NO top-level `deliverables/`/`reference/`) plus one
  sub-project (`<name>/{README, deliverables/, reference/}`, NO sub `CLAUDE.md`).
  The master offers the wildcard rule
  `Work/<spoke>/*/{deliverables,reference}/**` (one rule covers all current +
  future subs; survives a 2nd sub via the union leaf). The work `CLAUDE.md`
  carries an auto-maintained directory map (`work-map:start`/`end` sentinels) —
  no `@import`, no plan roster (the binder owns that).

**Identity bound (the #1 recursion control):** a spoke is minted ONLY for a
directory EXACTLY one level under `$WORK_HOME` — `project.sh` rejects any cwd
where `canonical(dirname(cwd)) != canonical($WORK_HOME)` (depth-2 BLOCKS). Only
the MASTER registers a spoke; sub-projects are ORGANIZATIONAL UNITS () with no
spoke, no anchor, no `CLAUDE.md` (— each sub `README` carries a
one-line launch advisory). Re-registering an existing spoke BLOCKS (no dup anchor,
no re-scaffold).

**Grow-later sub-modes:**

- `--under <spoke> --add-sub <name>` — scaffold a sub + emit its overlay rule
  (priors kept via the union leaf). The sub listing is auto-derived from disk by
  the work directory-map generator on the next refresh. On a FLAT
  spoke: WARN + advise manual relocation of existing top-level deliverables
  (— never auto-moved).
- `--adopt` — sub→top-level promotion: the operator `git mv` is EMITTED (not
  executed), then register the depth-1 spoke + scaffold the MISSING-ONLY work
  `CLAUDE.md` + mint the binder hub (existing `README`/`deliverables`/`reference`
  byte-unchanged). Lossless; ZERO content-file mutation.
```

`process.sh` exposes three sub-verbs matching the 6-step protocol's
deliberation/commit/skip arcs:

- `process.sh propose --kind <K> --target <T> [...]` — emit proposal JSON
  to stdout (Claude renders it for the user; user redlines per-field).
- `process.sh commit --kind <K> --proposal <validated.json>` — invoke
  `hooks/lib/overlay-master-mutate.sh` to atomically apply mutations + append
  action-log row.
- `process.sh skip --kind <K> --target <T> [--reason <free-text>]` —
  append a frictionless-skip action-log row (`unregistered: true`,
  `proposed_by: skipped`); no overlay mutation.

## Modes

| Mode | Pillars touched (R-37 atomic) | Vault writes | Action-log `kind` |
|---|---|---|---|
| `folder` | `frontmatter.path_routing` + optional `mandatory_files` | vault-root `CLAUDE.md` Vault Structure tree append (Class A only) | `folder` |
| `file-type` | `frontmatter.types` + `file_type_contracts.<type-slug>` | (none) | `file-type` |
| `tag-extension` | `tagging.taxonomy.dimension_prefixes` | (none) | `tag-extension` |
| `writer` | `vault_writers` (no-op `{}` payload for atomic action-log) | `Vault Writers/<slug>.md` writer-reference file | `writer` |
| `doc-amender-prompt` | (none — outside-vault state-tier asset) | `$VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md` (CREATE-ONLY) + optional `doc-dependencies.json` writer-fan-in entry | `doc-amender-prompt` |
| `project` | `frontmatter.path_routing.rules` (vault-view overlay rule; union shape, committed as `--kind folder`) | `anchored-spoke-registry.json` (standalone direct-patch, atomic temp+rename — master only) + `$WORK_HOME/<spoke>/` scaffold (flat MVP OR master + sub) — NEVER the vault-root `CLAUDE.md` tree | `folder` (overlay rule); registry patch writes NO action-log row |

### doc-amender-prompt Output Contract (the 5th class — Skill Creation Rules)

The Layer-3 mode (`modes/doc-amender-prompt.sh`) is the model-invocable
create-time companion to the `disable-model-invocation:true` runtime
(`skills/doc-amender/process.sh`); they are connected ONLY by the contract
`governance/file-type-contracts/doc-amender-prompt.md.json`.

- **Files written:** (1) the prompt asset at
  `$VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md` — **create-only** (refuses
  to clobber; atomic temp+rename); (2) optional (`--with-fan-in`) a
  `writer-fan-in` entry appended to `doc-dependencies.json :: entries[]`
  (create-only on the entry id).
- **Schema type:** `doc-amender-prompt` (validated against
  `doc-amender-prompt.md.json` BEFORE write — `frontmatter_required` present,
  `frontmatter_enums` honored, `amendment_strategy ↔ persistence_mode`
  consistent with the contract mapping).
- **Failure mode:** **block-and-log** — any validation failure / existing-file
  collision / invalid enum returns non-zero with a diagnostic; nothing is
  written. Never write-and-hope.

The merge-intent interview maps to the contract's `amendment_strategy`
(`table-upsert→template-fill/deterministic`, `decision-log→append-section/hybrid`,
`free-form→prompt-guided-amend/llm-mediated`).

Each mode handler lives at `modes/<kind>.sh` and is sourced by
`process.sh`. Adding a mode = adding a new `modes/<kind>.sh` file + a
case-arm in the dispatcher.

## 6-step protocol mapping

| Step | Where it lives |
|---|---|
| 1. DETECT | `pre-write-guard.sh` branch #1 (Classes A/B/C/D) — UPSTREAM; not part of this skill |
| 2. CONFIRM INTENT | Claude (in conversation) reads hook-supplied `additionalContext` OR user-direct argv, confirms target with operator |
| 3. PROPOSE | `process.sh propose <kind> ...` → `modes/<kind>.sh propose()` — emits draft JSON of per-pillar fields |
| 4. USER VALIDATE PER-FIELD | Claude (in conversation) renders proposal, gathers per-field accept/edit/reject; composes `validated.json` |
| 5. MUTATE + ACTION-LOG | `process.sh commit <kind> <validated.json>` → `modes/<kind>.sh commit()` → `hooks/lib/overlay-master-mutate.sh` (atomic; appends row) |
| 6. VAULT-ROOT CLAUDE.md SELF-UPDATE | `modes/folder.sh` only — appends user-cluster entry to vault-root `CLAUDE.md` Vault Structure tree (no `[F]` marker per) — invoked AFTER step 5 commit succeeds |

Frictionless skip (per `feedback_soft_mandate_pattern`): any step,
operator dismisses → `process.sh skip` records `unregistered: true`;
librarian governance-parity-audit surfaces as drift finding.

## Proposal shape (stdout from `process.sh propose`)

All modes emit a single JSON object on stdout:

```jsonc
{
  "kind": "folder | file-type | tag-extension | writer",
  "target": "<path or name>",
  "proposed_by": "claude-skill-invocation | hook-class-a/b/c/d | user-direct",
  "pillars": [
    {
      "pillar": "<top-level pillar slot name>",
      "payload": { /* deep-merge payload — see mode docs */ },
      "field_descriptions": {
        "<field-key>": "human-readable rationale for this field"
      },
      "collisions": [
        {"field": "<field-path>", "foundation_value": "...", "proposed_value": "...", "requires_override_reason": true}
      ]
    }
  ],
  "notes": [ /* freeform strings for user context */ ]
}
```

Claude renders this proposal to the operator, gathers per-field
edits/rejects, and composes a `validated.json` of the SAME shape with:
- Accepted pillar payloads carried through verbatim
- Rejected fields removed from `payload` + listed under top-level
  `rejected_fields: {pillar: {field: reason}}`
- Override reasons captured per-entry as `_override_reason: "<text>"`
  fields inline on each shadowing payload entry (canonical
  shape; per T-5, 2026-05-21). The retired
  top-level `override_reasons.<pillar>.<field>` dict pathway is no
  longer accepted by the hook-side R-52 check.

The validated.json is then passed to `process.sh commit`.

## Per-mode proposal payloads

### `folder` mode

```jsonc
{
  "kind": "folder",
  "target": "Engagements",
  "pillars": [
    {
      "pillar": "frontmatter",
      "payload": {
        "path_routing": [
          {"pattern": "Engagements/**", "type": "engagement-note", "auto_create": true}
        ]
      }
    },
    {
      "pillar": "mandatory_files",
      "payload": {
        "by_folder": {
          "Engagements/**": ["_index.md"]
        }
      }
    }
  ]
}
```

R-37 atomic: both pillars apply in a single `hooks/lib/overlay-master-mutate.sh`
invocation (two `--pillar/--payload-file` pairs).

### `file-type` mode

```jsonc
{
  "kind": "file-type",
  "target": "engagement-note",
  "pillars": [
    {
      "pillar": "frontmatter",
      "payload": {
        "types": ["engagement-note"]
      }
    },
    {
      "pillar": "file_type_contracts",
      "payload": {
        "engagement-note": {
          "$schema": "schemas/file-type-contract-schema.json",
          "type": "engagement-note",
          "frontmatter": { "required": ["type", "tags", "created", "updated"], "enums": {"type": ["engagement-note"]} },
          "body": { "free_form": true }
        }
      }
    }
  ]
}
```

R-37 atomic across the two pillars.

### `tag-extension` mode

```jsonc
{
  "kind": "tag-extension",
  "target": "delivery",
  "pillars": [
    {
      "pillar": "tagging",
      "payload": {
        "taxonomy": {
          "dimension_prefixes": {
            "delivery": ["spec", "build", "ship", "retro"]
          }
        }
      }
    }
  ]
}
```

Single-pillar mutation.

### `writer` mode

Writer mode is structurally distinct — the canonical declaration is a
markdown file at `Vault Writers/<slug>.md` (writer-reference file per
), not an overlay-master entry. The library is still
invoked (with a no-op `{}` vault_writers payload) so the action-log row
appends atomically under the same lockf serialization the other modes
use.

```jsonc
{
  "kind": "writer",
  "target": "granola-meetings",
  "pillars": [
    {
      "pillar": "vault_writers",
      "payload": {}
    }
  ],
  "writer_reference": {
    "destination": "<vault-root>/Vault Writers/granola-meetings.md",
    "frontmatter": {
      "type": "vault-writer",
      "writer_name": "granola-meetings",
      "writer_kind": "connector",
      "writer_subtype": "granola",
      "writer_skill": "meeting-note-ingestor-granola",
      "destinations": [
        {"path": "Meetings/{{date}} - {{title}}.md", "output_type": "markdown", "posture": "direct"}
      ],
      "status": "active",
      "source": "granola-workspace-id",
      "schedule": "manual",
      "created": "<ISO>",
      "updated": "<ISO>",
      "tags": ["#scope/writer", "#status/active"]
    },
    "body_template": "_generic-writer.md.template"
  }
}
```

The writer-reference file write goes through the standard write path
(tempfile + mv); `pre-write-guard.sh` branch #3 validates the resulting
frontmatter against `governance/file-type-contracts/vault-writer.md.json`
on write — schema-violation surfaces as DENY at hook time (the skill
trusts pre-write enforcement and does NOT re-validate downstream).

## Coordination locks

- **Hook entry (Class A/B/C):** `pre-write-guard.sh` branch #1 surfaces
  `additionalContext` proposing `/govern register --kind <X> --target <Y>`.
  Action-log `proposed_by` records `hook-class-a/b/c`.
- **Hook entry (Class D):** `pre-write-guard.sh` branch #1 (integrated
  into existing SKILL CHANGE PROTOCOL block) surfaces propose-and-validate
  on a vault-writing SKILL.md edit with no matching writer-reference.
  Action-log `proposed_by: hook-class-d`.
- **wizard entry:** Beat 5 emits writer-reference files via
  the SAME 4-mode skill body. Action-log `proposed_by: sp07-wizard`.
- **Direct invocation:** Operator runs `/govern register --kind <X>`
  outside any hook trigger. Action-log `proposed_by: user-direct`.

## Output Contract

**Files written (by mode):**

| Mode | Files written | Schema validated against |
|---|---|---|
| `folder` | `~/.claude/governance/overlay-master.json` (atomic via library) + `$VAULT_WRITER_STATE_ROOT/governance-action-log.jsonl` (append) + `<vault-root>/CLAUDE.md` (Class A tree append; no `[F]` marker) | `schemas/overlay-master-schema.json` + `schemas/governance-action-log-schema.json` |
| `file-type` | overlay-master.json + governance-action-log.jsonl | same as folder mode |
| `tag-extension` | overlay-master.json + governance-action-log.jsonl | same as folder mode |
| `writer` | `<vault-root>/Vault Writers/<slug>.md` (writer-reference file; standard atomic write through pre-write-guard.sh + post-write-verify.sh) + overlay-master.json no-op + governance-action-log.jsonl | `governance/file-type-contracts/vault-writer.md.json` (enforced at pre-write-guard.sh branch #3 downstream) + governance-action-log-schema.json |

**Skip-path file writes (all modes):** one row to
`$VAULT_WRITER_STATE_ROOT/governance-action-log.jsonl` with `unregistered: true`,
`proposed_by: skipped`, `target: <T>`. No overlay-master mutation. No vault
writes. Original triggering write proceeds (frictionless skip per
`feedback_soft_mandate_pattern`).

**Pre-write validation:**
- `process.sh commit` REQUIRES `--proposal <validated.json>` with the
  shape documented above; rejects (rc=2) if missing or malformed.
- Mode handlers compose pillar payloads from the proposal and write each
  to a tempfile under `$TMPDIR`; payloads are validated as parseable JSON
  before invoking the library.
- `hooks/lib/overlay-master-mutate.sh` performs (a) jsonschema Draft 2020-12
  validation against `schemas/overlay-master-schema.json` on the
  composed tempfile, (b) `lockf -k -t 0` serialization under
  `~/.claude/governance/.overlay-master.lock`, (c) atomic rename, and
  (d) action-log row append — all under the same lock.
- Writer mode additionally relies on `pre-write-guard.sh` branch #3 to
  validate the writer-reference frontmatter against
  `governance/file-type-contracts/vault-writer.md.json` at write time.
  Schema violation surfaces as DENY at hook time.
- R-37 multi-pillar bundling: file-type and folder modes invoke the
  library with two `--pillar/--payload-file` pairs in a single call;
  either both apply or neither does.
- R-52 collision tiebreaker: `process.sh propose` flags collisions
  against `~/.claude/governance/foundation-master.json` in the proposal
  output; commit phase rejects (rc=4) any shadowing payload entry that
  lacks an inline `_override_reason: "<text>"` field (canonical
  shape; per-entry only since T-5).

**Failure mode:** block-and-log per `feedback_no_skill_code_generation`
(failure-mode discipline) + `feedback_structural_over_bandaid`:

- Library `rc=2` (bad argv) / `rc=3` (pre-flight failure) / `rc=4`
  (schema validation failure) / `rc=5` (lock contention) / `rc=6`
  (atomic rename or action-log append failure) — surfaced verbatim by
  `process.sh commit`. No silent fallback. No retry loop.
- Writer-reference write failure (pre-write-guard.sh DENY) — surfaced
  by the standard write path; the skill does NOT retry; the operator
  must address the schema violation and re-invoke.
- Vault-root CLAUDE.md self-update failure (folder mode Class A step
  6) — emitted as a sidecar `_claude-md-tree-update-failed.json` next to
  vault-root CLAUDE.md; the overlay mutation (step 5) is NOT rolled
  back (canonical; survives). Librarian governance-parity-audit
  surfaces `vault-claude-md-tree-drift` finding for operator triage.

## Constraints

- All overlay-master mutations flow through `hooks/lib/overlay-master-mutate.sh`
  per `feedback_no_skill_code_generation` (single mutation library;
  schema-drift prevention). No mode handler writes `overlay-master.json`
  or `governance-action-log.jsonl` directly. No mode handler hand-composes
  action-log row JSON.
- Bash 3.2 compatible per existing skill substrate (no `declare -A`, no
  `mapfile`, no `${var,,}`).
- Foundation-repo-only authoring per `feedback_no_live_edits_during_foundation_repo_build`.
  Live `~/.claude/` install scaffolding ships via.
- Plans-tree governance is ORTHOGONAL — `/govern register` declines
  `--kind plan` (use `/new-plan` or `/backlog-research`).

## See also

- `hooks/lib/overlay-master-mutate.sh` (atomic mutation library — Batch B T-8; relocated to hooks/lib/ per)
- `schemas/overlay-master-schema.json` (overlay pillar structure — Batch A)
- `schemas/governance-action-log-schema.json` (action-log row shape — Batch A)
- `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract — T-12)
- Foundation governance semantic-extension-flow reference (lock chain — + Class D)
- Foundation governance target-state doc / / / (6-step protocol canonical)

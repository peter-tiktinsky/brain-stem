---
name: govern register
description: >
  Canonical /govern register skill family. 5 modes (folder / file-type /
  tag-extension / writer / doc-amender-prompt; the 5th class is
  doc-amender-prompt Layer-3 authoring). Orchestrates the 6-step propose-and-validate
  protocol: CONFIRM INTENT → PROPOSE per-pillar
  rules → USER VALIDATE PER-FIELD (full draft + per-field redline) →
  MUTATE OVERLAY-MASTER + APPEND ACTION-LOG (atomic via
  `hooks/lib/overlay-master-mutate.sh`) → VAULT-ROOT CLAUDE.md tree self-update
  (Class A folder mode only; no `[F]` marker).
disable-model-invocation: true
argument-hint: "--kind <folder|file-type|tag-extension|writer|doc-amender-prompt> --target <T> [...]"
---

# /govern register

Skill body for the canonical adopter-side governance-mutation entry point.
Both hook-invocation (via additionalContext from `pre-write-guard.sh` branch
#1 detection Classes A/B/C/D) and direct user invocation share a single
code path. Plans-tree creation is ORTHOGONAL — use `/new-plan` or
`/backlog-research`; never `/govern register`.

## Invocation contracts

```sh
# Class A — new top-level vault folder
/govern register --kind folder --target <vault-relative-path> [--inherit-from <parent-path>]

# Class B/C — new vault-root file or new file-type within existing folder
/govern register --kind file-type --name <type-slug> --contract <path-to-file-type-contract.json>

# Tag-dimension extension (operator-driven; no hook auto-fire)
/govern register --kind tag-extension --dimension <prefix> --values <comma-list>

# Class D — new vault-writer registration (hook auto-fire OR onboarding wizard OR direct)
/govern register --kind writer --writer-name <name> --writer-kind <connector|agentic-flow|auto-research|scheduled-skill|custom> [--writer-subtype <s>] [--writer-skill <skill-slug>]

# Class E (5th) — doc-amender prompt-authoring (Layer-3 guided flow)
/govern register --kind doc-amender-prompt --prompt-id <id> --destination-glob <glob> --merge-intent <table-upsert|decision-log|free-form> [--upstream-writers <csv>] [--goal <text>]
# commit with --with-fan-in to also append the writer-fan-in doc-deps entry.
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
| 6. VAULT-ROOT CLAUDE.md SELF-UPDATE | `modes/folder.sh` only — appends user-cluster entry to vault-root `CLAUDE.md` Vault Structure tree (no `[F]` marker) — invoked AFTER step 5 commit succeeds |

Frictionless skip: any step,
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
  shape). The retired
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
markdown file at `Vault Writers/<slug>.md` (writer-reference file),
not an overlay-master entry. The library is still
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
- **Onboarding wizard entry:** the onboarding wizard emits writer-reference
  files via the SAME 4-mode skill body.
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
writes. Original triggering write proceeds (frictionless skip).

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
  shape; per-entry only).

**Failure mode:** block-and-log (failure-mode discipline; structural
enforcement over band-aid):

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
  (single mutation library; schema-drift prevention). No mode handler writes
  `overlay-master.json` or `governance-action-log.jsonl` directly. No mode
  handler hand-composes action-log row JSON.
- Bash 3.2 compatible per existing skill substrate (no `declare -A`, no
  `mapfile`, no `${var,,}`).
- Plans-tree governance is ORTHOGONAL — `/govern register` declines
  `--kind plan` (use `/new-plan` or `/backlog-research`).

## See also

- `hooks/lib/overlay-master-mutate.sh` (atomic mutation library)
- `schemas/overlay-master-schema.json` (overlay pillar structure)
- `schemas/governance-action-log-schema.json` (action-log row shape)
- `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract)
- Foundation governance semantic-extension-flow reference (lock chain; Class D)
- Foundation governance target-state doc (6-step protocol)

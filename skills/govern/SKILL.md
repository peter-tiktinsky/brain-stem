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

## Invocation contracts

```sh
# Class A — new top-level vault folder
/govern register --kind folder --target <vault-relative-path> [--inherit-from <parent-path>]

# Class B/C — new vault-root file or new file-type within existing folder
/govern register --kind file-type --name <type-slug> --contract <path-to-file-type-contract.json>

# Tag-dimension extension (operator-driven; no hook auto-fire)
/govern register --kind tag-extension --dimension <prefix>

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
/govern register --kind project --under <spoke> --add-sub <name>              # add a sub-project to an existing spoke
/govern register --kind project --under <spoke> --add-folder <name> [--role <slug>]  # add a plain non-sub folder (routing rule, no registry write)
/govern register --kind project --adopt                           # promote a sub to a top-level spoke (post operator git mv)
/govern register --kind project --under <spoke> --retract-sub <sub>  # retract a moved-out sub's leftover routing rule
/govern register --kind project --under <spoke> --emit-moves <mapping.json>  # print the git mv commands for a mapping you name (moves nothing)
/govern register --kind project --anchor <dir> [--spoke-key <key>]  # register a launch directory outside ~/work (registry entry + identity CLAUDE.md + binder home)
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
cross-plan state lives in the machine-derived binder at `~/.claude-plans/_projects/<spoke>/`).

**Two create shapes:**

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
the MASTER registers a spoke; sub-projects are ORGANIZATIONAL UNITS with no
spoke, no anchor, no `CLAUDE.md` (— each sub `README` carries a
one-line launch advisory). Re-registering an existing spoke BLOCKS (no dup anchor,
no re-scaffold).

**Grow-later sub-modes:**

- `--under <spoke> --add-sub <name>` — scaffold a sub + emit its overlay rule
  (priors kept via the union leaf). The sub listing is auto-derived from disk by
  the work directory-map generator on the next refresh. On a FLAT
  spoke: WARN + advise manual relocation of existing top-level deliverables
  (— never auto-moved).
- `--under <spoke> --add-folder <name> [--role <slug>]` — mint a PLAIN top-level
  folder `Work/<spoke>/<name>` that is NOT a sub-project: no `deliverables/` or
  `reference/`, no `README`, no `CLAUDE.md`, and NO `anchored-spoke-registry.json`
  entry (a non-sub folder is an organizational unit, not a spoke). Emits its
  routing rule `Work/<spoke>/<name>/**` by default (via the union leaf, like
  `--add-sub`); the routing type-slug defaults to the folder-name slug, or the
  `--role <slug>` label when given. Re-derives the master work-map so the folder
  appears under "Other top-level folders (not sub-projects):", NOT as a
  sub-project. Re-running on an existing folder BLOCKS (non-destructive).
- `--adopt` — sub→top-level promotion: the operator `git mv` is EMITTED (not
  executed), then register the depth-1 spoke + scaffold the MISSING-ONLY work
  `CLAUDE.md` + establish the binder home (existing `README`/`deliverables`/`reference`
  byte-unchanged). Lossless; ZERO content-file mutation.
- `--under <spoke> --retract-sub <sub>` — retract the per-sub routing rule
  `Work/<spoke>/<sub>/**` a sub leaves behind once it has been promoted with
  `--adopt`. The rule is removed by exact string through
  `overlay-master-mutate.sh --retract-rule` (same lock, schema check and atomic
  rename; one action-log row). The commit BLOCKS while `Work/<spoke>/<sub>` still
  exists under the spoke: move it out first, nothing is retracted. The master's
  wildcard rule `Work/<spoke>/*/{deliverables,reference}/**` is never retracted by a
  sub name, and a re-run once the rule is gone changes nothing.
- `--under <spoke> --emit-moves <mapping.json>` — print the commands that move a flat
  spoke's content into its sub-projects. The mapping is a file you write,
  `{"moves": [{"from": "<path>", "to": "<path>"}, ...]}`, with paths relative to
  `~/work/<spoke>`. `propose` validates the whole mapping before it prints anything and
  emits the `moves` and the `commands`: one `mkdir -p --` per missing target parent, then
  one `git -C <spoke dir> mv --` per move, every path shell-quoted. `commit` validates
  again against the disk, prints exactly those lines on stdout and nothing else, and
  prints a one-line summary on stderr. It writes nothing, runs no `git` and appends no
  action-log row: the moves stay with you, and you run the printed lines. A target must
  sit inside an existing sub-project directory (never `deliverables` or `reference`) and
  must not exist, and no two moves may share a target or overlap a source. Validation
  stops at the first failure and prints that one line.
- `--anchor <dir> [--spoke-key <key>]` — register a launch directory OUTSIDE `~/work`
  (a code repository, a bounded `~/system` directory) as a spoke: one registry entry,
  a one-line identity `CLAUDE.md` in the directory and the binder home. No scaffold and
  no overlay rule, and no depth guard. The key is `--spoke-key`, else the directory's
  name lowercased with every run of other characters turned into one hyphen. `propose`
  refuses a missing directory, the home directory, `~/work` itself or anything inside
  it, a key that is invalid (lowercase letters, digits and hyphens; `home` is reserved)
  or taken, an anchor another spoke already holds, and any other sub-mode flag given
  with it. `commit` stages the identity file, adds the registry entry under a lock,
  places the file (an existing `CLAUDE.md` is kept as is), then makes the binder home;
  each step is safe to repeat, so a stopped commit is finished by running the same
  commit again. A session launched in the directory, or below it, resolves to the
  spoke; a nested directory registered later wins for its own subtree.
```

`process.sh` exposes four sub-verbs matching the 6-step protocol's
deliberation/compose/commit/skip arcs:

- `process.sh propose --kind <K> --target <T> [...]` — emit proposal JSON
  to stdout (Claude renders it for the user; user redlines per-field).
- `process.sh assemble <kind> --proposal <proposal.json> --rulings <rulings.json> [--out <validated.json>]` —
  compose `validated.json` from the proposal and the operator's per-field
  rulings (see "Rulings file and `process.sh assemble`" below); `--out` writes
  the file atomically, otherwise it prints to stdout.
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
| `doc-amender-prompt` | (none — outside-vault state-tier asset) | `$VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md` (CREATE-ONLY) + optional writer-fan-in entry in the overlay master's `doc_dependencies.entries[]` | `doc-amender-prompt` |
| `project` | `frontmatter.path_routing.rules` (vault-view overlay rule; union shape, committed as `--kind folder`) | `anchored-spoke-registry.json` (standalone direct-patch, atomic temp+rename — master only) + `$WORK_HOME/<spoke>/` scaffold (flat MVP OR master + sub) — NEVER the vault-root `CLAUDE.md` tree. `--add-folder` mints a plain non-sub folder + routing rule ONLY (NO registry write, NO `CLAUDE.md` tree append) | `folder` (overlay rule); registry patch writes NO action-log row |

### doc-amender-prompt Output Contract (the 5th class — Skill Creation Rules)

The Layer-3 mode (`modes/doc-amender-prompt.sh`) is the model-invocable
create-time companion to the `disable-model-invocation:true` runtime
(`skills/doc-amender/process.sh`); they are connected ONLY by the contract
`governance/file-type-contracts/doc-amender-prompt.md.json`.

- **Files written:** (1) the prompt asset at
  `$VAULT_WRITER_STATE_ROOT/prompts/<prompt_id>.md` — **create-only** (refuses
  to clobber; atomic temp+rename); (2) optional (`--with-fan-in`) a
  `writer-fan-in` entry appended to the overlay master's
  `doc_dependencies.entries[]` via `hooks/lib/overlay-master-mutate.sh`
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
| 4. USER VALIDATE PER-FIELD | Claude (in conversation) renders proposal, gathers per-field accept/edit/reject into a rulings file; `process.sh assemble <kind> --proposal <proposal.json> --rulings <rulings.json> --out <validated.json>` writes `validated.json` |
| 5. MUTATE + ACTION-LOG | `process.sh commit <kind> <validated.json>` → `modes/<kind>.sh commit()` → `hooks/lib/overlay-master-mutate.sh` (atomic; appends row) |
| 6. VAULT-ROOT CLAUDE.md SELF-UPDATE | `modes/folder.sh` only — appends user-cluster entry to vault-root `CLAUDE.md` Vault Structure tree (no `[F]` marker per) — invoked AFTER step 5 commit succeeds |

Frictionless skip (a soft mandate — strong recommendation, never a block): any step,
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
      }
    }
  ],
  "notes": [ /* freeform strings for user context */ ]
}
```

Claude renders this proposal to the operator, gathers per-field
edits/rejects into a rulings file, and `process.sh assemble` composes a `validated.json` of the SAME shape with:
- Accepted pillar payloads carried through verbatim
- Rejected fields removed from `payload` + listed under top-level
  `rejected_fields: {pillar: {field: reason}}`
- Override reasons captured per-entry as `_override_reason: "<text>"`
  fields inline on each shadowing payload entry (canonical
  shape; per T-5, 2026-05-21). The retired
  top-level `override_reasons.<pillar>.<field>` dict pathway is no
  longer accepted by the hook-side R-52 check.

The validated.json is then passed to `process.sh commit`.

### Rulings file and `process.sh assemble`

Step 4 ends in a rulings file, never a hand-written `validated.json`. The file is
`{"rulings": [...]}` (an empty list is valid); each ruling is one of:

```jsonc
{"target": "<target>", "verdict": "accept"}
{"target": "<target>", "verdict": "edit", "value": /* any JSON, null included */}
{"target": "<target>", "verdict": "reject", "reason": "<why>"}
```

A ruling carries no key its verdict does not name. A target is one of
`writer_reference.frontmatter.<field>`, `prompt_asset.frontmatter.<field>`,
`fan_in.<field>` (`consumer`, `upstream_writers`, `amendment_strategy`), the exact
target `prompt_asset.body`, or `<pillar>.<field>` (a key of that pillar's
`payload`). Nothing else is rulable: `target`, `kind`, `proposed_by`, `notes`,
`field_descriptions`, `writer_reference.destination` and `prompt_asset.prompt_id`
are proposal identity, so a different destination or id is a new `propose` run
with another `--target` or `--prompt-id`.

```bash
process.sh assemble <kind> --proposal <proposal.json> --rulings <rulings.json> [--out <validated.json>]
```

The kind is positional or `--kind <kind>`; a `project` proposal is committed as
proposed and has no per-field rulings. A field with no ruling is accepted as
proposed. The result is the proposal with each edit set at its target and each
rejected field removed (a pillar a reject emptied is dropped), plus a top-level
`rejected_fields` object appended last (`{"<scope>": {"<field>": "<reason>"}}`;
present only when a reject exists). Every other key keeps its place. Editing
`prompt_asset.frontmatter.amendment_strategy` also sets the `fan_in` copy that
`commit --with-fan-in` reads, unless `fan_in.amendment_strategy` has its own
ruling. An override reason rides inside an edit's `value` as an inline
`_override_reason`; assemble never writes one.

Without `--out` the validated JSON goes to stdout. With `--out` it is written to a
temp file beside the target and renamed into place, and the command prints
`govern-assemble: wrote <out>`.

Every refusal is exit 2: one stderr line that begins `govern-assemble: refused:`,
nothing written (an existing `--out` file stays byte-identical and no temp file
survives, a signal included). Beyond the argument and file checks, the checks run
in this order and the first failure speaks: the rulings shape, each ruling in turn
(verdict, keys, `value` or `reason`, target, a target ruled twice), then
`unresolved placeholder at <target>` (a rulable string leaf that is still a whole
`<...>` placeholder after the rulings apply: edit or reject it) and
`no pillar would remain`. A missing `jq` is exit 3 and a failed rename is exit 6
with `govern-assemble: write failed: <out>`.

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
          "dimension_prefixes": ["delivery"]
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
writes. Original triggering write proceeds (frictionless skip — a soft
mandate is a strong recommendation, never a block).

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
- Override reasons: a payload entry that shadows a foundation entry carries an
  inline `_override_reason: "<text>"` field (per-entry shape). The write-time
  hook reads that field when an overlay file is written through an editor tool;
  `process.sh propose`, `process.sh commit` and the mutation library do not
  check it.

**Failure mode:** block-and-log — a skill never generates its own mutation
code, and a structural layer beats a remembered reminder:

- Library `rc=2` (bad argv) / `rc=3` (pre-flight failure) / `rc=4`
  (schema validation failure) / `rc=5` (lock contention) / `rc=6`
  (atomic rename or action-log append failure) — surfaced verbatim by
  `process.sh commit`. No silent fallback. No retry loop.
- Writer-reference write failure (pre-write-guard.sh DENY) — surfaced
  by the standard write path; the skill does NOT retry; the operator
  must address the schema violation and re-invoke.
- Vault-root CLAUDE.md self-update failure, or the missing-CLAUDE.md
  deferral (folder mode Class A step 6) — surfaced as a plain stderr
  advisory naming the target and the missing/failed vault-root CLAUDE.md;
  the overlay mutation (step 5) is NOT rolled back (canonical; survives).
  No sidecar is written and no drift finding is emitted — a recovery net
  no code delivers would be a fiction.

## Constraints

- All overlay-master mutations flow through `hooks/lib/overlay-master-mutate.sh`
  rather than skill-generated code (single mutation library;
  schema-drift prevention). No mode handler writes `overlay-master.json`
  or `governance-action-log.jsonl` directly. No mode handler hand-composes
  action-log row JSON.
- Bash 3.2 compatible per existing skill substrate (no `declare -A`, no
  `mapfile`, no `${var,,}`).
- Foundation-repo-only authoring — never a live-install hand-edit.
  Live `~/.claude/` install scaffolding ships via.
- Plans-tree governance is ORTHOGONAL — `/govern register` declines
  `--kind plan` (use `/new-plan` or `/backlog-research`).

## See also

- `hooks/lib/overlay-master-mutate.sh` (atomic mutation library — Batch B T-8; relocated to hooks/lib/ per)
- `schemas/overlay-master-schema.json` (overlay pillar structure — Batch A)
- `schemas/governance-action-log-schema.json` (action-log row shape — Batch A)
- `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract — T-12)
- The 6-step protocol mapping above is canonical

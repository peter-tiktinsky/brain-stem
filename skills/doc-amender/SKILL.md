---
name: doc-amender
description: >
  Event-driven amendment runner for prompt-guided edits to fan-in
  destinations. Reads amender-eligible packets from the canonical ephemeral
  staging root ($CLAUDE_STATE_ROOT/vault-staging); for persistence.mode
  llm-mediated/hybrid runs the operator-authored prompt asset (per
  governance/file-type-contracts/doc-amender-prompt.md.json) through
  `claude -p`, for persistence.mode deterministic dispatches to
  compose-deterministic.sh (no claude -p); emits a REPLACEMENT packet via
  hooks/lib/staging-emit.sh with packet_kind=amender-replacement. NEVER writes
  destination directly (R-34 boundary preserved via round-trip through staging).
  Triggered by launchd WatchPaths on staging root (NOT cron). The operator
  authors prompt assets via the Layer-3 guided flow (/govern register --kind
  doc-amender-prompt). The runtime is paired with a Layer-3
  authoring companion, the persistence.mode contract extension, and the
  deterministic composer.
disable-model-invocation: true
argument-hint: "[--staging-root PATH] [--prompt-root PATH] [--dry-run] [--once]"
---

# Doc Amender

Event-driven LLM-amendment runner for the Bucket-1(b) prompt-guided edit lane
of the vault writer pipeline (Posture D — per-destination contract-driven
hybrid). Doc-amender sits BETWEEN `hooks/lib/staging-emit.sh` and
`skills/writer-reconciler/` in the writer-pipeline layering: it reads
amender-eligible packets from staging, runs an operator-authored prompt asset
through `claude -p` (or the deterministic composer for
`persistence.mode=deterministic`), and emits a REPLACEMENT packet back to
staging via `hooks/lib/staging-emit.sh --packet-kind amender-replacement`. The writer-reconciler
(WatchPaths-primary + relaxed hourly StartInterval backstop) then writes
the destination mechanically per R-34.

Doc-amender is **NOT** a cron skill. It is triggered by launchd `WatchPaths`
on the staging root — every new packet that lands fires one process per event.
Self-exclusion is critical: doc-amender's own emissions land in the same
staging root and would re-fire the WatchPaths trigger. `process.sh` filters by
`packet_kind ∈ {writer-emit, null}` (v1.0 back-compat) and explicitly excludes
`packet_kind ∈ {amender-replacement, amender-conflict}` to prevent an infinite
self-loop. Concurrent fires are coalesced (or blocked) via a global lockf on
`$STAGING_ROOT/.doc-amender.lock`.

Doc-amender is **NOT** a destination writer. R-34 is preserved structurally:
all output round-trips through `hooks/lib/staging-emit.sh`, and the writer-reconciler
owns the actual destination write on its WatchPaths-hybrid trigger (WatchPaths
primary + relaxed hourly StartInterval backstop).

## Pipeline

```
writer  ─emit─►  staging packet (packet_kind=writer-emit)
                       │
                       │  (launchd WatchPaths fire on packet-land)
                       ▼
                  doc-amender
                    1. eligibility filter (writer-fan-in + prompt-guided-amend)
                    2. prompt resolution ($VAULT_WRITER_STATE_ROOT/prompts/*.md)
                    3. survivorship 3-signal check
                    4. claude -p invocation (substituted prompt + 6-var context)
                       │
                       ▼
              hooks/lib/staging-emit.sh --packet-kind amender-replacement
                       │
                       │  (writer-reconciler WatchPaths fire + StartInterval backstop)
                       ▼
              writer-reconciler  ─writes─►  destination
                                              (mechanical-only per R-34)
```

## Invocation

```sh
# WatchPaths fire (launchd; bootstrapped by install-watch.sh)
./process.sh

# Explicit single-scan + exit (default behavior; same as cron one-shot)
./process.sh --once

# Dry-run — see eligibility plan + would-be claude -p invocations; write nothing
./process.sh --dry-run

# Install the launchd WatchPaths agent (renders the doc-amender plist)
./install-watch.sh

# Preview the rendered plist without bootstrapping
./install-watch.sh --dry-run
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--staging-root <path>` | `$CLAUDE_STATE_ROOT/vault-staging` (or `$STAGING_ROOT` env) | Root of the staging area; per-writer subdirs enumerated under it. |
| `--prompt-root <path>` | `$VAULT_WRITER_STATE_ROOT/prompts/` | Prompt asset directory (per `doc-amender-prompt.md.json :: applies_to.path_glob`). |
| `--dry-run` | off | Emit eligibility + prompt-resolution plan on stdout; skip LLM calls and staging-emit. |
| `--once` | off | Single scan + exit (default behavior — WatchPaths fires the process per event). |
| `--audit-log <path>` | `$CLAUDE_LOG_DIR/doc-amender-audit.log` | Append-only JSONL audit log (one row per amendment attempt). |

## Eligibility filter

Per WatchPaths fire OR explicit `--once` invocation, doc-amender decides which
packets to amend via the **writer-fan-in join surface**:

1. Read `governance/doc-dependencies.json`; filter `entries[]` to
   `kind == "writer-fan-in"` AND `amendment_strategy == "prompt-guided-amend"`.
2. Enumerate packets under `$STAGING_ROOT/<writer-id>/*.json`.
3. For each packet: parse JSON; **self-exclusion filter** —
   `packet_kind ∈ {writer-emit, null}` (drop `amender-replacement` and
   `amender-conflict` to prevent infinite self-loop on WatchPaths re-fire).
4. **Eligibility join** — packet is eligible iff some `writer-fan-in` entry
   satisfies: `packet.writer_id ∈ entry.upstream_writers[]` AND
   `packet.destination_path` matches `entry.consumer` glob.

## Prompt resolution

For each eligible packet:

- Default prompt asset root: `$VAULT_WRITER_STATE_ROOT/prompts/`
  (per `doc-amender-prompt.md.json :: applies_to.path_glob`).
- Override via `--prompt-root PATH` flag.
- **Match algorithm:** enumerate prompts in root; parse frontmatter; filter to
  entries whose `destination_glob` matches the packet's `destination_path` AND
  whose `amendment_strategy == "prompt-guided-amend"`.
  - **Exactly one match** → use it.
  - **Zero matches** → skip + audit-log `prompt-not-found`; no error (operator
    may not have authored a prompt for this destination yet).
  - **Multiple matches** → emit `_amender-conflict.json` sidecar listing
    candidates; operator triages via `/amend-accept` (deferred skill).
- **Variable substitution** per `doc-amender-prompt.md.json :: variable_namespace`
  6 entries: `packet_body`, `destination_current_content`, `destination_path`,
  `upstream_writers`, `writer_metadata`, `amendment_history`.

## Survivorship (3-signal)

The contract's `survivorship_policy_detail` declares 3 signals. Doc-amender
checks them in this order BEFORE invoking `claude -p`:

1. **`amender-paused-frontmatter`** (cheapest check) — read destination
   frontmatter `amender_paused`. If `true` → permanently skip until operator
   removes the flag. Audit `survivorship-skip / paused`.
2. **`operator-edit-wins`** — read destination frontmatter `last_user_edit`
   timestamp AND content-diff against the most-recent active manifest row's
   `content_sha256` (per `hooks/lib/manifest-record.sh query-destination-history
   --destination-path <path>`). If operator edit detected →
   skip LLM call; emit `_amender-conflict.json` sidecar next to the packet
   in staging. Audit `survivorship-skip / operator-edit`.
3. **`amender-conflict-sidecar`** — terminal signal: when signal 2 fires,
   write `<staging-packet-path>.amender-conflict.json` recording the conflict
   payload. Operator triages via `/amend-accept <sidecar>` (deferred skill).

If all 3 signals pass → invoke `claude -p` with substituted prompt + 6-variable
context; capture stdout as new body; emit replacement packet via staging-emit.

## Output Contract

**Files written:**
- **Replacement packet** at `$STAGING_ROOT/<original-writer-id>+amender/<new-sha>.json`
  via `hooks/lib/staging-emit.sh --packet-kind amender-replacement`. The reconciler
  picks it up on its WatchPaths-hybrid trigger (WatchPaths primary + relaxed
  hourly StartInterval backstop) and writes the destination mechanically.
- **Conflict sidecar** at `<original-packet-path>.amender-conflict.json` when
  survivorship signal 2 fires OR when prompt-resolution returns multiple
  matches. Free-form JSON; operator triages.
- **Audit log** at `$CLAUDE_LOG_DIR/doc-amender-audit.log` (append-only JSONL).
  One row per amendment attempt — including skip / conflict / success /
  failure outcomes.

**Schemas:**
- Replacement packet conforms to packet v1.1 shape — validated by
  `hooks/lib/staging-emit.sh` upstream (the v1.1 shape carries the `packet_kind`
  + `source_id` fields).
- Conflict sidecar is free-form JSON-object; minimum fields:
  `ts`, `reason`, `original_packet`, `destination_path`, `candidates` (when
  applicable). Documented inline in `process.sh`.
- Audit log row is JSONL — keys: `ts`, `packet`, `writer_id`,
  `destination_path`, `op`, `result`, `prompt_id`, `reason`.

**Pre-write validation:**
- Eligibility filter (`writer-fan-in` kind + `prompt-guided-amend` strategy
  + `writer_id` ∈ `upstream_writers[]` + `destination_path` matches `consumer`
  glob + `packet_kind ∈ {writer-emit, null}` self-exclusion).
- Prompt-resolution exactly-one-match (zero → skip; multiple → conflict).
- Survivorship signals 1, 2, 3 in order.
- Manifest history lookup (via `hooks/lib/manifest-record.sh query-destination-history`)
  for the content-hash diff side of signal 2.
- Replacement-packet emission via `staging-emit.sh` success (its exit code
  is the rc gate for the audit-log `OK` row).

**Failure mode:** `block and log`. Doc-amender NEVER writes the destination
directly. On any failure (LLM call rc != 0, prompt-resolution conflict,
survivorship conflict, staging-emit failure): emit `_amender-conflict.json`
sidecar; emit audit-log row with failure reason; continue to next packet.
The **original packet is RETAINED in staging** — the reconciler picks it up
on its next tick and writes the destination via the non-amended path (the
operator triages the sidecar separately via the deferred `/amend-accept` skill).

## Why event-driven, not cron

Operator-locked design decision (2026-05-19) per DQP-compliant
AskUserQuestion. Cost envelope rationale: ~N × $0.03/call where N = real
amender-eligible packet volume (almost certainly << 24/day in practice).
Self-exclusion + debounce + lockf prevent infinite self-loop. First-of-kind
WatchPaths fire mechanism; cadence is NOT coupled to the writer-reconciler's
WatchPaths-hybrid trigger (which would couple LLM cost to the mechanical
reconciler cadence — unwanted). NO `doc_amender_tick_minutes_default` field in pillar 7
(saves R-37 lockstep on `governance/vault-writers-rules.json` +
`schemas/vault-writers-rules-schema.json`).

## Limitations and non-goals

- **No classification.** Writer-references + `doc-dependencies.json` decide
  eligibility upstream. Doc-amender does not infer fan-in destinations.
- **No direct destination writes.** All output round-trips through
  `hooks/lib/staging-emit.sh` per R-34. The reconciler owns the destination write.
- **No semantic merging beyond the prompt.** Merging logic is delegated to
  the operator-authored prompt asset + LLM. Doc-amender does not paraphrase
  / summarize / reorder content itself.
- **No retroactive amendment.** Doc-amender amends only on new packet-land
  events. Pre-existing destinations are not amended unless a fresh packet
  references them.
- **No multi-vault.** One vault per doc-amender invocation. Multi-vault
  setups run separate launchd agents per vault root.
- **No cron tick.** Cadence is event-driven; coupling to a cron tick is
  explicitly rejected per the 2026-05-19 operator decision (cost-envelope
  + WatchPaths self-loop reasons documented above).

## Persistence modes (per `doc-amender-prompt.md.json :: persistence.mode`)

The prompt contract's `persistence.mode` selects the composition lane:

- **`llm-mediated`** — runs the prompt body through `claude -p` (the ported
  runtime above). Default for `amendment_strategy=prompt-guided-amend`.
- **`hybrid`** — append-section with LLM control (`amendment_strategy=append-section`).
- **`deterministic`** — NO `claude -p`; `process.sh` dispatches to
  `compose-deterministic.sh` (table-fill upsert + capped-append) when the
  prompt resolves to `persistence.mode=deterministic` (`amendment_strategy=template-fill`).
  The deterministic lane ALSO round-trips through `hooks/lib/staging-emit.sh` —
  it never writes the destination (R-34).

Prompt assets are authored via the Layer-3 guided flow
(`/govern register --kind doc-amender-prompt` — the 5th registration class),
which interviews the operator on per-destination merge intent and renders a
contract-compliant prompt asset to `$VAULT_WRITER_STATE_ROOT/prompts/`.

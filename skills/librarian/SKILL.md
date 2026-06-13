---
name: librarian
description: The vault/plan/governance librarian — a single skill with a flat, capability-name-keyed set of capabilities under capabilities/. Audits and reconciles governance pillars, plan-tree status, vault indices, and the Vault Writers ecosystem; renders manifest-derived read-replicas (tasks.md, _index.md, _backlog.md, _archive.md, rules-index). Routes to a capability by name; the capability bodies execute, they are not loaded inline.
disable-model-invocation: false
---

# librarian

The librarian is ONE skill with a flat `capabilities/` directory keyed
by capability NAME. This SKILL.md is a `<500-line` dispatcher:
each capability gets a `## Capability:` heading + a one-line purpose + a runtime
pointer. The per-capability prose lives in the capability `.sh` body's header,
the `capability-registry.json` `output_contract` block (the contract-of-record),
and the single GENERATED `docs/capability-reference.md` (generated
at release by `tools/`, not hand-authored here — anti-third-copy).

## Topology

- **Registry (contract-of-record):** `capability-registry.json` — per-capability
  `output_contract` (files-written · schema · validation · failure-mode) + the
  capability↔schema/path dependency map. Regenerated, never hand-edited.
- **Bijection:** `capability-registry-parity.sh` keys a strict bijection on the
  `## Capability:` headings BELOW. Heading set == registry key set == on-disk
  `capabilities/*.sh` set (the disk→registry orphan check is the NET-NEW 5th
  drift class). Move only the prose beneath a heading; never drop a
  heading without co-updating the parity auditor's `SKILL_MD` target.
- **Finding contract:** all capabilities emit findings via
  `hooks/lib/findings.sh` (`emit_finding` / `emit_event`). There is NO
  `schemas/librarian-finding-schema.json` — that reference is a PHANTOM,
  resolved to `hooks/lib/findings.sh`.
- **Failure mode (all bodies):** block-and-log, never write-and-hope.
- **bash 3.2 (R-23)** + argv-based Python heredoc (R-24) across every body.

## Invocation

```
/librarian <capability> [flags]      # run one capability by name
/librarian full                      # the audit-set sweep
```

The capability NAME is the routing key — there is no per-domain sub-skill and no
`domain:` registry field (SKIP; no current consumer). Domain
is the rule CATEGORY axis, not a skill boundary.

### What `full` runs (the audit-set roster)

`full` is the audit-set sweep: it runs every capability whose `capability-registry.json`
`invocation_modes` includes `librarian-full`. The **registry is the authoritative roster**
(contract-of-record); the set below is a snapshot of the current release (28
capabilities) — consult `invocation_modes` for the live membership:

> `governance-parity-audit`, `index-maintain`, `log-subtype-canonical`, `rules-index`,
> `writers-index-refresh`, `writers-overlap-refresh`, `writers-health-audit`,
> `plan-index`, `plan-parent-resolve`, `drift-sweep`,
> `trinity-drift-detect`, `frontmatter-enforce`, `placement-validate`, `xref-check`,
> `stale-detect`, `handoff-disposition-check`, `tag-coverage-audit`,
> `sanctioned-schema-drift-detect`, `capability-registry-parity`,
> `librarian-manifest-validate`, `skill-parity`, `waiver-audit`, `log-archive`, `backup`,
> `wikilink-repair`, `rename-detect`, `rename-cascade`, `rename-history-sync`.

`full` is NOT "every capability". Notably it does **not** run `backlog-index` or
`plan-archive` (see below), nor `tasks-render` / `subplan-aggregate` (those run per-plan,
on demand).

### Plan-tree read-replicas materialize LAZILY (not at install)

The three plan-tree aggregates are librarian-EMITTED on first relevant run — the installer
seeds **none** of them, so a brand-new adopter's `$PLANS_HOME` legitimately has no
`_index.md` / `_backlog.md` / `_archive.md` until a librarian capability writes them. No
shipped consumer hard-fails on their absence (the one runtime reader degrades gracefully).
Each has a different first-emit trigger — know which capability owns which file:

| Read-replica | Emitted by | Invocation modes | First materializes on |
|---|---|---|---|
| `$PLANS_HOME/_index.md`   | `plan-index`   | `ad-hoc`, `librarian-full`, `session-close-step-2` | first `/librarian full`, first session-close, or `/librarian plan-index` |
| `$PLANS_HOME/_backlog.md` | `backlog-index`| `ad-hoc`, `cron` | an explicit `/librarian backlog-index` or its scheduled cron run — **not** `full`, **not** session-close |
| `$PLANS_HOME/_archive.md` | `plan-archive` | `ad-hoc`, `cron` | an explicit `/librarian plan-archive` or its scheduled cron run — **not** `full`, **not** session-close |

So a `full` sweep (or any session-close) materializes `_index.md`, but `_backlog.md` and
`_archive.md` appear only when their own capability is run (ad-hoc or via the scheduled
cron). This is by design, not a gap.

---

## Capability: governance-parity-audit

Audit-time alignment backstop for the dual-surface governance pattern — walks
the pillar JSON surfaces + their narrative spokes, emits drift findings by
pillar (rule-id-mismatch, field-missing, tier-mismatch, source-divergence,
foundation-upgrade-touches-shadowed-entry, meta-rule-coverage-gap,
pillar-schema-malformed).
Runtime: `capabilities/governance-parity-audit.sh`.

## Capability: index-maintain

The first self-healing capability under the R-34 boundary — reconciles each
non-exempt folder's `_index.md` contents-enum table against filesystem reality;
auto-corrects mechanical drift (Lines/Type/rows/updated:/bootstrap) inside the
sentinels, flags semantic drift, never overwrites hand-tuned content.
Runtime: `capabilities/index-maintain.sh`.

## Capability: log-subtype-canonical

Audit-time (Layer 2) detector of unregistered `#log/*` / `#status/*` subtypes +
near-match drift in the registry (the Layer-1 write-time hook is foundation-owned, not
here). Categories: log-subtype-unregistered, log-subtype-near-match-drift,
log-subtype-owner-orphan.
Runtime: `capabilities/log-subtype-canonical.sh`.

## Capability: writers-index-refresh

Regenerates the canonical `Vault Writers/_index.md` catalog table from the
writer-reference files (sentinel-bounded; per-writer contract validation;
operator narrative preserved).
Runtime: `capabilities/writers-index-refresh.sh`.

## Capability: writers-overlap-refresh

Regenerates `Vault Writers/_overlap-matrix.md` — derives a glob form of each
destination path, clusters by glob equivalence, surfaces ≥2-writer clusters,
write-shape conflicts, and doc-deps writer-fan-in producer-join mismatches.
Runtime: `capabilities/writers-overlap-refresh.sh`.

## Capability: writers-health-audit

Read-only daily sweep of writer-reference files + skill registry + path_routing
for operational drift (dormant-writer, unresolved-destination,
orphan-writer-skill-ref, orphan-destination-ref, multi-writer-overlap). No vault
write.
Runtime: `capabilities/writers-health-audit.sh`.

## Capability: rules-index

The governance-rules-index regenerator — assembles a librarian-derived
read-replica of the rule register from the per-pillar `_rules[]` SoT + the
`_index.json` meta block, grouped by category with a retired-tombstone section.
Ships UNVALIDATED (no schema). DISTINCT from the `rules-hygiene` body.
Runtime: `capabilities/rules-index.sh`.

## Capability: tasks-render

Regenerates a single plan's `tasks.md` from its `manifest.tasks[]` —
sentinel-bounded read-replica with operator-narrative + per-row-Notes
survivorship, idempotent, `--check` parity mode. manifest read-only.
Runtime: `capabilities/tasks-render.sh`.

## Capability: subplan-aggregate

Pull-based master `sub_plans[]` aggregator (A-03) — reads each
sub-plan's published status into the master's `sub_plans[]` read-replica
(element shape `{sub_plan_id, slug, status, graduation_timestamp}`; the
graduation_timestamp WRITER; coarse-bucket keying). Never
hand-edited.
Runtime: `capabilities/subplan-aggregate.sh`.

## Capability: trinity-drift-detect

Detects spec/manifest/tasks/T-N status disagreement (the existing trinity axis)
AND the master↔sub aggregation axis (R-61 aggregation-integrity, R-62
sub-publishes-upward, R-63 sub-peer-isolation advisory). Reconciler-only, never
write-time.
Runtime: `capabilities/trinity-drift-detect.sh`.

## Capability: drift-sweep

Frontmatter-drift sweep over vault `.md` against the governance bundle PLUS the
master↔sub aggregation axis with an optional `--fix` that repairs a master's
`sub_plans[]` via the canonical aggregator (single-writer invariant).
Runtime: `capabilities/drift-sweep.sh`.

## Capability: plan-index

Regenerates `<plans-root>/_index.md` as a status-grouped navigation index;
A-06 reader cap — READS the master `sub_plans[]` aggregate for the per-master
coarse-bucket rollup. The plan-index.md capability contract is governed by the
registry `output_contract` (no governance/librarian-capabilities/ doc).
Runtime: `capabilities/plan-index.sh`.

## Capability: backlog-index

Regenerates `<plans-root>/_backlog.md` from `{researching, planned}` manifests;
A-06 reader cap — master-row-only policy (READS the aggregate) + satellite
-pointer retarget off the `<slug>.md` backlog-progress satellite to the plan dir /
master `handoff.md`.
Runtime: `capabilities/backlog-index.sh`.

## Capability: plan-archive

Promotes closed plans to archived + appends to `<plans-root>/_archive.md`; A-06
reader cap — master-subtree archival gate (a master archives only when every
`sub_plans[]` entry is terminal). Data-driven cooldown; idempotent.
Runtime: `capabilities/plan-archive.sh`.

## Capability: capability-registry-parity

Audits `capability-registry.json` against the `## Capability:` headings + the
on-disk `capabilities/*.sh` — 5 drift classes: bijection, script-missing,
schema-version, emits→writes_manifest_subtree, and the NET-NEW disk→registry
orphan check (closes the 40-vs-44 gap). Report-only (exit 0).
Runtime: `capabilities/capability-registry-parity.sh`.

## Capability: chronicle-index

Maintains the runtime episodic chronicle (`$MEM_DIR/episodic-chronicle.md`)
at session-close — read-mostly, no-LLM. Three idempotent roles: (1)
sentinel-bounded refresh of the MEMORY.md `## Episodic` pointer-line metadata
(the `last N sessions` count); (2) 50KB rotation — split the OLDEST rows to
`episodic-chronicle-archive-<date>.md` (split-to-archive, never delete/truncate;
`total_counted==0` aborts without blanking, group-sum assertion, atomic
`os.replace` — MODEL-AFTER `plan-index.sh:314-321`); (3) one-line-summary
backfill — replace the just-closed session's `— summary on review —` placeholder
with the harvested handoff/close-out one-liner (MODEL-AFTER
`handoff-disposition-check.sh:80-126`). Chained AFTER `handoff-disposition-check`
in `session-close.sh::step2_integrity()` so the close-out exists to harvest.
Runtime: `capabilities/chronicle-index.sh`.

## Capability: pointer-currency-scan

Advisory currency check for plain-text absolute-path pointers in the memory tier
(T-7). Predicate INVERTS `memory-staleness`: instead of "is
`last_validated` past the interval?", it asks "does each plain-text absolute-path
pointer in `MEMORY.md` + memory topic-files + `rules/*.md` still RESOLVE on disk?".
Scans the three plain-text-path classes NO existing cleaner covers (consolidation
Check-5 = markdown links inside MEMORY_DIR; `rules-hygiene` = `paths:` globs;
`rename-cascade` = wikilinks + 4 FM keys). Propose-only — NO `--fix` (the auto-fix
rename-cascade-known subset is DEFERRED to a follow-on, filed as a System Backlog
row). Emits `pointer-currency` NDJSON findings via `hooks/lib/findings.sh`; a
non-resolving target is `warn`, a still-rotating ephemeral checkpoint path is
`info` (`ephemeral-by-design`, never suppress-listed — a suppress-list itself
rots). CHANGE-GATED at session-close: fires ONLY when a tracked file changed since
the last scan (a content-hash state file under `HOOKS_STATE`, the lychee
`.lycheecache` analog) — SILENT no-op otherwise (defeats alert-fatigue). Chained
BETWEEN `stale-detect` and `handoff-disposition-check` in
`session-close.sh::step2_integrity()` (`--session-close` cadence). Advisory-first;
graceful degradation (MEMORY_DIR absent → exit 0 + stderr note; claude-mem absent
→ no effect). Registry `cron_block = none` (cadence is session-close, not cron).
Runtime: `capabilities/pointer-currency-scan.sh`.

## Capability: frontmatter-enforce

Validates (and optionally `--fix`es) frontmatter on vault files against the
26-row type table; runs the provides-canonicality, size-monitoring, and
schema-type-coverage drift audits, persisting `drift_findings.*` to the
librarian-manifest. Ported as-is.
Runtime: `capabilities/frontmatter-enforce.sh`.

## Capability: placement-validate

Validates vault file placement against the governance placement rules (reads
`vault.logs_whitelist_subdirs` from the user-manifest); emits placement
findings. Ported as-is.
Runtime: `capabilities/placement-validate.sh`.

## Capability: xref-check

Cross-reference integrity check over vault `.md` links; computes the xref_graph
into the librarian-manifest. Ported as-is.
Runtime: `capabilities/xref-check.sh`.

## Capability: stale-detect

Detects stale plan-root + vault files past their freshness threshold (walks
plan roots via `hooks/lib/plan-path.sh`) — 9 staleness rules (the per-rule roster
is the `stale-detect.sh` header block). Rule #9 (R-FLOW-MAINT-1, binder-freshness):
a per-spoke binder surface (`_projects/<spoke>/{research-index,decision-log,handoff-chronicle}.md`)
whose `updated:` regen date lags the newest constituent-plan activity (max
manifest/handoff mtime across the spoke's plans) by >14d emits a `severity: warn`
`binder-stale` finding — warn-only family (rules #4/#7/#8), no Stop/exit-2; an
absent binder is first-run state, not staleness.
Runtime: `capabilities/stale-detect.sh`.

## Capability: tag-coverage-audit

Audits vault tag-taxonomy coverage (reads `vault.tag_audit_exemptions` from the
user-manifest); emits coverage findings. Ported as-is.
Runtime: `capabilities/tag-coverage-audit.sh`.

## Capability: sanctioned-schema-drift-detect

Byte-diffs the 2 sanctioned schemas (plans-schema, plan-manifest-schema)
between the foundation-repo source and the live `~/.claude/schemas/` install;
exit 1 on drift. Self-contained (no lib source). Ported as-is.
Runtime: `capabilities/sanctioned-schema-drift-detect.sh`.

## Capability: handoff-disposition-check

Checks every close-out follow-up carries one of the 3 dispositions (FIX NOW /
ABSORB / STANDALONE); emits disposition-gap findings. Ported as-is.
Runtime: `capabilities/handoff-disposition-check.sh`.

## Capability: plan-parent-resolve

Resolves the R-28 `parent_plan:` frontmatter convention (via
`hooks/lib/frontmatter.sh`) and surfaces drift findings where a sub-task file's
parent does not resolve. Also re-validates the auto-stamped `project:` spoke key
(R-ARCH-PID-DRIFT / R-FLOW-MAINT-7) against the anchored-spoke registry (sourced
via `skills/new-plan/lib/spoke-resolve.sh`) and the plan's lineage; a
disagreement reuses the `parent-plan-path-drift` finding name with a
`drift_class` (`project-stamp-unregistered` | `project-stamp-vs-lineage`),
severity warn, for human adjudication — never a silent re-file.
Runtime: `capabilities/plan-parent-resolve.sh`.

## Capability: librarian-manifest-validate

Validates a staged `librarian-manifest.json` write against
`schemas/librarian-manifest-schema.json` (tier ajv → python-jsonschema →
minimal); DENY (exit 1) + diagnostic log on schema-invalid. Ported as-is.
Runtime: `capabilities/librarian-manifest-validate.sh`.

## Capability: skill-parity

Audits the skill registry against the on-disk skill bodies for parity drift.
Ported as-is.
Runtime: `capabilities/skill-parity.sh`.

## Capability: waiver-audit

Read-only audit of the governance waiver registry (the canonical writer is the
SP-owned `hooks/cascade-waiver.sh`, elsewhere). Ported as-is.
Runtime: `capabilities/waiver-audit.sh`.

## Capability: rules-hygiene

The `.claude/rules` lifecycle auditor — audits rule files against
`schemas/rules-schema.json` (judgment cap, requires confirmation). DISTINCT
from the `rules-index` regenerator. Ported as-is.
Runtime: `capabilities/rules-hygiene.sh`.

## Capability: log-archive

Archives old log files from `Vault/Logs/` per retention thresholds (dashboard
3d / general 7d) using `hooks/lib/dates.sh`. Ported as-is.
Runtime: `capabilities/log-archive.sh`.

## Capability: backup

Git add/commit/push wrapper across `system.backup_targets[]`; excludes
secret-bearing files (`settings.local.json`, `projects/`, `.pre-uninstall-*`)
and scans staged content for provider tokens before commit.
Runtime: `capabilities/backup.sh`.

## Capability: wikilink-repair

Rename-aware wikilink fixups over vault `.md` files (dry-run by default; atomic
per-file rewrite after review). Ported as-is.
Runtime: `capabilities/wikilink-repair.sh`.

## Capability: rename-detect

Detects file renames via `git log --diff-filter=R` across the vault + plans
roots; with `--register`, appends `drift_findings.rename_detected` to the
librarian-manifest (late-sources `hooks/lib/manifest.sh`). Upstream signal for
rename-cascade. Ported as-is.
Runtime: `capabilities/rename-detect.sh`.

## Capability: rename-cascade

Consumes rename-detect output and cascades wikilink updates downstream across
vault `.md` files (dry-run by default). Ported as-is.
Runtime: `capabilities/rename-cascade.sh`.

## Capability: rename-history-sync

Appends detected renames to the librarian-manifest `rename_history[]` (the
rename pipeline's history writer). Ported as-is.
Runtime: `capabilities/rename-history-sync.sh`.

## Capability: library-scrub

Dual-output promotion scrub: workshop research -> a universal
`_library/<topic>/<article>.md` (scrubbed of plan/project-specific detail, with
a synthesized `routing:` one-liner) AND a plan-SoT `<plan>/_research/` record,
with bidirectional `originating_plan:`/`library_refs[]` stamps and a
`workshop/_archive/` move — all in one propose/`--apply` (only `--apply`
writes). Novel-bet advisory-first; the propose diff is the human backstop;
empty-article output is block-and-logged.
Runtime: `capabilities/library-scrub.sh`.

## Capability: library-index

Keystone re-derive of the library's two `type: index` surfaces — per-topic
`_library/<topic>/_index.md` and the library-root `_library/_index.md` — from
article frontmatter on every run (C-IDX). Emits the sentinel-bounded
`contents-enum` table (`| File | Lines | Type | Description |`, wikilink File
cells) with a `routing:`-first Description chain; survivorship-preserves the H1
and the folder-context paragraph outside the sentinels; falls back to a prose
"Current Contents" section under the <3-distinct-types condition. The root index
aggregates member-article `routing:` (1:many) and carries each topic's staleness
date from `_library/log.md` when present. Audit-time findings (never a write-time
guard): over-threshold, basename-collision, near-duplicate-title, broken /
one-sided-edge (the R-FLOW-PROMO-4 crash-window detector), and R-LIB-1 body-shape.
A read-only `--query <topic>` mode (zero writes) resolves a topic (exact name
first, then case-insensitive/fuzzy prefix) and prints its `_index.md` to stdout —
or a short available-topics list when the topic does not resolve — serving the
three-load selectivity chain and the R-FLOW-PRE-4 at-cap pointer
`pre-research-check.sh` emits.
Runtime: `capabilities/library-index.sh`.

## Capability: library-log-rotate

The librarian (rotation/audit) half of the composite maintainer for the library
global change log `_library/log.md` (R-GOV-1a): the appender hook
(`hooks/library-log-append.sh`) is the sole appender of routine entries; this
capability owns rotation, audit, and any full re-derive and NEVER appends a
routine entry. When the log exceeds the threshold (R-LIB-8 `size_limits`
`{max_lines: 2000}`), the event lines are moved out of the live log into per-year
`_library/log-archive/<YYYY>.md` archives (each itself a C-FM-LOG `type: log`
artifact), the C-FM-LOG frontmatter is preserved, and the live log continues
fresh with an `[AUDIT]` rotation marker so the appender keeps appending to a small
tail. Under threshold it emits a `rotation-not-due` finding with zero writes
(idempotent); `--dry-run` reports would-rotate counts without writing.
Runtime: `capabilities/library-log-rotate.sh`.

## Capability: plan-research-index

Generates the per-spoke binder research surface
`_projects/<spoke>/research-index.md` (R-BIND-2/R-BIND-5) plus the
`research/<plan-slug>/` directory-symlink farm (R-BIND-8), re-derived from every
plan manifest's `research_artifacts[]` on every run. The binder is per-spoke: only
plans whose manifest `project:` matches the target spoke contribute rows, and rows
are grouped by `parent_plan:` lineage. One row per declared
`research_artifacts[]` entry (declaration is the selectivity gate): `| Path | Type
| Status | Plan-origin | One-liner | Library |`, the Library column derived from
`library_refs`. Row-content selectivity (02:179): a finalized finding body is
copied inline as a `> ` distilled blockquote ONLY when it is non-inferable — when
status is `finalized`, an explicit distilled field (`finding`/`distilled`/`summary`)
is present, and that text is not already inferable from the one-liner; every other
entry emits a path pointer, never the full body. The `research/` farm is generated
AND pruned each run — a symlink whose target plan `_research/` no longer exists, or
whose plan no longer belongs to the spoke, is unlinked (the link only; the target
is never followed or deleted). Re-derive surfaces one-sided R-FLOW-PROMO-4 edges
(a manifest `library_ref` without the article back-stamp, or vice versa) as
findings — DETECT + report, never repair-write (library-scrub owns the promotion
write-orchestration, R-FLOW-PROMO). Missing manifest fields render empty, never error
(R-BIND-10a). `--spoke <key>` scopes to one spoke; `--dry-run` reports findings +
would-be writes/links without writing.
Runtime: `capabilities/plan-research-index.sh`.

## Capability: plan-decision-log

Generates the per-spoke binder decision surface
`_projects/<spoke>/decision-log.md` (R-BIND-3 / R-BIND-6) — the
`decision_records[]` projection across every plan launched from the spoke,
re-derived from each plan manifest on every run. Distinct from the shipped
`handoff-disposition-check` close-out checker (this is a binder generator, not a
chronicle checker). The log is per-spoke: only plans whose manifest `project:`
matches the target spoke contribute rows, grouped by `parent_plan:` lineage. One
row per declared `decision_records[]` entry — a PURE projection, no symlink farm
and no inline-vs-pointer selectivity: `| ADR | Title | Status | Path |
Superseded-by | Created | Plan-origin |`. ADR bodies, rationale, and option-tables
STAY at the linked path; the projection never copies them inline. Append-immutable
per R-BIND-6: a record whose status is `superseded` is forward-linked via its
`superseded_by` ADR ordinal (cross-referenced to the in-projection row when that
ADR is present) and is NEVER dropped from the log. A `superseded` record missing
its forward-link, or a status outside the shipped enum
(`proposed|accepted|rejected|deprecated|superseded`), is surfaced as a finding (the
record still renders). Missing/empty `decision_records[]` renders an empty section,
never an error (R-BIND-10a). `--spoke <key>` scopes to one spoke; `--dry-run`
reports findings + would-be writes without writing.
Runtime: `capabilities/plan-decision-log.sh`.

## Capability: plan-handoff-index

Generates the per-spoke binder handoff surface
`_projects/<spoke>/handoff-chronicle.md` (R-BIND-4 / R-BIND-7) — the
session-handoff reconciliation chronicle across every plan launched from the
spoke, re-derived from each plan's `handoff.md` on every run. Distinct from the
shipped `handoff-disposition-check` close-out missing-disposition checker (this is
a chronicle generator, not a checker). Append-only, newest-first: one block per
session — source `handoff.md` path + session number/date + the `Next session:`
line + a ONE-LINE summary harvested from `### Locks captured` / `### Decision-Quality
Protocol passes`; when both canonical subsections are absent it FALLS BACK to the
first ~200 chars of the block body rather than emitting an empty row. Handoff
bodies are NEVER concatenated. This is the PRIMARY (re-derive) half of the
R-GOV-1a composite maintainer: the librarian re-derive owns the WHOLE file
(frontmatter + intro + the sentinel-bounded chronicle region), and the
SECONDARY-ROLE hook (`hooks/handoff-chronicle-append.sh`) appends ONE block at the
HEAD of the sentinel region `<!-- handoff-chronicle:start --> … <!-- handoff-chronicle:end -->`
— DISJOINT surfaces (the hook never re-derives, the librarian never appends a
routine block). A missing/unreadable/empty/no-session-heading `handoff.md` is a
defensive skip + finding, never an error (R-BIND-10a). `--spoke <key>` scopes to
one spoke; `--dry-run` reports findings + would-be writes without writing.
Runtime: `capabilities/plan-handoff-index.sh`.

## Capability: memory-globalize

Promotes a vault memory entry to a global `.claude/rules/<name>.md` rule (only
with `--apply`; validates the candidate vs `schemas/rules-schema.json`;
name-collision guard; requires confirmation). Ported as-is.
Runtime: `capabilities/memory-globalize.sh`.

## Capability: memory-hygiene

The memory lifecycle auditor — index-health + staleness over
`system.memory_dir` (resolved via `hooks/lib/paths.sh`; thresholds via
`hooks/lib/dates.sh`; requires confirmation). Ported as-is.
Runtime: `capabilities/memory-hygiene.sh`.

## Capability: memory-staleness

Detects stale memory entries against `schemas/memory-schema.json` staleness
thresholds; emits NDJSON candidates (skip-and-log). Ported as-is.
Runtime: `capabilities/memory-staleness.sh`.

## Capability: session-close

The load-bearing session-close orchestrator — chains the
C1/C2/C3/S2 capability set; cut caps degrade via `run_capability`
skip-not-installed. Ported AS-IS UNMODIFIED.
Runtime: `capabilities/session-close.sh`.

## Capability: review

The operator-facing DRAIN of `.review-queue.json` — the consumer
half of the guaranteed-surfacing mechanism whose producer/banner/mandate/stop-block
halves already ship. Judgment-tier (an LLM diff-presentation + decision loop, like
`memory-hygiene`); requires confirmation; never auto-fires `AskUserQuestion`. This
is a SKILL.md judgment RUBRIC with NO `capabilities/review.sh` disk body — the
mechanical state writes are the four `hooks/lib/review-queue.sh` primitives
(`confirm_item`/`reject_item`/`defer_item`/`suppress_item`); the rubric below is the
judgment loop that decides which to call (a spec-only registry entry without a disk
body is bijection-legal — the orphan check is the converse).
Runtime: none (judgment rubric — see the rubric below; the registry `review` entry is
`implementation_status: spec-only`).

### Rubric (the review walk)

1. **Source the primitives.** `source "$CLAUDE_HOME/hooks/lib/review-queue.sh"` (the
   `enqueue_item` producer + the four state-transition drains
   `confirm_item`/`reject_item`/`defer_item`/`suppress_item` + the reader
   `review_queue_pending_count`). Resolve the queue file via the lib's
   `_rq_queue_file` (memory-state tier, beside `.consolidation-state.json`).
2. **Read OPEN items.** Select items with `state == "open"`. Each carries
   `{id, subject, classification (revalidation|hygiene|conflict|promotion), severity
   (low|medium|high), defer_count, dismiss_count, diff?, ...}` per
   `schemas/review-queue-schema.json`.
3. **Sort + cap.** High-severity first, then oldest-first. Process at most ~20 items
   per pass (batch cap) — surface the remaining count and stop.
4. **Auto-suppress (anti-fatigue).** Before presenting, for any LOW-severity `hygiene`
   item whose `dismiss_count >= 3`, call `suppress_item <id>` and skip it.
   **Revalidation items are EXEMPT from auto-suppress** — they always surface.
5. **Present (per item).** Render a DIFF + a plain-language impact statement — NOT a bare
   APPROVE. State what changes, where, and why it surfaced.
6. **Collect exactly one disposition** per item — never auto-fire `AskUserQuestion`:
   - **CONFIRM** → apply the class-appropriate write INSIDE this walk, then `confirm_item <id>`:
     - `promotion` → write the buffered proposal to `{system.memory_dir}/*.md` (the ONLY
       System-B→System-A memory write — Gate 1; `mem-promote` NEVER writes — the apply
       point is HERE, inside the review walk).
     - `revalidation` → stamp `last_validated: <today>` on the referenced memory file
       (resets the 180d clock).
     - `conflict` → record the operator-chosen resolution (conflicts are operator-decided,
       never auto-resolved).
   - **REJECT-WITH-REASON** → `reject_item <id> "<reason>"` (reason MANDATORY).
   - **DEFER (capped)** → `defer_item <id> "<reason>"` (reason MANDATORY; `defer_count++`).
     At `defer_count >= 2` force-escalate — the item stays in the queue (a bare defer
     NEVER clears it).
7. **Report.** Summarize per class: confirmed / rejected / deferred / suppressed counts +
   the remaining OPEN count (which the SessionStart banner re-surfaces next session).

> **Producer asymmetry (v1.0.0, operator-ratified):** the `conflict` + `promotion` classes
> are fully end-to-end (live producers exist + this drain). For the remaining two classes:
> - **`revalidation` producer = LANDED** (T-09): `hooks/memory-consolidation-run.sh`
>   `enqueue_revalidation` feeds this drain, SessionEnd-gated (≥24h AND ≥5 sessions). The
>   SessionStart "N memories due for revalidation" banner count is non-zero on any adopt running
>   ~180+ days.
> - **`hygiene` producer = still DEFER-v1.1:** Check 7 temporal-hygiene auto-fixes relative-date
>   strings in place but never enqueues; orphan / dead-ref / budget checks emit to the audit log
>   only. So the hygiene-review count is always 0 in v1.0.0 (deferred to v1.1). Accepted asymmetry.

### Output Contract (review)

- **Files written:** `{system.memory_dir}/*.md` (on a CONFIRM of a promotion item — Gate 1,
  with confirmation) + `.review-queue.json` (every disposition, via the lib primitives).
- **Schema:** items validated against `schemas/review-queue-schema.json` (the lib's
  `enqueue_item` validates on append; the drains preserve the schema-defined `state` enum).
  Memory writes validate against `schemas/memory-schema.json`.
- **Validation:** queue resolved via `hooks/lib/review-queue.sh`; memory-dir via
  `hooks/lib/paths.sh`; requires confirmation on every write.
- **Failure mode:** **block-and-log** — abort on validation failure; no partial state.

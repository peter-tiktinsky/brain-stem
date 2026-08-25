---
name: librarian
description: The vault/plan/governance librarian — a single skill with a flat, capability-name-keyed set of capabilities under capabilities/. Audits and reconciles governance pillars, plan-tree status, vault indices, and the Vault Writers ecosystem; renders manifest-derived read-replicas (tasks.md, _index.md, _backlog.md, rules-index). Routes to a capability by name; the capability bodies execute, they are not loaded inline.
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

`/librarian full` is the MANUAL, ad-hoc audit-set sweep. The **schedulable** subset of that
roster (every capability declaring a `cron_block` cadence of `daily`/`weekly`/`monday`) ALSO
runs automatically at each detached **session-close**, gated by `hooks/lib/cadence.sh`'s
`sweep_due()` rolling-window ledger — there is no standalone background `full` runner; the
deterministic close-time cadence gate is the automatic trigger.

`full` is the audit-set sweep: it runs every capability whose `capability-registry.json`
`invocation_modes` includes `librarian-full`. The **registry is the authoritative roster**
(contract-of-record); the set below is a snapshot of the current release (40
capabilities) — consult `invocation_modes` for the live membership:

> `governance-parity-audit`, `index-maintain`, `log-subtype-canonical`, `rules-index`,
> `writers-index-refresh`, `writers-overlap-refresh`, `writers-health-audit`, `plan-index`,
> `plan-parent-resolve`, `drift-sweep`, `trinity-drift-detect`, `frontmatter-enforce`,
> `placement-validate`, `xref-check`, `stale-detect`, `handoff-disposition-check`,
> `tag-coverage-audit`, `sanctioned-schema-drift-detect`, `capability-registry-parity`, `librarian-manifest-validate`,
> `skill-parity`, `waiver-audit`, `log-archive`,
> `wikilink-repair`, `rename-detect`, `rename-cascade`, `rename-history-sync`,
> `plan-research-index`, `plan-decision-log`, `plan-handoff-index`, `project-context-situating`,
> `work-map-generate`, `work-index-maintain`, `binder-handoff-append-wrapper`, `chronicle-index`,
> `pointer-currency-scan`, `plan-terminal-lag-check`, `library-index`, `library-log-rotate`,
> `coverage-guard`.

`full` is NOT "every capability". Notably it does **not** run `backlog-index`
(see below), nor `tasks-render` / `matrix-render` / `subplan-aggregate`
(those run per-plan, on demand).

### Plan-tree read-replicas materialize LAZILY (not at install)

The two plan-tree aggregates are librarian-EMITTED on first relevant run — the installer
seeds **none** of them, so a brand-new adopter's `$PLANS_HOME` legitimately has no
`_index.md` / `_backlog.md` until a librarian capability writes them. No
shipped consumer hard-fails on their absence (the one runtime reader degrades gracefully).
Each has a different first-emit trigger — know which capability owns which file:

| Read-replica | Emitted by | Invocation modes | First materializes on |
|---|---|---|---|
| `$PLANS_HOME/_index.md`   | `plan-index`   | `ad-hoc`, `librarian-full`, `session-close-step-2` | first `/librarian full`, first session-close, or `/librarian plan-index` |
| `$PLANS_HOME/_backlog.md` | `backlog-index`| `ad-hoc`, session-close | first session-close, or an explicit `/librarian backlog-index` — **not** `full` |

So a `full` sweep (or any session-close) materializes `_index.md`; `_backlog.md` now
materializes at session-close too (or via an explicit `/librarian backlog-index`) — but
still **not** via `full` (`backlog-index` is not in the `librarian-full` roster).

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
sentinel-bounded read-replica with operator-narrative preserved and per-row
ledger Notes carried forward across re-renders (including on done/struck rows;
whole-cell `{{placeholder}}` cells are dropped, not carried), idempotent,
`--check` parity mode. manifest read-only.
Runtime: `capabilities/tasks-render.sh`.

## Capability: matrix-render

Regenerates a single plan's `traceability-matrix.md` from its `manifest.tasks[]`
— the sibling of `tasks-render` for the matrix mirror (the 8th incident drift
site; nothing rendered or consumed it before). Sentinel-bounded
(`<!-- matrix:start -->`/`<!-- matrix:end -->`) one-row-per-task table; the render
owns the four SoT-derived columns (Task / Build-item / SoT clause / Acceptance),
the two downstream-filled columns (Build artifact / Independent verdict) are
human-owned and preserved across re-renders via the prior-notes survivorship
pattern. Line-anchored sentinel location (block-and-log on ambiguity), idempotent,
`--check` parity mode. manifest read-only. Wired beside the tasks-render structural
trigger in `hooks/post-manifest-binder-refresh.sh` (opt-in per file: fires only when
the matrix already carries the sentinel).
Runtime: `capabilities/matrix-render.sh`.

## Capability: subplan-aggregate

Pull-based master `sub_plans[]` aggregator () — reads each
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

Regenerates `<plans-root>/_index.md` as a single-table plan ledger (house
tasks.md style): one `| Plan | Status | Project dir | Subs |` row per plan,
sorted by status group then numeric slug, with a `**By status:**` counts line
and the collapsed `## Archived (N)` age view-filter. Status and Project dir are
first-class cells on every row (`—` marks an empty resolution, loud); the
former by-status H2 groups and appended `## By project directory` section are
superseded by the columns. reader cap — READS the master `sub_plans[]`
aggregate for the per-master coarse-bucket rollup (the Subs cell). The
plan-index.md capability contract is governed by the registry `output_contract`
(no governance/librarian-capabilities/ doc).
Runtime: `capabilities/plan-index.sh`.

## Capability: backlog-index

Regenerates `<plans-root>/_backlog.md` — the 7-column active funnel table
(Project Dir carries the registry-resolved project-home directory; Target carries
the `promoted_to`/`absorbed_into` plan-dir key) plus the derived settled ledger in
the `backlog-settled` sentinel region — and the machine-written
`_inbox/_index.md` (active + settled rosters + remediation highlights). Runs the
terminal-resolution closure loop over `_inbox/` notes first (write-if-changed
`resolution:` restamps when a target plan reaches `lifecycle.terminal_status`);
the stamp EVENT relocates the note to the settled home (`_inbox/_settled/`,
forward-only — already-settled flat notes are never moved), and the `_settled/`
walk is render-only (settled-ledger rows at the note's real location; residents
without settlement evidence draw the `inbox-settled-misfiled` advisory).
Settlement classifies on terminal-resolution EVIDENCE — an out-of-enum
`resolution:` corroborated by `resolved_at`/`superseded_by` settles, with the
`inbox-resolution-out-of-enum` advisory keeping vocabulary drift visible.
reader cap for plan rows — master-row-only policy (READS the aggregate).
Runtime: `capabilities/backlog-index.sh`.

## Capability: inbox-settle

The manual-settlement channel for a funnel note settled by operator judgment
with NO plan target (the shape the closure loop can never auto-stamp): stamps
the terminal `resolution:` + `resolved_at:` and relocates the note to
`_inbox/_settled/` in one event (default run is dry; writes only with
`--apply`). STRICT vocabulary — `--resolution` must be a member of the
governance `resolution_enum` (the sanctioned channel never mints drift);
`superseded` requires `--superseded-by`. Refuses an already-settled note and a
destination collision.
Runtime: `capabilities/inbox-settle.sh`.

## Capability: capability-registry-parity

Audits `capability-registry.json` against the `## Capability:` headings + the
on-disk `capabilities/*.sh` across the drift-class roster (bijection,
script-missing, schema-version, emits→writes_manifest_subtree, disk→registry
orphan, manifest-write-fiction, index exec-mode, full-runs roster — the
lettered enumeration in the capability's header comment is the SoT; the count
is deliberately unpinned). Report-only (exit 0).
Runtime: `capabilities/capability-registry-parity.sh`.

## Capability: coverage-guard

The reach-verified coverage guard — the standing regression guard over the
sentinel/canary corpus. Runs every declared sentinel's fixture and asserts the
corpus is GREEN (each fixture exists + is fired + catches its planted defect) and
the coverage allowlists are empty across every surface. Report-only findings
(coverage-guard-sentinel-escaped / coverage-guard-allowlist-nonempty); exit 0.
The corpus is test infrastructure, so this is a no-op on an adopter install.
Runtime: `capabilities/coverage-guard.sh`.

## Capability: chronicle-index

Maintains the runtime episodic chronicle (`$MEM_DIR/episodic-chronicle.md`)
at session-close — read-mostly, no-LLM. Three idempotent roles: (1)
sentinel-bounded refresh of the MEMORY.md `## Episodic` pointer-line metadata
(the `last N sessions` count); (2) 50KB rotation — split the OLDEST rows to
`episodic-chronicle-archive-<date>.md` (split-to-archive, never delete/truncate;
`total_counted==0` aborts without blanking, group-sum assertion, atomic
`os.replace` — MODEL-AFTER `plan-index`'s rotation); (3) one-line-summary
backfill — replace the just-closed session's `— summary on review —` placeholder
with the harvested handoff/close-out one-liner (MODEL-AFTER
`handoff-disposition-check`'s harvester). Chained AFTER `handoff-disposition-check`
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
6-row type table (`foundation-master.json` frontmatter.types); runs the provides-canonicality, size-monitoring, and
schema-type-coverage drift audits, persisting `drift_findings.*` to the
librarian-manifest. Ported as-is.
Runtime: `capabilities/frontmatter-enforce.sh`.
The whole-vault `--full` walk follows symlinks to reach vault-proper clusters behind them
(with a realpath cycle-guard), but PRUNES the external symlink surfaces —
`Work`, `Plans`, `Projects`, `Wiki`, `Skills` — at the vault root, since those are governed
elsewhere. So deliverables under the `Work/` surface (a symlink to the external work home)
are not reached by `--full`; audit them with a scoped invocation,
`frontmatter-enforce.sh --scope <vault>/Work` — the same dedicated-scan pattern
`library-index` uses for the `_library` root. The mtime-gated `--recent` default stays
symlink-inert.

## Capability: placement-validate

Validates vault file placement against the governance placement rules; emits
placement findings. Ported as-is.
Runtime: `capabilities/placement-validate.sh`.

## Capability: xref-check

Cross-reference integrity check over vault `.md` links; computes the xref_graph
into the librarian-manifest. Ported as-is.
Runtime: `capabilities/xref-check.sh`.

## Capability: stale-detect

Detects stale plan-root + vault files past their freshness threshold (walks
plan roots via `hooks/lib/plan-path.sh`) — 8 staleness rules (the per-rule roster
is the `stale-detect.sh` header block; rule 6, residual vault `Logs/`, retired with
the vault `Logs/` folder at G3). Rule #9 (binder-freshness):
a per-spoke binder surface (`_projects/<spoke>/{research-index,decision-log,handoff-chronicle}.md`)
whose `updated:` regen date lags the newest constituent-plan activity (max
manifest/handoff mtime across the spoke's plans) by >14d emits a `severity: warn`
`binder-stale` finding — warn-only family (rules #4/#7/#8), no Stop/exit-2; an
absent binder is first-run state, not staleness. POSTURE: the binder is now
auto-maintained (session-close + a plan-manifest-write trigger + a session-start
refresh-from-disk), so a `binder-stale` finding indicates the auto-maintenance
pipeline did not run — a pipeline-failure signal to investigate the maintenance
chain, not a normal stale state (a generator re-run repairs the surface but does
not explain the miss).
Runtime: `capabilities/stale-detect.sh`.

## Capability: tag-coverage-audit

Audits vault tag-taxonomy coverage (reads `vault.tag_audit_exemptions` from the
user-manifest); emits coverage findings. Ported as-is.
Runtime: `capabilities/tag-coverage-audit.sh`.

## Capability: sanctioned-schema-drift-detect

Byte-diffs all shipped schemas (every `schemas/*.json` in the foundation-manifest)
between the foundation-repo source and the live `~/.claude/schemas/` install;
exit 1 on drift. Self-contained (no lib source). Ported as-is.
Runtime: `capabilities/sanctioned-schema-drift-detect.sh`.

## Capability: handoff-disposition-check

Checks every close-out follow-up carries one of the 3 dispositions (FIX NOW /
ABSORB / STANDALONE); emits disposition-gap findings. Ported as-is.
Runtime: `capabilities/handoff-disposition-check.sh`.

## Capability: plan-terminal-lag-check

Close-time surface-and-walk enforcement: emits a `plan-terminal-lag`
finding when a plan's own status is non-terminal under a `parent_plan` master
whose status IS terminal, and prompts the walk. Writes NO status — never
auto-closes, never auto-stamps `verified` — and touches no aggregation. TERMINAL
= {completed, superseded} (byte-identical to
trinity-drift-detect.sh / subplan-aggregate.sh; `completed` is the sole terminal done-state).
Runtime: `capabilities/plan-terminal-lag-check.sh`.

## Capability: plan-parent-resolve

Resolves the R-28 `parent_plan:` frontmatter convention (via
`hooks/lib/frontmatter.sh`) and surfaces drift findings where a sub-task file's
parent does not resolve. Also re-validates the auto-stamped `project:` spoke key
against the anchored-spoke registry (sourced
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

Archives old log files from the XDG state-tier run-log dir `$CLAUDE_LOG_DIR`
(default `state/logs/`) to `$CLAUDE_LOG_DIR/archive/` per retention thresholds
(dashboard 3d / general 7d) using `hooks/lib/dates.sh`.
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

Consumes rename-detect output and cascades wikilink AND markdown-link updates
downstream across vault `.md` files (dry-run by default; markdown targets are
re-rendered source-file-relative, never substring-replaced). `--from-history`
also loads the librarian-manifest `rename_history[]` trail (populated by
rename-detect `--persist-history`), so a move that left the 24h detection
window stays repairable.
Runtime: `capabilities/rename-cascade.sh`.

## Capability: rename-history-sync

Appends detected renames to `hooks/doc-dependencies.json` `rename_history[]` (the
rename pipeline's history writer).
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
one-sided-edge (the crash-window detector), and body-shape.
A read-only `--query <topic>` mode (zero writes) resolves a topic (exact name
first, then case-insensitive/fuzzy prefix) and prints its `_index.md` to stdout —
or a short available-topics list when the topic does not resolve — serving the
three-load selectivity chain and the at-cap pointer
`pre-research-check.sh` emits.
Runtime: `capabilities/library-index.sh`.

## Capability: library-log-rotate

The librarian (rotation/audit) half of the composite maintainer for the library
global change log `_library/log.md`: the appender hook
(`hooks/library-log-append.sh`) is the sole appender of routine entries; this
capability owns rotation, audit, and any full re-derive and NEVER appends a
routine entry. When the log exceeds the threshold (`size_limits`
`{max_lines: 2000}`), the event lines are moved out of the live log into per-year
`_library/log-archive/<YYYY>.md` archives (each itself a C-FM-LOG `type: log`
artifact), the C-FM-LOG frontmatter is preserved, and the live log continues
fresh with an `[AUDIT]` rotation marker so the appender keeps appending to a small
tail. Under threshold it emits a `rotation-not-due` finding with zero writes
(idempotent); `--dry-run` reports would-rotate counts without writing.
Runtime: `capabilities/library-log-rotate.sh`.

## Capability: link-grammar-convert

Converts live-prose wikilinks to the ruled relative markdown-link grammar
across the vault view, under the promoted house conversion pattern:
structural-fresh seed from the vault-view walk, `.lgcnew` dry-run siblings
(never in-place), a register with a blank approval line that `--apply` refuses
without, a full apply-time refusal battery (fire band, editor running, dirty
tree, register-vs-derivation drift, non-interactive shell), ambiguity routed
to a judgment register never guessed, and six self-verifying per-file
invariants including hard-blocking RESOLUTION-SET EQUALITY (every converted
link must resolve to the same physical file in both the logical vault-view
frame and the physical frame). Memory-namespace targets are exempt (that tier
resolves against its own namespace); fenced/inline-code wikilinks are
quotations and never converted; alias and `#anchor` tails round-trip.
Runtime: `capabilities/link-grammar-convert.sh`.

## Capability: plan-research-index

Generates the per-spoke binder research surface
`_projects/<spoke>/research-index.md` plus the
`research/<plan-slug>/` directory-symlink farm, re-derived from every
plan manifest's `research_artifacts[]` on every run. The binder is per-spoke: only
plans whose manifest `project:` matches the target spoke contribute rows, and rows
are grouped by `parent_plan:` lineage. One row per declared
`research_artifacts[]` entry (declaration is the selectivity gate): `| Path | Type
| Status | Plan-origin | One-liner | Library |`, the Library column derived from
`library_refs`. Each Path cell is a RESOLVING relative-path link chosen by the
artifact's declared home (two routes): an artifact under `_research/` keeps the
`research/<plan-slug>/` farm route with the full path-remainder (so nested subdirs
resolve); any other sanctioned declare home (`decisions/`, `target-state/` incl.
`canonical/`, `deliverables/`, a legacy `research/` dir, a plan-root file) links by a
binder-relative path straight to the plan file — the link derives from the declared
path, so it resolves regardless of home and stays green through a later repoint-at-move.
Row-content selectivity (02:179): a finalized finding body is
copied inline as a `> ` distilled blockquote ONLY when it is non-inferable — when
status is `finalized`, an explicit distilled field (`finding`/`distilled`/`summary`)
is present, and that text is not already inferable from the one-liner; every other
entry emits a path pointer, never the full body. The `research/` farm is generated
AND pruned each run — a symlink whose target plan `_research/` no longer exists, or
whose plan no longer belongs to the spoke, is unlinked (the link only; the target
is never followed or deleted). Re-derive surfaces one-sided edges
(a manifest `library_ref` without the article back-stamp, or vice versa) as
findings — DETECT + report, never repair-write (library-scrub owns the promotion
write-orchestration). Missing manifest fields render empty, never error
(never an error). `--spoke <key>` scopes to one spoke; `--dry-run` reports findings +
would-be writes/links without writing.
Runtime: `capabilities/plan-research-index.sh`.

## Capability: plan-research-declare

The A1-clause-4 session-close DECLARATION writer (140) — the SINGLE
surface that populates `research_artifacts[]`. At session close (step 2, BEFORE
`plan-research-index`) it reconciles each active-spoke plan's
`manifest.research_artifacts[]` from that plan's OWN research homes: the sanctioned
graduation home `<plan>/_research/` plus the structured in-plan dirs `decisions/`,
`target-state/`, `deliverables/`. Routing to the OWNING spoke is DERIVED — it writes
each plan's OWN manifest and the renderer groups by the `project:` key (the
true owner, never the over-attributed brain-stem). APPEND-only + defensive:
a missing field is empty (never an error), an author-curated entry is preserved
byte-for-byte (path is the idempotency key), only newly-discovered artifacts are
appended, and re-running is a write-no-op. It NEVER writes `_library` (universal-only,
) and NEVER invokes `library-scrub --apply` (the manual PROMOTION path).
`--spoke <key>` scopes to one spoke; `--dry-run` reports would-be declarations without
writing. Block-and-log; atomic temp+os.replace; exit 0 always.
Runtime: `capabilities/plan-research-declare.sh`.

## Capability: plan-decision-log

Generates the per-spoke binder decision surface
`_projects/<spoke>/decision-log.md` — the
`decision_records[]` projection across every plan launched from the spoke,
re-derived from each plan manifest on every run. Distinct from the shipped
`handoff-disposition-check` close-out checker (this is a binder generator, not a
chronicle checker). The log is per-spoke: only plans whose manifest `project:`
matches the target spoke contribute rows, grouped by `parent_plan:` lineage. One
row per declared `decision_records[]` entry — a PURE projection, no symlink farm
and no inline-vs-pointer selectivity: `| ADR | Title | Status | Path |
Superseded-by | Created | Plan-origin |`. ADR bodies, rationale, and option-tables
STAY at the linked path; the projection never copies them inline. Append-immutable
per the append-immutability contract: a record whose status is `superseded` is forward-linked via its
`superseded_by` ADR ordinal (cross-referenced to the in-projection row when that
ADR is present) and is NEVER dropped from the log. A `superseded` record missing
its forward-link, or a status outside the shipped enum
(`proposed|accepted|rejected|deprecated|superseded`), is surfaced as a finding (the
record still renders). Missing/empty `decision_records[]` renders an empty section,
never an error. `--spoke <key>` scopes to one spoke; `--dry-run`
reports findings + would-be writes without writing.
Runtime: `capabilities/plan-decision-log.sh`.

## Capability: plan-handoff-index

Generates the per-spoke binder handoff surface
`_projects/<spoke>/handoff-chronicle.md` — the
session-handoff reconciliation chronicle across every plan launched from the
spoke, re-derived from each plan's `handoff.md` on every run. Distinct from the
shipped `handoff-disposition-check` close-out missing-disposition checker (this is
a chronicle generator, not a checker). Append-only, newest-first: one block per
session — source `handoff.md` path + session number/date + the `Next session:`
line + a ONE-LINE summary harvested from `### Locks captured` / `### Decision-Quality
Protocol passes`; when both canonical subsections are absent it FALLS BACK to the
first ~200 chars of the block body rather than emitting an empty row. Handoff
bodies are NEVER concatenated. This is the PRIMARY (re-derive) half of the
composite maintainer: the librarian re-derive owns the WHOLE file
(frontmatter + intro + the sentinel-bounded chronicle region), and the
SECONDARY-ROLE hook (`hooks/handoff-chronicle-append.sh`) appends ONE block at the
HEAD of the sentinel region `<!-- handoff-chronicle:start --> … <!-- handoff-chronicle:end -->`
— DISJOINT surfaces (the hook never re-derives, the librarian never appends a
routine block). A missing/unreadable/empty/no-session-heading `handoff.md` is a
defensive skip + finding, never an error. `--spoke <key>` scopes to
one spoke; `--dry-run` reports findings + would-be writes without writing.
Runtime: `capabilities/plan-handoff-index.sh`.

## Capability: project-context-situating

Generates the per-spoke GENERATED situating card `_projects/<spoke>/_situating.md`
— the eager, force-ingested binder surface a session reads at SessionStart to
self-orient. The situating card is the SOLE binder cover — the project binder is
100% machine-derived, generated entirely from each contributing plan's manifest,
with no hand-curated cover surface. The card is per-spoke: only plans whose manifest `project:`
matches the target spoke contribute. It is DERIVED entirely from each contributing
plan's `manifest.json` (fields from `schemas/plan-manifest-schema.json`) and carries
ONLY machine-derivable blocks: the plan roster (`slug`/`title`/per-plan `status`),
an AGGREGATE project-level status computed BY RULE (there is no native aggregate
field — precedence `in-progress > paused > planned > completed > closed`), active
focus (the in-progress plan's current `tasks[]` task + blocker), a latest-handoff
pointer per in-progress plan (each plan's newest session heading by parsed session_key),
and pointers to `research-index.md` / `decision-log.md` / `handoff-chronicle.md` + the
`~/work/<spoke>/deliverables/` path. It EXCLUDES (hard) the non-derivable
library-refs and the free "active SoT" pointer (non-derivable curation the card
deliberately omits) and EXCLUDES all work-spoke directory-map / "what-lives-where" content (the
work-map generator's domain —D disjoint roles). The frontmatter REUSES the
existing `index` file-type (— no new file-type, no governance-type lockstep) plus a
`generated: true` sentinel that distinguishes the machine card from a curated index;
the body carries the `_Auto-generated … Do not hand-edit._` line. The card is
force-ingested every session, so it is bounded `< 9728B` (the `format_output`
budget, `hooks/lib/registry.sh` `format_output_allow`) and is defensively trimmed if a degenerate
roster would overflow. A malformed manifest is a defensive skip + finding, never a
crash (never an error). `--spoke <key>` scopes to one spoke; `--dry-run` reports
findings + would-be writes without writing.
Runtime: `capabilities/project-context-situating.sh`.

## Capability: work-map-generate

Regenerates the GENERATED work-map directory-map block inside a work spoke's
`CLAUDE.md` FROM DISK. This is the WORK surface — the work `CLAUDE.md`'s "what lives
where" directory map — the disjoint counterpart to the BINDER surface the situating
card owns (`project-context-situating`); the two never overlap (D disjoint roles).
The work `CLAUDE.md` is scaffolded by `skills/govern/lib/project-workspace/scaffold.sh`
with a FROZEN block contract: a `## What lives where` map bounded by
`<!-- work-map:start generated:true -->` … `<!-- work-map:end -->`, closing with the
`_Auto-maintained by \`librarian work-map-generate\` — do not hand-edit this block._`
line. Everything OUTSIDE those markers (the identity line, the README/updates
pointer, the binder pointer) is OWNED by scaffold.sh — this generator PRESERVES it
byte-for-byte and replaces ONLY the inside-markers content. The map is DERIVED from
the TOP LEVEL of `$WORK_HOME/<spoke>/` ONLY (not recursive): MASTER layout (the spoke
has sub-project dirs and no top-level `deliverables/`+`reference/` pair) lists the
actual sub-project dir names; FLAT layout lists `deliverables/` (polished work) +
`reference/` (raw notes) + `README.md` + `updates.md` with their roles. The block is
deterministic on the same disk state (idempotent: a re-run without a disk change is
byte-identical). Survivorship / leave-orphan: if the spoke's `CLAUDE.md` is
ABSENT, or carries NO work-map markers (a legacy / hand-authored `CLAUDE.md`), it
DEFENSIVELY SKIPS with a finding — it NEVER injects markers into a `CLAUDE.md` that
lacks the shape, and an absent spoke dir is the same defensive skip. It writes ONLY
the marker block in `$WORK_HOME/<spoke>/CLAUDE.md` (atomic `os.replace`) and NEVER
`README.md`, `updates.md`, anything under `deliverables/`/`reference/`, the
content outside the markers, or anything under the plans root. Block-and-log, exit 0,
never crash. `--spoke <key>` scopes to one spoke; `--dry-run` reports findings +
would-be writes without writing.
Runtime: `capabilities/work-map-generate.sh`.

## Capability: work-index-maintain

A WORK-SCOPED index pass that walks `$WORK_HOME` and mints/refreshes a
C-IDX-conformant `_index.md` inside each `deliverables/` and `reference/` directory
under each work spoke. This is the universal-foundation counterpart to
`index-maintain` (which is VAULT_ROOT-scoped): a work spoke lives at an EXTERNAL root
(`$WORK_HOME/<spoke>/`, not under the vault root), so `index-maintain`'s vault walk
never reaches it. This pass targets `$WORK_HOME` DIRECTLY — it does NOT modify
`index-maintain`'s VAULT_ROOT scoping, and it is NOT a per-spoke overlay-glob
registration. The `_index.md` it mints conforms to the SAME C-IDX contract: frontmatter
`type: index` + `tags` (`#project/<spoke>`) + `updated` + `parent_folder` (depth≥2) and
a `<!-- contents-enum:start -->` … `<!-- contents-enum:end -->` block enumerating the
directory's `.md` files in the `| Name | Lines | Type | Description |` row shape — so a
file minted here passes `index-maintain`'s index contract + `frontmatter-enforce`'s index
type. Scope per spoke (all spokes by default, or `--spoke <key>`): a FLAT spoke's
`deliverables/` + `reference/` are the TOP level; a MASTER spoke holds NONE of its own —
each sub-project is a DIRECT child of the master (`$WORK_HOME/<spoke>/<sub>/`) and owns
its own `deliverables/` + `reference/`. There is NO literal `sub-projects/` dir in the
shipped scaffold layout, so the AC's "(master) `sub-projects/_index.md`" resolves to the
per-sub-project `$WORK_HOME/<spoke>/<sub>/{deliverables,reference}/_index.md`; the master's
TOP-LEVEL sub-project navigation is the work-map's domain (`work-map-generate`), NOT this
pass (D disjoint roles). The pass OWNS the contents-enum block: it MINTS the full
`_index.md` when absent, else REFRESHES ONLY the text between the markers (markers +
everything outside preserved byte-for-byte). A marker-less existing `_index.md` (legacy /
hand-authored) is a leave-orphan skip — the shape is never imposed. Deterministic +
idempotent: a re-run without a disk change is byte-identical. It writes ONLY `_index.md`
files under `$WORK_HOME/<spoke>/.../{deliverables,reference}/` (atomic `os.replace`) and
NEVER `README.md`, `updates.md`, `CLAUDE.md`, deliverable/reference bodies, or
anything under the plans root. An absent work home / absent spoke / absent-or-unreadable
target subfolder is a defensive skip + finding. Block-and-log, exit 0, never crash.
`--spoke <key>` scopes to one spoke; `--dry-run` reports findings + would-be writes without
writing.
Runtime: `capabilities/work-index-maintain.sh`.

## Capability: binder-handoff-append-wrapper

The thin session-close ADAPTOR that wires the shipped-but-ORPHANED
`hooks/handoff-chronicle-append.sh` into the session-close capability chain (R-B).
The appender hook is the SECONDARY-ROLE (incremental append) half of the composite
composite maintainer for the per-spoke binder `handoff-chronicle.md`, but it takes
POSITIONAL args (`<handoff.md path> <spoke>`), so the generic `run_capability`
wrapper cannot drive it directly. This adaptor accepts `--spoke <key>` (so
`run_capability binder-handoff-append-wrapper --spoke "$active_spoke"` works),
resolves the just-finalized `handoff.md` for that spoke's active plan (walks
`PLANS_ROOT` for plans whose manifest `project:` == the spoke, prefers the
in-progress plan, picks the newest `handoff.md` by mtime; `--handoff <path>`
overrides), and invokes the positional-arg appender. It writes NOTHING itself — the
appender is the sole writer (ONE block at the HEAD of the chronicle's
`<!-- handoff-chronicle:start --> … <!-- handoff-chronicle:end -->` sentinel
region). Session-close fires it BEFORE `plan-handoff-index`'s full re-derive
(the append-before-re-derive ordering), which absorbs the appended block idempotently — the append
and the re-derive are DISJOINT roles that render IDENTICAL block text, so running
both produces NO duplication. Unresolvable spoke / no `handoff.md` / a blocked
appender all emit a finding and exit 0 (block-and-log; never crash the close).
Runtime: `capabilities/binder-handoff-append-wrapper.sh`.

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
skip-not-installed. **Backup is no longer chained** — the orchestrator is
structurally commit-free (no `git add`/`commit`/`push` reachable), so the auto and
manual close paths run the identical safe chain. `/librarian backup` stays the
standalone by-hand capability (`SECURITY.md` — "a capability you run by hand,
never automatically").
Runtime: `capabilities/session-close.sh`.

### Manual-close backup offer

A MANUAL `/librarian session-close` ends with a backup OFFER: after the chain, if
tracked `system.backup_targets[]` have uncommitted changes, surface
`N file(s) changed across <targets> — run /librarian backup to commit+push? [y/N]`
as an explicit confirm. NEVER auto-fire it — the user decides. The detached
auto-close (SessionEnd spawn / SessionStart backstop) never reaches this rubric, so
it never offers and never commits.

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
> - **`revalidation` producer = LANDED**: `hooks/memory-consolidation-run.sh`
>   `enqueue_revalidation` feeds this drain, SessionEnd-gated (≥24h AND ≥5 sessions). The
>   SessionStart "N memories due for revalidation" banner count is non-zero on any adopt running
>   ~180+ days.
> - **`hygiene` producer = still DEFER-v1.1:** Check 7 temporal-hygiene auto-fixes relative-date
>   strings in place but never enqueues; orphan / dead-ref / budget checks emit to the audit log
>   only. So the hygiene-review count is always 0 while the producer stays propose-only. Accepted asymmetry.

### Output Contract (review)

- **Files written:** `{system.memory_dir}/*.md` (on a CONFIRM of a promotion item — Gate 1,
  with confirmation) + `.review-queue.json` (every disposition, via the lib primitives).
- **Schema:** items validated against `schemas/review-queue-schema.json` (the lib's
  `enqueue_item` validates on append; the drains preserve the schema-defined `state` enum).
  Memory writes validate against `schemas/memory-schema.json`.
- **Validation:** queue resolved via `hooks/lib/review-queue.sh`; memory-dir via
  `hooks/lib/paths.sh`; requires confirmation on every write.
- **Failure mode:** **block-and-log** — abort on validation failure; no partial state.

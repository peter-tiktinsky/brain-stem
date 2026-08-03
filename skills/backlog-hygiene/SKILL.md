---
name: backlog-hygiene
description: >
  The GTD review loop over the manifest-derived backlog. Scans the pre-plan idea
  inbox + the in-flight plan manifests for funnel/lifecycle staleness and missing
  dispositions, enforces the R-29/30/31/56 lifecycle rules, and with --fix applies
  safe auto-maintenance (auto-flag missing dispositions).
  Delegates table regeneration to the librarian. Use as a scheduled maintenance task
  or on demand. Trigger on: "backlog hygiene", "clean up backlog", "/backlog-hygiene",
  "stale backlog items", or any request to audit backlog freshness.
disable-model-invocation: false
argument-hint: "[--dry-run] [--fix]"
---

# Backlog Hygiene

The GTD review-loop stage of the orchestration funnel () and the **declared
enforcement home for R-29 / R-30 / R-31 / R-56** (`plans-rules.json :: _rules[]
enforcement_layer: ["skill:backlog-hygiene"]` — these rules have NO enforcement until
this skill ships). Periodic sweep over the manifest-derived backlog: flags
funnel/lifecycle timeouts and missing dispositions and produces a hygiene report so the
active backlog stays trustworthy. It is a **reporter + delegator** — it never moves
rows and never writes `_backlog.md`; with `--fix` it applies only the single safe
auto-maintenance operation the disposition rule (R-56) sanctions.

The backlog is a **manifest-derived read replica** ():
- `{paths.plans_root}/_backlog.md` is the unified rendered view, owned exclusively by
  `librarian:backlog-index` (`writers_allowed: ["librarian"]`).
- Archival is **not** a separate store: the plan-index default-hides `completed` plans
  older than 14 days into a collapsed view (`/librarian plan-index --all` shows them). It
  is a display-only render-time filter — no row moves, no status changes, no archive file.
- Pre-plan ideas live as `{paths.plans_root}/_inbox/<slug>.md` notes (funnel status
  `new / triaged / briefed`).
- In-flight plans are `{paths.plans_root}/<NN>-<slug>/manifest.json` with the canonical
  6-state `lifecycle.status` (`researching / planned / in-progress / paused / completed /
  superseded`).
- Session history lives **with the work item** in the plan dir / master `handoff.md` +
  git — there is NO per-plan progress satellite (: RETIRED entirely; the entire
  satellite-health check class + the old `--fix` skeleton-render + the
  `See [[Logs/...]]` reference regex are GONE, not relocated).

Hygiene reads R-29/30/31/56 + `backlog_row.stale_advisory_days` from the landed
`governance/plans-rules.json`, computes findings, and **delegates** the one mutating
operation it must NOT perform itself:
- **Table regeneration** → `librarian:backlog-index` (recommended, or run `/librarian backlog-index`).

Curly-brace tokens (`{paths.plans_root}`, `{paths.hooks_state}`) resolve at runtime
from `user-manifest.json` via `hooks/lib/paths.sh`.

## Output Contract

**Files written:**
- `{paths.hooks_state}/backlog-hygiene-report.md` — the hygiene report. **Always written**
  (even on "all clear") so consumers (`morning-brief`) have a fresh data point.
- With `--fix` (auto-maintenance, NOT report-only):
  - **auto-flag missing dispositions (R-56)** — in-place adds `disposition: DEFERRED`
    (plus a `## Notes` flag line) to any idea note / `{researching, planned}` manifest
    whose disposition has been missing past `backlog_row.stale_advisory_days[1]` (the
    21d escalation), so the GTD loop has a row to act on. Below 21d it is reported, not
    auto-set.

**Never written:**
- `{paths.plans_root}/_backlog.md` — librarian-owned. Regeneration is delegated to `librarian:backlog-index`.
- No per-plan progress satellite, no skeleton-render, no vault `Logs/` write ().

**Schema:** the report is written outside the vault (no `frontmatter-rules.json#types`
gate). With `--fix`, any frontmatter mutation on an idea note validates against
`governance/plans-rules.json :: inbox.note_frontmatter`; any manifest mutation validates
against `schemas/plan-manifest-schema.json` — on validation failure the change is rolled
back and downgraded to a report-only finding (block-and-log).

**Pre-write validation:**
1. The report is always written to `{paths.hooks_state}`, never to the vault or the plans tree.
2. A `--fix` disposition stamp keeps the note/manifest schema-valid; otherwise it is rolled back (block-and-log).
3. `--dry-run` writes zero files (it suppresses both the report write and `--fix`).

**Failure mode:** **block and log** — the skill aborts on validation failure rather
than writing partial state. On any failure, no files are mutated and the user is told
what went wrong.

## Hard rules

1. **Never regenerate the view; never move rows.** Hygiene flags; it never writes `_backlog.md` and never moves a row. Regeneration is delegated; archival is a display-only plan-index filter (no row ever moves).
2. **Delegate regeneration.** Recommend (or invoke) `librarian:backlog-index`; never reimplement it.
3. **`--fix` is auto-maintenance, not report-only.** It applies exactly one safe operation — auto-flag stale-missing dispositions (R-56). It is NOT the retired skeleton-render and NOT a no-op report.
4. **Dry-run is safe.** With `--dry-run`, the report is produced in memory and zero files are written (no `--fix` mutations either).
5. **Report always written** (unless `--dry-run`). Even on "all clear", so `morning-brief` has a fresh data point.
6. **Date math uses the `updated` frontmatter field** (inbox notes) or `manifest.updated` (plans), not file modification times or git history.

## Invocation

```sh
/backlog-hygiene             # report-only sweep
/backlog-hygiene --dry-run   # preview; write nothing at all
/backlog-hygiene --fix       # also apply safe auto-maintenance (R-56 disposition flag)
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--dry-run` | off | Produce the report only; write zero files (suppresses both the report write and `--fix`). |
| `--fix` | off | Apply safe auto-maintenance: auto-flag missing dispositions past the 21d escalation (R-56). Mutually exclusive with `--dry-run`. |

> Archival is a display-only plan-index view filter (default-hides `completed` plans
> older than 14 days; `--all` shows them). Nothing is promoted, moved, or stamped —
> hygiene never touches archival.

---

## Execution

### 1. Load the backlog substrate + the rules

Read, in order:
1. `governance/plans-rules.json` — extract `_rules[]` R-29/R-30/R-31/R-56 (the lifecycle/disposition contracts this skill enforces), `backlog_row.stale_advisory_days` (`[14, 21]`), `backlog_row.disposition_enum`, `lifecycle.status_enum`, and `inbox.funnel_status_enum`.
2. `{paths.plans_root}/_backlog.md` — the unified rendered view (for cross-referencing rows to sources). Read-only.
3. Every `{paths.plans_root}/_inbox/*.md` idea note — extract `title`, funnel `status`, `disposition`, `updated`.
4. Every `{paths.plans_root}/<NN>-<slug>/manifest.json` — extract `title`, `status`, `disposition`, `updated`.
5. The librarian manifest `drift_findings.backlog_index[]` (if present) — the `backlog-row-missing-disposition` findings emitted by `librarian:backlog-index`. Hygiene is the declared **consumer** + severity-escalator of those findings.

For each item, compute `days_stale = today - updated`.

### 2. Apply funnel + lifecycle staleness rules

**Inbox idea notes** (funnel status):

| Funnel status | Timeout | Trigger | Severity | Recommended action |
|---|---|---|---|---|
| `new` | 7 days | Captured but not triaged | Warning | Run `/backlog-triage --item <slug>`, or remove the note |
| `triaged` | 7 days | Triaged but not researched/graduated | Warning | Run `/backlog-research --promote <slug>` or `/backlog-research <slug>`, or defer with reason |
| `briefed` | 14 days | Brief exists but never graduated to a plan | Warning | Review the note and decide: promote to a plan, defer, or remove |

**In-flight plan manifests** (`lifecycle.status`):

| Status | Timeout | Trigger | Severity | Recommended action |
|---|---|---|---|---|
| `researching` | 3 days | No research output produced | Alert | Check whether the research session failed; restart or defer |
| `planned` | 14 days | Planned but not started | Warning | Confirm still intended; start, defer, or close |
| `in-progress` | 7 days | No file changes in the plan dir | Alert | Check whether blocked; update `manifest.updated`, or close |

**Refinement:** for `in-progress` plans, if the plan directory has recent git activity, the item is moving even though `updated` is old — flag as "needs `manifest.updated` refresh" rather than as stale work.

### 3. Check disposition + lifecycle integrity (R-56)

| Check | Trigger | Severity |
|---|---|---|
| Missing disposition (R-56) | An idea note or `{researching, planned}` manifest has no `disposition` in `backlog_row.disposition_enum`. Escalate by age against `backlog_row.stale_advisory_days`: `14d` advisory → Warning; `21d` escalation → Alert. | Warning → Alert |
| Manifest status orphan | A manifest declares a `status` outside `plans-rules.json :: lifecycle.status_enum` | Error |
| Slug violation | A plan slug does not conform to `slug_rules.pattern`, or an inbox slug carries a `NN-` prefix (violates `inbox.slug_pattern`) | Warning |
| Missing brief | A `briefed` inbox note or a `researching` plan with no `00-ideation-brief.md` at the expected location | Warning |
| Stuck dependency | An item blocked by another whose status is `completed` or `superseded` (dependency resolved; should unblock) | Warning |

Where `librarian:backlog-index` already emitted a `backlog-row-missing-disposition` / `manifest-status-orphan` / `slug-violation` finding (Step 1.5), reuse it and escalate by `stale_for_days` rather than recomputing — hygiene is the severity-escalation consumer.

### 4. Apply `--fix` auto-maintenance (only with `--fix`, never `--dry-run`)

One safe, disposition-rule-sanctioned operation — nothing else is auto-fixed (oversized rows, ambiguous staleness, and conflicts all require judgment and are reported only):

1. **R-56 auto-flag missing dispositions.** For every idea note / `{researching, planned}` manifest whose disposition is missing AND `days_stale ≥ stale_advisory_days[1]` (21d escalation), set `disposition: DEFERRED` in place (and append a `## Notes` flag line on idea notes / record it in the manifest) so the row stops floating and the GTD loop has something to act on. Validate the edited frontmatter before write; roll back + downgrade to report-only on failure.

### 5. Delegate regeneration

Hygiene does NOT regenerate `_backlog.md`. Instead:
- If any inbox note / manifest changed disposition or status (including this run's `--fix` flags) since the last `_backlog.md` regen, recommend (or, interactively, invoke) **`librarian:backlog-index`**.

Surface it as an explicit "Recommended next step" line in the report. Skip when `--dry-run`. (Archival needs no step — the plan-index display filter hides aged `completed` plans automatically at render time.)

### 6. Write the hygiene report

Write `{paths.hooks_state}/backlog-hygiene-report.md` (skip entirely on `--dry-run`):

```markdown
# Backlog Hygiene Report

**Date:** YYYY-MM-DD
**Inbox notes scanned:** N
**Plan manifests scanned:** N
**Issues found:** N
**Auto-fixes applied:** N (only with --fix)

## Flagged items

| Item | Source | Status | Days stale | Severity | Issue | Recommended action |
| ... |

## Disposition + lifecycle issues (R-56 / R-29/30/31)

| Item | Issue | Severity | Detail |
| ... |

## Auto-maintenance applied (--fix)

| Item | Operation | Detail |
| ... |

## Recommended next steps

- Regenerate the view: `/librarian backlog-index` (N rows would change)

## Summary

- Warnings: N · Alerts: N · Errors: N · Info: N
- All clear: Yes/No
```

### 7. Report to the user

```
## Backlog Hygiene Complete

Inbox notes: N · Plan manifests: N
Issues: N (breakdown by severity) · Auto-fixes: N (if --fix)

[Top 3 most urgent items, if any]

Recommended: <`/librarian backlog-index`, if applicable>
Full report: {paths.hooks_state}/backlog-hygiene-report.md
```

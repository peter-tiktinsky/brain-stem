---
title: {{title}} — Spec
type: spec
status: planned
created: {{date}}
updated: {{date}}
---

# {{title}} — Spec

**Status:** {researching | planned | in-progress | on-hold | closed | superseded | archived}
**Created:** {YYYY-MM-DD}
**Parent:** {`plan: parent-plan-id` or `—`}
**Goal:** {One sentence. When this ships, what is true that wasn't true before?}

<!--
SHAPE CONTRACT — governance/file-type-contracts/spec.md.json.
Section order is load-bearing (primacy/recency). IMMUTABLE HEAD: Goal + Problem
Statement + Constraints — if these change the plan is being re-scoped and should
land a new sub-plan, not an in-place edit. MUTABLE TAIL: Solution
Approach + Files Modified + Success Metrics + Risk. Cap ~500 lines (hard 600) → split to
sub-plan. Use tables aggressively (34-38% more token-efficient than JSON). Do NOT repeat
manifest.tasks[] prose here — manifest.json is the canonical task home.
The **Status:** marker is a SINGLE lifecycle.status_enum token (governance/plans-rules.json)
— never a prose paragraph. R-27 emits an advisory if it resolves to more than one token.
Decisions and rationale belong in decisions/ADR-NN-<slug>.md or the Solution Approach
amendment register, not the status line.
-->

## Problem Statement

{2-4 sentences. What's broken, missing, or suboptimal today? Why does it matter now? Frozen at scaffold time; only edited if the plan is fundamentally re-scoped.}

## Constraints

- {Hard constraint — e.g., "Must not break existing digest-run pipeline"}
- {Budget constraint — e.g., "Under $5 per execution"}
- {Scope constraint — e.g., "single-team scope; no cross-org rollout"}
- {Anti-scope lock — what is explicitly OUT of scope}

## Current State

{How does the system work today? Specific file paths, skill names, infrastructure components. Grounds the reader in what exists before proposing changes. Cache-friendly — doesn't change once briefed.}

| File / Component | Role | What Changes |
|-----------------|------|-------------|
| `{path}` | {current role} | {what this plan does to it} |

## Solution Approach

{3-8 sentences. High-level strategy — what are we building, how does it integrate with existing infrastructure? Not a task list — that's in tasks.md. This is where post-Session-1 amendment blocks land.}

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| {e.g., storage format} | {e.g., JSON flat file} | {why this over alternatives} |

## Files Modified/Created

| File | Action | Purpose |
|------|--------|---------|
| `{path}` | New / Modify | {one-line purpose} |

## Success Metrics

| Metric | Target | How to Measure |
|--------|--------|---------------|
| {e.g., execution time} | {e.g., <30s} | {e.g., time the skill invocation} |

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| {risk description} | Low/Med/High | Low/Med/High | {mitigation strategy} |

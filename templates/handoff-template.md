---
title: {{title}} — Handoff
type: handoff
created: {{date}}
updated: {{date}}
---

# {{title}} — Handoff

Append-only session record. Newest entry at top.

<!--
SHAPE CONTRACT — governance/file-type-contracts/handoff.md.json. STRICTLY APPEND-ONLY, NEWEST-FIRST. Never edit
a prior session block — if an earlier claim is later proven wrong, the correction lands as a
NEW block referencing the prior one. New sessions PREPEND a `## Session N — <title>` block
directly below this line. A fresh agent resuming the plan reads ONLY the top block — the
`**Next session:** T-N` line is the load-bearing resume contract. Per-session block target
300-1,500 tokens. Hard cap 50KB → split older sessions to handoff-archive.md.
Section subsections below are the suggested skeleton (handoff.md.json section_subsections);
keep the ones the session populated, drop the rest.
-->

## Session 0 — scaffold

**Date:** {{date}}
**Next session:** T-1 — {first task title}

### Scope
{What this session set out to do.}

### Decision-Quality Protocol passes
{Any DQP fork decided this session — option set + recommendation + rationale. Omit if none.}

### Locks captured
{Decisions/constraints locked this session.}

### Spec deltas
{Any spec.md amendments or re-scopes. Omit if none.}

### Files modified
| File | Change |
|------|--------|
| `{path}` | {created / modified section X / deleted} |

### Follow-up dispositions
{Close-out follow-ups, each with one disposition: FIX NOW / ABSORB / STANDALONE. Omit if none.}

### Memories saved
{Auto-memory entries written this session. Omit if none.}

---

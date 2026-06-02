---
title: {{title}} — Tasks
type: tasks
status: planned
created: {{date}}
updated: {{date}}
---

# {{title}} — Tasks

**Spec:** `{{plan_dir}}/spec.md`
**Last Updated:** {{date}}

## Status Key

`not-started` | `in-progress` | `done` | `blocked` | `cut`

<!--
SHAPE CONTRACT — governance/file-type-contracts/tasks.md.json.
Structure = ledger-at-top + per-task-at-bottom. The ledger is the primacy slot (at-a-glance
state of the whole plan in <50 lines); per-task blocks are ordered by Depends-on so the
current/next-up task sits at the bottom (recency effect). Task IDs use the T-N format
(T-1, T-2, T-3.5 …) per task_id_pattern ^T-[0-9]+(\.[0-9]+)?$ and are IMMUTABLE once
published. R-37 LOCKSTEP: ledger row count == manifest.tasks[] length; status flips sync via
<!-- task-done: NN/T-M --> sentinels. Per-task Description 200-800 tokens (under 200 = the
agent re-explores; over 800 = context rot). File References are absolute paths, no exceptions.
-->

## Task ledger

| ID | Title | Status | Depends on | Notes |
|----|-------|--------|-----------|-------|
| T-1 | {verb-first title} | not-started | — | {one-line} |
| T-2 | {verb-first title} | not-started | T-1 | {one-line} |

---

## Tasks

### T-1: {Verb-first title — e.g., "Create parser for inbox files"}

**Status:** not-started
**Dependencies:** none
**Description:** {2-4 sentences. What to build, why it matters, how it fits the overall solution. 200-800 tokens.}

**File References:**
- `{/abs/path/to/file1.md}` — {why: read for schema, modify to add X, create new}
- `{/abs/path/to/file2.py}` — {why}

**Acceptance Criteria:**
- [ ] {Verb-first. e.g., "Parse all 6 Inbox file types without error"}
- [ ] {Verb-first. e.g., "Write output to correct vault location per routing rules"}
- [ ] {Verb-first. e.g., "Preserve existing data — no overwrites of historical entries"}

---

### T-2: {Verb-first title}

**Status:** not-started
**Dependencies:** T-1
**Description:** {2-4 sentences.}

**File References:**
- `{/abs/path}` — {why}

**Acceptance Criteria:**
- [ ] {Verb-first}
- [ ] {Verb-first}

---

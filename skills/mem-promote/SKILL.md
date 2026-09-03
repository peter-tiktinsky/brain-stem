---
name: mem-promote
description: >
  Propose promotions of claude-mem (System B) observations into the curated file-memory corpus
  (System A): gather, MECE-reshape, route semantic conflicts, then propose-then-confirm
  through the memory review queue. NEVER auto-writes. Use for "/mem-promote" or "mem-promote".
type: skill
---

# /mem-promote — System B → System A pre-promotion pipeline

Bridges claude-mem's automatic wide-net recall (System B, archival tier) into
the curated, always-loaded file-memory (System A, core tier). This is **Gate 1**
of the two promotion gates: **PROPOSE-THEN-CONFIRM ONLY.
There is no auto-commit toggle, ever.** The destination is trusted and
always-in-context, so an unattended write is the self-output → trusted-memory
poisoning loop (MINJA >95% ASR; ASB 84.3%) — the defense is that nothing lands
without explicit operator confirmation.

> Standalone skill: mem-promote is its own top-level skill, separate from the
> librarian capability set. The librarian's other memory
> capabilities (globalize / hygiene / staleness) are separate.

## What it does NOT do

- It does **NOT** write memory files. No `--apply`, no `--auto`, no auto-commit
  surface of any kind. The pipeline only **buffers proposals** into the memory
  review queue (`hooks/lib/review-queue.sh::enqueue_item`); the operator
  confirms or rejects-with-reason via `/librarian review`.
- It does **NOT** resolve conflicts. A genuine semantic contradiction emits a
  distinct **CONFLICT artifact** surfaced side-by-side; it is never auto-resolved.
- It does **NOT** require claude-mem. When the System-B DB is absent it is
  dead-but-harmless (see Degradation).

## Pipeline

### 1. Gather (no new embedding infra)
The curated `*.md` tier is unembedded (only claude-mem observations carry Chroma
vectors); a vector index over it is deferred. Recall is two-channel:

- **Shell prefilter (`scripts/prefilter.sh`):** reads claude-mem observations
  for the named session(s), clusters them by Jaccard token overlap, and
  de-conflicts each cluster against the curated `memory/*.md` file set. The
  capture floor is **widened to Jaccard ≥ 0.20** and each candidate carries up
  to **≤ 8 ranked neighbors** (the widened gather floor).
  Jaccard scores are **inputs, not the decision**.
- **LLM semantic read (this skill, Claude-reasoned):** read the `MEMORY.md`
  index AND `MEMORY-archive.md` (when it exists) as the semantic channel —
  closing the recall gap the cold-spill seam would otherwise open. The shell
  scores are a prefilter; the classification below is LLM-reasoned.

### 2. MECE reshape (Mem0 A.U.D.N. adapted + NARROW)
For each candidate, classify against the de-conflicted neighbors:

- **ADD** — novel; no curated memory covers it → propose a new file.
- **MERGE-INTO** — same subject as an existing memory, complementary → propose
  an edit folding the new content in.
- **NARROW** — overlaps an existing memory in part; trim the overlapping span
  and **promote only the residual** (the MECE primitive).
- **NOOP** — already fully covered → drop (no proposal).
- **SUPERSEDE** — a newer correct state of an existing memory → propose the
  tombstone-with-pointer pair (`B.supersedes=A`, `A.superseded_by=B`).

**No DELETE.** Retain-don't-delete is invariant.

### 3. Conflict detection + routing (semantic, NOT token overlap)
A *direct conflict* = the candidate asserts ¬P about subject S where a curated
memory asserts P. This is a **semantic** judgment, not token overlap.

- Unambiguous newer-state → a **SUPERSEDE** proposal.
- Genuine contradiction → a distinct **CONFLICT artifact** (class `conflict`,
  severity `high`) surfaced side-by-side for the operator's decision. **Never
  auto-resolved.** A high-severity CONFLICT is the only review class that may
  reach the Stop-block — and even then it yields to the R-26 checkpoint
  Stop-block + the ≥80% context-pressure valve.

### 4. Proposal artifact → review queue
Each proposal is buffered (NOT applied) via `enqueue_item` with the artifact:

```
{ candidate_id, subject, classification,
  deconflicted_against[], reshaped_memory?, narrowed_out?, conflict?,
  provenance: { source: "claude-mem", source_observation_id } }
```

mapped onto the review-queue item shape (`id`, `severity`, `state: "open"`,
`class`, `defer_count: 0`, `dismiss_count: 0`, `payload`). The operator clears
each item only on explicit confirm OR reject-with-reason via `/librarian review`.

## Degradation (no-claude-mem-DB graceful-degradation contract)
The foundation floor is complete from System A + Gate 2 (globalize) + RULES
alone; **System B is strictly additive.** When the claude-mem SQLite+Chroma DB
at `~/.claude-mem/` is **absent**, Gate 1 is **dead-but-harmless**:

- DB absent → **0 candidates → clean exit, status `n/a`** (not an error, not a
  non-zero exit). `scripts/prefilter.sh` prints `status=n/a candidates=0` and
  exits 0.
- System A, Gate 2 globalize (A→RULES), and RULES remain fully operational.
- No hard dependency on System B anywhere in the pipeline.

## Invocation

```
/mem-promote                              # current-session scope (when a DB exists)
scripts/prefilter.sh --session <jsonl>    # explicit session(s); repeatable
scripts/prefilter.sh --dry-run            # summary counts only; no enqueue
```

## Output Contract

- **Files written:** appends proposal/conflict items to `.review-queue.json`
  (via `hooks/lib/review-queue.sh::enqueue_item`); a sidecar log line per
  enqueue at `.review-queue-log.md`. **Never** writes `memory/*.md` files.
- **Schema:** items validate against `schemas/review-queue-schema.json`; the
  proposal payload carries the artifact shape above.
- **Pre-write validation:** `enqueue_item` validates each item against the
  queue schema before append (required-field gate + optional schema-conformance
  gate when a validator is present).
- **Failure mode: block-and-log.** An invalid item is REFUSED and logged — never
  written. A missing System-B DB degrades to status `n/a` (0 candidates), never
  a partial/poisoned write.

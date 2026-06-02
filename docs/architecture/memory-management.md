# MEMORY.md load guard + cold-spill seam

> **For the memory *model* — the triad (Semantic / Procedural / Episodic), project-vs-global memory, and the three accessibility layers — see `memory-model.md`. This doc is the load-guard *mechanics* deep-dive.** **Audience:** foundation authors plus adopters who want to understand WHY the `MEMORY.md` auto-loaded index is byte-capped, how the load guard reads and enforces that cap, and how the documented cold-spill seam keeps the index bounded without losing recall. Two phrases recur below: the **UNDERSTAND surface** (a plain-English document a *human* reads to grasp the rule — this doc) and the **APPLY surface** (the machine-readable record the *assistant* reads to enforce the rule per save). **Canonical for:** the byte-first load contract, the both-raw-and-stripped counting rule, the record-only budget monitor ("Check 8"), the cold-spill overflow-routing rule, and the fixed section order. **This is the UNDERSTAND surface;** the APPLY surface the assistant reads per-write is the load-contract slot inside the shipped governance bundle at `~/.claude/governance/foundation-master.json :: mandatory_files.mandates._memory_md_cap`.

---

## What `MEMORY.md` is and why it is byte-capped

Claude Code is a tool that runs an AI assistant inside your terminal. By default the assistant forgets everything between work sessions — each new conversation starts blank. To stop that, the system keeps a small set of plain-text notes on disk: **one short note file per topic** (your preferences, project facts, lessons learned from past mistakes), plus a single **index file called `MEMORY.md`** that lists them all. The shape and meaning of those notes — the memory model — is the subject of the sibling doc; here we care only about one thing: keeping the index small enough to actually load.

At the start of every new conversation, the tool automatically reads that **one** index file into the assistant's working context — and even then it reads only the **first 200 lines OR the first 25KB, whichever comes first**.

"25KB" means 25 kilobytes — a measure of file size. One typed keyboard character is roughly one byte, so 25KB is about 25,000 characters (25,600 bytes, to be exact). Anything past that point — the 201st line, or the byte after the 25,600th — is **simply not read**. There is no error, no warning, no "…truncated" marker. It is just absent.

That is the **silent cut**, and it is the problem this whole document exists to manage: the bottom of an over-long index becomes invisible to the assistant, and you would never know unless you measured the file yourself. This behaviour is documented by Anthropic at `code.claude.com/docs/en/memory`.

### Why the cap applies to the index, not the detail files — the "read-replica" framing

Borrow an idea from databases: a **read-replica** is a lightweight copy kept for fast lookup, not the full record. `MEMORY.md` is exactly that — the table of contents. Each line is one short pointer ("here is the rule, here is where the detail lives"), and the full explanation sits in a separate per-topic note file.

The index must stay inside the load contract (200 lines / 25KB). The detail files do **not**, because they are read **on demand** — only when the assistant actually needs that topic. Because the auto-loaded index is a single file (there is no multi-file *loaded* split — `MEMORY.md` does not support an `@import`-style include), the only realizable structure is one hot-loaded `MEMORY.md` index plus cold, on-demand topic files: the progressive-disclosure pattern. The load cap therefore bites on the index alone, which is precisely why the index must be kept lean.

---

## The byte-first load guard

A **guard** here is an automatic check that runs the moment you save a file — think of it as a spell-checker that flags a problem and lets you keep typing, not a wall that stops you. This particular guard watches each project's `MEMORY.md` index and, when a save would push the index over the documented limits, it prints a plain-language warning naming which limit was crossed and the file's actual current size — then **lets the save go through anyway**. It is **advisory**: it warns but does not stop you. It never blocks an adopter from saving a memory.

The guard is scoped precisely: it fires only on a Write or Edit to a per-project memory **index** — a file at `~/.claude/projects/<project>/memory/MEMORY.md` (one such index exists per project that has memory). Writes to the per-topic detail files in that same `memory/` directory, and writes to any other file, are not checked by this rule.

All of its thresholds come from a **single configuration source** — the load-contract slot inside the shipped governance bundle at `~/.claude/governance/foundation-master.json :: mandatory_files.mandates._memory_md_cap.thresholds` — so the write-time guard, the budget monitor, and this document never drift apart.

| Threshold | Value | Role |
|---|---|---|
| `max_bytes` | 25600 (25KB) | **Governing trigger** — bites first |
| `max_lines` | 200 | Secondary early-warning signal |
| `max_chars_per_line` | 200 | Secondary early-warning signal (per line) |

**The byte cap is the governing trigger** because it is the limit reached first. A "fact-first" index — one short, dense line per topic — reaches 25KB before it reaches 200 lines, at roughly 110 entries. (That ~110-entry figure is illustrative, drawn from experience; the only published contract is the 200-line / 25KB rule itself.) The guard gates primarily on the byte cap; the line count and per-line length are secondary signals layered on top to catch drift before the byte cap is reached.

### What the write-time guard checks — a flat exceed-check

The write-time guard runs a **flat threshold check** at the moment of saving: it measures the about-to-be-saved index three ways and warns if **any one** of the three caps is exceeded —

- more than 200 lines, **or**
- more bytes than the byte cap (25,600), **or**
- one or more lines over 200 characters.

It does **not** grade the warning by how close you are — there are no "you're at 80% of the cap" percentage bands here. It is a plain over/under check: under all three caps, silence; over any one, a single advisory warning that names the breached cap(s), the actual value(s), and a remediation pointer (move detail into per-topic files; trim to ≤200-character one-line entries). The write proceeds either way. The graded percentage bands described below are a *separate* mechanism that lives in the after-session budget monitor, not in this write-time check.

---

## The escalation bands live in the budget monitor, not the write-time guard

A second, separate piece of machinery — the **budget monitor**, which runs *after* a session ends rather than at save time — reacts to the index size in **graded steps** as it grows. Its budget check stays **record-only**: it writes a status line to its own log and never edits, deletes, or prunes anything in response to a size breach.

| Band | Trigger | Behaviour |
|---|---|---|
| **Green** | Below 75% of the byte cap (and no over-length lines) | Records a GREEN status. The index has comfortable headroom. |
| **Yellow** | At 75%–89% of the byte cap | Records a YELLOW status. This is the band where you should start moving cold content out — the cold-spill seam (below) is the documented remediation. |
| **Red** | At or over 90% of the byte cap, **or** any single line over the 200-character cap | Records a RED status in its log so the breach is observable. It does **not** auto-delete or auto-prune anything in response to the size breach; remediation is the operator-driven cold-spill seam (below). |

A note on what RED does and does **not** do: the budget check **records** the budget status (GREEN / YELLOW / RED) in its consolidation log — it never deletes a topic file, never removes a *live* index line, and never edits your curated content in response to a size breach. There is **no automatic deletion of curated memory** here: a too-large index is surfaced for a human to trim via the propose-only cold-spill seam (below), not pruned automatically.

One bounded exception belongs to a **different** check in the same after-session run, and it is purely a consistency repair, not a content prune: the monitor's index-accuracy pass removes a *dead* index reference — a line in `MEMORY.md` that points to a topic file which **no longer exists on disk** — and records the count as "Dead references removed" in the consolidation log. It only deletes the now-broken pointer line, never a real memory; it deletes nothing whose target file is still present. So the accurate statement is: no curated content is ever auto-deleted, and the only automatic removal is of pointer lines whose target file is already gone.

Why both the write-time guard and the budget check are advisory/record-only and never blocking: the design treats the cap as a *drift signal to surface*, not a wall to throw. Over-blocking a legitimate save is worse than a too-long index a human can trim.

### Count both raw and comment-stripped; gate on the larger — a budget-monitor rule

This rule belongs to the **budget monitor's Check 8**, not the write-time guard. (The write-time guard, above, does a plain line/byte/char count with no comment handling; only the after-session monitor does the two-way measurement described here.)

`MEMORY.md` can contain HTML-style comment blocks — text wrapped in `<!--` and `-->` that humans use for side-notes but that does not display as normal content. This creates a loophole: someone could hide bulky content inside comments to dodge a naive size check, even though that hidden text could still cost the assistant load-time budget at session start.

To close that loophole, the budget monitor measures the file **two ways** — once counting everything ("raw"), and once with the comment blocks removed ("stripped") — and acts on whichever **line** count is **bigger**. "Gate on the larger" simply means: use the worse of the two measurements (the **gate** is the value the check decides on), so comments can never buy free headroom. Concretely: a 300-line index where 150 lines are commented out might slip past a raw-line check after stripping, yet still cost budget — so the monitor uses the larger measurement and flags it.

(The byte count is taken on the raw file. The both-raw-and-stripped rule applies to the **line** count, where commented-out content could otherwise hide. This conservatism is deliberate: Claude Code *may* strip block-level HTML comments out of some auto-loaded files before injecting them into context, but that stripping is **not** documented for `MEMORY.md` specifically — so the monitor does not assume comments are free.)

---

## The two pieces of installed machinery that read the same cap

Two installed scripts consume the load guard, and both read the **same** single configuration slot, so they can never drift apart.

- `~/.claude/hooks/pre-write-guard.sh` — **the write-time check.** It runs as a **PreToolUse hook**: the Claude Code harness fires it automatically *just before* an Edit or Write to a file lands on disk, so the check happens in the moment of saving. (A "hook" is a small script the system runs automatically at a set moment without you asking; the PreToolUse event is documented at `code.claude.com/docs`.) It fires only when the file being saved is a per-project memory index at `~/.claude/projects/<project>/memory/MEMORY.md`; for that save it runs the flat exceed-check (lines / bytes / per-line length), emits the advisory warning if any cap is exceeded, and lets the write proceed. It does **no** comment-stripping and uses **no** percentage bands — those belong to the budget monitor. It reads the byte cap from the foundation-master bundle slot via `CLAUDE_HOME`, single-sourced on adopters; the hardcoded 25600 is a fallback only if the slot is ever unreachable. This is the per-write APPLY path.
- `~/.claude/hooks/memory-consolidation-run.sh` — **the budget monitor (its "Check 8").** It runs detached after a session ends. It computes the raw line count, the byte count, the char-per-line count, **and** a comment-stripped line count; it takes the effective line count as the **larger** of raw versus stripped, and gates the breach percentage on the **larger** of the byte ratio and the line ratio, with the byte cap governing. It then **records** the resulting GREEN / YELLOW / RED budget status in its consolidation log. The budget check itself **never** auto-deletes a topic file, never removes a *live* index line, and never edits curated content — it is record-only. (A separate index-accuracy pass in the same run removes only *dead* pointer lines whose target file is already gone — see the budget-monitor section above.) It reads the cap from the same bundle slot (through `~/.claude/hooks/lib/foundation-overlay-load.sh`, the shared bundle reader) with the documented numbers as a fall-back only. It uses a kernel-level lock (`/usr/bin/lockf`, a built-in macOS tool) so only one instance ever runs at a time, with no stale-lock cleanup needed.

### The session-end gate that decides whether Check 8 even runs

The budget monitor does **not** run on every session close. A fast gate — `~/.claude/hooks/memory-consolidation-check.sh`, which must finish in under 100ms — decides. It spawns the detached monitor only when **at least 24 hours AND at least 5 sessions** have passed since the last run. (The SessionEnd event that fires this gate is documented at `code.claude.com/docs`.) This keeps the background work rare and cheap.

The gate respects an opt-out. The toggle lives in the adopter's user manifest at `~/.claude/user-manifest.json` — the field `behavioral.hook_preferences.memory_consolidation_enabled`, set to `false`. (The manifest is written during onboarding by the `/onboard` flow; consolidation is enabled by default, so the only way it is off is an explicit `false`.) On opt-out the gate writes a `## Skipped` line to the audit log — so the *absence* of a run is observable rather than silent.

---

## The fixed section order — why it makes cold-spill possible

The index is organized into three sections in a **fixed, unchanging order**: `## Semantic`, then `## Procedural`, then `## Episodic`. (What each section *holds*, and why that order, is defined in `memory-model.md`. The load-guard mechanics depend only on the order being **locked** — not on what the names mean.)

Because the order never changes, the **cold boundary** — where the least-likely-to-be-needed content lives — is always at a known place: the **tail of the coldest non-episodic section**, which is Procedural first, then Semantic. That is exactly what the future auto-spill will relocate.

The `## Episodic` section is the only one that grows without bound from ordinary use, so it is the **sampled / windowed** section (the newest ~10 entries plus a `glob memory/episode_*.md` pointer to the rest), and it is **never** cold-spilled — sampling already keeps it small.

This locked order ships in the index template at `~/.claude/templates/MEMORY.md.template`, which is seeded lazily into a project's memory directory the first time a project needs an index by `~/.claude/hooks/memory-seed.sh` (no-clobber: an existing `MEMORY.md` is preserved unconditionally). So the cold boundary is knowable from the very first index.

---

## The cold-spill seam — documented only, not yet built

A **seam** here is a planned joint where a future capability will attach. The overflow-routing rule is written down now even though the machinery is not built yet — because writing it down is cheap, and the structure it depends on (the fixed section order above) must be true from day one, so the future machinery drops into a fully-specified surface without re-deciding anything.

**The overflow-routing rule.** When the index approaches the byte cap (the yellow band), the **coldest non-episodic entries** get relocated to a separate on-demand file, `MEMORY-archive.md`, leaving **one pointer line** in the index where they were. The index stays inside the load contract; the moved facts stay on disk, one hop away.

**The fixed section order makes the cold boundary knowable.** Because the order is locked at `## Semantic → ## Procedural → ## Episodic`, the spill always pulls from the tail of the coldest non-episodic section — Procedural first, then Semantic — and never from Episodic (which sampling already keeps small).

Be explicit: this section describes an **intended behaviour, not running code.** The routing rule and its invariants are locked; the spilling itself is deferred.

---

## `MEMORY-archive.md` is deliberately not created yet

`MEMORY-archive.md` is **not created** by the foundation install, and no hook auto-spills into it. This is deliberate: creating an empty archive before anything needs it would add a confusing, empty file.

The trigger to build the auto-spill machinery is **volume-gated** — built only when a real index actually gets close to the limit — and explicitly **not** time-based. ("Wait 30 days"-style calendar triggers are treated as arbitrary; the signal that matters is the index actually approaching the cap.)

The configuration record reflects this honestly: the `overflow_routing` block inside the bundle slot at `~/.claude/governance/foundation-master.json :: mandatory_files.mandates._memory_md_cap.overflow_routing` carries `archive_created: false` and `auto_spill: "v-next (volume-gated)"`, alongside `archive_target: "MEMORY-archive.md"` and the locked `fixed_section_order`. Plain takeaway: **do not create `MEMORY-archive.md` until the index genuinely demands it.**

---

## Closing the recall gap the cold-spill would open

"Recall" means the assistant's ability to find a fact when it needs one. Moving facts out of the auto-loaded index into the archive would, on its own, open a **recall gap**: those archived facts are no longer in the assistant's session-start context. If a de-duplication step then ran against the live index alone, it could re-propose a fact that had merely been archived.

The design closes that gap deliberately. The promotion pipeline at `~/.claude/skills/mem-promote` reads **both** the live `MEMORY.md` index **and** `MEMORY-archive.md` (when it exists) during its gather / de-duplication step — so it never proposes a duplicate of an archived fact. The cold-spill seam and this dual-surface read are designed **together**: spilling never silently removes a fact from the de-duplication step's view.

This is the one place the load-guard mechanics touch the wider memory pipeline. The pipeline's own internals — how it classifies, how it proposes-then-confirms, how it degrades when the optional recall plugin is absent — belong in `memory-model.md`, not this mechanics deep-dive.

---

## Single config source, no drift

All of the guard's thresholds come from **one shipped configuration record**, so the write-time guard, the budget monitor, and this document never disagree. That record is the load-contract slot inside the composed governance bundle the adopter receives: `~/.claude/governance/foundation-master.json :: mandatory_files.mandates._memory_md_cap`. Both consumer scripts read the cap from that slot (with the documented 25KB / 200-line / 200-char numbers baked in **only** as a fall-back if the slot is ever unreachable).

This is the single-source-of-truth discipline: humans read **this doc** to UNDERSTAND (grasp the rule); the assistant reads the **JSON slot** to APPLY the cap per write (enforce it).

---

## See also

The human-readable narrative companions to the governance pillars ship under the adopter vault at `System Governance/`. What the foundation install seeds there is the folder itself plus its `_index.md` catalog; this architecture doc is the docs-site UNDERSTAND surface for the load-guard mechanics. For the memory *model* — the triad, project-vs-global memory, and the accessibility layers — see `memory-model.md`.

---

## References

These are the installed artifacts that implement and back this document.

- `~/.claude/governance/foundation-master.json :: mandatory_files.mandates._memory_md_cap` — **the APPLY surface.** The load-contract slot inside the shipped, composed governance bundle. Carries the thresholds (`max_bytes` 25600, `max_lines` 200, `max_chars_per_line` 200, `governing_trigger` = bytes), the `line_count_method` (count both raw and stripped; gate on the larger), and the `overflow_routing` block (`archive_created: false`, `archive_target: MEMORY-archive.md`, `auto_spill: v-next (volume-gated)`, the locked `fixed_section_order`). Both consumer hooks read the cap from this slot. *The JSON is what the assistant reads per-write; this doc is what humans read to UNDERSTAND.*
- `~/.claude/hooks/pre-write-guard.sh` — the write-time advisory (a PreToolUse hook on Edit/Write — fires just before the save lands). Scoped to per-project memory indexes (`~/.claude/projects/<project>/memory/MEMORY.md`). Runs a **flat exceed-check** on lines / bytes / per-line length; emits the breach warning + remediation if any cap is exceeded, then lets the write proceed. Does **no** comment-stripping and uses **no** percentage bands. Reads the byte cap from the bundle slot via `CLAUDE_HOME`; 25600 is a fallback only.
- `~/.claude/hooks/memory-consolidation-run.sh` — the budget monitor (its "Check 8"): byte-first, both-raw-and-stripped, gate-on-larger; this is the script that owns the GREEN (<75%) / YELLOW (75–89%) / RED (≥90% or any over-length line) **percentage bands** and the comment-stripping rule. Its budget check **records** the status in the consolidation log and prunes no curated content; a separate index-accuracy pass in the same run removes only *dead* pointer lines whose target file no longer exists ("Dead references removed"). Reads the cap via `~/.claude/hooks/lib/foundation-overlay-load.sh`; single-instance via `/usr/bin/lockf`.
- `~/.claude/hooks/memory-consolidation-check.sh` — the under-100ms session-end gate that decides whether the budget monitor runs at all (≥24h AND ≥5 sessions; opt-out via `behavioral.hook_preferences.memory_consolidation_enabled: false` in `~/.claude/user-manifest.json` writes a `## Skipped` audit line so absence-of-runs is observable).
- `~/.claude/hooks/lib/foundation-overlay-load.sh` — the bundle reader the budget monitor routes through to query the load-contract slot; falls back to the documented defaults when the bundle is unreachable.
- `~/.claude/templates/MEMORY.md.template` — the starter index template carrying the locked `## Semantic → ## Procedural → ## Episodic` section order and an HTML-comment header stating the load contract.
- `~/.claude/hooks/memory-seed.sh` — lazily copies the template into a project's memory directory the first time it is needed (no-clobber; always exits 0), so the locked section order is present from day one.
- `~/.claude/skills/mem-promote` — the promotion pipeline whose gather / de-duplication step reads BOTH the live `MEMORY.md` index AND `MEMORY-archive.md` (when it exists), closing the recall gap the cold-spill would otherwise open. Referenced here only for that dual-surface read.
- Anthropic docs: `code.claude.com/docs/en/memory` — the external documentation of the load contract (first 200 lines OR first 25KB, whichever comes first; entries past the cap silently drop), and the research-backed source for the entire load-guard premise.
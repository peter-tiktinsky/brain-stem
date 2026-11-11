---
name: session-checkpoint
description: Write the current session state to the per-session checkpoint.md in the Session Continuity Block schema (atomic, idempotent, blocks until written). Invoked via /session-checkpoint or by context-pressure enforcement (R-26). Use when context pressure approaches limit, before long tool chains, or when the user requests a handoff snapshot.
disable-model-invocation: false
argument-hint: "[optional: explicit blocker or context note to include]"
---

# /session-checkpoint — Write Session Continuity Block

Your job: capture the live session state into `$CLAUDE_STATE_ROOT/sessions/<sid>/checkpoint.md` (per-session canonical path; `<sid>` is the resolved session id `${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}`) in a single atomic write, using the Session Continuity Block schema. This skill is load-bearing for context-pressure enforcement (rule R-26 in the S1 governance rule register; the rule's provenance lives in the JSON rules-index, not a markdown enforcement map). Failure mode is **block and log**: every required field must be populated or explicitly marked `[MISSING]`.

---

## Output Contract

**Files written:**
- `$CLAUDE_STATE_ROOT/sessions/<sid>/checkpoint.md` — single canonical "current session state" file PER SESSION (where `<sid>` is the resolved session id `${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}`). Overwritten atomically on each invocation. `$CLAUDE_STATE_ROOT` resolves through the two-root XDG tier (paths.sh); the legacy bare path under the install root was retired (cross-session-pollution incident class closure).

**Schema:** Session Continuity Block, keyed fields (the 10-field block below). The flat scalar lines `plan_id`/`phase`/`task_id` are a binding invariant (see Checkpoint file contract).

**Pre-write validation:**
1. All 10 required fields must be present in the output (populated OR marked `[MISSING]`).
2. Write via temp-file + `mv` for atomicity.
3. After write, `stat` the file to confirm mtime is within 5 seconds of now.

**Failure mode: block and log.**
- If a field cannot be determined (no active plan, no task list, etc.), write the literal string `[MISSING]` — do NOT silently skip the field.
- If the write itself fails (permission, disk), surface the error to the user immediately. Do not continue silently.
- Never produce a checkpoint without all 10 field keys present.

---

## Required fields (10)

| # | Field | How to populate |
|---|---|---|
| 1 | `plan_id` | Active plan slug from `~/.claude-plans/` (the plan you're currently executing). If no plan, `[MISSING]`. |
| 2 | `phase` | Current phase number/name within the plan. If no phases, `[MISSING]`. |
| 3 | `task_id` | Current task ID and status. Pull from TaskList if active; otherwise narrative from conversation. If none, `[MISSING]`. |
| 4 | `completed_steps` | Concrete list of steps/tasks completed *this session*. One per line. If none yet, `[]`. |
| 5 | `files_modified` | Files you've Edit/Write-touched this session (absolute paths). If none, `[]`. |
| 6 | `key_decisions` | Architectural/design decisions reached. One bullet each. If none, `[]`. |
| 7 | `next_steps` | Ordered list of what to do next on resume. Cold-start-readable — no shorthand. `[MISSING]` only if genuinely unknown. |
| 8 | `ac_status` | Acceptance criteria checklist from the plan (done/pending per item). If no AC defined, `[MISSING]`. |
| 9 | `current_blocker` | Current error, test failure, or blocker. Empty string `""` if none — not `[MISSING]`. |
| 10 | `context_pct_at_checkpoint` | Integer percent read from `$CLAUDE_STATE_ROOT/sessions/<sid>/context-pressure.json` `.pct` field at write time (per-session canonical path; `<sid>` is the resolved session id `${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}`). If file missing, `[MISSING]`. |

**Do not invent content.** `[MISSING]` is honest; fabrication breaks cold-start recovery.

---

## Procedure

The mechanical steps are one command, `checkpoint-gather.sh`, that ships beside this skill. You write the nine session fields; the command resolves the per-session directory, reads the context pressure, writes the block header and the `## Action Required` tail, validates the fields, writes the file atomically and verifies the result. It sources `paths.sh` itself, the same single source of truth the hooks use, so the dir it writes is the **exact** dir the readers (`stop-checkpoint-check.sh`, `pre-compact-checkpoint.sh`, `session-register.sh`) and the writer (`prompt-context.sh`) resolve. Each Bash tool call is a fresh shell, so run the command in one call.

What the command resolves, for reference (it is not a step to run):

```bash
CKPT_DIR="$CLAUDE_STATE_ROOT/sessions/$SID"   # binding root: / 
```

The session id resolves env-then-env as `${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}` (the harness exports `$CLAUDE_CODE_SESSION_ID` into Bash-tool subshells; `$CLAUDE_SESSION_ID` is the test-injection seam). If **both** are empty the command refuses rather than write: an empty `<sid>` collapses `sessions/<sid>/` to `sessions/` and overwrites a single shared file (the cross-session-corruption class). When the Stop-gate message names the exact `sessions/<sid>/checkpoint.md` path, pass that path verbatim as `--path` after the script name; the command then does not consult the session id.

### Step 1 — Gather the fields

Use the conversation history as your primary source. Check TaskList if you've been tracking work. If you know the active plan, read its spec briefly for phase/AC if needed. **Do not spawn research agents** — this skill must complete in under ~15 seconds. You write nine of the ten fields; the command supplies `context_pct_at_checkpoint` from the per-session pressure file (`[MISSING]` when the file is absent or holds no integer).

### Step 2 — Run the command

Run it once, with the nine fields as the heredoc body. The quoted delimiter keeps `$` and backticks in the fields literal. The body is the Template below minus its four header lines and its `## Action Required` tail, in the same shape. Cold-start-readable — a fresh Claude session must be able to resume from this file alone.

```bash
bash "${CLAUDE_HOME:-$HOME/.claude}/skills/session-checkpoint/checkpoint-gather.sh" <<'EOF'
plan_id: <value or [MISSING]>
phase: <value or [MISSING]>
task_id: <value or [MISSING]>

## completed_steps
- <item>
- <item>

## files_modified
- <absolute path>
- <absolute path>

## key_decisions
- <decision + one-line rationale>

## next_steps
- <ordered action>
- <ordered action>

## ac_status
- [x] <done item>
- [ ] <pending item>

## current_blocker
<blocker description or empty>
EOF
```

The command refuses — exit status 2, a line starting `checkpoint-gather: refused:` on stderr, nothing written — when a field is missing, appears twice or is empty (write `[MISSING]` or `[]`, never a blank), when the session id cannot be resolved, when `--path` is malformed, when a field text carries a line the command writes itself (the header lines or `## Action Required`), or when nothing arrives on stdin. Read the refusal line, fix what it names and run the command again. Exit status 1 with a line starting `checkpoint-gather: write failed:` or `checkpoint-gather: verify failed:` means the file did not land: surface the error to the user immediately.

On success the command prints exactly one line, `checkpoint-gather: wrote <path> (context_pct_at_checkpoint: <pct>)`, after confirming the file exists, is non-empty and has an mtime within 5 seconds of now. Report that line to the user in one line.

---

## Template (exact format)

```markdown
# Session Continuity Block
**Generated:** <ISO 8601 UTC timestamp>
**Source:** /session-checkpoint skill — manual or enforcement invocation
**context_pct_at_checkpoint:** <pct or [MISSING]>

plan_id: <value or [MISSING]>
phase: <value or [MISSING]>
task_id: <value or [MISSING]>

## completed_steps
- <item>
- <item>

## files_modified
- <absolute path>
- <absolute path>

## key_decisions
- <decision + one-line rationale>

## next_steps
- <ordered action>
- <ordered action>

## ac_status
- [x] <done item>
- [ ] <pending item>

## current_blocker
<blocker description or empty>

## Action Required
- Resume from this checkpoint in a fresh session
- Re-read files listed under files_modified before continuing edits
- Verify next_steps still valid against current plan state
```

The flat scalar lines `plan_id:` / `phase:` / `task_id:` (each `^[a-z_]+: .+$`) are a **binding invariant** — the header plus ≥3 of these lines is what marks a checkpoint *rich*, and a rich checkpoint is preserved at **any age**. Two hooks write this same file besides you: `pre-compact-checkpoint.sh` (mechanical extraction) and `prompt-context.sh` (the passive 35% context-pressure capture). Both count these lines through one shared helper, `hooks/lib/checkpoint-guard.sh`, and neither overwrites a model-authored block that carries them. Provenance is the one exception: a block carrying the mechanical provenance line `**Source:** PreCompact hook — mechanical extraction` is a refreshable snapshot and is never rich, so the next compaction rotates it and extracts afresh instead of re-injecting a stale snapshot. Keep them flat scalar lines — they are what protects your output.

---

## Checkpoint file contract

`$CLAUDE_STATE_ROOT/sessions/<sid>/checkpoint.md` is the single canonical "current session state" pointer PER SESSION (where `<sid>` is the resolved session id `${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}`). **Do not create dated variants from this skill.** Dated files (`sessions/<sid>/checkpoint-YYYYMMDD-HHMMSS.md`) are written by the shared guarded-write helper `hooks/lib/checkpoint-guard.sh` on behalf of BOTH hook writers — `pre-compact-checkpoint.sh` and `prompt-context.sh` — which archive the prior bare `checkpoint.md` to a dated variant before any overwrite they are allowed to make (never over a rich checkpoint: that one is preserved outright rather than rotated). Rich means model-authored: a block this skill writes wins at any age, while a block carrying the provenance line `**Source:** PreCompact hook — mechanical extraction` is a snapshot the next compaction refreshes. That's legitimate rotation history and should not be disturbed. The legacy bare path under the install root was retired to close the cross-session-pollution incident class.

Your scope is strictly the per-session `checkpoint.md`. Overwrite it. Never append. Never write to dated filenames.

---

## portability note (for the S2 install-verify gate)

This skill writes to `$CLAUDE_STATE_ROOT`-resolved per-session paths (not hardcoded `$HOME/.claude` literals). It is one of the surfaces the S2 hook-portability verify-gate checks alongside the C2 literal-sourcing hooks; the verify-gate owns the mechanic.

---

## Invocation contexts

1. **User-invoked `/session-checkpoint`** — produce the checkpoint and report briefly. Accept an optional argument that should be appended under `current_blocker` or `key_decisions` based on content.
2. **After the R-26 context-pressure banner** — the user sees a `CONTEXT PRESSURE <pct>%` banner (the hook's `systemMessage`, once per band entry: warn default 45%, mandate default 48%). It recommends this skill, then `/compact`, or a fresh session. It is a recommendation to the user, not a mandate to you: run the skill when the user asks for it.
3. **Stop hook block (48-80%)** — Stop returns exit 2 when the checkpoint is missing, or is a header-less stub or panic fallback older than 10 minutes; a Session Continuity Block satisfies the band at any age. Run this skill, then retry stop.

The warn/mandate banner thresholds are manifest-overridable via `user-manifest.json :: hooks.context_pressure.{warn,mandate}_pct` (defaults 45/48) and are percentages of the harness auto-compact window, not the model window. The stop-gate's 48/80/90 boundaries are fixed constants in `stop-checkpoint-check.sh` on the raw `.pct` by design and are NOT settings-driven (`hard_pct` is schema-parity vocabulary only —).

---

## What this skill does NOT do

- Does not force `/compact` — context compaction stays a user/Claude decision.
- Does not rotate or archive old checkpoints — `hooks/lib/checkpoint-guard.sh` owns rotation, and the two hook writers reach it on the next checkpoint write.
- Does not write to memory — that's session-close / librarian scope.
- Does not touch plan files or handoffs — checkpoint is ephemeral state, not persistent history.

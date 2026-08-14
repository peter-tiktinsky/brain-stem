#!/bin/bash
# Hook: PreCompact — Mechanically extract session state if no fresh checkpoint exists.
# Zero-LLM-cost: all bash/grep/sed/jq. Must complete in <3 seconds.
# Output matches Session Continuity Block schema from CLAUDE.md.
# 2026-05-10 fix (-rework, authorized):
#   (1) Removed invalid hookSpecificOutput emission.
#       "PreCompact" is NOT in Claude Code's hookEventName enum
#       (PreToolUse|UserPromptSubmit|PostToolUse|PostToolBatch only).
#       Old emit was rejected by validator; additionalContext never reached
#       post-compact intake. Hook now exits 0 silently. SessionStart
#       source=compact reads checkpoint.md per R-26 contract.
#   (2) Added a structure precedence guard.
#       /session-checkpoint output (rich) wins over PreCompact mechanical extraction.
#       If checkpoint.md has structured content (Session Continuity Block header
#       + ≥3 populated fields), exit 0 without overwriting. Mechanical extraction
#       only runs when the checkpoint is missing, empty, unstructured, or is a
#       previous panic-fallback.
#       Predicate RE-ADJUDICATED (T-2): the guard was `age < 600s AND
#       structured`, which released a rich checkpoint at any age past ten minutes
#       — exactly when a long session had made it irreplaceable. Rich now wins at
#       ANY AGE, and the accepted consequence is deliberate: a mechanically
#       extracted block is itself structured, so a second compaction preserves the
#       first one's snapshot instead of refreshing it. Refresh belongs to the
#       higher-provenance writer (/session-checkpoint, which is also what the R-26
#       bands mandate); silently destroying a handoff record to keep a mechanical
#       one current is the trade this hook used to make, and it is the wrong one.
#       The predicate itself lives in hooks/lib/checkpoint-guard.sh and is shared
#       with the other writer of this file (prompt-context.sh).
#   (3) [MISSING] tokens replace empty fields per R-26 contract verbatim
#       ("never silently skipped").
set -uo pipefail

# hardcoded install-path literal ([DRIFT] 3).
# hook-journal.sh is a hooks/lib/ peer; source it only when present + provide a
# no-op journal_emission fallback so the hook never hard-fails before it lands.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
# The single owner of "may I overwrite this checkpoint?", shared with the other
# writer of this file (prompt-context.sh). Sourced UNCONDITIONALLY — a
# graceful-degrade guard here would silently restore the unguarded overwrite.
source "$SCRIPT_DIR/lib/checkpoint-guard.sh"
[ -r "$SCRIPT_DIR/lib/hook-journal.sh" ] && source "$SCRIPT_DIR/lib/hook-journal.sh"
if ! command -v journal_emission >/dev/null 2>&1; then
  journal_emission() { :; }
fi

# Per-session checkpoint dir roots at $CLAUDE_STATE_ROOT (/
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"
# Coordination registry is machine-local under $CLAUDE_STATE_ROOT/.coordination
# ($COORD_DIR emitted by paths.sh), not the legacy $VAULT_LOGS path.
SESSION_REGISTRY="${COORD_DIR:-$CLAUDE_STATE_ROOT/.coordination}/session-registry.json"

# Read the PreCompact payload (the transcript path).
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line accumulates as it arrives, so a stream that keeps
# delivering is never truncated; blank lines are PRESERVED and the trailing-newline
# trim reproduces `$(cat)` exactly, so the payload reaches jq byte-identical.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
# The two reference implementations under skills/librarian/capabilities/ are NOT
# equivalent and this is neither: handoff-disposition-check.sh re-arms per read but
# DROPS blank lines; rename-cascade.sh bounds only the FIRST read, then free-runs an
# unbounded `cat`. This is the byte-preserving form the other hook drains carry.
INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    INPUT="${INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${INPUT%$'\n'}" != "$INPUT" ]; do INPUT="${INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
fi
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
fi
if [[ -z "$SESSION_ID" ]]; then
  # Cannot construct per-session path; graceful degrade (no checkpoint to write/preserve)
  exit 0
fi
SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
CHECKPOINT_FILE="$SESSION_DIR/checkpoint.md"

mkdir -p "$SESSION_DIR"

# --- Structure precedence guard (2026-05-10; predicate re-adjudicated per the
#     header note above) ---
# A rich checkpoint is preserved verbatim at ANY age: /session-checkpoint output
# wins over mechanical extraction. checkpoint_guarded_write below applies the same
# predicate, so this early exit is a work-avoidance shortcut — it skips the
# extraction that would be discarded anyway — and NOT a second derivation of the
# rule. Mechanical extraction proceeds for a missing, empty, unstructured or
# panic-fallback checkpoint.
if checkpoint_is_rich "$CHECKPOINT_FILE"; then
  exit 0
fi

# --- Mechanical State Extraction ---
has_structured=false
plan_id=""
phase=""
task_id=""
completed_steps=""
files_modified=""
key_decisions=""
next_steps=""
ac_status=""
current_blocker=""

# 1. Determine THIS session's active plan — session-anchored.
# Retire the global mtime-MRU: instead of `find "$PLANS_DIR" … | xargs ls -t |
# head -1` over the WHOLE plan tree (which, under concurrent sessions, let a peer's
# most-recently-touched plan poison this session's fallback checkpoint), derive the
# active plan from THIS session's OWN touched paths in the registry — the T-4
# select(.key == $sid) filter, symmetric with the sibling block below. The candidate
# set can never include a peer session's plan. There is NO global-MRU fallback: an
# empty session source degrades to [MISSING] via the R-26 block below (a global scan
# on empty would reintroduce the exact cross-session bleed this fix removes).
if [[ -d "$PLANS_DIR" ]] && [[ -f "$SESSION_REGISTRY" ]]; then
  # Candidate plan files = this session's own touched paths under $PLANS_DIR that
  # end in .md (spec/tasks/etc.). jq keys on $sid so a peer's plan is unreachable.
  session_plan_files=$(jq -r --arg sid "$SESSION_ID" --arg plans "$PLANS_DIR/" \
    '.sessions | to_entries | map(select(.key == $sid)) | .[0] // empty
     | .value.touched_files // []
     | map(select(startswith($plans) and endswith(".md"))) | .[]' \
    "$SESSION_REGISTRY" 2>/dev/null)
  # Newest-still-present among the SESSION'S OWN files only (a within-session recency
  # tiebreak → freshest phase/AC extraction; never a cross-session selector). The
  # existence filter + the [[ -n ]] empty-guard keep xargs from falling through to a
  # bare `ls -t` on the cwd when the session has no plan-tree touch.
  active_plan=""
  present_plan_files=$(printf '%s\n' "$session_plan_files" \
    | while IFS= read -r f; do [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"; done)
  if [[ -n "$present_plan_files" ]]; then
    active_plan=$(printf '%s\n' "$present_plan_files" | xargs ls -t 2>/dev/null | head -1)
  fi

  if [[ -n "$active_plan" ]]; then
    rel_path="${active_plan#$PLANS_DIR/}"
    plan_id=$(echo "$rel_path" | sed 's|/.*||; s|\.md$||')
    has_structured=true

    phase=$(grep -iE '^\s*(#+\s*)?phase\s+[0-9]' "$active_plan" 2>/dev/null | grep -iE '(in.progress|current|active|\*\*)' | head -1 | sed 's/^[# ]*//' | head -c 100)
    if [[ -z "$phase" ]]; then
      phase=$(grep -iE '^\s*(#+\s*)?phase\s+[0-9]' "$active_plan" 2>/dev/null | tail -1 | sed 's/^[# ]*//' | head -c 100)
    fi

    plan_dir=$(dirname "$active_plan")
    tasks_file="$plan_dir/tasks.md"
    if [[ -f "$tasks_file" ]]; then
      task_id=$(grep -iE '\[[ ~x]\].*in.progress|\-\s*\[~\]|\-\s*\[ \].*current' "$tasks_file" 2>/dev/null | head -3 | tr '\n' '; ' | head -c 300)
      completed_steps=$(grep -iE '\[x\]' "$tasks_file" 2>/dev/null | tail -10 | tr '\n' '; ' | head -c 500)
    fi

    next_steps=$(sed -n '/[Nn]ext [Ss]tep/,/^##/p' "$active_plan" 2>/dev/null | grep -E '^\s*-' | head -5 | tr '\n' '; ' | head -c 300)
    ac_status=$(sed -n '/[Aa]cceptance [Cc]riteria/,/^##/p' "$active_plan" 2>/dev/null | grep -E '^\s*-\s*\[' | head -10 | tr '\n' '; ' | head -c 300)
  fi
fi

# 2. Read session registry for touched files — T-4 (2026-05-11):
# scope to current $SESSION_ID deterministically (was MRU-heartbeat-active,
# stochastic — a guard signal must be deterministic — plus cross-session pollution).
if [[ -f "$SESSION_REGISTRY" ]]; then
  registry_files=$(jq -r --arg sid "$SESSION_ID" '.sessions | to_entries | map(select(.key == $sid)) | .[0] // empty | .value.touched_files // [] | .[]' "$SESSION_REGISTRY" 2>/dev/null | head -20 | tr '\n' '; ')
  if [[ -n "$registry_files" ]]; then
    files_modified="$registry_files"
    has_structured=true
  fi
fi

# 3. Read existing checkpoint for accumulated state (only if stale; the freshness
# guard above already returned for fresh+structured cases).
if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
  if [[ -z "$key_decisions" ]]; then
    key_decisions=$(sed -n '/[Kk]ey [Dd]ecision/,/^##/p' "$CHECKPOINT_FILE" 2>/dev/null | grep -E '^\s*-' | head -5 | tr '\n' '; ' | head -c 300)
  fi
  if [[ -z "$current_blocker" ]]; then
    current_blocker=$(sed -n '/[Bb]locker\|[Ee]rror/,/^##/p' "$CHECKPOINT_FILE" 2>/dev/null | grep -E '^\s*-' | head -3 | tr '\n' '; ' | head -c 200)
  fi
  has_structured=true
fi

# Replace [MISSING] for empty fields per R-26 contract verbatim.
plan_id="${plan_id:-[MISSING]}"
phase="${phase:-[MISSING]}"
task_id="${task_id:-[MISSING]}"
completed_steps="${completed_steps:-[MISSING]}"
files_modified="${files_modified:-[MISSING]}"
key_decisions="${key_decisions:-[MISSING]}"
next_steps="${next_steps:-[MISSING]}"
ac_status="${ac_status:-[MISSING]}"
current_blocker="${current_blocker:-[MISSING]}"

# --- Write checkpoint (only path reached: unstructured/missing/empty checkpoint) ---
# The dated-variant rotation that used to sit inline here (Cause-1 relocation, Plan
# 190 / RULING 3 — moved out of session-register.sh, which runs at SessionStart only
# and cannot rotate on the NEXT checkpoint write) now belongs to
# checkpoint_guarded_write, so both writers of this file rotate identically. Ordering
# is unchanged: the archive still happens at write time, i.e. AFTER the
# accumulated-state read above, so the archived copy is the pre-overwrite content.
if [[ "$has_structured" == "true" ]]; then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  checkpoint_guarded_write "$CHECKPOINT_FILE" <<EOF
# Session Continuity Block
**Generated:** $ts
**Source:** PreCompact hook — mechanical extraction (no fresh /session-checkpoint output)

plan_id: $plan_id
phase: $phase
task_id: $task_id
completed_steps: $completed_steps
files_modified: $files_modified
key_decisions: $key_decisions
next_steps: $next_steps
ac_status: $ac_status
current_blocker: $current_blocker

## Action Required
- Resume from this checkpoint after compaction
- Re-read any files listed in files_modified if actively editing
- Note: this is mechanically-extracted. Any /session-checkpoint output present here would have been preserved verbatim by the structure gate, at any age.
EOF
  cp_rc=$?
  journal_emission "PreCompact" "state-write:checkpoint:structured-extraction" "$cp_rc"
else
  # --- Transcript fallback (no structured sources) ---
  panic_context="No structured state sources found."
  if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
    last_actions=$(tail -50 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r 'select(.type == "tool_use" or .type == "assistant") | .content // .tool_name // empty' 2>/dev/null | tail -10 | tr '\n' '; ' | head -c 500)
    if [[ -n "$last_actions" ]]; then
      panic_context="Panic checkpoint from transcript tail: ${last_actions}"
    fi
  fi

  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  checkpoint_guarded_write "$CHECKPOINT_FILE" <<EOF
# Panic Checkpoint (auto-generated at compaction)
**Generated:** $ts
**Source:** PreCompact hook — no structured sources, transcript fallback

## Last Known Context
$panic_context

## Action Required
- Read this file to restore context
- Check task list for current progress
- Re-read any files you were actively editing
EOF
  cp_rc=$?
  journal_emission "PreCompact" "state-write:checkpoint:panic-fallback" "$cp_rc"
fi

# 2026-05-10 fix: invalid hookSpecificOutput emission removed.
# PreCompact hooks cannot inject additionalContext via hookSpecificOutput.
# SessionStart source=compact reads checkpoint.md to restore context.
exit 0

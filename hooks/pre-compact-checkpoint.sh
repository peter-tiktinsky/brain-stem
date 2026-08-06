#!/bin/bash
# Hook: PreCompact — Mechanically extract session state if no fresh checkpoint exists.
# Zero-LLM-cost: all bash/grep/sed/jq. Must complete in <3 seconds.
# Output matches Session Continuity Block schema from CLAUDE.md.
# 2026-05-10 fix (Session 2-rework, authorized):
#   (1) Removed invalid hookSpecificOutput emission.
#       "PreCompact" is NOT in Claude Code's hookEventName enum
#       (PreToolUse|UserPromptSubmit|PostToolUse|PostToolBatch only).
#       Old emit was rejected by validator; additionalContext never reached
#       post-compact intake. Hook now exits 0 silently. SessionStart
#       source=compact reads checkpoint.md per R-26 contract.
#   (2) Added freshness + structure precedence guard.
#       /session-checkpoint output (rich) wins over PreCompact mechanical extraction.
#       If checkpoint.md is < 10 minutes old AND has structured content
#       (Session Continuity Block header + ≥3 populated fields), exit 0
#       without overwriting. Mechanical extraction only runs when checkpoint
#       is stale OR missing OR is a previous panic-fallback.
#   (3) [MISSING] tokens replace empty fields per R-26 contract verbatim
#       ("never silently skipped").
set -uo pipefail

# hardcoded install-path literal ([DRIFT] 3).
# hook-journal.sh is a hooks/lib/ peer; source it only when present + provide a
# no-op journal_emission fallback so the hook never hard-fails before it lands.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
[ -r "$SCRIPT_DIR/lib/hook-journal.sh" ] && source "$SCRIPT_DIR/lib/hook-journal.sh"
if ! command -v journal_emission >/dev/null 2>&1; then
  journal_emission() { :; }
fi

# Per-session checkpoint dir roots at $CLAUDE_STATE_ROOT (/
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"
# Coordination registry is machine-local under $CLAUDE_STATE_ROOT/.coordination
# ($COORD_DIR emitted by paths.sh), not the legacy $VAULT_LOGS path.
SESSION_REGISTRY="${COORD_DIR:-$CLAUDE_STATE_ROOT/.coordination}/session-registry.json"

INPUT=$(cat)
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

# --- Freshness + structure precedence guard (2026-05-10 fix) ---
# If checkpoint.md exists, is < 10 minutes old, AND has structured content,
# preserve it. /session-checkpoint output wins over mechanical extraction.
if [[ -f "$CHECKPOINT_FILE" ]]; then
  cp_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
  age_seconds=$(( $(date +%s) - cp_mtime ))
  if [[ "$age_seconds" -lt 600 ]]; then
    if grep -q "^# Session Continuity Block" "$CHECKPOINT_FILE" 2>/dev/null; then
      populated_lines=$(grep -cE "^[a-z_]+: .+$" "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
      # Strip whitespace just in case
      populated_lines="${populated_lines//[^0-9]/}"
      if [[ "${populated_lines:-0}" -ge 3 ]]; then
        # Fresh + structured. Preserve verbatim. Exit silently.
        exit 0
      fi
    fi
  fi
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
# stochastic per feedback_guard_signal_determinism + cross-session pollution).
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

# --- Cause-1 relocation (RULING 3): archive the prior bare checkpoint.md
#     to a dated variant BEFORE overwriting it. Rotation was relocated here from
#     session-register.sh (which runs at SessionStart only and cannot rotate on the
#     NEXT checkpoint write). Reached only on the stale/missing write path (the
#     fresh-preserve gate returned earlier at :62-76), and placed AFTER the
#     accumulated-state read above so the archived copy is the pre-overwrite content.
#     COPY (not move) then overwrite, so a failed archive never loses the checkpoint;
#     the checkpoint-YYYYMMDD-HHMMSS.md dated variant is legitimate rotation history.
if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
  archive_ts=$(date -u +"%Y%m%d-%H%M%S")
  cp "$CHECKPOINT_FILE" "$SESSION_DIR/checkpoint-${archive_ts}.md" 2>/dev/null || true
fi

# --- Write checkpoint (only path reached: stale/missing/empty checkpoint) ---
if [[ "$has_structured" == "true" ]]; then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp="${CHECKPOINT_FILE}.tmp.$$"
  cat > "$tmp" <<EOF
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
- Note: this is mechanically-extracted. If /session-checkpoint had been run within 10 minutes, that content was preserved by the freshness gate.
EOF
  mv "$tmp" "$CHECKPOINT_FILE"
  journal_emission "PreCompact" "state-write:checkpoint:structured-extraction" 0
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
  tmp="${CHECKPOINT_FILE}.tmp.$$"
  cat > "$tmp" <<EOF
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
  mv "$tmp" "$CHECKPOINT_FILE"
  journal_emission "PreCompact" "state-write:checkpoint:panic-fallback" 0
fi

# 2026-05-10 fix: invalid hookSpecificOutput emission removed.
# PreCompact hooks cannot inject additionalContext via hookSpecificOutput.
# SessionStart source=compact reads checkpoint.md to restore context.
exit 0

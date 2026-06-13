#!/bin/bash
# Hook: UserPromptSubmit — Inject context pressure warnings + peer awareness.
# Silent (no output) when solo and context is low.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"
# the producer/reader API when present (graceful-degrade — advisory band).
[ -r "$SCRIPT_DIR/lib/review-queue.sh" ] && source "$SCRIPT_DIR/lib/review-queue.sh"
[ -r "$SCRIPT_DIR/lib/context-pressure.sh" ] && source "$SCRIPT_DIR/lib/context-pressure.sh"

# Per-session checkpoint/pressure dir roots at $CLAUDE_STATE_ROOT (/
# /), via the paths.sh SoT — NOT $HOOKS_STATE. registry.sh (sourced
# above) sources paths.sh, so SESSION_STATE_ROOT is exported here.
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"

# (`sessions/<sid>/context-pressure.json`). PRESSURE_FILE construction moved
# AFTER SESSION_ID resolution. Empty SID → PRESSURE_FILE="" → existence checks
# fall through to default-pct-0 path; R-26 mandate firing preserved.
# Read stdin once up-front so we can resolve the per-session checkpoint path
# before the pressure block (which reads CHECKPOINT_FILE mtime).
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="${CLAUDE_SESSION_ID:-}"
fi
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
if [[ -n "$SESSION_ID" ]]; then
  SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
  CHECKPOINT_FILE="$SESSION_DIR/checkpoint.md"
  PRESSURE_FILE="$SESSION_DIR/context-pressure.json"
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
  if command -v write_context_pressure >/dev/null 2>&1; then
    write_context_pressure "$TRANSCRIPT_PATH" "$PRESSURE_FILE" 2>/dev/null || true
  fi
else
  # No session ID — checkpoint + pressure operations skipped (per-session path unavailable).
  # Existence checks against "" return false, so pressure mandates default to pct=0.
  CHECKPOINT_FILE=""
  PRESSURE_FILE=""
fi

# --- Context pressure enforcement (R-26) ---
# Re-firing mandates with mtime-based clearing condition.
# Clearing window: checkpoint.md mtime must be < 600s (10 min) old.
# The one-shot last_warned flag has been removed — mandates fire every
# UserPromptSubmit until the clearing condition is met.
CLEARING_WINDOW_SEC=600

# --- T-13 (G3): manifest-driven thresholds for hooks.context_pressure ---
# Reads warn_pct/mandate_pct from $CLAUDE_HOME/user-manifest.json (defaults 45/48
# when absent or null). These are the ONLY context_pressure thresholds any hook
# consumes: this hook enforces warn+mandate in-band. The stop-gate's 48/80/90
# boundaries are FIXED constants in stop-checkpoint-check.sh by design (a safety
# gate is not weakened by misconfig) — so `hard_pct` is schema-parity vocabulary
# only and is intentionally NOT read here or by the stop-gate (neither this hook
# nor the stop-gate reads that field).
USER_MANIFEST="${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json"
WARN_PCT=45
MANDATE_PCT=48
if [[ -f "$USER_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
  _ctxp_read() {
    local jq_path="$1" default="$2"
    local val
    val=$(jq -r "${jq_path} // empty" "$USER_MANIFEST" 2>/dev/null)
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s' "$val"
    else
      printf '%s' "$default"
    fi
  }
  WARN_PCT=$(_ctxp_read '.hooks.context_pressure.warn_pct' 45)
  MANDATE_PCT=$(_ctxp_read '.hooks.context_pressure.mandate_pct' 48)
fi

pressure_context=""
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
  pct_int=${pct%.*}

  # Compute checkpoint freshness (mtime age in seconds; large number if absent)
  if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
    ckpt_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    ckpt_age=$(( now - ckpt_mtime ))
  else
    ckpt_age=999999
  fi
  checkpoint_fresh=false
  if (( ckpt_age < CLEARING_WINDOW_SEC )); then
    checkpoint_fresh=true
  fi

  if (( pct_int >= MANDATE_PCT )); then
    if ! $checkpoint_fresh; then
      # mandate% immediate-action mandate — re-fires every prompt until cleared
      pressure_context="CONTEXT PRESSURE ${pct}% — IMMEDIATE ACTION REQUIRED.
Before responding to the user's prompt, invoke /session-checkpoint.
Do not take any other tool action until checkpoint is written to $CHECKPOINT_FILE.
This is a blocking mandate enforced by the Stop hook (R-26).
Clearing condition: checkpoint.md mtime < 10 min old."
    fi
  elif (( pct_int >= WARN_PCT )); then
    if ! $checkpoint_fresh; then
      # warn% at-next-break mandate — re-fires every prompt until cleared
      pressure_context="CONTEXT PRESSURE ${pct}%. At the next natural task boundary (current tool chain complete), invoke /session-checkpoint to write $CHECKPOINT_FILE with the Session Continuity Block.
Do not begin new multi-step work until checkpoint is written.
Clearing condition: checkpoint.md mtime < 10 min old (R-26)."
    fi
  elif (( pct_int >= 35 )); then
    # 35% silent passive checkpoint — preserves prior behavior as PreCompact feed.
    # Only writes if no fresh checkpoint already exists (don't clobber manual ones).
    if ! $checkpoint_fresh && [[ -n "$CHECKPOINT_FILE" ]]; then
      cat > "$CHECKPOINT_FILE" <<CKPT 2>/dev/null || true
# Auto-checkpoint at ${pct}% context — $(date -Iseconds)
# Passive 35% silent capture — feeds PreCompact hook
CKPT
    fi
  fi
fi

# ---: memory-review re-firing band — YIELDS to R-26 ---
# Escalates a UserPromptSubmit mandate for aged (high-severity pending >3d) or
# defer_count≥2 review items. The band NEVER competes with the R-26 checkpoint
# mandate: it fires ONLY when pressure_context is empty (no active checkpoint
# mandate). Clear-condition: the item leaves the queue only on explicit confirm
# OR reject-with-reason (never silent dismiss / session-exit / bare defer) —
# enforced at the queue layer, so the mandate re-fires every prompt until then.
# The aged/defer thresholds are resolved env > user-manifest.json ::
# hooks.memory_review > default inside review-queue.sh.
if [[ -z "$pressure_context" ]] \
   && command -v review_queue_has_aged_or_deferred >/dev/null 2>&1; then
  if ! { command -v memory_review_opt_out >/dev/null 2>&1 && memory_review_opt_out; }; then
    if review_queue_has_aged_or_deferred; then
      pressure_context="MEMORY REVIEW MANDATE — one or more aged/high-severity memory-review items are pending (>3d high-severity, or deferred ≥2 times). At the next natural task boundary, run /librarian review to address them: each item clears ONLY on explicit confirm OR reject-with-reason. This mandate re-fires every prompt until the queue clears, and YIELDS to the R-26 checkpoint mandate + the ≥80% context-pressure valve (session-continuity always wins)."
    fi
  fi
fi

# stdin + SESSION_ID parsed at top (T-2). Re-check empty case here:
if [[ -z "$SESSION_ID" ]]; then
  # No session ID but we may still have pressure / memory-review context
  if [[ -n "$pressure_context" ]]; then
    format_output "UserPromptSubmit" "$pressure_context"
  fi
  exit 0
fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

# Read registry under lock (2s timeout — skip on contention)
reg=$(lockf -k -t 2 "$REGISTRY_LOCK" cat "$REGISTRY_FILE" 2>/dev/null) || {
  # Registry unavailable — still emit pressure warnings
  if [[ -n "$pressure_context" ]]; then
    format_output "UserPromptSubmit" "$pressure_context"
  fi
  exit 0
}

# Fast path: only our own session → silent
peer_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
  '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active" or .value.status == "closing" or .value.status == "closed-pending-reconciliation")] | length')
if (( peer_count == 0 )); then
  # No peers, but may still have pressure context
  if [[ -n "$pressure_context" ]]; then
    format_output "UserPromptSubmit" "$pressure_context"
  fi
  exit 0
fi

# Detect session-close in prompt for enhanced context
is_close=false
if echo "$PROMPT" | grep -qi 'session-close\|/librarian.*close'; then
  is_close=true
fi

context=""

# Pending reconciliation check
pending_info=$(get_pending_info "$reg" "$SESSION_ID")
if [[ -n "$pending_info" ]]; then
  context="$pending_info"
fi

# Peer summary
peer_summary=$(get_peer_summary "$reg" "$SESSION_ID")
if [[ -n "$peer_summary" ]]; then
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}${peer_summary}"
fi

# File overlaps
overlaps=$(get_file_overlaps "$reg" "$SESSION_ID")
if [[ -n "$overlaps" ]]; then
  overlap_list=$(echo "$overlaps" | head -10 | tr '\n' ', ' | sed 's/,$//')
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}Warning: Overlapping files with peer sessions: ${overlap_list}. Re-read before editing."
fi

# Enhanced context for session-close
if $is_close; then
  # Full peer detail for close coordination
  close_detail=$(echo "$reg" | jq -r --arg sid "$SESSION_ID" '
    .sessions | to_entries[] | select(.key != $sid) |
    "- \(.key[0:8])... status=\(.value.status) files=\(.value.touched_files | length) close_summary=\"\(.value.close_summary // "")\""
  ')

  active_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active")] | length')
  pending_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "closed-pending-reconciliation")] | length')

  # Recommend close mode
  if (( active_count > 0 )); then
    mode="scoped (other sessions still active)"
  elif (( pending_count > 0 )); then
    mode="reconciler (last active session, pending peers need reconciliation)"
  else
    mode="solo (no coordination needed)"
  fi

  context="${context}

SESSION CLOSE COORDINATION:
Peer sessions:
${close_detail}
Recommended close mode: ${mode}
pending_reconciliation: $(echo "$reg" | jq -r '.pending_reconciliation')"
fi

# Merge pressure context with peer context
if [[ -n "$pressure_context" ]]; then
  if [[ -n "$context" ]]; then
    context="${pressure_context}

${context}"
  else
    context="$pressure_context"
  fi
fi

if [[ -n "$context" ]]; then
  format_output "UserPromptSubmit" "$context"
fi

exit 0

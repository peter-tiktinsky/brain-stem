#!/bin/bash
# Hook: Stop — Enforce checkpoint writing before session exit at high context.
# Exit 2 = force continuation. Exit 0 = allow stop.
set -euo pipefail

# Hook-portability — source the journal peer via $SCRIPT_DIR.
# hook-journal.sh is a hooks/lib/ peer (named in registry.sh's peer-source
# loop); source it only when present and provide a no-op journal_emission
# fallback so the hook never hard-fails when the peer is absent (matches
# registry.sh graceful-degrade).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
[ -r "$SCRIPT_DIR/lib/hook-journal.sh" ] && source "$SCRIPT_DIR/lib/hook-journal.sh"
if ! command -v journal_emission >/dev/null 2>&1; then
  journal_emission() { :; }
fi

STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-$CLAUDE_HOME/hooks/state}}"
CLEARING_WINDOW_SEC=600

# Per-session checkpoint paths + per-session pressure file paths.
# Use the env var Claude Code sets in hook subprocesses (no stdin parsing in this hook).
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  # Cannot determine session — allow stop (graceful degrade; we cannot enforce
  # per-session checkpoint freshness without knowing which session is stopping).
  exit 0
fi
CHECKPOINT_FILE="$STATE_DIR/sessions/$SESSION_ID/checkpoint.md"
PRESSURE_FILE="$STATE_DIR/sessions/$SESSION_ID/context-pressure.json"

# Read context percentage
pct=0
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
fi
pct_int=${pct%.*}

# Safety valve: >90% always allows stop (context too full to continue productively).
# The memory-review band YIELDS to this valve unconditionally.
if (( pct_int > 90 )); then
  exit 0
fi

# Below 48%: no R-26 enforcement band. This is the ONLY point the memory-
# review Stop-block may fire — and ONLY for HIGH-SEVERITY CONFLICTS. The
# memory-review band NEVER competes with or overrides session-continuity: the
# R-26 48-80%/80-90% gates and the >90% valve all take precedence (they are
# evaluated above and below this branch and win). Even a genuine contradiction
# defers to the checkpoint Stop-block (escalation ladder).
if (( pct_int < 48 )); then
  # Memory-review Stop-block for high-severity CONFLICTS only.
  # Reads the review queue via hooks/lib/review-queue.sh (block-and-log); fires
  # only when a high-severity CONFLICT item is unaddressed AND the operator has
  # not opted out. All thresholds manifest-driven (user-manifest.json ::
  # hooks.memory_review). Advisory degrade: if the queue lib is absent, no-op.
  _rq_lib="$SCRIPT_DIR/lib/review-queue.sh"
  if [ -r "$_rq_lib" ]; then
    source "$_rq_lib"
    if command -v memory_review_opt_out >/dev/null 2>&1 && memory_review_opt_out; then
      exit 0
    fi
    if command -v review_queue_has_high_severity_conflict >/dev/null 2>&1 \
       && review_queue_has_high_severity_conflict; then
      echo "Unaddressed HIGH-SEVERITY memory CONFLICT in the review queue. Run /librarian review to confirm or reject-with-reason before stopping. (memory-review Stop-block — yields to R-26)" >&2
      journal_emission "Stop" "deny-stop:memory-review:high-severity-conflict:pct=${pct}" 2
      exit 2
    fi
  fi
  exit 0
fi

# Compute checkpoint freshness
ckpt_exists=false
ckpt_age=999999
if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
  ckpt_exists=true
  ckpt_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  ckpt_age=$(( now - ckpt_mtime ))
fi

# 48-80% band: R-26 mtime-freshness gate. Checkpoint must be < 10 min old.
if (( pct_int < 80 )); then
  if $ckpt_exists && (( ckpt_age < CLEARING_WINDOW_SEC )); then
    exit 0
  fi
  echo "Context at ${pct}%. Cannot stop — checkpoint stale (mtime age ${ckpt_age}s, limit ${CLEARING_WINDOW_SEC}s)." >&2
  echo "Invoke /session-checkpoint first to refresh $CHECKPOINT_FILE (per-session path). After checkpoint is written, stop will be allowed. (R-26 48-80% band)" >&2
  journal_emission "Stop" "deny-stop:48-80-band:checkpoint-stale:age=${ckpt_age}s:pct=${pct}" 2
  exit 2
fi

# 80-90% band: checkpoint must at minimum exist (pre-existing rule, preserved)
if $ckpt_exists; then
  exit 0
fi

echo "Context at ${pct}%. You must save a checkpoint before stopping. Invoke /session-checkpoint to write $CHECKPOINT_FILE (per-session path). (R-26 80-90% band)" >&2
journal_emission "Stop" "deny-stop:80-90-band:checkpoint-missing:pct=${pct}" 2
exit 2

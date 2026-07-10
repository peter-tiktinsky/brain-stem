#!/bin/bash
# Hook: Stop — Enforce checkpoint writing before session exit at high context.
# Exit 2 = force continuation. Exit 0 = allow stop.
set -euo pipefail

# hook-portability — source the journal peer via $SCRIPT_DIR
# ([DRIFT] 3). hook-journal.sh is a hooks/lib/ peer
# (named in registry.sh's peer-source loop as landing at/); source it
# only when present and provide a no-op journal_emission fallback so the hook
# never hard-fails before the peer lands (matches registry.sh graceful-degrade).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
[ -r "$SCRIPT_DIR/lib/hook-journal.sh" ] && source "$SCRIPT_DIR/lib/hook-journal.sh"
if ! command -v journal_emission >/dev/null 2>&1; then
  journal_emission() { :; }
fi
# the context-pressure writer (the .pct producer the bands below read).
[ -r "$SCRIPT_DIR/lib/context-pressure.sh" ] && source "$SCRIPT_DIR/lib/context-pressure.sh"

# T-3: the Stop turn-boundary heartbeat needs the registry RMW primitives +
# REGISTRY_LOCK, so source the coordination lib (graceful-degrade like the peers above;
# env-wins paths.sh re-source is idempotent). This covers a long AUTONOMOUS single-turn
# run that emits no new UserPromptSubmit — the gap per-prompt refresh alone leaves open.
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh"

# Internal lockf re-exec target. `stop-checkpoint-check.sh --do-heartbeat <sid>` refreshes
# ONLY that session's last_heartbeat while holding REGISTRY_LOCK across the
# read_registry..write_registry span (heartbeat_row from registry.sh), then exits — before
# the stdin drain + gate logic below, so the re-exec never blocks and never gates.
if [ "${1:-}" = "--do-heartbeat" ]; then
  command -v heartbeat_row >/dev/null 2>&1 && heartbeat_row "${2:-}"
  exit 0
fi

# Per-session checkpoint/pressure dir roots at $CLAUDE_STATE_ROOT (/
# /), via the paths.sh SoT (sourced above) — NOT $HOOKS_STATE.
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"
CLEARING_WINDOW_SEC=600

# T-2: per-session checkpoint paths.
# T-3 (2026-05-11): per-session pressure file paths.
# Session id comes from the env var Claude Code sets in hook subprocesses.
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  # Cannot determine session — allow stop (graceful degrade; we cannot enforce
  # per-session checkpoint freshness without knowing which session is stopping).
  exit 0
fi
CHECKPOINT_FILE="$STATE_DIR/sessions/$SESSION_ID/checkpoint.md"
PRESSURE_FILE="$STATE_DIR/sessions/$SESSION_ID/context-pressure.json"

# T-3: refresh this session's last_heartbeat at the Stop turn-boundary so a
# long autonomous single-turn run (no new UserPromptSubmit to trigger the per-prompt
# refresh) still keeps its heartbeat fresh and is not reaped by the T-1 verdict. Holds
# REGISTRY_LOCK across the RMW via the --do-heartbeat lockf re-exec (fail-open to a
# direct unlocked upsert). Every path ends in `|| true` so it can NEVER non-zero-exit
# and wrongly force-continue the Stop gate under `set -euo pipefail`.
if command -v heartbeat_row >/dev/null 2>&1; then
  ensure_coord_dir 2>/dev/null || true
  if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
    lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-heartbeat "$SESSION_ID" >/dev/null 2>&1 \
      || heartbeat_row "$SESSION_ID" || true
  else
    heartbeat_row "$SESSION_ID" || true
  fi
fi

# refresh .pct from the transcript at stop time so the gate sees the pressure
# AFTER the just-completed tool chain (a stale last-prompt pct would under-protect).
# The Stop payload carries transcript_path on stdin; drain non-blocking (</dev/null
# in tests → empty → the writer no-ops and any existing pressure file is preserved).
STOP_INPUT=""
[ -t 0 ] || STOP_INPUT=$(cat 2>/dev/null || true)
if command -v write_context_pressure >/dev/null 2>&1; then
  _tp=$(printf '%s' "$STOP_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
  write_context_pressure "$_tp" "$PRESSURE_FILE" 2>/dev/null || true
fi

# Read context percentage
pct=0
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
fi
pct_int=${pct%.*}

# Safety valve: >90% always allows stop (context too full to continue productively).
# The memory-review band YIELDS to this valve unconditionally (.7).
if (( pct_int > 90 )); then
  exit 0
fi

# Below 48%: no R-26 enforcement band. This is the ONLY point the memory-
# review Stop-block may fire — and ONLY for HIGH-SEVERITY CONFLICTS. The
# memory-review band NEVER competes with or overrides session-continuity: the
# R-26 48-80%/80-90% gates and the >90% valve all take precedence (they are
# evaluated above and below this branch and win). Even a genuine contradiction
# defers to the checkpoint Stop-block (canonical/escalation ladder; C2).
if (( pct_int < 48 )); then
  # memory-review Stop-block for high-severity CONFLICTS only.
  # Reads the review queue via hooks/lib/review-queue.sh (block-and-log); fires
  # only when a high-severity CONFLICT item is unaddressed AND the operator has
  # not opted out. The memory-review thresholds it consults are resolved env >
  # user-manifest.json :: hooks.memory_review > default inside review-queue.sh
  #. Advisory degrade: if the queue lib is absent, no-op.
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

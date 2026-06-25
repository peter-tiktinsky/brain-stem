#!/bin/bash
# Hook: SessionStart — auto-close integrity backstop (T-3).
# SessionEnd (session-deregister.sh) spawns the auto-close integrity subset on a
# GRACEFUL exit, but it never fires on SIGKILL/crash/terminal-close — so a crashed
# session never runs the integrity pass. This backstop catches that case: it scans
# the coordination registry for a prior session that went STALE WITHOUT a clean
# close (the reconcile-sessions.sh crash predicate — status not closed /
# closed-pending AND dead pid AND last_heartbeat older than STALE_THRESHOLD_SECS)
# and that has not already been swept, then runs the (T-1 commit-free)
# close orchestrator ONCE, detached, and stamps `auto_close_swept_at` on the swept
# rows so a later SessionStart does not re-run the subset for them.
# Ownership boundary: registry REAPING stays owned by reconcile-sessions.sh — this
# backstop adds ONLY the integrity pass the reaper never runs; it never deletes a
# row.
# Concurrency: lockf-guarded against a dedicated auto-close-backstop.lock (the
# feedback_shell_lock_pattern `/usr/bin/lockf -k -t 0` re-exec; -t 0 = non-blocking
# so two concurrently-starting sessions don't both sweep the same dead one — the
# loser hits contention and skips cleanly). The `auto_close_swept_at` marker covers
# the sequential case.
# NEVER blocks SessionStart (spawns the close detached); NEVER fail-hard; exits 0
# on every path. Graceful no-op when jq/lockf/registry are absent.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

command -v jq >/dev/null 2>&1 || exit 0

# --- lockf concurrency guard (auto-close-backstop.lock) ----------------------
# Re-exec self under /usr/bin/lockf -k -t 0 so the whole find-mark-spawn decision
# runs while holding the advisory lock; -t 0 = non-blocking (exit 75 on contention
# -> a concurrent backstop is already running; skip cleanly). Mirrors
# reconcile-sessions.sh's guard but on a DEDICATED lock so it never contends with
# an actual reconcile.
ensure_coord_dir 2>/dev/null || true
AUTO_CLOSE_LOCK="${COORD_DIR:-${CLAUDE_STATE_ROOT:-$HOME/.local/state/brain-stem}/.coordination}/auto-close-backstop.lock"
if [ -z "${AUTO_CLOSE_BACKSTOP_LOCKED:-}" ] && command -v lockf >/dev/null 2>&1; then
  export AUTO_CLOSE_BACKSTOP_LOCKED=1
  /usr/bin/lockf -k -t 0 "$AUTO_CLOSE_LOCK" "$0" "$@" >/dev/null 2>&1 || true
  # Any rc (incl. 75 contention) -> exit 0: the backstop is best-effort and must
  # never disrupt SessionStart.
  exit 0
fi

# --- crashed-session sweep ---------------------------------------------------
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
now_epoch=$(date +%s)
reg=$(read_registry 2>/dev/null) || exit 0

sids=$(printf '%s' "$reg" | jq -r '.sessions // {} | keys[]' 2>/dev/null) || exit 0

found=0
for sid in $sids; do
  status=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].status // ""' 2>/dev/null)
  swept=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].auto_close_swept_at // ""' 2>/dev/null)

  # Already swept -> never re-run the subset for this row.
  [ -n "$swept" ] && [ "$swept" != "null" ] && continue

  # A clean close (closed) or a row the reconciler will reconcile
  # (closed-pending-reconciliation) is NOT a crash — skip.
  case "$status" in
    closed|closed-pending-reconciliation) continue ;;
  esac

  pid=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].pid // 0' 2>/dev/null)
  hb=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].last_heartbeat // ""' 2>/dev/null)

  # Live pid -> the session is still running, not crashed. Hard skip.
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "null" ]; then
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
  fi

  # Fresh heartbeat -> hard KEEP override even if the pid looked dead (mirrors the
  # reconcile-sessions.sh bidirectional heartbeat check). Only a STALE heartbeat
  # (or none) qualifies as crashed.
  if [ -n "$hb" ] && [ "$hb" != "null" ]; then
    hb_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$hb" +%s 2>/dev/null || echo 0)
    if [ "$hb_epoch" -gt 0 ] && [ $(( now_epoch - hb_epoch )) -le "${STALE_THRESHOLD_SECS:-1800}" ]; then
      continue
    fi
  fi

  # Crashed/killed session that never closed cleanly + unswept -> mark it swept.
  reg=$(printf '%s' "$reg" | jq --arg s "$sid" --arg now "$now" \
    '.sessions[$s].auto_close_swept_at = $now' 2>/dev/null)
  found=1
done

# If at least one crashed row was found, persist the swept markers and run the
# (global, commit-free) integrity chain ONCE, detached. The orchestrator's own 60s
# idempotent_guard collapses any redundant run; the chain is global so a single run
# covers every crashed session swept this pass.
if [ "$found" -eq 1 ]; then
  [ -n "$reg" ] && write_registry "$reg"
  SESSION_CLOSE="$SCRIPT_DIR/../skills/librarian/capabilities/session-close.sh"
  if [ -f "$SESSION_CLOSE" ]; then
    ( "$SESSION_CLOSE" >/dev/null 2>&1 & ) || true
  fi
fi

exit 0

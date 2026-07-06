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
# Concurrency: TWO nested lockf guards, acquired outer -> inner (non-cyclic, so
# deadlock-free). OUTER = a dedicated auto-close-backstop.lock process-dedup guard
# (feedback_shell_lock_pattern `/usr/bin/lockf -k -t 0` re-exec; -t 0 = non-blocking
# so two concurrently-starting sessions don't both sweep the same dead one — the
# loser hits contention and skips cleanly; the `auto_close_swept_at` marker covers
# the sequential case). INNER = the SHARED registry.lock (REGISTRY_LOCK, `-t 2`) held
# across ONLY the read_registry..write_registry RMW span, so the backstop's sweep is
# mutually exclusive with the registrar + reaper (they all take REGISTRY_LOCK) —
# closing the lost-update race. The inner lock is RELEASED before the detached
# session-close.sh spawn (which itself takes REGISTRY_LOCK): the sweep runs in a
# re-exec'd child that hands its `found` result to the lock-released parent via a
# sentinel file, and the parent spawns after the lock releases (see the guards below).
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

# --- nested REGISTRY_LOCK guard (registry.lock), released BEFORE the spawn ----
# Second, INNER self-reexec (distinct marker) that holds the SHARED REGISTRY_LOCK
# across ONLY the read_registry..write_registry RMW span below — so the backstop's
# sweep is mutually exclusive with the registrar + reaper (they all take
# REGISTRY_LOCK), closing the lost-update race. `-t 2`; on contention/timeout any rc
# -> exit 0 (fail-open, NO partial write). When lockf is absent the guard is skipped
# and the sweep runs unlocked (graceful-degrade), mirroring the outer guard.
# CRITICAL (spawn-release): the detached session-close.sh spawn sits AFTER
# write_registry, and session-close.sh itself takes REGISTRY_LOCK via its own
# registry writers. If the spawn ran while THIS hook still held REGISTRY_LOCK, the
# detached child would stall behind (or self-deadlock against) the parent's held
# lock. So the inner lock is scoped to END at write_registry: the re-exec'd child
# does read..sweep..write_registry and communicates whether a crashed row was found
# via a sentinel file under COORD_DIR (NOT an exit code — that collides with lockf's
# 75 contention code), then EXITS, releasing the inner lock. The PARENT (this branch,
# after lockf returns and the lock is RELEASED) reads the sentinel and does the
# detached spawn in the lock-released context.
# Honor an inherited sentinel path (the re-exec'd child MUST use the SAME path the
# parent set — so do not recompute it with the child's own $$; ${VAR:-default}
# preserves the exported value across the re-exec).
AUTO_CLOSE_FOUND_SENTINEL="${AUTO_CLOSE_FOUND_SENTINEL:-${AUTO_CLOSE_LOCK%.lock}.found.$$}"
if [ -z "${AUTO_CLOSE_REGISTRY_LOCKED:-}" ] \
   && [ -n "${REGISTRY_LOCK:-}" ] \
   && command -v lockf >/dev/null 2>&1; then
  export AUTO_CLOSE_REGISTRY_LOCKED=1
  export AUTO_CLOSE_FOUND_SENTINEL
  rm -f "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null || true
  # Child runs read..sweep..write_registry under REGISTRY_LOCK, writes the sentinel,
  # and returns (it never reaches the spawn — the marker gates it below). On lockf
  # return the inner lock is RELEASED.
  /usr/bin/lockf -k -t 2 "$REGISTRY_LOCK" "$0" "$@" >/dev/null 2>&1 || true
  # --- lock RELEASED here. Spawn the detached close ONCE if the child found a crash.
  if [ -f "$AUTO_CLOSE_FOUND_SENTINEL" ]; then
    rm -f "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null || true
    SESSION_CLOSE="$SCRIPT_DIR/../skills/librarian/capabilities/session-close.sh"
    if [ -f "$SESSION_CLOSE" ]; then
      ( "$SESSION_CLOSE" >/dev/null 2>&1 & ) || true
    fi
  fi
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

# If at least one crashed row was found, persist the swept markers. write_registry
# is the LAST operation under the inner REGISTRY_LOCK — the detached session-close.sh
# spawn is DELIBERATELY NOT here: when this body runs under the inner lock re-exec
# (AUTO_CLOSE_REGISTRY_LOCKED set), the spawn would inherit the held REGISTRY_LOCK and
# the detached child (which takes REGISTRY_LOCK itself) would stall behind it. Instead
# the `found` result is handed to the lock-RELEASED parent via the sentinel file, and
# the parent spawns after lockf returns (see the nested guard above). When lockf is
# absent (no inner re-exec — this body runs inline, unlocked), we spawn HERE directly,
# since there is no held lock to release (graceful-degrade path).
if [ "$found" -eq 1 ]; then
  [ -n "$reg" ] && write_registry "$reg"
  if [ -n "${AUTO_CLOSE_REGISTRY_LOCKED:-}" ] && [ -n "${AUTO_CLOSE_FOUND_SENTINEL:-}" ]; then
    # Locked re-exec: hand the found flag to the lock-released parent; DO NOT spawn.
    : > "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null || true
  else
    # Unlocked (lockf-absent) inline path: no held lock to release -> spawn here.
    SESSION_CLOSE="$SCRIPT_DIR/../skills/librarian/capabilities/session-close.sh"
    if [ -f "$SESSION_CLOSE" ]; then
      ( "$SESSION_CLOSE" >/dev/null 2>&1 & ) || true
    fi
  fi
fi

exit 0

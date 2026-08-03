#!/bin/bash
# Hook/utility: reconcile-sessions — the coordination-registry reconciler.
#
# C2-owned body (.6: reconciliation is effectively always-on;
# session-deregister conditionally spawns this in the background, and
# `/librarian … close` Step 2c also calls it). It is the registry PRODUCER that
# reaps stale + closed-pending peers so peer-awareness / R-42 /
# pre-compact files_modified / post-compaction restore stay live.
#
# UNOWNED-SURFACE closure (feedback_f3_ownership_vs_tree_asis_port_gap): named
# in + but absent from the1.1 hooks roster — T-04
# authors the body AND adds the2 "Owns" +.1 roster line (T-12).
#
# Concurrency: TWO nested lockf guards, acquired outer -> inner (non-cyclic, so
# deadlock-free). OUTER = reconcile.lock process-dedup (/3 lock roster;
# feedback_shell_lock_pattern `/usr/bin/lockf -k -t 0` re-exec) — a second concurrent
# run hits contention (exit 75) and skips cleanly (reconciliation is idempotent).
# INNER = the SHARED registry.lock (REGISTRY_LOCK, `-t 2`) held across the entire
# read_registry..write_registry RMW span, so the reaper's sweep is mutually exclusive
# with the registrar (track-vault-write.sh) and the integrity-backstop — closing the
# lost-update race (two writers, two different locks, same file). The registrar only
# ever takes REGISTRY_LOCK, so the outer-dedup -> inner-registry order never cycles.
#
# Reconcile rules (data-non-destructive on live processes):
#   - stale (dead pid OR last_heartbeat older than STALE_THRESHOLD_SECS): drop.
#   - closed: drop (the session ended cleanly; deregister already marked it).
#   - closed-pending-reconciliation: drop (this run reconciles it).
#   - active with a live pid + fresh heartbeat: keep.
# After the sweep, clear pending_reconciliation + stamp last_reconciled.
#
# NEVER fail-hard. Invoked detached/background or via the librarian; exit 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# --- lockf concurrency guard (reconcile.lock) --------------------------------
# Re-exec self under /usr/bin/lockf -k -t 0 so the whole reconcile runs while
# holding the advisory lock; -t 0 = non-blocking (exit 75 on contention -> a
# concurrent reconcile is already running; skip cleanly).
ensure_coord_dir 2>/dev/null || true
if [ -z "${RECONCILE_SESSIONS_LOCKED:-}" ] \
   && [ -n "${RECONCILE_LOCK:-}" ] \
   && command -v lockf >/dev/null 2>&1; then
  export RECONCILE_SESSIONS_LOCKED=1
  rc=0
  /usr/bin/lockf -k -t 0 "$RECONCILE_LOCK" "$0" "$@" || rc=$?
  # 75 = contention (another reconcile holds the lock); any rc -> exit 0 (the
  # reconcile is best-effort and must never disrupt a SessionEnd spawn).
  exit 0
fi

# --- nested REGISTRY_LOCK guard (registry.lock) ------------------------------
# Second, INNER self-reexec (distinct marker var so it never collides with the
# outer reconcile.lock guard) that holds the SHARED REGISTRY_LOCK across the whole
# read_registry..write_registry span below. This is what makes the reaper's RMW
# mutually exclusive with the registrar + backstop (they all take REGISTRY_LOCK).
# `-t 2` = block up to 2s; on contention/timeout any rc -> exit 0 (fail-open, NO
# partial write — write_registry is not reached under a failed acquisition). When
# lockf is absent the guard is skipped and the sweep runs unlocked (graceful-degrade,
# exit 0), mirroring the outer guard. The sweep body ends at write_registry with NO
# trailing spawn, so wrapping the whole post-outer-guard body is clean (nothing
# mutates the registry after the inner lock releases).
if [ -z "${RECONCILE_SESSIONS_REGISTRY_LOCKED:-}" ] \
   && [ -n "${REGISTRY_LOCK:-}" ] \
   && command -v lockf >/dev/null 2>&1; then
  export RECONCILE_SESSIONS_REGISTRY_LOCKED=1
  /usr/bin/lockf -k -t 2 "$REGISTRY_LOCK" "$0" "$@" || true
  exit 0
fi

# --- reconcile sweep ---------------------------------------------------------
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
now_epoch=$(date +%s)
reg=$(read_registry)

sids=$(printf '%s' "$reg" | jq -r '.sessions // {} | keys[]' 2>/dev/null) || sids=""

for sid in $sids; do
  status=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].status // ""' 2>/dev/null)
  pid=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].pid // 0' 2>/dev/null)
  hb=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].last_heartbeat // ""' 2>/dev/null)
  started=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].started // ""' 2>/dev/null)

  drop=false
  case "$status" in
    closed|closed-pending-reconciliation)
      drop=true
      ;;
    *)
      # active (or unknown). T-1: the per-row keep/drop verdict is now
      # the SHARED session_liveness_verdict (registry.sh) — HEARTBEAT-AUTHORITATIVE with
      # pid demoted to advisory, so the reaper, the view, session-close, and the
      # integrity-backstop all score a row identically. fresh_hb -> KEEP; stale_hb ->
      # DROP (INCLUDING the live-pid + stale-hb phantom quadrant — DROP, which renders
      # the non-unique shared pid inert, the fix). Absent/unparseable hb floors
      # staleness off `started` (always written at session-register.sh:47) so a no-hb
      # row still ages; pid is a keep-signal ONLY when hb AND started are both absent
      # (backward-compat shim for a pre-heartbeat registry).
      #
      # BEHAVIOR DELTA vs the pre-128 inline block: the fresh/stale-hb and dead-pid+no-hb
      # quadrants are byte-preserved (matrix + tz + fixtures stay GREEN). The one
      # changed quadrant is live-pid + absent-hb + STALE `started`: previously KEPT (pid
      # live, no hb to flip it), now DROPPED via the started-floor — the intended "no-hb
      # rows still age" aging behavior, not a regression. The BSD-only `date -u -jf` parse
      # moved into the verdict's portable iso8601_to_epoch (BSD + GNU), so a Linux adopter
      # no longer silently degrades to pid-only.
      if session_liveness_verdict "$pid" "$hb" "$started" "$now_epoch"; then
        drop=false
      else
        drop=true
      fi
      ;;
  esac

  if [ "$drop" = "true" ]; then
    reg=$(printf '%s' "$reg" | jq --arg s "$sid" 'del(.sessions[$s])' 2>/dev/null)
  fi
done

# Clear pending flag + stamp last_reconciled.
reg=$(printf '%s' "$reg" | jq --arg now "$now" \
  '.pending_reconciliation = false | .last_reconciled = $now' 2>/dev/null)

[ -n "$reg" ] && write_registry "$reg"

exit 0

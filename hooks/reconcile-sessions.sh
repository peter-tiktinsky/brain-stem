#!/bin/bash
# Hook/utility: reconcile-sessions — the coordination-registry reconciler.
# C2-owned body (.6: reconciliation is effectively always-on;
# session-deregister conditionally spawns this in the background, and
# `/librarian … close` Step 2c also calls it). It is the registry PRODUCER that
# reaps stale + closed-pending peers so peer-awareness / R-42 / R-36 /
# pre-compact files_modified / post-compaction restore stay live.
# UNOWNED-SURFACE closure (feedback_f3_ownership_vs_tree_asis_port_gap): named
# in + but absent from the1.1 hooks roster — T-04
# authors the body AND adds the2 "Owns" +.1 roster line (T-12).
# Concurrency: TWO nested lockf guards, acquired outer -> inner (non-cyclic, so
# deadlock-free). OUTER = reconcile.lock process-dedup (/3 lock roster;
# feedback_shell_lock_pattern `/usr/bin/lockf -k -t 0` re-exec) — a second concurrent
# run hits contention (exit 75) and skips cleanly (reconciliation is idempotent).
# INNER = the SHARED registry.lock (REGISTRY_LOCK, `-t 2`) held across the entire
# read_registry..write_registry RMW span, so the reaper's sweep is mutually exclusive
# with the registrar (track-vault-write.sh) and the integrity-backstop — closing the
# lost-update race (two writers, two different locks, same file). The registrar only
# ever takes REGISTRY_LOCK, so the outer-dedup -> inner-registry order never cycles.
# Reconcile rules (data-non-destructive on live processes):
#   - stale (dead pid OR last_heartbeat older than STALE_THRESHOLD_SECS): drop.
#   - closed: drop (the session ended cleanly; deregister already marked it).
#   - closed-pending-reconciliation: drop (this run reconciles it).
#   - active with a live pid + fresh heartbeat: keep.
# After the sweep, clear pending_reconciliation + stamp last_reconciled.
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

  drop=false
  case "$status" in
    closed|closed-pending-reconciliation)
      drop=true
      ;;
    *)
      # active (or unknown). A NON-LIVE pid provisionally marks the row for drop, but
      # a FRESH heartbeat is a HARD KEEP override (S2): a live, actively-writing peer
      # whose recorded pid we cannot kill -0 (e.g. the pid resolver missed, or the
      # process re-exec'd) must NOT be reaped while it is still heartbeating. So the
      # heartbeat check runs UNCONDITIONALLY (no longer gated behind drop=false) and is
      # bidirectional: fresh -> drop=false (KEEP override), stale -> drop=true. Reap
      # only when BOTH signals say gone.
      # : the liveness test is the shared pid_is_live predicate, which treats
      # null / 0 / missing / non-numeric / dead as NOT live -> drop=true. This closes
      # the prior null-pid blind spot: the dead-pid check was gated behind
      # `pid != 0 && pid != null`, so a null/0-pid row was reaped ONLY if its heartbeat
      # was also stale; a null-pid row with no/fresh heartbeat survived forever.
      if ! pid_is_live "$pid"; then
        drop=true
      fi
      if [ -n "$hb" ] && [ "$hb" != "null" ]; then
        hb_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$hb" +%s 2>/dev/null || echo 0)
        if [ "$hb_epoch" -gt 0 ]; then
          if [ $(( now_epoch - hb_epoch )) -gt "${STALE_THRESHOLD_SECS:-1800}" ]; then
            drop=true
          else
            # Fresh heartbeat: hard KEEP override even if the pid looked dead.
            drop=false
          fi
        fi
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

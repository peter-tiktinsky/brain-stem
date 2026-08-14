#!/bin/bash
# Hook: SessionStart — auto-close integrity backstop (T-3).
#
# SessionEnd (session-deregister.sh) spawns the auto-close integrity subset on a
# GRACEFUL exit, but it never fires on SIGKILL/crash/terminal-close — so a crashed
# session never runs the integrity pass. This backstop catches that case: it scans
# the coordination registry for a prior session that went STALE WITHOUT a clean
# close (the reconcile-sessions.sh crash predicate — status not closed /
# closed-pending AND dead pid AND last_heartbeat older than STALE_THRESHOLD_SECS)
# and that has not already been swept, then runs the (T-1 commit-free)
# close orchestrator ONCE, detached, and stamps `auto_close_swept_at` on the swept
# rows so a later SessionStart does not re-run the subset for them.
#
# Ownership boundary: registry REAPING stays owned by reconcile-sessions.sh — this
# backstop adds ONLY the integrity pass the reaper never runs, and (T-8) it
# TRIGGERS the reaper at SessionStart with a detached, lock-released spawn to catch
# crash/SIGKILL ends that never fired SessionEnd plus the long-lived shared-pid ghost
# class. It still deletes NO row itself — the spawned reconcile-sessions.sh does all
# reaping, under its own reconcile.lock + REGISTRY_LOCK.
#
# Concurrency: TWO nested lockf guards, acquired outer -> inner (non-cyclic, so
# deadlock-free). OUTER = a dedicated auto-close-backstop.lock process-dedup guard
# (the canonical `/usr/bin/lockf -k -t 0` re-exec; -t 0 = non-blocking
# so two concurrently-starting sessions don't both sweep the same dead one — the
# loser hits contention and skips cleanly; the `auto_close_swept_at` marker covers
# the sequential case). INNER = the SHARED registry.lock (REGISTRY_LOCK, `-t 2`) held
# across ONLY the read_registry..write_registry RMW span, so the backstop's sweep is
# mutually exclusive with the registrar + reaper (they all take REGISTRY_LOCK) —
# closing the lost-update race. The inner lock is RELEASED before the detached
# session-close.sh spawn (which itself takes REGISTRY_LOCK): the sweep runs in a
# re-exec'd child that hands its `found` result to the lock-released parent via a
# sentinel file, and the parent spawns after the lock releases (see the guards below).
#
# NEVER blocks SessionStart (spawns the close detached); NEVER fail-hard; exits 0
# on every path. Graceful no-op when jq/lockf/registry are absent.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

# --- Detached-spawn env pin (T-3) -----------------------------------
# Sanctioned call-site block, verbatim from hooks/lib/detached-spawn-env.sh's header.
# Re-pins CLAUDE_HOME (the measured escape vector) + MEMORY_DIR to the tree THIS hook was
# loaded from, so every detached child below resolves that tree instead of re-minting
# $HOME/.claude from paths.sh's ${VAR:-default} fallback. In a real install the anchor
# IS $HOME/.claude, so the pin is a byte no-op.
# ONE placement covers all FOUR of this hook's spawns — spawn_reconcile() (149/:238),
# the lock-RELEASED close, and the no-lockf inline degrade close — because it sits above
# both lockf re-execs and the pinned env is EXPORTED, so each re-exec'd child inherits it
# and re-pins idempotently. ADDITIVE: the lock-ordering below is untouched; the pin runs
# long before REGISTRY_LOCK is ever taken and holds no resource of its own.
# PLACEMENT: the block resolves $SCRIPT_DIR, so it MUST stay BELOW the SCRIPT_DIR
# assignment. Above it every clause degrades politely and the scrub is INERT while
# grepping identically to a working one (asserted by the T-2/T-3 line-order guards).
_DSE="$SCRIPT_DIR/lib/detached-spawn-env.sh"
# shellcheck source=/dev/null
if "${BASH:-bash}" -n "$_DSE" 2>/dev/null; then . "$_DSE" 2>/dev/null || true; fi
if ! command -v pin_detached_spawn_env >/dev/null 2>&1; then pin_detached_spawn_env() { :; }; fi
pin_detached_spawn_env || true

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
# BOUNDED drain: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook chain hangs with zero output. The
# bound is PER READ: a stream that keeps delivering is never truncated, only silence
# is. HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE; do :; done
  unset _STDIN_WAIT _STDIN_LINE
fi

command -v jq >/dev/null 2>&1 || exit 0

# T-8: detached SessionStart reconcile trigger. Spawns reconcile-sessions.sh in
# the background from the LOCK-RELEASED context ONLY — NEVER while this hook holds
# REGISTRY_LOCK, because the reaper's own inner guard takes REGISTRY_LOCK itself and a spawn
# under the held lock would stall the child. The reaper owns all reaping; this only triggers
# it. Idempotent; the reaper's outer reconcile.lock (-t 0) dedups concurrent runs.
spawn_reconcile() {
  local reconciler="$SCRIPT_DIR/reconcile-sessions.sh"
  if [ -x "$reconciler" ] || [ -f "$reconciler" ]; then
    ( "$reconciler" >/dev/null 2>&1 & ) || true
  fi
}

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
#
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
    # The re-exec'd child wrote the crashed session's id on line 1 of the sentinel and its
    # stored cwd (if the row carried one) on line 2; read both and thread them into the
    # detached close so the recovery close reconciles the CRASHED session's spoke/handoff,
    # not the recovering session's own $PWD.
    _crashed_sid="$(head -1 "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null | tr -d '[:space:]')"
    # A path may legitimately contain spaces, so this line is NOT whitespace-stripped the
    # way the id is — only the trailing newline goes, which $( ) removes.
    _crashed_cwd="$(sed -n '2p' "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null)"
    rm -f "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null || true
    # WHY $HOME WHEN THE ROW CARRIES NO CWD (the ordinary case today: no registry writer
    # records one). The alternative is to thread nothing — and then the detached close
    # falls back to ambient $PWD, which here is the RECOVERING session's launch dir. That
    # would attribute a crashed session's close to whatever spoke happens to be starting
    # up, which is precisely the cross-spoke mis-write this threading exists to stop. A
    # crashed session's cwd is genuinely unknowable at this point, so the resolution lands
    # deliberately on the registry's documented `home` catch-all instead of guessing.
    [ -n "$_crashed_cwd" ] || _crashed_cwd="$HOME"
    SESSION_CLOSE="$SCRIPT_DIR/../skills/librarian/capabilities/session-close.sh"
    if [ -f "$SESSION_CLOSE" ]; then
      if [ -n "$_crashed_sid" ]; then
        ( "$SESSION_CLOSE" --session-id "$_crashed_sid" --cwd "$_crashed_cwd" >/dev/null 2>&1 & ) || true
      else
        ( "$SESSION_CLOSE" --cwd "$_crashed_cwd" >/dev/null 2>&1 & ) || true
      fi
    fi
  fi
  # T-8: SessionStart reconcile trigger, fired here in the LOCK-RELEASED context
  # (lockf has returned, REGISTRY_LOCK is free). session-register.sh (#1 in the SessionStart
  # array; this backstop is #7) has already refreshed the own row's heartbeat, so the T-1
  # verdict KEEPS the own row while the sweep reaps stale-hb ghosts on the shared pid.
  spawn_reconcile
  exit 0
fi

# --- crashed-session sweep ---------------------------------------------------
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
now_epoch=$(date +%s)
reg=$(read_registry 2>/dev/null) || exit 0

sids=$(printf '%s' "$reg" | jq -r '.sessions // {} | keys[]' 2>/dev/null) || exit 0

found=0
crashed_sid=""
crashed_cwd=""
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
  started=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].started // ""' 2>/dev/null)

  # T-5: crash detection now routes through the SHARED heartbeat-authoritative
  # verdict (session_liveness_verdict, registry.sh) so the backstop, the reaper, the view,
  # and session-close all agree on the same (pid, hb, started, now) input. A row whose
  # verdict is LIVE is still running -> NOT a crash, skip. Only a DEAD verdict on a
  # non-closed, unswept row qualifies as crashed. This replaces BOTH the pid hard-skip
  # AND the BSD-only `date -u -jf` fresh-hb check (140) — the epoch parse now lives in the
  # verdict's portable iso8601_to_epoch (BSD + GNU), so a Linux adopter no longer silently
  # degrades. Ownership boundary unchanged: this backstop deletes NO row (reaping stays
  # owned by reconcile-sessions.sh); it only marks auto_close_swept_at + spawns the close.
  if session_liveness_verdict "$pid" "$hb" "$started" "$now_epoch"; then
    continue
  fi

  # Crashed/killed session that never closed cleanly + unswept -> mark it swept.
  reg=$(printf '%s' "$reg" | jq --arg s "$sid" --arg now "$now" \
    '.sessions[$s].auto_close_swept_at = $now' 2>/dev/null)
  # Capture the FIRST crashed session's id to thread into the recovery close spawn, so the
  # detached close reconciles the CRASHED session's spoke/handoff (session-close reads
  # .sessions[<id>].touched_files for its R-25 scan) rather than the recovering session's
  # own $PWD. The spawn fires once; the first crashed row is the threaded identity.
  # Its cwd rides along WHEN THE ROW HAS ONE — read defensively rather than assumed,
  # because no registry writer records the field today (session-register.sh stores
  # session_id/source/pid/heartbeat/touched_files). A row that gains one later is threaded
  # with no further change here; an absent one takes the documented fallback at the spawn.
  if [ -z "$crashed_sid" ]; then
    crashed_sid="$sid"
    crashed_cwd=$(printf '%s' "$reg" | jq -r --arg s "$sid" '.sessions[$s].cwd // ""' 2>/dev/null)
  fi
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
    # Locked re-exec: hand the crashed session's id (line 1) and its stored cwd (line 2,
    # empty when the row carries none) to the lock-released parent via the sentinel CONTENT
    # (the parent — which does not run this sweep — reads them back and threads them into
    # the spawn); DO NOT spawn here (the spawn must run lock-released).
    printf '%s\n%s\n' "$crashed_sid" "$crashed_cwd" > "$AUTO_CLOSE_FOUND_SENTINEL" 2>/dev/null || true
  else
    # Unlocked (lockf-absent) inline path: no held lock to release -> spawn here, threading
    # the crashed session's id so the close reconciles the crashed spoke. Same cwd rule as
    # the lock-released spawn above: the row's stored cwd when it has one, else $HOME —
    # never this recovering session's ambient, which belongs to a different session.
    [ -n "$crashed_cwd" ] || crashed_cwd="$HOME"
    SESSION_CLOSE="$SCRIPT_DIR/../skills/librarian/capabilities/session-close.sh"
    if [ -f "$SESSION_CLOSE" ]; then
      if [ -n "$crashed_sid" ]; then
        ( "$SESSION_CLOSE" --session-id "$crashed_sid" --cwd "$crashed_cwd" >/dev/null 2>&1 & ) || true
      else
        ( "$SESSION_CLOSE" --cwd "$crashed_cwd" >/dev/null 2>&1 & ) || true
      fi
    fi
  fi
fi

# T-8: no-lockf graceful-degrade path — the sweep ran inline with NO held
# REGISTRY_LOCK, so trigger the reaper here. Guarded on AUTO_CLOSE_REGISTRY_LOCKED so the
# locked re-exec child (which reaches this same exit while HOLDING REGISTRY_LOCK) never
# spawns — its parent spawns in the lock-released branch above instead.
if [ -z "${AUTO_CLOSE_REGISTRY_LOCKED:-}" ]; then
  spawn_reconcile
fi

exit 0

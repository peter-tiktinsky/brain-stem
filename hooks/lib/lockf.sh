# lib/lockf.sh — macOS-native lockf re-exec sentinel for cron wrappers.
# Source this file — do not execute it.
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/lockf.sh"
#   claude_lockf_reexec "$HOOKS_STATE/<job-name>.lock" "$@"
#   # ... rest of script runs while holding the lock ...
#
# Forward the wrapping script's "$@" to the helper so re-exec preserves
# original positional args. Cron wrappers fired by launchd typically have
# no args, but the forward is mandatory for correctness — `"$@"` inside
# this function shadows the script's args otherwise.
#
# Pattern: re-exec the calling script under `/usr/bin/lockf -k -t 0 LOCKFILE`
# so the entire body runs while holding an exclusive advisory lock. Flags:
#   -k : keep the lockfile after the inner process exits (single file path
#        is reused across invocations; safer than tempfile-per-run).
#   -t 0 : non-blocking acquisition (exit 75 on contention).
# The kernel releases the lock automatically on process death, eliminating
# the stale-lock failure class that affects userspace lock primitives. This
# is the canonical macOS shell-lock pattern (the kernel-backed
# /usr/bin/lockf -k -t 0 re-exec): not flock (not shipped on macOS
# /usr/bin), not mkdir-based (rejected during multi-session-coordination
# design 2026-03-30).
#
# Lockfile path constraint — $HOOKS_STATE only:
#   Lockfiles MUST live under $HOOKS_STATE (resolved by lib/paths.sh from
#   user-manifest.json .paths.hooks_state, else $CLAUDE_STATE_ROOT/hooks-state),
#   never /tmp. /tmp is unreliable for cross-invocation persistence (Apple
#   periodic cleanup, tmpfs on some configurations, no SELinux context),
#   and HOOKS_STATE is the single sanctioned hooks-runtime-state directory.
#   Callers are responsible for `mkdir -p "$(dirname "$LOCK_FILE")"` before
#   invoking this helper; this is unconditional best practice and matches
#   the live librarian-cron.sh convention.
#
# Exit semantics:
#   - Outer (no sentinel) call: re-execs $0 under lockf and exits with the
#     inner script's status, OR exits 0 + writes a skip line to
#     $LOG_DIR/<basename>-skip.log when lockf returns 75 (contention).
#   - Inner call (sentinel set): returns 0 immediately so the caller can
#     proceed with real work.
#
# Caller environment requirements:
#   $LOG_DIR (or $LOG_FILE → caller's $(dirname "$LOG_FILE") substitute):
#     Must be set before invoking the helper. Skip-log path is
#     "$LOG_DIR/<basename>-skip.log" (matches existing librarian-cron
#     convention). Helper falls back to "$HOOKS_STATE/<basename>-skip.log"
#     if $LOG_DIR is unset or empty, so it never errors at log-time.
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile/readarray, no
# ${var,,}/${var^^} case conversion, no regex capture groups in production
# paths, no [[ =~ ]] for branching.
#
# Coordination: T-2e (multi-session-coordination lock-wrapper) — if
# T-2e ships first, it consumes this helper; otherwise ships and T-2e
# adopts. Same public entry point either direction.

# Sentinel env var. Set on the outer invocation BEFORE the lockf re-exec;
# the inner re-execed process inherits it and short-circuits the helper.
# Single global is sufficient: cron wrappers do not nest, and any future
# nesting case can carry the lockfile path in the sentinel value to detect
# already-held locks vs. new requests.
: "${CLAUDE_LOCKF_REEXECED:=}"

# claude_lockf_reexec <lockfile>
#
# On the outer call (sentinel empty): re-exec $0 under /usr/bin/lockf and
# exit. On the inner call (sentinel set): return 0 so the caller proceeds.
# Never returns to the outer caller — either exits 0 (clean skip) or exits
# with the inner script's status.
claude_lockf_reexec() {
  local lockfile="$1"
  if [ -z "$lockfile" ]; then
    echo "claude_lockf_reexec: missing lockfile arg" >&2
    return 2
  fi
  shift  # drop lockfile; remaining "$@" = caller's forwarded script args

  # Inner call — sentinel set means we are running inside the re-exec
  # already; release control back to the caller.
  if [ -n "${CLAUDE_LOCKF_REEXECED:-}" ]; then
    return 0
  fi

  # Outer call — set sentinel, re-exec, classify exit.
  export CLAUDE_LOCKF_REEXECED=1

  # Resolve skip-log location. Prefer caller's $LOG_DIR (matches existing
  # librarian-cron convention). Fall back to $HOOKS_STATE if unset; final
  # fallback to the lockfile's parent directory so the helper never errors.
  local skip_log_dir="${LOG_DIR:-${HOOKS_STATE:-}}"
  if [ -z "$skip_log_dir" ]; then
    skip_log_dir="$(dirname "$lockfile")"
  fi
  mkdir -p "$skip_log_dir" 2>/dev/null || true

  local self_basename
  self_basename="$(basename "$0")"
  local skip_log="$skip_log_dir/${self_basename%.sh}-skip.log"

  # `set -e` tolerance: capture rc via || rc=$? so the helper works
  # whether or not callers set -e. lockf returning 75 (contention) is a
  # normal-skip path, not a script-killing error.
  local rc=0
  /usr/bin/lockf -k -t 0 "$lockfile" "$0" "$@" || rc=$?

  if [ "$rc" -eq 75 ]; then
    echo "$(date -Iseconds) $self_basename skip: lockf contention on $lockfile" >> "$skip_log"
    exit 0
  fi
  exit "$rc"
}

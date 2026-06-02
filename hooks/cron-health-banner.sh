#!/bin/bash
# Hook: SessionStart (#2) — surface launchd/cron lane health as an advisory banner.
#
# SessionStart fire-order #2:
# session-register -> cron-health-banner -> spec-context-inject -> session-start
# -> memory-seed. Reports launchd/cron health (last-run staleness of the
# foundation lanes — writer-reconciler + doc-amender) so the operator notices a
# silently-dead background lane at session start.
#
# Surfacing contract: emit an additionalContext banner ONLY when a lane looks
# degraded (its stdout log is missing or stale beyond the staleness window);
# silent/clean pass when every lane is healthy. NEVER denies; always exits 0.
# Advisory-only — a SessionStart hook that non-zero-exits can break the session.
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR. registry.sh
# provides format_output_allow; paths.sh provides CLAUDE_LOG_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_HOME:-$HOME/.claude}/logs}"

# No log dir yet (fresh install, no lane has ever run) -> nothing to report.
[ -d "$LOG_DIR" ] || exit 0

# Staleness window (seconds). Manifest-overridable; default 24h — the lanes are
# WatchPaths-primary + relaxed-interval backstop, so a >24h-cold stdout log is a
# reasonable "looks dead" signal. Use the paths.sh manifest reader when present.
STALE_SECS="${CRON_HEALTH_STALE_SECS:-}"
if [ -z "$STALE_SECS" ] && command -v _manifest_get >/dev/null 2>&1; then
  _v="$(_manifest_get .hooks.cron_health.stale_threshold_secs 2>/dev/null || true)"
  [ -n "$_v" ] && STALE_SECS="$_v"
  unset _v
fi
[ -z "$STALE_SECS" ] && STALE_SECS=86400

now_epoch=$(date +%s)
degraded=""

# Check each foundation lane's stdout log. A lane is degraded if its stdout log
# is present but cold beyond the window. An ABSENT log is NOT flagged (the lane
# may simply never have fired on a fresh / quiet install — flagging it would be
# noise; absence is benign until the lane has run at least once).
for lane in writer-reconciler doc-amender; do
  log="$LOG_DIR/${lane}-stdout.log"
  [ -f "$log" ] || continue
  mtime=$(stat -f %m "$log" 2>/dev/null || stat -c %Y "$log" 2>/dev/null || echo 0)
  [ "$mtime" -gt 0 ] 2>/dev/null || continue
  age=$(( now_epoch - mtime ))
  if [ "$age" -gt "$STALE_SECS" ]; then
    hours=$(( age / 3600 ))
    degraded="${degraded}
- ${lane}: last activity ${hours}h ago (stale; lane may not be firing)."
  fi
done

# Healthy -> silent clean pass.
[ -z "$degraded" ] && exit 0

banner="[Cron health] One or more background lanes look stale:${degraded}
Check launchctl status + ${LOG_DIR}/<lane>-stderr.log."

if command -v format_output_allow >/dev/null 2>&1; then
  format_output_allow "SessionStart" "$banner" || true
else
  printf '%s\n' "$banner" >&2
fi

exit 0

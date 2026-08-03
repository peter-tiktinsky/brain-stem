#!/bin/bash
# Hook: SessionStart (#2) — surface launchd/cron lane health as an advisory banner.
#
# SessionStart fire-order #2 (session-register -> cron-health-banner ->
# spec-context-inject -> session-start -> memory-seed).
# Reports launchd/cron health for the two foundation lanes
# (writer-reconciler + doc-amender) so the operator notices a silently-dead
# background lane at session start.
#
# Two signals, both from where the lane actually leaves evidence:
#   1. NEVER-LOADED (dead-on-arrival): probe `launchctl print gui/$UID/<label>`
#      for each foundation label. A staged-but-never-bootstrapped lane produces
#      no activity at all, so staleness alone can never see it — the liveness
#      probe flags it. Only assessed when the GUI domain is reachable (a non-Aqua
#      / headless shell has none — skip rather than false-flag every lane).
#   2. STALENESS: read the mtime of the wrapper's TRUE activity signal — the
#      timestamped fire log (<lane>-<ts>.log) + audit log (<lane>-audit.log) the
#      cron wrappers write. The plist StandardOutPath (<lane>-stdout.log) is NEVER
#      written by the wrappers (they redirect all output to the timestamped/audit
#      logs), so reading it was structurally blind; that read is retired here.
#
# Surfacing contract: emit an additionalContext banner ONLY when a lane looks
# not-loaded or stale; silent/clean pass when every lane is healthy. An ABSENT
# activity log on a LOADED lane is benign (the lane may simply not have fired yet
# on a fresh/quiet install). NEVER denies; always exits 0 — a SessionStart hook
# that non-zero-exits can break the session.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR. registry.sh
# provides format_output_allow; paths.sh provides CLAUDE_LOG_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_HOME:-$HOME/.claude}/logs}"

# Staleness window (seconds). Manifest-overridable; default 24h — the lanes are
# WatchPaths-primary + relaxed-interval backstop, so a >24h-cold activity log is a
# reasonable "looks dead" signal. Use the paths.sh manifest reader when present.
STALE_SECS="${CRON_HEALTH_STALE_SECS:-}"
if [ -z "$STALE_SECS" ] && command -v _manifest_get >/dev/null 2>&1; then
  _v="$(_manifest_get .hooks.cron_health.stale_threshold_secs 2>/dev/null || true)"
  [ -n "$_v" ] && STALE_SECS="$_v"
  unset _v
fi
[ -z "$STALE_SECS" ] && STALE_SECS=86400

# launchctl liveness seam (mockable for CI, which has no launchd GUI domain).
LAUNCHCTL="${CRON_HEALTH_LAUNCHCTL:-launchctl}"
LABEL_PREFIX="${LABEL_PREFIX:-com.brain-stem}"
uid="$(id -u 2>/dev/null || echo 0)"
domain="gui/$uid"

# Assess liveness only when the GUI domain is actually reachable. A non-Aqua shell
# (ssh / headless) has no gui/$UID domain, so probing every label would false-flag
# them all; when the domain query fails we simply skip the never-loaded check.
launchctl_domain_ok=0
if { command -v "$LAUNCHCTL" >/dev/null 2>&1 || [ -x "$LAUNCHCTL" ]; } \
   && "$LAUNCHCTL" print "$domain" >/dev/null 2>&1; then
  launchctl_domain_ok=1
fi

# Newest mtime of a lane's TRUE activity signal: any <lane>-*.log EXCEPT the
# never-written plist StandardOut/ErrorPath. Echoes an epoch, or empty if none.
newest_activity_mtime() {
  local lane="$1" f base m best=""
  for f in "$LOG_DIR/${lane}-"*.log; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      "${lane}-stdout.log"|"${lane}-stderr.log") continue ;;
    esac
    m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    [ "$m" -gt 0 ] 2>/dev/null || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; fi
  done
  printf '%s' "$best"
}

now_epoch=$(date +%s)
degraded=""

for lane in writer-reconciler doc-amender; do
  label="${LABEL_PREFIX}.${lane}"

  # (1) never-loaded (dead-on-arrival): the label is not in the GUI domain.
  if [ "$launchctl_domain_ok" = "1" ] \
     && ! "$LAUNCHCTL" print "$domain/$label" >/dev/null 2>&1; then
    degraded="${degraded}
- ${lane}: lane not loaded (${label} is not bootstrapped in ${domain}; run the SessionStart bootstrap or render-launchd.sh ${lane})."
    continue
  fi

  # (2) staleness: read the wrapper's true activity signal. LOG_DIR may not exist
  # yet on a lane that has never fired — that is benign (nothing to flag).
  [ -d "$LOG_DIR" ] || continue
  mtime="$(newest_activity_mtime "$lane")"
  [ -n "$mtime" ] || continue    # loaded but no activity yet -> benign
  age=$(( now_epoch - mtime ))
  if [ "$age" -gt "$STALE_SECS" ]; then
    hours=$(( age / 3600 ))
    degraded="${degraded}
- ${lane}: last activity ${hours}h ago (stale; lane may not be firing)."
  fi
done

# Healthy -> silent clean pass.
[ -z "$degraded" ] && exit 0

banner="[Cron health] One or more background lanes look degraded:${degraded}
Check launchctl status + ${LOG_DIR}/<lane>-stderr.log."

if command -v format_output_allow >/dev/null 2>&1; then
  format_output_allow "SessionStart" "$banner" || true
else
  printf '%s\n' "$banner" >&2
fi

exit 0

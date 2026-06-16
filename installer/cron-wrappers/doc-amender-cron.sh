#!/bin/bash
# installer/cron-wrappers/doc-amender-cron.sh — launchd entry-point for the
# doc-amender LLM lane (WatchPaths-only; event-driven on packet-land).
# Invoked by the doc-amender launchd job (templates/launchd/
# doc-amender.plist.tmpl: WatchPaths only — no StartInterval). Resolves the
# SINGLE canonical ephemeral staging root ($CLAUDE_STATE_ROOT/vault-staging,
# once per fire. doc-amender NEVER writes the destination (R-34 boundary); it
# round-trips amender-replacement packets back to staging.
# (sources paths.sh + lockf.sh, sets PATH, logs under $CLAUDE_LOG_DIR,
# lock-protects the tick). doc-amender's own in-process lockf single-instance
# guard ($STAGING_ROOT/.doc-amender.lock) is the real concurrency boundary;
# this wrapper-level lock is belt-and-suspenders against duplicate fires.
# Bash 3.2 compatible (R-23). jq not required by this wrapper.

set -uo pipefail

PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi
LOCK_LIB="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/lockf.sh"
if [ -r "$LOCK_LIB" ]; then
  # shellcheck source=/dev/null
  . "$LOCK_LIB"
fi

export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CH="${CLAUDE_HOME:-$HOME/.claude}"
LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/logs}"
LOG_FILE="$LOG_DIR/doc-amender-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR="${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}"
LOCK_FILE="$STATE_DIR/doc-amender-cron.lock"

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

echo "=== doc-amender-cron launchd-fire-received: $(date -Iseconds) pid=$$ ===" >> "$LOG_FILE"

if command -v claude_lockf_reexec >/dev/null 2>&1; then
  claude_lockf_reexec "$LOCK_FILE" "$@"
fi

# The SINGLE canonical ephemeral staging root (.2:74), same value
# the plist's WatchPaths fires on and process.sh defaults to.
STAGING_ROOT="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/vault-staging"

PROCESS_SH="$CH/skills/doc-amender/process.sh"
if [ ! -r "$PROCESS_SH" ]; then
  echo "$(date -Iseconds) doc-amender-cron: process.sh missing at $PROCESS_SH; aborting tick" >> "$LOG_FILE"
  exit 2
fi

AUDIT_LOG="$LOG_DIR/doc-amender-audit.log"

echo "$(date -Iseconds) doc-amender-cron: invoking process.sh --staging-root $STAGING_ROOT --once" >> "$LOG_FILE"

# shellcheck disable=SC2086
bash "$PROCESS_SH" --staging-root "$STAGING_ROOT" --audit-log "$AUDIT_LOG" --once >> "$LOG_FILE" 2>&1

rc=$?
echo "$(date -Iseconds) doc-amender-cron: process.sh exit rc=$rc" >> "$LOG_FILE"
exit "$rc"

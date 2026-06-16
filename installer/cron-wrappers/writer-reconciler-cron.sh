#!/bin/bash
# installer/cron-wrappers/writer-reconciler-cron.sh — launchd entry-point for
# the writer-reconciler (the sole R-34 mechanical destination writer).
# Invoked by the writer-reconciler launchd job (templates/launchd/
# writer-reconciler.plist.tmpl: WatchPaths primary + relaxed StartInterval
# backstop). Resolves the SINGLE canonical ephemeral staging root
# ($CLAUDE_STATE_ROOT/vault-staging,.2:74) and invokes
# $CLAUDE_HOME/skills/writer-reconciler/process.sh once per fire with the
# reconciler arg surface (--staging-root / --rules-file / --audit-log).
# flags (--vault-root / --state-file → process.sh exit 2): this wrapper carries
# the reconciler's ACTUAL arg surface. Mirrors the librarian/architect
# cron-wrapper pattern (sources paths.sh + lockf.sh, sets PATH, logs under
# $CLAUDE_LOG_DIR, lock-protects the tick). The in-process lockf single-instance
# guard inside process.sh (HARD PREREQ) is the real concurrency boundary;
# this wrapper-level lock is belt-and-suspenders against duplicate cron fires.
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
LOG_FILE="$LOG_DIR/writer-reconciler-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR="${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}"
LOCK_FILE="$STATE_DIR/writer-reconciler-cron.lock"

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

echo "=== writer-reconciler-cron launchd-fire-received: $(date -Iseconds) pid=$$ ===" >> "$LOG_FILE"

if command -v claude_lockf_reexec >/dev/null 2>&1; then
  claude_lockf_reexec "$LOCK_FILE" "$@"
fi

# The SINGLE canonical ephemeral staging root (.2:74). paths.sh
# exports CLAUDE_STATE_ROOT (= ~/.local/state/brain-stem); the same value the
# plist's WatchPaths fires on (render-launchd.sh WRITER_STAGING_ROOT) and the
# value process.sh defaults to.
STAGING_ROOT="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/vault-staging"

PROCESS_SH="$CH/skills/writer-reconciler/process.sh"
if [ ! -r "$PROCESS_SH" ]; then
  echo "$(date -Iseconds) writer-reconciler-cron: process.sh missing at $PROCESS_SH; aborting tick" >> "$LOG_FILE"
  exit 2
fi

RULES_FILE="$CH/governance/vault-writers-rules.json"
AUDIT_LOG="$LOG_DIR/writer-reconciler-audit.log"

echo "$(date -Iseconds) writer-reconciler-cron: invoking process.sh --staging-root $STAGING_ROOT" >> "$LOG_FILE"

reconciler_args=""
reconciler_args="$reconciler_args --staging-root $STAGING_ROOT"
[ -r "$RULES_FILE" ] && reconciler_args="$reconciler_args --rules-file $RULES_FILE"
reconciler_args="$reconciler_args --audit-log $AUDIT_LOG"

# shellcheck disable=SC2086
bash "$PROCESS_SH" $reconciler_args >> "$LOG_FILE" 2>&1

rc=$?
echo "$(date -Iseconds) writer-reconciler-cron: process.sh exit rc=$rc" >> "$LOG_FILE"
exit "$rc"

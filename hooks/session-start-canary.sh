#!/bin/bash
# SessionStart hook: legacy plans-dir tripwire.
#
# Detect resurrection of the legacy ~/.claude/plans/ stub with unexpected contents.
# The plans dir migrated to ~/.claude-plans/ on 2026-04-13; the legacy
# ~/.claude/plans/ path is retired. Any non-README.md content under it is a
# stale-reference bug; capture forensics, log, and preserve the placeholder for manual
# investigation.
#
# Invocation contract (Claude Code SessionStart):
#   env: HOOKS_STATE_OVERRIDE (test isolation), PLANS_DIR_DEAD (legacy-stub path override)
#
# Failure mode: best-effort, read-only forensics. The hook MUST NOT block SessionStart
# on internal errors (it always exits 0).

set -uo pipefail

# === Path resolution (foundation-repo dev: self-contained; live deploy: paths.sh-equivalent) ===
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
PLANS_DIR_DEAD="${PLANS_DIR_DEAD:-${CLAUDE_HOME:-$HOME/.claude}/plans}"

mkdir -p "$HOOKS_STATE" 2>/dev/null || true

# Part (1): Plans-dir tripwire (verbatim —)
LOG="$HOOKS_STATE/tripwire.log"

UNEXPECTED=""
if [[ -d "$PLANS_DIR_DEAD" ]]; then
  UNEXPECTED=$(/bin/ls -A "$PLANS_DIR_DEAD" 2>/dev/null | grep -v '^README\.md$' || true)
fi
if [[ -n "$UNEXPECTED" ]]; then
  TS="$(date -Iseconds)"
  FORENSICS="$HOOKS_STATE/tripwire-forensics.log"
  {
    echo "=========="
    echo "$TS REAPPEARANCE — capturing forensics (canary pid $$)"
    echo "-- ancestor chain (pid → ppid → ...):"
    pid=$$
    depth=0
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $depth -lt 12 ]]; do
      ps -o pid=,ppid=,etime=,command= -p "$pid" 2>/dev/null
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      depth=$((depth + 1))
    done
    echo "-- dir contents:"
    ls -la@ "$PLANS_DIR_DEAD" 2>&1
    echo "-- dir stat:"
    stat -f "birth=%SB ctime=%Sc mtime=%Sm uid=%Su" "$PLANS_DIR_DEAD" 2>&1
    echo "-- lsof on dir:"
    lsof +D "$PLANS_DIR_DEAD" 2>&1 | head -20
    echo "-- recent claude/node/bun/python/mcp processes:"
    ps -axo pid=,ppid=,etime=,command= 2>/dev/null | grep -E '(claude|node|bun|python|mcp)' | grep -v grep | head -30
    echo "-- launchd jobs (claude / cron / librarian / digest / meeting / plan-exec / backlog / architect):"
    launchctl list 2>&1 | grep -E 'claude|cron|librarian|digest|meeting|plan-exec|backlog|architect' | head -20
    echo ""
  } >> "$FORENSICS"
  echo "$TS TRIPWIRE: $PLANS_DIR_DEAD has unexpected contents — see tripwire-forensics.log" >> "$LOG"
  echo "$TS   unexpected files: $(echo "$UNEXPECTED" | tr '\n' ' ')" >> "$LOG"
  echo "$TS   action: NONE (manual investigation required — placeholder README preserved)" >> "$LOG"
fi

exit 0

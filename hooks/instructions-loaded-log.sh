#!/bin/bash
# Hook: InstructionsLoaded — memory-reaching-model diagnostic logger.
#
# Records that instructions (CLAUDE.md / MEMORY.md / rules) reached the model
# for a session — the diagnostic signal used to verify the curated memory tier
# is actually loading.
#
# Side-effect contract: writes ONE diagnostic row to the state-root diagnostic
# log and nothing else. No additionalContext, no registry mutation, no vault
# write. Exits 0 silently. NEVER fail-hard.
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0

# Diagnostic log path under the hooks-state root (HOOKS_STATE_OVERRIDE wins for
# test isolation). The diagnostic is machine-local ephemeral state, not a vault
# artifact — it never reaches Logs/.
STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}}"
DIAG_LOG="$STATE_DIR/instructions-loaded.log"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Read the InstructionsLoaded payload (best-effort; not required). Drain stdin.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi
[ -z "$SESSION_ID" ] && SESSION_ID="-"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Append one diagnostic row: timestamp + event + session id. The presence of a
# row is the memory-reaching-model signal (instructions were loaded this fire).
printf '%s\tInstructionsLoaded\tsession=%s\n' "$TS" "$SESSION_ID" >> "$DIAG_LOG" 2>/dev/null || true

exit 0

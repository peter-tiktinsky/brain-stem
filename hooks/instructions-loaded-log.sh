#!/bin/bash
# Hook: InstructionsLoaded — memory-reaching-model diagnostic logger.
# C5-owned body in a C2 slot (canonical/InstructionsLoaded ->
# instructions-loaded-log.sh;.12: memory-reaching-model
# diagnostic at the C2<->C5 boundary). Records that instructions (CLAUDE.md /
# MEMORY.md / rules) reached the model for a session — the diagnostic signal
# used to verify the curated memory tier is actually loading.
# Side-effect contract: writes ONE diagnostic row to the state-root diagnostic
# log and nothing else. No additionalContext, no registry mutation, no vault
# write. Exits 0 silently. NEVER fail-hard.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0

# Diagnostic log path under the hooks-state root (HOOKS_STATE_OVERRIDE wins for
# test isolation). The diagnostic is machine-local ephemeral state, not a vault
# artifact — it never reaches Logs/.
STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
DIAG_LOG="$STATE_DIR/instructions-loaded.log"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Read the InstructionsLoaded payload (best-effort; not required). Drain stdin.
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line is accumulated as it arrives, so a stream that keeps
# delivering is never truncated and an expiry mid-stream keeps what already arrived;
# the trailing-newline trim reproduces `$(cat)` exactly, and absent input still reads
# as empty. HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls
# back rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    INPUT="${INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${INPUT%$'\n'}" != "$INPUT" ]; do INPUT="${INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
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

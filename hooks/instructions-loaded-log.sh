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
# UNCHANGED and load-bearing: a consumer parses this row's trailing `session=<id>`
# field, so the tab log keeps its exact shape and stays the last-line surface.
printf '%s\tInstructionsLoaded\tsession=%s\n' "$TS" "$SESSION_ID" >> "$DIAG_LOG" 2>/dev/null || true

# --- Context-budget telemetry row (NDJSON sibling log) -----------------------
# The InstructionsLoaded payload carries the identity of the file that loaded —
# file_path, memory_type (User/Project/Local/Managed) and load_reason
# (session_start / nested_traversal / path_glob_match / include / compact) — and
# the tab row above discards all three. This block RETAINS them, plus the loaded
# file's byte size, so the always-on context budget is measured from the
# platform's own event instead of estimated. Detection only: the loaded file is
# read for its SIZE, never written.
#
# ONE log, rows discriminated by "event": the SessionEnd hook-spill counter in
# session-deregister.sh appends its own row shape ("hook-spill-count") here, so
# a reader has a single per-session telemetry stream to open. Row builder is jq
# (correct escaping for arbitrary paths); jq absent degrades to the tab row
# alone, which is why that row stays the presence signal. NEVER fail-hard.
NDJSON_LOG="$STATE_DIR/instructions-loaded.ndjson"
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  IL_FILE=$(printf '%s' "$INPUT" | jq -r '.file_path // empty' 2>/dev/null)
  IL_TYPE=$(printf '%s' "$INPUT" | jq -r '.memory_type // empty' 2>/dev/null)
  IL_REASON=$(printf '%s' "$INPUT" | jq -r '.load_reason // empty' 2>/dev/null)
  # bytes: wc -c of the loaded file when it is a readable regular file; empty
  # (rendered as JSON null) when the path is absent, unreadable or not a file.
  IL_BYTES=""
  if [ -n "$IL_FILE" ] && [ -f "$IL_FILE" ] && [ -r "$IL_FILE" ]; then
    IL_BYTES=$(wc -c < "$IL_FILE" 2>/dev/null | tr -d ' ')
  fi
  jq -cn \
    --arg ts "$TS" --arg sid "$SESSION_ID" --arg fp "$IL_FILE" \
    --arg mt "$IL_TYPE" --arg lr "$IL_REASON" --arg by "$IL_BYTES" \
    '{ts: $ts, event: "instructions-loaded", session_id: $sid,
      file_path: $fp, memory_type: $mt, load_reason: $lr,
      bytes: (if $by == "" then null else ($by | tonumber) end)}' \
    >> "$NDJSON_LOG" 2>/dev/null || true
fi

exit 0

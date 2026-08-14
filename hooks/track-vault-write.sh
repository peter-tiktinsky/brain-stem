#!/bin/bash
# BASH-BLINDNESS (R-5, documented-by-design): this Edit|Write write-time governor is blind to Bash-tool writes (heredoc/cp/mv/tee/python) — the "honest residual" labeled at placement-validate.sh:95-96; the rule-30 Phase-2 PreToolUse Bash command-screen escalation is data-gated + NOT built.
# Hook: PreToolUse + PostToolUse Edit|Write — record the touched file path into
# the current session's registry row (the R-42 loop).
#
# PostToolUse Edit|Write fire-order #1 (the
# R-42 loop): records touched files into the registry so prompt-context.sh
# surfaces peer summaries / file-overlap warnings on the next UserPromptSubmit.
# REGISTRY_FILE comes from lib/registry.sh.
#
# Graceful no-op when $CLAUDE_SESSION_ID (and stdin .session_id) are absent, or
# when the tool input carries no file path. NEVER fail-hard; never deny.
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

# --- append the touched path to this session's row (capped, deduped) ---------
track_path() {
  command -v jq >/dev/null 2>&1 || return 0
  local sid="$1" path="$2" reg updated now
  [ -z "$sid" ] && return 0
  [ -z "$path" ] && return 0
  ensure_coord_dir 2>/dev/null || true
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  reg=$(read_registry)
  # Upsert the row if absent (a PreToolUse may fire before SessionStart racing);
  # append the path (unique) and cap the list at TOUCHED_FILES_CAP (keep newest).
  updated=$(printf '%s' "$reg" | jq \
    --arg sid "$sid" --arg f "$path" --arg hb "$now" --argjson cap "${TOUCHED_FILES_CAP:-100}" '
    .sessions[$sid] = ((.sessions[$sid] // {status: "active", touched_files: []})
      + {last_heartbeat: $hb})
    | .sessions[$sid].touched_files =
        (((.sessions[$sid].touched_files // []) + [$f]) | unique)
    | .sessions[$sid].touched_files =
        (.sessions[$sid].touched_files
          | if (length > $cap) then .[(length - $cap):] else . end)
    ' 2>/dev/null)
  [ -n "$updated" ] && write_registry "$updated"
}

# Internal lockf re-exec target: `track-vault-write.sh --do-track <sid> <path>`
# runs the upsert while holding registry.lock, then exits. Checked BEFORE stdin
# parsing — the re-exec carries its args, not a stdin payload.
if [ "${1:-}" = "--do-track" ]; then
  track_path "${2:-}" "${3:-}"
  exit 0
fi

# Read the tool-use JSON payload once (session_id + tool file path).
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

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi
[ -z "$SESSION_ID" ] && exit 0

# The edited/written path lives at tool_input.file_path (Edit + Write both).
FILE_PATH=""
if [ -n "$INPUT" ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
fi
[ -z "$FILE_PATH" ] && exit 0

ensure_coord_dir 2>/dev/null || true
if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
  lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-track "$SESSION_ID" "$FILE_PATH" >/dev/null 2>&1 \
    || track_path "$SESSION_ID" "$FILE_PATH"
else
  track_path "$SESSION_ID" "$FILE_PATH"
fi

exit 0

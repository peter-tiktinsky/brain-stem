#!/bin/bash
# Hook: SessionStart (#1) — register the session into the coordination registry
# AND, on source=compact, restore the per-session checkpoint + reset the
# context-pressure gauge (rotation is relocated to the next checkpoint write).
#
# C2-owned body (canonical/SessionStart fire-order #1;.4 restore +
# rotation;.6 lockf-guarded registry at <coord-root>/.coordination). It must
# run FIRST in the SessionStart row so the registry/checkpoint-restore context
# exists before spec-context-inject (#3), session-start (#4), memory-seed (#5).
#
# Two responsibilities (.4,.6):
#   1. Register / refresh this session's row in session-registry.json
#      (machine-local ephemeral,; REGISTRY_FILE from lib/registry.sh),
#      lockf-guarded against registry.lock.
#   2. On source=compact: re-inject the per-session checkpoint.md verbatim as text
#      additionalContext (the canonical bare checkpoint.md is KEPT in place so both
#      R-26 mandate readers inherit it fresh), AND reset the context-pressure gauge
#      + drop a compact-pending marker (Cause-2). Rotation is NO LONGER
#      owned here: session-register runs at SessionStart only and cannot rotate on
#      the NEXT checkpoint write, so archival is relocated to pre-compact-checkpoint.sh
#      (RULING 3). The .pct reset + marker let the R-26 recompute survive
#      the compaction boundary (prompt-context.sh / stop-checkpoint-check.sh honor it).
#
# Graceful no-op when $CLAUDE_SESSION_ID (and stdin .session_id) are absent —
# the zero-cross-session-pollution invariant. NEVER fail-hard:
# a SessionStart hook that non-zero-exits can break the user's session.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR — no $HOME/.claude
# body literal. registry.sh sources paths.sh and exports COORD_DIR/REGISTRY_FILE.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

# read-modify-write the registry row for $1 (session id) recording pid $2.
# Atomic write via the lib's write_registry (temp+rename). Preserves
# touched_files + started on a re-fire so the R-42 file list survives. Invoked
# directly OR re-exec'd under lockf (the --do-register internal entry-point).
#
# ADVISORY PID (T-1): the recorded pid is ADVISORY / display-only —
# NOT a liveness key and NOT a session-identity key. Multiple Claude session-ids
# provably inhabit one OS process (Task/Agent subagents, /clear-resume-compaction),
# so no OS-process signal can ever make pid unique; liveness is decided by the
# HEARTBEAT-authoritative session_liveness_verdict (registry.sh), which demotes pid
# to a backward-compat shim consulted only when a row carries neither a heartbeat
# nor a `started` floor. `last_heartbeat` (refreshed here + per-prompt + at Stop) and
# `started` (the always-present staleness floor) are the load-bearing fields. The pid
# is still passed explicitly so a lockf re-exec doesn't record the lockf pid, and it
# remains useful for display (peer summaries) — it is simply never the keep-signal.
register_row() {
  command -v jq >/dev/null 2>&1 || return 0
  local sid="$1" rpid="$2" now reg updated
  ensure_coord_dir 2>/dev/null || true
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  reg=$(read_registry)
  updated=$(printf '%s' "$reg" | jq \
    --arg sid "$sid" --argjson pid "$rpid" --arg hb "$now" \
    '.sessions[$sid] = ((.sessions[$sid] // {})
       + {pid: $pid, status: "active", last_heartbeat: $hb}
       + {touched_files: ((.sessions[$sid].touched_files) // []),
          started: ((.sessions[$sid].started) // $hb)})' 2>/dev/null)
  [ -n "$updated" ] && write_registry "$updated"
}

# resolve_session_pid — return the long-lived Claude process pid, NOT the
# transient hook subshell ($$) this SessionStart hook runs in (S2 fix). Storing $$
# (a subshell that exits the instant this hook returns) would make the row look
# dead within milliseconds. Since the reaper's verdict is
# HEARTBEAT-authoritative (session_liveness_verdict in registry.sh, refactored onto
# the shared verdict at reconcile-sessions.sh's per-row drop-block), so the pid is
# advisory — but a sane long-lived pid is still stored for display/backward-compat.
#
# This is a NEW $PPID-comm-walk resolver: walk up to ~4 ancestors via
# `ps -o ppid=`, return the first whose `ps -o comm=` contains 'claude'. It is
# NOT a reuse of session-close's own lookup — that is a session-ID REVERSE lookup
# matching ancestor pids against stored .value.pid rows. The only thing borrowed
# is the prior-art observation that the parent chain is walkable; the technique
# here (comm-name match) is different. Fail-open: fall back to $PPID, then $$, so
# a session always registers even when the walk finds no 'claude' ancestor.
resolve_session_pid() {
  local p="${PPID:-$$}" depth=0 comm
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$depth" -lt 4 ]; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null || true)
    case "$comm" in
      *claude*) printf '%s' "$p"; return 0 ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  # Fail-open: prefer the immediate parent ($PPID) over the subshell ($$).
  printf '%s' "${PPID:-$$}"
}

# Internal lockf re-exec target: `session-register.sh --do-register <sid> <pid>`
# runs the upsert while holding registry.lock, then exits.
if [ "${1:-}" = "--do-register" ]; then
  register_row "${2:-}" "${3:-0}"
  exit 0
fi

# State root for the per-session checkpoint dir. Roots at $CLAUDE_STATE_ROOT
# via the paths.sh SoT — NOT $HOOKS_STATE: the
# checkpoint is ephemeral per-session state. HOOKS_STATE_OVERRIDE wins for test
# isolation (a throwaway dir, never the live state tree).
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"

# Read the SessionStart JSON payload once (session_id + source). Env var preferred;
# stdin .session_id fallback.
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line accumulates as it arrives, so a stream that keeps
# delivering is never truncated; blank lines are PRESERVED and the trailing-newline
# trim reproduces `$(cat)` exactly, so the payload reaches jq byte-identical.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
# The two reference implementations under skills/librarian/capabilities/ are NOT
# equivalent and this is neither: handoff-disposition-check.sh re-arms per read but
# DROPS blank lines; rename-cascade.sh bounds only the FIRST read, then free-runs an
# unbounded `cat`. This is the byte-preserving form the other hook drains carry.
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

SOURCE="startup"
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  _s=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
  [ -n "$_s" ] && SOURCE="$_s"
  unset _s
fi

# Transcript path (Cause-2): needed to record the usage-block count at the
# compaction boundary in the compact-pending marker. Absent on non-compact fires.
TRANSCRIPT_PATH=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
fi

# Graceful no-op: no session id -> cannot register or build a per-session path.
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# --- 1. Register / refresh this session's registry row (lockf-guarded) -------
# Serialize the read-modify-write under registry.lock by re-exec'ing the
# --do-register entry-point under lockf. Fail-open: if lockf is unavailable or
# contended, fall back to a direct (unlocked) upsert so the session still
# registers — the registry self-reaps and write_registry is atomic.
ensure_coord_dir 2>/dev/null || true
# Record the long-lived Claude pid (resolve_session_pid), NOT this hook's
# transient subshell $$ — see the resolver above (S2). Passed explicitly so the
# lockf re-exec records this pid, not the lockf pid.
SESSION_PID=$(resolve_session_pid)
if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
  lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-register "$SESSION_ID" "$SESSION_PID" >/dev/null 2>&1 \
    || register_row "$SESSION_ID" "$SESSION_PID"
else
  register_row "$SESSION_ID" "$SESSION_PID"
fi

# --- 2. Post-compaction checkpoint restore + .pct reset (source=compact) -----
# Only on source=compact (R-26 /.4).
if [ "$SOURCE" = "compact" ]; then
  SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
  CHECKPOINT_FILE="$SESSION_DIR/checkpoint.md"
  # --- Cause-1 (RULING 3): restore/re-inject the canonical checkpoint
  #     verbatim. The bare checkpoint.md is KEPT in place (NO rotation here) so the
  #     fresh session inherits it directly and both R-26 mandate readers see it
  #     fresh — no false-fire. Rotation is relocated to the NEXT checkpoint write in
  #     pre-compact-checkpoint.sh (session-register runs at SessionStart only).
  if [ -f "$CHECKPOINT_FILE" ] && [ -s "$CHECKPOINT_FILE" ]; then
    content=$(cat "$CHECKPOINT_FILE" 2>/dev/null || true)
    if [ -n "$content" ]; then
      restore_text="POST-COMPACTION CHECKPOINT RESTORE:

${content}"
      # Emit as SessionStart additionalContext via the registry helper when
      # available; else a plain stderr advisory. Never block; never deny.
      if command -v format_output_allow >/dev/null 2>&1; then
        format_output_allow "SessionStart" "$restore_text" || true
      else
        printf '%s\n' "$restore_text" >&2
      fi
    fi
  fi
  # --- Cause-2: compact-boundary .pct reset + pending marker ---------
  #     Reset context-pressure.json to pct=0 so the first post-compact
  #     UserPromptSubmit does not read the stale pre-compact value, AND drop a
  #     .compact-pending marker recording the usage-block count at the compaction
  #     boundary. prompt-context.sh (writer call site :65-68) and
  #     stop-checkpoint-check.sh (stop-time refresh :86-89) honor the marker: they
  #     suppress the write_context_pressure recompute until the transcript advances
  #     PAST this boundary (a genuine post-compact usage block appears), so the reset
  #     SURVIVES the recompute (a session-register-only reset is provably inert
  #     without the writer-side guard). The marker clears once a fresh block exists →
  #     real post-compact pressure is written and the R-26 mandate fires as designed.
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
  boundary_blocks=0
  if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ] && command -v jq >/dev/null 2>&1; then
    _bb=$(jq -rs '[ .[]? | objects | ((.message? | objects | .usage?) // .usage?) | objects ] | length' "$TRANSCRIPT_PATH" 2>/dev/null)
    case "$_bb" in ''|*[!0-9]*) _bb=0 ;; esac
    boundary_blocks="$_bb"
    unset _bb
  fi
  printf '%s\n' "$boundary_blocks" > "$SESSION_DIR/.compact-pending" 2>/dev/null || true
  if printf '{"pct":0}\n' > "$SESSION_DIR/context-pressure.json.tmp.$$" 2>/dev/null; then
    mv "$SESSION_DIR/context-pressure.json.tmp.$$" "$SESSION_DIR/context-pressure.json" 2>/dev/null \
      || rm -f "$SESSION_DIR/context-pressure.json.tmp.$$" 2>/dev/null
  fi
fi

exit 0

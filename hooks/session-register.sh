#!/bin/bash
# Hook: SessionStart (#1) — register the session into the coordination registry
# AND, on source=compact, restore the per-session checkpoint + rotate it.
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
#   2. On source=compact with a fresh per-session checkpoint.md present:
#      cat it -> re-inject verbatim as text additionalContext -> mv it to
#      sessions/<sid>/checkpoint-<ts>.md (rotation/archive, NOT delete).
#      Rotation is owned HERE, not by the session-checkpoint skill (.4).
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
# NOT a reuse of session-close.sh:135-143 — that is a session-ID REVERSE lookup
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
# isolation (feedback_test_isolation_for_hooks_state).
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"

# Read the SessionStart JSON payload once (session_id + source). Drain stdin so
# we never block. Env var preferred; stdin .session_id fallback.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
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

# --- 2. Post-compaction checkpoint restore + rotation (source=compact) -------
# Only on source=compact (R-26 /.4). Re-inject the live checkpoint verbatim
# as text, then archive it to a dated variant (rotation, not delete).
if [ "$SOURCE" = "compact" ]; then
  SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
  CHECKPOINT_FILE="$SESSION_DIR/checkpoint.md"
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
      # Rotate: archive the live checkpoint to a dated variant. Owned HERE
      # (the skill writes only the live checkpoint.md, never dated ones).
      ts=$(date -u +"%Y%m%d-%H%M%S")
      mv "$CHECKPOINT_FILE" "$SESSION_DIR/checkpoint-${ts}.md" 2>/dev/null || true
    fi
  fi
fi

exit 0

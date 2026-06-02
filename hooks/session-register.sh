#!/bin/bash
# Hook: SessionStart (#1) — register the session into the coordination registry
# AND, on source=compact, restore the per-session checkpoint + rotate it.
#
# SessionStart fire-order #1 (restore + rotation; lockf-guarded registry at
# <coord-root>/.coordination). It must run FIRST in the SessionStart row so the
# registry/checkpoint-restore context exists before spec-context-inject (#3),
# session-start (#4), memory-seed (#5).
#
# Two responsibilities:
#   1. Register / refresh this session's row in session-registry.json
#      (machine-local ephemeral; REGISTRY_FILE from lib/registry.sh),
#      lockf-guarded against registry.lock.
#   2. On source=compact with a fresh per-session checkpoint.md present:
#      cat it -> re-inject verbatim as text additionalContext -> mv it to
#      sessions/<sid>/checkpoint-<ts>.md (rotation/archive, NOT delete).
#      Rotation is owned HERE, not by the session-checkpoint skill.
#
# Graceful no-op when $CLAUDE_SESSION_ID (and stdin .session_id) are absent —
# the zero-cross-session-pollution invariant. NEVER fail-hard:
# a SessionStart hook that non-zero-exits can break the user's session.
set -uo pipefail

# Portability: resolve libs via $SCRIPT_DIR — no $HOME/.claude
# body literal. registry.sh sources paths.sh and exports COORD_DIR/REGISTRY_FILE.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

# read-modify-write the registry row for $1 (session id) recording pid $2.
# Atomic write via the lib's write_registry (temp+rename). Preserves
# touched_files + started on a re-fire so the R-42 file list survives. Invoked
# directly OR re-exec'd under lockf (the --do-register internal entry-point).
# The recorded pid is the SESSION's process (clean_stale keys `kill -0 $pid` on
# it), passed explicitly so a lockf re-exec doesn't record the lockf pid.
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

# Internal lockf re-exec target: `session-register.sh --do-register <sid> <pid>`
# runs the upsert while holding registry.lock, then exits.
if [ "${1:-}" = "--do-register" ]; then
  register_row "${2:-}" "${3:-0}"
  exit 0
fi

# State root for the per-session checkpoint dir. HOOKS_STATE_OVERRIDE wins for
# test isolation; else HOOKS_STATE
# (resolved by paths.sh under the install convention).
STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}}"

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
SESSION_PID=$$
if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
  lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-register "$SESSION_ID" "$SESSION_PID" >/dev/null 2>&1 \
    || register_row "$SESSION_ID" "$SESSION_PID"
else
  register_row "$SESSION_ID" "$SESSION_PID"
fi

# --- 2. Post-compaction checkpoint restore + rotation (source=compact) -------
# Only on source=compact (R-26). Re-inject the live checkpoint verbatim
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

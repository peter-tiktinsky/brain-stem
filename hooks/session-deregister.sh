#!/bin/bash
# Hook: SessionEnd — deregister the session + conditionally spawn reconciliation.
# C2-owned body (canonical/SessionEnd fire-order: session-deregister ->
# session-episode-write;.6 always-on SessionEnd). Two responsibilities:
#   1. Mark this session's registry row closed (status: "closed").
#   2. Reconciliation is effectively always-on (.6): whenever a
#      `closed-pending-reconciliation` peer exists, spawn reconcile-sessions.sh
#      in the BACKGROUND (a detached, non-blocking spawn — SessionEnd must not
#      block on a synchronous reconcile). reconcile-sessions.sh (T-04) is the
#      registry producer that reaps stale/closed-pending peers under
#      reconcile.lock.
# Graceful no-op when $CLAUDE_SESSION_ID (and stdin .session_id) are absent.
# NEVER fail-hard: a SessionEnd hook that non-zero-exits can disrupt close.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || exit 0

# Drain stdin (SessionEnd JSON payload) so we never block.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi

# Graceful no-op: no session context.
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# --- 1. Mark this session's row closed (read-modify-write) -------------------
# Only mutate a row that exists; if the session never registered, no-op.
close_row() {
  local sid="$1" now reg updated
  ensure_coord_dir 2>/dev/null || true
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  reg=$(read_registry)
  # No-op if the row is absent.
  if [ "$(printf '%s' "$reg" | jq -r --arg sid "$sid" 'has("sessions") and (.sessions | has($sid))' 2>/dev/null)" != "true" ]; then
    return 0
  fi
  updated=$(printf '%s' "$reg" | jq \
    --arg sid "$sid" --arg hb "$now" \
    '.sessions[$sid] = (.sessions[$sid] + {status: "closed", closed_at: $hb})' 2>/dev/null)
  [ -n "$updated" ] && write_registry "$updated"
}

if [ "${1:-}" = "--do-close" ]; then
  close_row "${2:-}"
  exit 0
fi

ensure_coord_dir 2>/dev/null || true
if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
  lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-close "$SESSION_ID" >/dev/null 2>&1 \
    || close_row "$SESSION_ID"
else
  close_row "$SESSION_ID"
fi

# --- 2. Conditional reconcile spawn (.6) -----------------------------------
# Spawn reconcile-sessions.sh in the background only when a closed-pending peer
# exists (another session left the registry pending). The spawn is detached so
# SessionEnd never blocks on the reconcile. reconcile.lock keeps concurrent
# reconciles mutually exclusive (the reconciler itself acquires it).
RECONCILER="$SCRIPT_DIR/reconcile-sessions.sh"
if [ -x "$RECONCILER" ] || [ -f "$RECONCILER" ]; then
  reg=$(read_registry)
  pending_peers=$(printf '%s' "$reg" | jq -r --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[]
       | select(.key != $sid)
       | select(.value.status == "closed-pending-reconciliation")] | length' 2>/dev/null)
  if [ -n "$pending_peers" ] && [ "$pending_peers" -gt 0 ] 2>/dev/null; then
    # Detached background spawn; never block the SessionEnd path.
    ( "$RECONCILER" >/dev/null 2>&1 & ) || true
  fi
fi

# --- 3. Auto-close integrity spawn (T-2) ----------------------------
# This session is ending without a formal `/librarian session-close`, so spawn the
# close orchestrator DETACHED to run the integrity subset — indexes/frontmatter/
# plan-drift stay honest without depending on the user remembering. The orchestrator
# is structurally commit-free (T-1: no git add/commit/push reachable), so
# the plain invocation IS the safe subset — no flag. It auto-detects scope from the
# registry (solo/scoped/reconciler). Suppressed when a manual close already ran (a
# fresh <60s session-close receipt), the same 60s window as the orchestrator's own
# idempotent_guard. Path resolved $SCRIPT_DIR-relative like $RECONCILER. Detached so
# SessionEnd never blocks; never fail-hard.
SESSION_CLOSE="$SCRIPT_DIR/../skills/librarian/capabilities/session-close.sh"
if [ -f "$SESSION_CLOSE" ]; then
  AC_LOG_DIR="${SESSION_CLOSE_LOG_DIR:-${CLAUDE_STATE_ROOT:-$HOME/.local/state/brain-stem}/logs}"
  fresh_receipt=""
  if [ -d "$AC_LOG_DIR" ]; then
    fresh_receipt=$(find "$AC_LOG_DIR" -name 'session-close-*.md' -type f -mmin -1 2>/dev/null | head -1)
  fi
  if [ -z "$fresh_receipt" ]; then
    ( "$SESSION_CLOSE" >/dev/null 2>&1 & ) || true
  fi
fi

exit 0

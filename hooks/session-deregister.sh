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

# --- Detached-spawn env pin (T-3) -----------------------------------
# Sanctioned call-site block, verbatim from hooks/lib/detached-spawn-env.sh's header.
# Re-pins CLAUDE_HOME (the measured escape vector) + MEMORY_DIR to the tree THIS hook was
# loaded from, so the two detached children below (section 2's reconcile spawn and
# section 3's auto-close spawn) never
# re-resolve through paths.sh's ${VAR:-default} fallbacks in whatever ambient they wake
# up in. In a real install the anchor IS $HOME/.claude, so the pin is a byte no-op.
# ADDITIVE — nothing below changes; the pin only has to precede the forks.
# PLACEMENT: the block resolves $SCRIPT_DIR, so it MUST stay BELOW the SCRIPT_DIR
# assignment. Above it every clause degrades politely and the scrub is INERT while
# grepping identically to a working one (asserted by the T-2/T-3 line-order guards).
_DSE="$SCRIPT_DIR/lib/detached-spawn-env.sh"
# shellcheck source=/dev/null
if "${BASH:-bash}" -n "$_DSE" 2>/dev/null; then . "$_DSE" 2>/dev/null || true; fi
if ! command -v pin_detached_spawn_env >/dev/null 2>&1; then pin_detached_spawn_env() { :; }; fi
pin_detached_spawn_env || true

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

# Read the SessionEnd JSON payload (session_id fallback).
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

# THIS session's cwd, from the SessionEnd payload — the session's LAUNCH directory, and the
# only place it is available at this seam (the coordination registry stores no cwd). It is
# read here, next to the session_id, and threaded into the auto-close spawn below for the
# same reason the id is: the detached child cannot recover it for itself. Ambient $PWD is
# NOT a substitute — the detached chain's working directory is whatever the harness lane
# happened to have, and a lane rooted at $HOME resolves the `home` spoke for a session that
# belonged to another one. Empty (no payload / no jq) simply threads nothing, and the child
# falls back to its documented ambient-$PWD resolution exactly as before.
SESSION_CWD=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  SESSION_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi

# Graceful no-op: no session context.
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

ensure_coord_dir 2>/dev/null || true
if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
  lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-close "$SESSION_ID" >/dev/null 2>&1 \
    || close_row "$SESSION_ID"
else
  close_row "$SESSION_ID"
fi

# --- 2. Unconditional reconcile spawn at SessionEnd (T-8,.6) ------
# Spawn reconcile-sessions.sh detached UNCONDITIONALLY at every SessionEnd. The old
# gate (spawn ONLY when a closed-pending-reconciliation peer existed) never tripped on
# `status:active` ghosts keyed to a shared long-lived pid, so stale rows accumulated
# until someone ran the reaper by hand (a measured corpus of 83 rows had 82 stale,
# all reaped by one manual run). The sweep is idempotent + heartbeat-authoritative, and the
# reconciler's own OUTER reconcile.lock (-t 0) dedups concurrent runs, so an
# unconditional spawn is safe. Detached so SessionEnd never blocks; reap OWNERSHIP stays
# with reconcile-sessions.sh — this hook only triggers it. Exits 0 on every path.
RECONCILER="$SCRIPT_DIR/reconcile-sessions.sh"
if [ -x "$RECONCILER" ] || [ -f "$RECONCILER" ]; then
  # Detached background spawn; never block the SessionEnd path.
  ( "$RECONCILER" >/dev/null 2>&1 & ) || true
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
    # T-4: thread THIS session's id explicitly so the detached close self-IDs
    # its OWN registry row (not a sibling's under a shared ancestor pid) instead of the
    # demoted pid ancestor-walk. SESSION_ID is resolved near the top of this file
    # (argv first, env fallback).
    # T-4: thread THIS session's cwd the same way, for the same reason — the close
    # resolves the ACTIVE SPOKE from it, and every binder writer in its chain is scoped to
    # that one key. Without the thread the child resolves its own ambient $PWD and can
    # rewrite another spoke's binder. Both branches keep the id thread; the cwd rides only
    # when the payload carried one.
    if [ -n "$SESSION_CWD" ]; then
      ( "$SESSION_CLOSE" --session-id "$SESSION_ID" --cwd "$SESSION_CWD" >/dev/null 2>&1 & ) || true
    else
      ( "$SESSION_CLOSE" --session-id "$SESSION_ID" >/dev/null 2>&1 & ) || true
    fi
  fi
fi

# --- 4. Hook-spill count (context-budget telemetry) --------------------------
# THE SEAM, stated: this EXISTING SessionEnd hook, not a new registration. The
# count needs (a) a SessionEnd fire and (b) THIS session's id — both already
# resolved above — so no fourth shipped surface (hook body + two settings
# templates + manifest entry) is minted for a one-row diagnostic.
#
# WHAT IS COUNTED: hook output over the harness's additionalContext cap of
# 10,000 characters is not delivered inline — it is written to
# <projects-dir>/<session-id>/tool-results/hook-*-additionalContext.txt and
# replaced in context by a short preview plus the file path. Each such file is
# therefore one hook emission that overflowed. The session dir is the SIBLING of
# the auto-memory dir under the project dir, so it derives from paths.sh's
# resolve_memory_dir() rather than from a second hardcoded projects path.
#
# by_hook is NULL BY CONSTRUCTION: the filename is
# hook-<invocation-uuid>-<index>-additionalContext.txt — it carries no hook
# name, and nothing else on disk maps the uuid back to an emitter. The row says
# so rather than inventing an attribution.
#
# ISOLATION FROM THE HOOK'S CONTRACT: the whole block runs in a subshell with
# `|| true`, after every existing side effect, and touches no variable the
# sections above read. It cannot change this hook's behaviour or exit code.
# The state path expression is byte-identical to the one in
# instructions-loaded-log.sh — the two writers share one log.
(
  command -v jq >/dev/null 2>&1 || exit 0
  SPILL_STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
  mkdir -p "$SPILL_STATE_DIR" 2>/dev/null || exit 0
  command -v resolve_memory_dir >/dev/null 2>&1 || exit 0
  SPILL_PROJECT_DIR="$(dirname "$(resolve_memory_dir)")"
  SPILL_DIR="$SPILL_PROJECT_DIR/$SESSION_ID/tool-results"
  SPILL_COUNT=0
  SPILL_BYTES=0
  if [ -d "$SPILL_DIR" ]; then
    for _sf in "$SPILL_DIR"/hook-*-additionalContext.txt; do
      [ -f "$_sf" ] || continue
      SPILL_COUNT=$((SPILL_COUNT + 1))
      _sb=$(wc -c < "$_sf" 2>/dev/null | tr -d ' ')
      case "$_sb" in ''|*[!0-9]*) _sb=0 ;; esac
      SPILL_BYTES=$((SPILL_BYTES + _sb))
    done
  fi
  jq -cn \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg sid "$SESSION_ID" \
    --arg dir "$SPILL_DIR" --arg n "$SPILL_COUNT" --arg b "$SPILL_BYTES" \
    '{ts: $ts, event: "hook-spill-count", session_id: $sid,
      count: ($n | tonumber), bytes: ($b | tonumber),
      by_hook: null,
      by_hook_unavailable: "spill filenames carry hook-<invocation-uuid>-<index>, not the emitting hook name",
      tool_results_dir: $dir}' \
    >> "$SPILL_STATE_DIR/instructions-loaded.ndjson" 2>/dev/null || true
) >/dev/null 2>&1 || true

exit 0

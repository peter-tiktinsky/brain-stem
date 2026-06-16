#!/usr/bin/env bash
# pre-dispatch-scoping.sh — T-2 — Pre-dispatch scoping protocol
# + 6 refusal filters (extracted standalone module).
# EXTRACTED from the live dispatch.sh inline scoping block into a clean
# standalone module (fork-1(a) clean-modules + fork-2
# orchestrator/lib home). dispatch.sh wires this in at the --job boundary
# (T-06). Decoupled from the 3 DEFER surfaces (governance.sh caps,
# retry-dispatch.sh mechanical-only-retry, the verifier ENHANCEMENT) — this
# module sources NO project .sh lib; it shells out to brief-meta.py + jq only.
# When the brief declares any of scope_summary / team_topology /
# dispatch_decision:
#   1. Write a human-readable scope packet to
#      $ORCHESTRATOR_STATE_DIR/dispatches/<dispatch-id>/scope-packet.md
#   2. Check the refusal-filter cross-validation: decision=dispatch-multi
#      AND any of the 6 filters=fail → filter_check_failed
#   3. Advisory by default (OQ-A first-wave rollout); blocking when
#      ORCHESTRATOR_SP04_T2_BLOCKING=1 (exit code 12, marker "T-2")
# Legacy briefs (no T-2 fields) skip entirely — backwards-compatible.
# The 6 canonical refusal-filter keys (the scoping SHAPE) live in
# brief-meta.py SP04_FILTER_KEYS: sequential_edges, shared_global_context,
# token_value_asymmetry, decomposition_ambiguity, depth_signal,
# verifier_coupling.
# Usage:
#   pre-dispatch-scoping.sh <brief-path> <target-name>
# Env vars:
#   ORCHESTRATOR_SP04_T2_BLOCKING   — "1" to block (exit 12) on filter-fail;
#                                      unset/empty = advisory (default; proceed)
#   ORCHESTRATOR_STATE_DIR          — state dir override
#                                      (default: $CLAUDE_STATE_ROOT/runtime)
#   CLAUDE_HOME                     — install root (default: ~/.claude)
# Exit codes:
#   0   — advisory pass / legacy-skip / brief-meta degraded (graceful)
#   12  — BLOCKING mode + dispatch-multi + filter-fail (marker "T-2")

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIEF_META="$SCRIPT_DIR/brief-meta.py"

BRIEF="${1:-}"
TARGET="${2:-}"
if [[ -z "$BRIEF" ]] || [[ -z "$TARGET" ]]; then
  echo "Usage: pre-dispatch-scoping.sh <brief-path> <target-name>" >&2
  exit 0
fi
if [[ ! -f "$BRIEF" ]]; then
  echo "[T-2] brief not found: $BRIEF (advisory; not blocking)" >&2
  exit 0
fi
if [[ ! -f "$BRIEF_META" ]]; then
  echo "[T-2] brief-meta.py not found: $BRIEF_META (advisory; skipping scoping)" >&2
  exit 0
fi

# --- Locations ---
SP04_STATE_DIR="${ORCHESTRATOR_STATE_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/runtime}"
SP04_DISPATCHES_DIR="$SP04_STATE_DIR/dispatches"

# --- Utility: derive slug from name (mirrors dispatch.sh to_slug) ---
to_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# brief-meta.py has a HARD PyYAML dep (import yaml → sys.exit(2) if absent).
# Graceful-skip via the live `|| echo '{}'` pattern so a missing PyYAML (or any
# brief-meta failure) degrades to legacy-skip rather than blocking dispatch.
_SP04_JSON=$(python3 "$BRIEF_META" scoping "$BRIEF" 2>/dev/null || echo '{}')
_SP04_FIELDS_PRESENT=$(echo "$_SP04_JSON" | jq -r 'if (. == {}) then "no" else "yes" end' 2>/dev/null || echo "no")
if [[ "$_SP04_FIELDS_PRESENT" != "yes" ]]; then
  # Legacy brief (no T-2 fields) — skip entirely (backwards-compatible).
  exit 0
fi

_SP04_SHAPE_ERR=$(echo "$_SP04_JSON" | jq -r '._shape_error // ""' 2>/dev/null || echo "")
if [[ -n "$_SP04_SHAPE_ERR" ]]; then
  # cmd_check (the dispatch.sh T-4 gate) already returned 12 upstream; this
  # branch is defensive.
  {
    echo ""
    echo "================================================================"
    echo "T-2: scoping shape error reached pre-flight gate."
    echo "Brief: $BRIEF"
    echo "Detail: $_SP04_SHAPE_ERR"
    echo "================================================================"
  } >&2
  exit 12
fi

_SP04_SLUG=$(to_slug "$TARGET")
_SP04_TS=$(date -u +"%Y-%m-%dT%H%M%SZ")
_SP04_DISPATCH_ID="${_SP04_SLUG}-${_SP04_TS}"
_SP04_DIR="$SP04_DISPATCHES_DIR/$_SP04_DISPATCH_ID"
mkdir -p "$_SP04_DIR"
_SP04_PACKET="$_SP04_DIR/scope-packet.md"
{
  echo "# Scope Packet — $TARGET"
  echo ""
  echo "**Dispatch ID:** \`$_SP04_DISPATCH_ID\`"
  echo "**Brief:** \`$BRIEF\`"
  echo "**Dispatched at:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "**T-2** (Pre-Dispatch Scoping Protocol)"
  echo ""
  _SP04_SS=$(echo "$_SP04_JSON" | jq -r '.scope_summary // ""')
  if [[ -n "$_SP04_SS" ]]; then
    echo "## Scope summary"
    echo ""
    echo "$_SP04_SS"
    echo ""
  fi
  _SP04_TT=$(echo "$_SP04_JSON" | jq -r '.team_topology // empty')
  if [[ -n "$_SP04_TT" ]]; then
    echo "## Team topology"
    echo ""
    echo "$_SP04_JSON" | jq -r '
      .team_topology |
      "- pattern: \(.pattern)" +
      (if .N then "\n- N: \(.N)" else "" end) +
      (if .synthesis then "\n- synthesis: \(.synthesis)" else "" end) +
      (if .rationale then "\n- rationale: \(.rationale)" else "" end)'
    echo ""
    _SP04_THEMES=$(echo "$_SP04_JSON" | jq -r '.team_topology.themes // [] | length')
    if [[ "$_SP04_THEMES" != "0" ]]; then
      echo "### Themes"
      echo ""
      echo "$_SP04_JSON" | jq -r '
        .team_topology.themes[] |
        "- **\(.name):** \(.brief)" +
        (if (.expected_artifacts | length) > 0
         then "\n  - expected_artifacts: \(.expected_artifacts | join(", "))"
         else "" end)'
      echo ""
    fi
  fi
  _SP04_DD=$(echo "$_SP04_JSON" | jq -r '.dispatch_decision // empty')
  if [[ -n "$_SP04_DD" ]]; then
    echo "## Dispatch decision"
    echo ""
    echo "$_SP04_JSON" | jq -r '
      .dispatch_decision |
      "- decision: \(.decision)" +
      (if .rationale then "\n- rationale: \(.rationale)" else "" end)'
    echo ""
    _SP04_HAS_FILTERS=$(echo "$_SP04_JSON" | jq -r '.dispatch_decision.multi_agent_filters_passed // [] | length')
    if [[ "$_SP04_HAS_FILTERS" != "0" ]]; then
      echo "### Refusal filters"
      echo ""
      echo "$_SP04_JSON" | jq -r '
        .dispatch_decision.multi_agent_filters_passed[] |
        to_entries[] | "- \(.key): \(.value)"'
      echo ""
    fi
  fi
  echo "## Filter-check result"
  echo ""
  _SP04_FCF=$(echo "$_SP04_JSON" | jq -r '.filter_check_failed // false')
  echo "- filter_check_failed: $_SP04_FCF"
  if [[ "$_SP04_FCF" == "true" ]]; then
    echo "- failed filters: $(echo "$_SP04_JSON" | jq -r '.filter_fail_reasons | join(", ")')"
  fi
} > "$_SP04_PACKET"
echo "[T-2] scope packet written: $_SP04_PACKET" >&2

# Cross-validation gate (advisory vs blocking).
_SP04_FCF=$(echo "$_SP04_JSON" | jq -r '.filter_check_failed // false')
if [[ "$_SP04_FCF" == "true" ]]; then
  _SP04_REASONS=$(echo "$_SP04_JSON" | jq -r '.filter_fail_reasons | join(", ")')
  if [[ "${ORCHESTRATOR_SP04_T2_BLOCKING:-}" == "1" ]]; then
    {
      echo ""
      echo "================================================================"
      echo "T-2: dispatch refused (BLOCKING mode)"
      echo "Brief: $BRIEF"
      echo "Decision: dispatch-multi"
      echo "Failed refusal filters: $_SP04_REASONS"
      echo ""
      echo "Re-scope to dispatch-single or abort-and-rescope, or"
      echo "re-decompose until all 6 filters pass."
      echo "Scope packet: $_SP04_PACKET"
      echo "================================================================"
    } >&2
    exit 12
  else
    {
      echo ""
      echo "================================================================"
      echo "[T-2 ADVISORY] dispatch-multi + filter-fail detected — proceeding"
      echo "Brief: $BRIEF"
      echo "Failed filters: $_SP04_REASONS"
      echo "(set ORCHESTRATOR_SP04_T2_BLOCKING=1 to reject this class)"
      echo "Scope packet: $_SP04_PACKET"
      echo "================================================================"
    } >&2
  fi
fi

exit 0

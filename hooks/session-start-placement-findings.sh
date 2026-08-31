#!/bin/bash
# session-start-placement-findings.sh — SessionStart reader for OPEN plans-root placement
# findings AND for OPEN research-declare closed-scope findings (two independent
# librarian-manifest drift_findings leaves; each check is self-gating, so one leaf's
# silence never starves the other's banner).
#
# Leaf 1 — placement. The placement-validate plans-root-namespace sweep persists its
# findings to drift_findings.placement.plans_root (scope-keyed so the vault-scoped sweep
# every graceful session close runs can never clobber it). The leaf's entry class: a
# non-allowlisted plans-root entry that a Bash write slipped past the write-time
# closed-namespace arm (binder-root strays outside the registry-derived writer-owned
# set land here too, path-qualified) — it otherwise sits unnoticed. This hook surfaces
# the open count + entries at session start so they cannot be forgotten, and silences
# itself when findings_count is 0. Mirrors pending-investigations-reminder.sh.
#
# Leaf 2 — research-declare closed scope (T-3). plan-research-declare's anti-scope
# gate warns (never appends) when an undeclared research artifact is found under a
# research_closed:true plan — a warn addressed to a HUMAN adjudicator, but its per-run
# NDJSON channel is transient (session-close deletes the sink; the close log digests only
# top categories). The declare writer therefore persists a summary leaf at
# drift_findings.research_declare_closed_scope; this hook surfaces it at session start so a
# detached close's warns still reach the operator, and silences at findings_count 0 (the
# next close's sweep refreshes the count).
#
# Fail-open: any error / missing manifest exits 0 with no output.

# Source the canonical path resolver so $CLAUDE_STATE_ROOT resolves to the real XDG
# state tier (the pattern the librarian capabilities use; canonical resolver at
# hooks/lib/manifest.sh). SCRIPT_DIR-relative so it resolves both in the installed
# layout (~/.claude/hooks/lib/paths.sh) and the source tree. Best-effort: sourcing is
# fail-open (2>/dev/null || true) so a missing lib never turns the reader fatal.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || true

MANIFEST="${MANIFEST_PATH:-$CLAUDE_STATE_ROOT/manifests/librarian-manifest.json}"
[ -r "$MANIFEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CNT=$(jq -r '.drift_findings.placement.plans_root.findings_count // 0' "$MANIFEST" 2>/dev/null)
case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac

# Only surface when the persisted scope is the plans-root sweep (vault runs also write here).
SCOPE=$(jq -r '.drift_findings.placement.plans_root.scope // ""' "$MANIFEST" 2>/dev/null)

if [ "$CNT" -gt 0 ] && [ "$SCOPE" = "plans-root-namespace" ]; then
  ENTRIES=$(jq -r '(.drift_findings.placement.plans_root.open_entries // []) | join(", ")' "$MANIFEST" 2>/dev/null)
  # The persisted plans_root leaf's entry class: a non-allowlisted plans-root entry is a
  # bare basename; a binder-root stray is PATH-QUALIFIED as _projects/<spoke>/<name>.
  cat <<EOF
[OPEN PLACEMENT FINDINGS — $CNT] The plans-tree closed-namespace sweep (librarian placement-validate --scope <plans-root>) has $CNT open finding(s). Open entries (non-allowlisted plans-root entries, bare basenames; binder-root strays path-qualified as _projects/<spoke>/<name>): ${ENTRIES:-<see manifest drift_findings.placement>}. Re-home each durable artifact to its owning context via the funnel (promote-from-inbox --capture <slug> then graduate) — a plans-root stray lands in <plan>/_research/ — or adjudicate it. Re-run the sweep after re-homing — this reminder silences when findings_count is 0.
EOF
fi

# Leaf 2 (T-3): research-declare closed-scope warns — same jq pattern, its own gate.
RCNT=$(jq -r '.drift_findings.research_declare_closed_scope.findings_count // 0' "$MANIFEST" 2>/dev/null)
case "$RCNT" in ''|*[!0-9]*) RCNT=0 ;; esac

if [ "$RCNT" -gt 0 ]; then
  RENTRIES=$(jq -r '(.drift_findings.research_declare_closed_scope.open_entries // []) | join(", ")' "$MANIFEST" 2>/dev/null)
  cat <<EOF
[OPEN RESEARCH-DECLARE FINDINGS — $RCNT] plan-research-declare found $RCNT undeclared research artifact(s) under research_closed:true plan(s) — the anti-scope gate warned INSTEAD of appending (post-closure drops need human adjudication). Entries (plan-qualified as <plan>: <artifact path>): ${RENTRIES:-<see manifest drift_findings.research_declare_closed_scope>}. Adjudicate each: hand-declare the artifact in that plan's manifest research_artifacts[] (append-only; the declare writer preserves hand-authored entries verbatim), or re-home/remove the file if it does not belong. The next session close re-runs the sweep — this reminder silences when findings_count is 0.
EOF
fi
exit 0

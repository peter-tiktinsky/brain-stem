#!/bin/bash
# session-start-placement-findings.sh — SessionStart reader for OPEN plans-root placement
# findings. The placement-validate plans-root-namespace sweep persists its findings to the
# librarian-manifest (drift_findings.placement.plans_root — scope-keyed so the vault-scoped
# sweep every graceful session close runs can never clobber it); a non-allowlisted plans-root entry that a
# Bash write slipped past the write-time closed-namespace arm otherwise sits unnoticed. This
# hook surfaces the open count + entries at session start so they cannot be forgotten, and
# silences itself when findings_count is 0. Mirrors pending-investigations-reminder.sh.
# Fail-open: any error / missing manifest exits 0 with no output.

MANIFEST="${MANIFEST_PATH:-${CLAUDE_STATE_ROOT:-$HOME/.claude/state}/manifests/librarian-manifest.json}"
[ -r "$MANIFEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CNT=$(jq -r '.drift_findings.placement.plans_root.findings_count // 0' "$MANIFEST" 2>/dev/null)
case "$CNT" in ''|*[!0-9]*) exit 0 ;; esac
[ "$CNT" -gt 0 ] || exit 0

# Only surface when the persisted scope is the plans-root sweep (vault runs also write here).
SCOPE=$(jq -r '.drift_findings.placement.plans_root.scope // ""' "$MANIFEST" 2>/dev/null)
[ "$SCOPE" = "plans-root-namespace" ] || exit 0

ENTRIES=$(jq -r '(.drift_findings.placement.plans_root.open_entries // []) | join(", ")' "$MANIFEST" 2>/dev/null)
cat <<EOF
[OPEN PLACEMENT FINDINGS — $CNT] The plans-tree closed-namespace sweep (librarian placement-validate --scope <plans-root>) has $CNT open finding(s). Non-allowlisted plans-root entries: ${ENTRIES:-<see manifest drift_findings.placement>}. Each durable artifact with no owning plan should be re-homed to its owning context via the funnel (promote-from-inbox --capture <slug> then graduate; the artifact lands in <plan>/_research/), or adjudicated. Re-run the sweep after re-homing — this reminder silences when findings_count is 0.
EOF
exit 0

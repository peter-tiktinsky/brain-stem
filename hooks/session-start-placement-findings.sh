#!/bin/bash
# session-start-placement-findings.sh — SessionStart reader for OPEN plans-root placement
# findings. The placement-validate plans-root-namespace sweep persists its findings to the
# librarian-manifest (drift_findings.placement.plans_root — scope-keyed so the vault-scoped
# sweep every graceful session close runs can never clobber it). That leaf carries two entry
# classes: a non-allowlisted plans-root entry that a Bash write slipped past the write-time
# closed-namespace arm, and a binder-farm stray (a non-symlink entry inside a spoke's research/
# symlink farm) — either otherwise sits unnoticed. This hook surfaces the open count + entries
# at session start so they cannot be forgotten (a farm entry is path-qualified so it is never
# mislabeled as a plans-root entry), and silences itself when findings_count is 0. Mirrors
# pending-investigations-reminder.sh.
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
# The persisted plans_root leaf carries TWO entry classes (both surfaced under this one
# scope, so a farm finding is neither swallowed by the scope gate above nor mislabeled as
# a plans-root entry): a non-allowlisted plans-root entry is a bare basename, a binder-farm
# stray is PATH-QUALIFIED as _projects/<spoke>/research/<name>. The wording names both.
cat <<EOF
[OPEN PLACEMENT FINDINGS — $CNT] The plans-tree closed-namespace sweep (librarian placement-validate --scope <plans-root>) has $CNT open finding(s). Open entries (non-allowlisted plans-root entries, bare basenames; and/or binder-farm strays, path-qualified as _projects/<spoke>/research/<name>): ${ENTRIES:-<see manifest drift_findings.placement>}. Re-home each durable artifact to its owning context via the funnel (promote-from-inbox --capture <slug> then graduate) — a plans-root stray lands in <plan>/_research/; a binder-farm stray is re-homed to its owning plan and the farm regenerates — or adjudicate it. Re-run the sweep after re-homing — this reminder silences when findings_count is 0.
EOF
exit 0

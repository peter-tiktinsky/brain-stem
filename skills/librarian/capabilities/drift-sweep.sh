#!/bin/bash
# drift-sweep — Frontmatter-drift sweep over vault .md files against the
# governance bundle, PLUS the master<->sub aggregation axis with an optional
# --fix that re-points a master's sub_plans[] read-replica to reality.
# Librarian reconciler: the existing frontmatter-drift sweep is PRESERVED; the
# master<->sub aggregation axis is a new extension. Cross-file invariants
# live in this reconciler, NEVER write-time.
# Output Contract
#   Files written: findings to stdout (NDJSON via hooks/lib/findings.sh) or the
#     --output sink. With --fix, the master sub_plans[] read-replica is repaired
#     by delegating to subplan-aggregate.sh — drift-sweep itself never
#     hand-edits sub_plans[]; it invokes the canonical aggregator so the writer
#     stays single-sourced.
#   Failure mode: block-and-log; never write-and-hope. Per-file errors are soft
#     findings, not sweep-fatal.
# CLI:
#   drift-sweep.sh [--dry-run] [--live] [--batch-size N] [--output FILE]
#                  [--plans] [--fix] [--scope <plans-root>]
#     --plans   run ONLY the master<->sub aggregation axis (skip the vault sweep)
#     --fix     repair master sub_plans[] drift via subplan-aggregate.sh
#     --scope   plan-tree root for the master<->sub axis (default: PLANS_DIR)
# Env overrides:
#   FOUNDATION_MASTER   governance bundle (default: $GOVERNANCE_DIR/foundation-master.json)
#   VAULT_ROOT          vault root for the frontmatter sweep
#   PLANS_DIR           plan-tree root for the master<->sub axis
#   FINDINGS_OUTPUT     NDJSON sink
# Bash 3.2 clean per R-23.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/paths.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"

FOUNDATION_MASTER="${FOUNDATION_MASTER:-${GOVERNANCE_DIR:-$CLAUDE_HOME_RES/governance}/foundation-master.json}"

# R-52 union-load: read governance through the foundation<->overlay merger so an
# adopter's overlay-master.json frontmatter amendments are honored — never consume
# foundation-master RAW. Materialize the merged union ONCE and redirect
# $FOUNDATION_MASTER at it; every downstream python3 read of "$FOUNDATION_MASTER"
# (frontmatter.types + r32_type_aliases at ~136/~150) is then unchanged. The redirect
# is read-only (the existence-check gate at ~101 either sees the real file when the
# merger is absent, or the valid union when present). Degrades to the raw bundle if
# the merger is unavailable (loud-safe, never broken).
_OVL="${FOUNDATION_OVERLAY_LOAD:-${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -f "$FOUNDATION_MASTER" ]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$_UNION" ] && bash "$_OVL" --foundation-path "$FOUNDATION_MASTER" \
        --overlay-path "$(dirname "$FOUNDATION_MASTER")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
        && [ -s "$_UNION" ]; then
    FOUNDATION_MASTER="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [ -n "$_UNION" ]; then rm -f "$_UNION"; fi
fi

DRY_RUN=true
BATCH_SIZE=50
OUTPUT=""
PLANS_ONLY=false
DO_FIX=false
SCOPE="${PLANS_DIR:-$HOME/.claude-plans}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --live)       DRY_RUN=false; shift ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --plans)      PLANS_ONLY=true; shift ;;
    --fix)        DO_FIX=true; shift ;;
    --scope)      SCOPE="$2"; shift 2 ;;
    -h|--help)    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *)            echo "drift-sweep: unknown flag: $1" >&2; exit 1 ;;
  esac
done

export FINDINGS_OUTPUT="${OUTPUT:-${FINDINGS_OUTPUT:-}}"

# --- master<->sub aggregation axis (NET-NEW) ---------------------
# Re-uses the trinity-drift-detect master<->sub detector for the read; --fix
# delegates the repair to the canonical aggregator (single-writer invariant).
# DERIVE disposition: this axis INHERITS trinity-drift-detect's retire/preserve —
# the wrapped detector runs the (manifest-only) master<->sub axis + the PRESERVED
# trinity-task-ledger-lag, and no longer emits the retired artifact-frontmatter
# axes (spec-manifest-divergence / header-trinity-divergence). No change here.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
run_master_sub_axis() {
  local td="$SELF_DIR/trinity-drift-detect.sh"
  if [[ -x "$td" || -f "$td" ]]; then
    bash "$td" --scope "$SCOPE" || true
  fi
  if [[ "$DO_FIX" == "true" ]]; then
    local agg="$SELF_DIR/subplan-aggregate.sh"
    if [[ -f "$agg" ]]; then
      local entry
      for entry in "$SCOPE"/*/; do
        [[ -f "$entry/manifest.json" ]] || continue
        # repair only masters (subplan-aggregate is a no-op shape on non-masters)
        if grep -q '"sub_plans"' "$entry/manifest.json" 2>/dev/null \
           || grep -q '"type"[[:space:]]*:[[:space:]]*"master"' "$entry/manifest.json" 2>/dev/null; then
          FOUNDATION_TEST_MODE=1 bash "$agg" "$entry" || true
        fi
      done
    fi
  fi
}

if [[ "$PLANS_ONLY" == "true" ]]; then
  run_master_sub_axis
  exit 0
fi

# --- frontmatter-drift sweep (PRESERVED axis) ------------------------
# DERIVE disposition: UNAFFECTED. This sweep flags only fields in a type's
# required[] (missing_required). `status` is NOT in the spec/tasks/ideation-brief
# required[] (foundation-master.frontmatter.types.*.required), so stripping status:
# from plan artifacts does not trip missing_required. No change here.
if [[ ! -f "$FOUNDATION_MASTER" ]]; then
  echo "drift-sweep: foundation-master.json not found at $FOUNDATION_MASTER; "\
       "running master<->sub axis only" >&2
  run_master_sub_axis
  exit 0
fi
if [[ -z "${VAULT_ROOT:-}" ]] || [[ ! -d "${VAULT_ROOT:-/nonexistent}" ]]; then
  echo "drift-sweep: VAULT_ROOT unset/absent; running master<->sub axis only" >&2
  run_master_sub_axis
  exit 0
fi

SCAN_COUNT=0
FINDING_COUNT=0
BATCH_COUNT=0

emit_event "{ \"drift_sweep_start\": \"$(date -Iseconds 2>/dev/null || date)\", \"mode\": \"$([ "$DRY_RUN" = true ] && echo 'dry-run' || echo 'live')\" }"

set +e
set +o pipefail

while IFS= read -r -d '' file; do
  SCAN_COUNT=$((SCAN_COUNT + 1))
  REL="${file#$VAULT_ROOT/}"
  [[ "$REL" == "Logs/.coordination/"* ]] && continue
  [[ "$REL" == "CLAUDE.md" ]] && continue
  [[ "$REL" == .claude/projects/* ]] && continue
  [[ "$REL" == _test* ]] && continue

  FM=$(awk '/^---$/{c++;next} c==1{print} c>=2{exit}' "$file" 2>/dev/null)
  [[ -z "$FM" ]] && continue

  FILE_TYPE=$(printf '%s\n' "$FM" | grep -E '^type:' 2>/dev/null | head -1 | sed 's/^type:[[:space:]]*//' || true)
  if [[ -n "$FILE_TYPE" ]]; then
    SCHEMA_KEY=$(python3 - "$FOUNDATION_MASTER" "$FILE_TYPE" <<'PY' 2>/dev/null
import json, sys
bundle = json.load(open(sys.argv[1]))
t = sys.argv[2]
type_map = bundle.get('r32_type_aliases', {})
key = type_map.get(t, t)
types = bundle.get('frontmatter', {}).get('types', {})
print(key if (key in types and not key.startswith('_')) else '')
PY
)
    if [[ -z "$SCHEMA_KEY" ]]; then
      FINDING_COUNT=$((FINDING_COUNT + 1))
      emit_finding "unregistered_type" "$REL" "type" "$FILE_TYPE"
    else
      MISSING=$(printf '%s\n' "$FM" | python3 - "$FOUNDATION_MASTER" "$SCHEMA_KEY" <<'PY' 2>/dev/null
import json, sys
bundle = json.load(open(sys.argv[1]))
key = sys.argv[2]
fm_lines = sys.stdin.read().splitlines()
fm = {}
for ln in fm_lines:
    if ":" in ln:
        k, _, v = ln.partition(":")
        fm[k.strip()] = v.strip()
types = bundle.get('frontmatter', {}).get('types', {})
req = types.get(key, {}).get('required', [])
missing = [f for f in req if not fm.get(f)]
print(",".join(missing))
PY
)
      if [[ -n "$MISSING" ]]; then
        FINDING_COUNT=$((FINDING_COUNT + 1))
        emit_finding "missing_required" "$REL" "schema_key" "$SCHEMA_KEY" "missing" "$MISSING"
      fi
    fi
  fi

  BATCH_COUNT=$((BATCH_COUNT + 1))
  if [[ $BATCH_COUNT -ge $BATCH_SIZE ]]; then
    emit_event "{ \"progress\": $SCAN_COUNT, \"findings_so_far\": $FINDING_COUNT }"
    BATCH_COUNT=0
  fi
done < <(find "$VAULT_ROOT" -name "*.md" -print0 2>/dev/null)

set -e
set -o pipefail

emit_event "{ \"drift_sweep_end\": \"$(date -Iseconds 2>/dev/null || date)\", \"files_scanned\": $SCAN_COUNT, \"findings\": $FINDING_COUNT }"

# Always run the master<->sub axis after the vault sweep.
run_master_sub_axis

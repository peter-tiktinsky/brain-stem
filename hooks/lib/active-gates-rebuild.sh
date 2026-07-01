#!/bin/bash
# active-gates-rebuild.sh — RELOCATED to hooks/lib/ (#3).
# Co-located with the live-guard layer it audits (hooks/lib/live-guard.sh).
# NOT registered in capability-registry.json (registering would falsely
# conscript it into the librarian bijection + cron surface; #3); the
# capability-registry-parity 40-vs-44 drift closes once this relocates out.
# reads the CANONICAL `status` field, never the retired `top_level_status`.
# Gate SELECTION keys on `live_mutation_scope.enabled` (the live-mutation gate
# is orthogonal to plan status); where any plan-status read is needed it uses
# the single canonical `status` field per. Verified: zero
# `top_level_status` references in this body.
# Original provenance: librarian capability (/81 T-8 full ship).
# Walks plan-tree manifests; extracts live_mutation_scope blocks where
# enabled=true; emits a flat active-gates.json read-replica consumed by
# live-guard.sh fast-path. Compile-time scope-overlap detection (k8s/VS Code
# lesson — never punt scope conflict to runtime in security gate). Sub-plan
# UNION merging via inherits_from (additive-only on scope_paths/exempt_paths/
# launchd_labels/g2_commit_denylist).
# T-3.5 contract:
#   --plans-root <path>  Override $HOME/.claude-plans walk root. PEER to
#                        live-guard.sh's PLANS_ROOT_OVERRIDE env var.
#   --output <path>      Override default output path.
#   --schema-version <v> Force schema_version field; default 1.
#   --strict             Fail (rc=2) on scope_overlap_check FAILED instead of
#                        emitting the read-replica with FAILED status.
#   --skip-overlap-check Emit deferred-to-T-8 sentinel for downgrade testing.
# T-8 ship (this file):
#   - Compile-time scope_paths overlap detection across enabled MASTER gates.
#     Sub-plans inheriting via inherits_from are NOT separate gates — they
#     additively contribute to their master. Two MASTER gates whose scope_paths
#     overlap (either equal or one prefix-contains the other after $VAR
#     expansion + /** strip) is a manifest authoring error caught here.
#   - Sub-plan UNION merging: for each master gate G and each sub-plan S with
#     S.inherits_from == G.plan_id AND S.enabled == true, UNION-merge:
#         scope_paths, exempt_paths, layer_3.launchd_labels,
#         layer_3.session_end_hooks, layer_3.user_prompt_submit_writers,
#         g2_commit_denylist
#     Sub-plan provenance stamped under _merged_sub_plans[] for audit.
#   - mtime cache invalidation contract: read-replica records the latest
#     manifest mtime in $.metadata.youngest_manifest_mtime. live-guard.sh
#     slow-path-fallback contract: if any plan-tree manifest mtime exceeds
#     read-replica's $.regenerated_at, replica is stale → walk slow-path.
#     Documented here for T-13 PostToolUse hook to invalidate via re-invocation.
# Output shape:
#     schema_version: 1,
#     regenerated_at: "<iso8601>",
#     regenerated_by: "active-gates-rebuild.sh",
#     plans_root: "<resolved>",
#     scope_overlap_check: "passed" | "FAILED" | "skipped",
#     metadata: {
#       master_gate_count, sub_plan_merge_count,
#       youngest_manifest_mtime, scope_overlap_findings: [...]
#     gates: [<live_mutation_scope-with-plan_id-and-_merged_sub_plans>, ...]
# Exit codes:
#   0 — read-replica written successfully (overlap may be FAILED unless --strict)
#   1 — unexpected internal error
#   2 — overlap detected and --strict was set

set -uo pipefail

# === Arg parsing ==========================================================
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-${PLANS_DIR:-$HOME/.claude-plans}}"
OUTPUT_PATH=""
SCHEMA_VERSION=1
STRICT_MODE=0
SKIP_OVERLAP_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plans-root)
      PLANS_ROOT="$2"; shift 2 ;;
    --output)
      OUTPUT_PATH="$2"; shift 2 ;;
    --schema-version)
      SCHEMA_VERSION="$2"; shift 2 ;;
    --strict)
      STRICT_MODE=1; shift ;;
    --skip-overlap-check)
      SKIP_OVERLAP_CHECK=1; shift ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -60
      exit 0 ;;
    *)
      echo "active-gates-rebuild: unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="${ACTIVE_GATES_PATH:-${CLAUDE_HOME:-$HOME/.claude}/state/active-gates.json}"
fi

OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
mkdir -p "$OUTPUT_DIR" 2>/dev/null || true

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# === Helpers ==============================================================

# Normalize a glob path for comparison: expand $VARs, strip trailing /** or /*.
normalize_path() {
  local p="$1"
  p="${p//\$HOME/$HOME}"
  p="${p//\$VAULT_ROOT/${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}}"
  p="${p//\$CLAUDE_HOME/${CLAUDE_HOME:-$HOME/.claude}}"
  # Strip trailing globstar / star segments for prefix-overlap calculus
  p="${p%/\*\*}"
  p="${p%/\*}"
  printf '%s\n' "$p"
}

# Check if two normalized paths overlap (one prefix-contains the other,
# or they are equal). Treats path as directory prefix.
paths_overlap() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  # Normalize trailing slashes
  a="${a%/}"; b="${b%/}"
  [[ "$a" == "$b/"* ]] && return 0
  [[ "$b" == "$a/"* ]] && return 0
  return 1
}

# Track the youngest mtime across all walked manifests.
YOUNGEST_MTIME=0

# === Walk top-level manifests, collect MASTER gates =======================
MASTER_GATES_JSON='[]'

if [[ -d "$PLANS_ROOT" ]]; then
  for manifest in "$PLANS_ROOT"/*/manifest.json; do
    [[ -e "$manifest" ]] || continue
    plan_slug=$(basename "$(dirname "$manifest")")

    # Track mtime
    m_epoch=$(stat -f %m "$manifest" 2>/dev/null || stat -c %Y "$manifest" 2>/dev/null || echo 0)
    [[ "$m_epoch" -gt "$YOUNGEST_MTIME" ]] && YOUNGEST_MTIME="$m_epoch"

    # Master gate: enabled=true AND inherits_from is null/absent
    gate=$(jq -c --arg plan_id "$plan_slug" '
      select(
        ((.live_mutation_scope.enabled // false) == true)
        and ((.live_mutation_scope.inherits_from // null) == null)
      )
      | .live_mutation_scope + {plan_id: $plan_id}
    ' "$manifest" 2>/dev/null || echo "")

    [[ -z "$gate" ]] && continue
    MASTER_GATES_JSON=$(echo "$MASTER_GATES_JSON" | jq -c --argjson g "$gate" '. + [$g]')
  done
fi

# === Walk sub-plan manifests, collect SUB-PLAN contributions ==============
# Sub-plan = ~/.claude-plans/<plan>/<NN-*>/manifest.json with
#   live_mutation_scope.enabled=true AND inherits_from set.
# Build sub-plan list keyed by (master_plan_id, sub_plan_slug).
SUB_PLAN_CONTRIBS_JSON='[]'

if [[ -d "$PLANS_ROOT" ]]; then
  for sp_manifest in "$PLANS_ROOT"/*/[0-9][0-9]*-*/manifest.json; do
    [[ -e "$sp_manifest" ]] || continue
    sub_plan_slug=$(basename "$(dirname "$sp_manifest")")
    master_dir=$(basename "$(dirname "$(dirname "$sp_manifest")")")

    m_epoch=$(stat -f %m "$sp_manifest" 2>/dev/null || stat -c %Y "$sp_manifest" 2>/dev/null || echo 0)
    [[ "$m_epoch" -gt "$YOUNGEST_MTIME" ]] && YOUNGEST_MTIME="$m_epoch"

    contrib=$(jq -c --arg sp "$sub_plan_slug" --arg md "$master_dir" '
      select((.live_mutation_scope.enabled // false) == true)
      | select((.live_mutation_scope.inherits_from // null) != null)
      | {
          master_plan_id: .live_mutation_scope.inherits_from,
          master_dir: $md,
          sub_plan_id: $sp,
          contribution: (.live_mutation_scope | del(.enabled, .inherits_from, .schema_version))
        }
    ' "$sp_manifest" 2>/dev/null || echo "")

    [[ -z "$contrib" ]] && continue
    SUB_PLAN_CONTRIBS_JSON=$(echo "$SUB_PLAN_CONTRIBS_JSON" | jq -c --argjson c "$contrib" '. + [$c]')
  done
fi

# === UNION-merge sub-plan contributions into matching master gates =========
# For each master gate G with plan_id P, find all sub-plans where
# inherits_from==P (matched by master_plan_id field). UNION-merge additive
# fields: scope_paths, exempt_paths, layer_3.launchd_labels,
# layer_3.session_end_hooks, layer_3.user_prompt_submit_writers, g2_commit_denylist.
# Sub-plan provenance stamped under _merged_sub_plans[] for audit.
SUB_PLAN_MERGE_COUNT=0

MERGED_GATES_JSON=$(echo "$MASTER_GATES_JSON" | jq -c \
  --argjson contribs "$SUB_PLAN_CONTRIBS_JSON" '
  map(
    . as $master
    | $master.plan_id as $pid
    | ($contribs | map(select(.master_plan_id == $pid))) as $matched
    | if ($matched | length) == 0 then
        . + {_merged_sub_plans: []}
      else
        # Compute UNION across additive fields
        ($matched | map(.contribution)) as $cs
        | . + {
            scope_paths: ((.scope_paths // []) + ($cs | map(.scope_paths // []) | flatten) | unique),
            exempt_paths: ((.exempt_paths // []) + ($cs | map(.exempt_paths // []) | flatten) | unique),
            g2_commit_denylist: ((.g2_commit_denylist // []) + ($cs | map(.g2_commit_denylist // []) | flatten) | unique),
            layer_3: (
              (.layer_3 // {})
              + {
                  launchd_labels: (((.layer_3.launchd_labels // []) + ($cs | map(.layer_3.launchd_labels // []) | flatten)) | unique),
                  session_end_hooks: (((.layer_3.session_end_hooks // []) + ($cs | map(.layer_3.session_end_hooks // []) | flatten)) | unique_by(.path)),
                  user_prompt_submit_writers: (((.layer_3.user_prompt_submit_writers // []) + ($cs | map(.layer_3.user_prompt_submit_writers // []) | flatten)) | unique_by(.path_pattern))
                }
            ),
            _merged_sub_plans: ($matched | map({sub_plan_id, master_dir}))
          }
      end
  )
')

# Count how many sub-plan merges happened (number of contribs whose master existed)
SUB_PLAN_MERGE_COUNT=$(echo "$MERGED_GATES_JSON" \
  | jq -r '[.[] | ._merged_sub_plans | length] | add // 0')

# Surface ORPHAN sub-plans (inherits_from points to a non-enabled or absent master)
ORPHAN_SUB_PLANS_JSON=$(echo "$SUB_PLAN_CONTRIBS_JSON" | jq -c \
  --argjson masters "$MASTER_GATES_JSON" '
  map(.master_plan_id as $mp
      | select(
          ($masters | map(.plan_id) | index($mp)) == null
        )
      | {sub_plan_id, master_plan_id, master_dir})
')

# === Compile-time scope_paths overlap detection ===========================
# Pairwise check across MASTER gates only. Sub-plans contribute additively
# to their master and are NOT separate gates. An overlap means two distinct
# masters claim scope on the same path-prefix space, which is an authoring
# error per Agent 2's k8s/VS Code lesson.
SCOPE_OVERLAP_CHECK="passed"
OVERLAP_FINDINGS_JSON='[]'

if [[ "$SKIP_OVERLAP_CHECK" == "1" ]]; then
  SCOPE_OVERLAP_CHECK="skipped"
else
  # Extract (plan_id, scope_path) pairs from MERGED gates
  PAIRS=$(echo "$MERGED_GATES_JSON" | jq -r '
    .[] as $g | $g.scope_paths[]? | $g.plan_id + "\t" + .
  ')

  if [[ -n "$PAIRS" ]]; then
    # Build all distinct (plan_id, normalized_path) tuples
    declare -a PLANS=()
    declare -a NORMS=()
    declare -a RAW=()
    while IFS=$'\t' read -r pid path; do
      [[ -z "$pid" ]] && continue
      norm=$(normalize_path "$path")
      PLANS+=("$pid")
      NORMS+=("$norm")
      RAW+=("$path")
    done <<< "$PAIRS"

    n=${#PLANS[@]}
    for ((i=0; i<n; i++)); do
      for ((j=i+1; j<n; j++)); do
        # Skip same-plan comparisons (same gate's own scope_paths can be coarse)
        [[ "${PLANS[i]}" == "${PLANS[j]}" ]] && continue
        if paths_overlap "${NORMS[i]}" "${NORMS[j]}"; then
          finding=$(jq -nc \
            --arg pa "${PLANS[i]}" --arg ra "${RAW[i]}" \
            --arg pb "${PLANS[j]}" --arg rb "${RAW[j]}" \
            '{plan_a: $pa, path_a: $ra, plan_b: $pb, path_b: $rb}')
          OVERLAP_FINDINGS_JSON=$(echo "$OVERLAP_FINDINGS_JSON" \
            | jq -c --argjson f "$finding" '. + [$f]')
          SCOPE_OVERLAP_CHECK="FAILED"
        fi
      done
    done
  fi
fi

# === Compose youngest_manifest_mtime as ISO8601 ===========================
if [[ "$YOUNGEST_MTIME" -gt 0 ]]; then
  YMM_ISO=$(date -u -r "$YOUNGEST_MTIME" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$YOUNGEST_MTIME" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo "unknown")
else
  YMM_ISO="none"
fi

# === Emit read-replica ====================================================
MASTER_COUNT=$(echo "$MERGED_GATES_JSON" | jq 'length')

jq -n \
  --argjson schema_version "$SCHEMA_VERSION" \
  --arg ts "$TS" \
  --arg plans_root "$PLANS_ROOT" \
  --arg overlap "$SCOPE_OVERLAP_CHECK" \
  --argjson gates "$MERGED_GATES_JSON" \
  --argjson master_count "$MASTER_COUNT" \
  --argjson sp_merges "$SUB_PLAN_MERGE_COUNT" \
  --arg ymm "$YMM_ISO" \
  --argjson findings "$OVERLAP_FINDINGS_JSON" \
  --argjson orphans "$ORPHAN_SUB_PLANS_JSON" \
  '{
    schema_version: $schema_version,
    regenerated_at: $ts,
    regenerated_by: "active-gates-rebuild.sh",
    plans_root: $plans_root,
    scope_overlap_check: $overlap,
    metadata: {
      master_gate_count: $master_count,
      sub_plan_merge_count: $sp_merges,
      youngest_manifest_mtime: $ymm,
      scope_overlap_findings: $findings,
      orphan_sub_plans: $orphans
    },
    gates: $gates
  }' > "$OUTPUT_PATH"

# === Status to stderr =====================================================
echo "active-gates-rebuild: wrote $OUTPUT_PATH" >&2
echo "  plans_root=$PLANS_ROOT" >&2
echo "  master_gates=$MASTER_COUNT  sub_plan_merges=$SUB_PLAN_MERGE_COUNT" >&2
echo "  scope_overlap_check=$SCOPE_OVERLAP_CHECK" >&2

if [[ "$SCOPE_OVERLAP_CHECK" == "FAILED" ]]; then
  echo "  overlap findings:" >&2
  echo "$OVERLAP_FINDINGS_JSON" | jq -r '.[] | "    \(.plan_a):\(.path_a)  ⟷  \(.plan_b):\(.path_b)"' >&2
  if [[ "$STRICT_MODE" == "1" ]]; then
    echo "active-gates-rebuild: --strict mode; exiting non-zero on overlap" >&2
    exit 2
  fi
fi

orphan_count=$(echo "$ORPHAN_SUB_PLANS_JSON" | jq 'length')
if [[ "$orphan_count" -gt 0 ]]; then
  echo "  orphan sub-plans (inherits_from points to non-enabled/absent master):" >&2
  echo "$ORPHAN_SUB_PLANS_JSON" | jq -r '.[] | "    \(.master_dir)/\(.sub_plan_id) → inherits_from=\(.master_plan_id) (NOT FOUND in enabled masters)"' >&2
fi

exit 0

#!/bin/bash
# git-hooks/dogfood-harness/verdict-stamper.sh — R-46-cousin verdict-stamper.
#
# Repo-only, author-side, NOT installed.
# Writes a harness_validated[] verdict-pass entry to a plan manifest at the
# dogfood-harness seam. This is the entry that makes a plan manifest's
# `verified` state forgery-proof:
#
#   * Guard 2 (pre-write-guard.sh:592-596) FORBIDS a status flip to
#     `verified` unless the manifest already carries a fresh harness_validated[]
#     verdict-pass (verdict=="pass" AND harness_freshness=="fresh").
#   * Guard 1 (pre-write-guard.sh:577-588) then FORBIDS a flip to
#     `closed` unless the current status is `verified`.
#
# So `verified` is reachable ONLY through an actual validation pass that this
# stamper records (machine-stamped semantics).
#
# This stamper does NOT flip status. It writes ONLY the harness_validated[]
# precondition; the human/operator (or the install-verify gate) then makes
# the status→verified write, which the guard permits because the precondition
# is present.
#
# ---------------------------------------------------------------------------
# Fires at install-verify (internal/tests/install-verify-orchestrator.sh wires
# the firing into the install-verify gate sequence). This script is invoked,
# on a passing dogfood-harness run, with the run metadata as flags (see Usage).
# ---------------------------------------------------------------------------
#
# Schema contract (plan-manifest-schema.json:614-630, harness_validated[]
# items, additionalProperties:false — exactly these 10 required keys):
#   harness_id        string
#   sub_plan_id       string
#   run_id            string
#   sha               string  ^[0-9a-f]{7,40}$  (foundation-repo HEAD SHA)
#   timestamp         string  date-time
#   verdict           string  enum: pass|fail|partial|skip
#   tier              string  enum: tier-1|tier-2|tier-3
#   evidence_path     string
#   harness_freshness string  enum: fresh|stale-7d|stale-30d|invalidated
#   schema_version    integer const 1
#
# Usage:
#   verdict-stamper.sh \
#     --manifest <plan-manifest.json> \
#     --harness-id <fixture-id> \
#     --sub-plan-id <NN-slug> \
#     --run-id <run-id> \
#     --verdict <pass|fail|partial|skip> \
#     --tier <tier-1|tier-2|tier-3> \
#     --evidence-path <path> \
#     [--sha <7-40 hex>]        # default: foundation-repo HEAD
#     [--freshness <fresh|stale-7d|stale-30d|invalidated>]  # default: fresh
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile/readarray, no
# parameter-expansion case conversion, no GNU-only constructs.

set -euo pipefail

MANIFEST=""
HARNESS_ID=""
SUB_PLAN_ID=""
RUN_ID=""
VERDICT=""
TIER=""
EVIDENCE_PATH=""
SHA=""
FRESHNESS="fresh"

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --harness-id)    HARNESS_ID="$2"; shift 2 ;;
    --sub-plan-id)   SUB_PLAN_ID="$2"; shift 2 ;;
    --run-id)        RUN_ID="$2"; shift 2 ;;
    --verdict)       VERDICT="$2"; shift 2 ;;
    --tier)          TIER="$2"; shift 2 ;;
    --evidence-path) EVIDENCE_PATH="$2"; shift 2 ;;
    --sha)           SHA="$2"; shift 2 ;;
    --freshness)     FRESHNESS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Required-arg validation ---
for pair in "manifest:$MANIFEST" "harness-id:$HARNESS_ID" "sub-plan-id:$SUB_PLAN_ID" \
            "run-id:$RUN_ID" "verdict:$VERDICT" "tier:$TIER" "evidence-path:$EVIDENCE_PATH"; do
  key="${pair%%:*}"; val="${pair#*:}"
  if [ -z "$val" ]; then
    echo "ERROR: --$key is required" >&2
    exit 1
  fi
done

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi

# --- Enum guards (mirror the schema enums; fail loud rather than write a
#     schema-invalid entry the validator would reject) ---
case "$VERDICT" in pass|fail|partial|skip) ;; *) echo "ERROR: --verdict must be pass|fail|partial|skip (got '$VERDICT')" >&2; exit 1 ;; esac
case "$TIER" in tier-1|tier-2|tier-3) ;; *) echo "ERROR: --tier must be tier-1|tier-2|tier-3 (got '$TIER')" >&2; exit 1 ;; esac
case "$FRESHNESS" in fresh|stale-7d|stale-30d|invalidated) ;; *) echo "ERROR: --freshness must be fresh|stale-7d|stale-30d|invalidated (got '$FRESHNESS')" >&2; exit 1 ;; esac

# --- Resolve sha (foundation-repo HEAD by default; ^[0-9a-f]{7,40}$) ---
if [ -z "$SHA" ]; then
  SHA=$(git -C "$(dirname "$MANIFEST")" rev-parse HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")
fi
case "$SHA" in
  *[!0-9a-f]* | "") echo "ERROR: --sha must match ^[0-9a-f]{7,40}\$ (got '$SHA'); pass --sha explicitly if not in a git repo" >&2; exit 1 ;;
esac
SHA_LEN=${#SHA}
if [ "$SHA_LEN" -lt 7 ] || [ "$SHA_LEN" -gt 40 ]; then
  echo "ERROR: --sha length must be 7..40 (got '$SHA')" >&2
  exit 1
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Build the entry (exactly the 10 required keys; additionalProperties:false) ---
ENTRY=$(jq -n \
  --arg harness_id "$HARNESS_ID" \
  --arg sub_plan_id "$SUB_PLAN_ID" \
  --arg run_id "$RUN_ID" \
  --arg sha "$SHA" \
  --arg timestamp "$TIMESTAMP" \
  --arg verdict "$VERDICT" \
  --arg tier "$TIER" \
  --arg evidence_path "$EVIDENCE_PATH" \
  --arg harness_freshness "$FRESHNESS" \
  '{
     harness_id: $harness_id,
     sub_plan_id: $sub_plan_id,
     run_id: $run_id,
     sha: $sha,
     timestamp: $timestamp,
     verdict: $verdict,
     tier: $tier,
     evidence_path: $evidence_path,
     harness_freshness: $harness_freshness,
     schema_version: 1
   }')

# --- Append the entry to harness_validated[] (creates the array if absent).
#     Does NOT touch status — the verdict-pass is the precondition the guard
#     reads; the status→verified write is a separate, gated operation. ---
TMP="${MANIFEST}.tmp.$$"
jq --argjson entry "$ENTRY" \
  '.harness_validated = ((.harness_validated // []) + [$entry])' \
  "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

echo "verdict-stamper: wrote harness_validated[] entry to $MANIFEST"
echo "  harness_id=$HARNESS_ID sub_plan_id=$SUB_PLAN_ID verdict=$VERDICT freshness=$FRESHNESS sha=$SHA"
if [ "$VERDICT" = "pass" ] && [ "$FRESHNESS" = "fresh" ]; then
  echo "  => fresh verdict-pass: satisfies the verified-requires-fresh-verdict precondition (pre-write-guard.sh:592-596)."
fi

#!/bin/bash
# pre-commit-harness-validated.sh — R-46-cousin gate
#
# Foundation-repo + plans-repo pre-commit hook. Refuses to commit a plan-tree
# manifest change that flips a sub-plan's `top_level_status` from
# `in_progress` → `complete` unless `harness_validated[]` contains a fresh,
# verdict-pass entry matching the foundation-repo HEAD within last 7 days.
#
# Installation: symlink from {repo}/.git/hooks/pre-commit to this file.
# The hook detects which repo it's running in via `git rev-parse --show-toplevel`
# and runs appropriate logic. Single-source-of-truth body lives here in
# foundation-repo work tree.
#
# Override:
#   $REPO_ROOT/.allow-harness-validation-skip sentinel + `git commit --no-verify`
#   (two physical actions; logged to gate-decisions.log)
#
# Test isolation env (mirrors live-guard.sh contract):
#   FOUNDATION_REPO_OVERRIDE  - SHA-resolution override (for test fixtures)
#   PLANS_ROOT_OVERRIDE       - plan-tree walk root
#   HOOKS_STATE_OVERRIDE      - audit log directory base
#   PRE_COMMIT_STAGED_OVERRIDE - test-mode list of staged paths (newline-separated)
#   PRE_COMMIT_DIFF_OVERRIDE  - test-mode dir containing pre/post manifest snapshots
#                               (named <basename>.before.json / .after.json)
#
# Exit codes: 0=allow commit; 1=reject commit (gate fired); 2=internal error
# (treated per error_action; default deny per security-gate posture).

set -uo pipefail

HOOK_NAME="pre-commit-harness-validated"

# === Path resolution ===================================================
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "$HOOK_NAME: not in a git repo; pass through" >&2
  exit 0
}

FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/brain-stem}"
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-$HOME/.claude-plans}"
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}"
SENTINEL="$REPO_ROOT/.allow-harness-validation-skip"

mkdir -p "$HOOKS_STATE" 2>/dev/null || true
DECISIONS_LOG="$HOOKS_STATE/gate-decisions.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

CAP="${UPDATE_HARNESS_CAP:-$FOUNDATION_REPO/git-hooks/dogfood-harness/update-harness-validated.sh}"

audit() {
  local decision="$1" reason="$2" sub_plan_id="${3:-}" sha="${4:-}"
  jq -nc \
    --arg ts "$TS" --arg hook "$HOOK_NAME" --arg decision "$decision" \
    --arg reason "$reason" --arg sub_plan_id "$sub_plan_id" \
    --arg sha "$sha" --arg repo "$REPO_ROOT" \
    '{ts:$ts, hook:$hook, decision:$decision, reason:$reason, sub_plan_id:$sub_plan_id, sha:$sha, repo:$repo}' \
    >> "$DECISIONS_LOG" 2>/dev/null || true
}

# === Sentinel override =================================================
if [[ -f "$SENTINEL" ]]; then
  echo "$HOOK_NAME: sentinel $SENTINEL present; allow + log" >&2
  audit "allow" "sentinel-override-via-.allow-harness-validation-skip"
  exit 0
fi

# === Get staged plan-tree manifests ====================================
# Test mode: PRE_COMMIT_STAGED_OVERRIDE provides newline-separated paths
# Production mode: git diff --cached --name-only filtered to manifests
get_staged_manifests() {
  if [[ -n "${PRE_COMMIT_STAGED_OVERRIDE:-}" ]]; then
    printf '%s\n' "$PRE_COMMIT_STAGED_OVERRIDE" | grep -E 'manifest\.json$' || true
    return
  fi
  git diff --cached --name-only 2>/dev/null | grep -E 'manifest\.json$' || true
}

# === Get pre/post manifest content for a staged path ==================
# Test mode: PRE_COMMIT_DIFF_OVERRIDE/<basename>.before.json + .after.json
# Production mode: git show :0:<path> for staged version, HEAD:<path> for prior
get_before_after() {
  local path="$1" mode="$2"  # mode: before|after

  if [[ -n "${PRE_COMMIT_DIFF_OVERRIDE:-}" ]]; then
    local base ; base=$(basename "$path" | sed 's/\.json$//')
    local fixture="$PRE_COMMIT_DIFF_OVERRIDE/${base}.${mode}.json"
    if [[ -f "$fixture" ]]; then cat "$fixture"; else echo "{}"; fi
    return
  fi

  if [[ "$mode" == "before" ]]; then
    git show "HEAD:$path" 2>/dev/null || echo "{}"
  else
    git show ":0:$path" 2>/dev/null || echo "{}"
  fi
}

# === Detect flip-to-complete ===========================================
# Returns 0 with sub_plan_id printed to stdout if flip detected
# Returns 1 if no flip
detect_flip_to_complete() {
  local manifest_path="$1"
  local before after before_status after_status sub_plan_id

  before=$(get_before_after "$manifest_path" before)
  after=$(get_before_after "$manifest_path" after)

  before_status=$(jq -r '.top_level_status // "absent"' <<< "$before" 2>/dev/null)
  after_status=$(jq -r '.top_level_status // "absent"' <<< "$after" 2>/dev/null)

  # Flip semantics: anything → complete, when before was NOT complete
  if [[ "$after_status" == "complete" && "$before_status" != "complete" ]]; then
    sub_plan_id=$(jq -r '.sub_plan_id // .project // ""' <<< "$after")
    [[ -z "$sub_plan_id" || "$sub_plan_id" == "null" ]] && sub_plan_id=$(basename "$(dirname "$manifest_path")")
    echo "$sub_plan_id"
    return 0
  fi
  return 1
}

# === Main loop =========================================================
get_foundation_sha() {
  if [[ -n "${FOUNDATION_SHA_OVERRIDE:-}" ]]; then
    echo "$FOUNDATION_SHA_OVERRIDE"
    return
  fi
  if [[ -d "$FOUNDATION_REPO/.git" ]]; then
    git -C "$FOUNDATION_REPO" rev-parse HEAD 2>/dev/null
  fi
}

FOUNDATION_SHA=$(get_foundation_sha)
if [[ -z "$FOUNDATION_SHA" ]]; then
  echo "$HOOK_NAME: cannot resolve foundation-repo HEAD; pass through (best-effort)" >&2
  audit "allow" "foundation-sha-unresolved-best-effort"
  exit 0
fi

reject_count=0
checked_count=0

while IFS= read -r manifest; do
  [[ -z "$manifest" ]] && continue
  checked_count=$((checked_count + 1))

  sub_plan_id=$(detect_flip_to_complete "$manifest") || continue

  # Resolve manifest absolute path for capability call
  abs_manifest="$manifest"
  if [[ "$abs_manifest" != /* ]]; then
    abs_manifest="$REPO_ROOT/$abs_manifest"
  fi

  if [[ ! -f "$abs_manifest" ]]; then
    # Test mode: synthetic manifest may not exist on disk yet (only in
    # PRE_COMMIT_DIFF_OVERRIDE fixtures). Use the after-fixture as the
    # manifest content for freshness-check.
    abs_manifest=$(mktemp -t manifest-fixture-XXXXXX.json)
    get_before_after "$manifest" after > "$abs_manifest"
    trap 'rm -f "$abs_manifest"' EXIT
  fi

  if "$CAP" freshness-check "$abs_manifest" "$sub_plan_id" \
        --foundation-sha "$FOUNDATION_SHA" --max-age-days 7 >/dev/null 2>&1; then
    audit "allow" "harness-validated-fresh-pass-found" "$sub_plan_id" "$FOUNDATION_SHA"
    continue
  else
    echo "$HOOK_NAME: REJECT $manifest" >&2
    echo "  Reason: sub-plan '$sub_plan_id' is being flipped to top_level_status=complete," >&2
    echo "          but no fresh+pass harness_validated[] entry exists for foundation-sha=$FOUNDATION_SHA" >&2
    echo "          within last 7 days." >&2
    echo "" >&2
    echo "  Resolution: run the dogfood-harness, get verdict-pass entry, then retry." >&2
    echo "  Override: touch $SENTINEL && git commit --no-verify" >&2
    echo "" >&2
    audit "reject" "harness-validated-stale-or-missing" "$sub_plan_id" "$FOUNDATION_SHA"
    reject_count=$((reject_count + 1))
  fi
done < <(get_staged_manifests)

if (( reject_count > 0 )); then
  exit 1
fi

if (( checked_count == 0 )); then
  audit "allow" "no-manifest-changes-staged"
fi

exit 0

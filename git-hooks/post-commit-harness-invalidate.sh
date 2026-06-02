#!/bin/bash
# post-commit-harness-invalidate.sh — cross-sub-plan invalidation hook
#
# Foundation-repo post-commit hook. After a commit lands, walks plan-tree
# manifests and marks `harness_validated[]` entries `invalidated` when the
# committed changes intersect any sub-plan's declared
# `live_mutation_scope.scope_paths`. Closes the cross-sub-plan invalidation
# discipline gap:
#
#   "A harness_validated[] entry at sha-X for sub-plan-Y is INVALIDATED
#    when any merge to main lands at sha-Y' that touches files within
#    sub-plan-Y's declared live_mutation_scope.scope_paths."
#
# Invocation: post-commit hooks receive no arguments.
# Reads HEAD~1..HEAD diff for the commit just made.
#
# Test isolation env:
#   FOUNDATION_REPO_OVERRIDE  - root for git diff lookup
#   PLANS_ROOT_OVERRIDE       - plan-tree walk root
#   POST_COMMIT_DIFF_OVERRIDE - newline-separated paths to treat as the
#                               "just committed" file set (test mode)
#   HOOKS_STATE_OVERRIDE      - audit log directory base
#
# Exit codes: 0 always (post-commit cannot reject; only logs + invalidates).

set -uo pipefail

HOOK_NAME="post-commit-harness-invalidate"

FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/brain-stem}"
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-$HOME/.claude-plans}"
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}"
CAP="${UPDATE_HARNESS_CAP:-$FOUNDATION_REPO/git-hooks/dogfood-harness/update-harness-validated.sh}"

mkdir -p "$HOOKS_STATE" 2>/dev/null || true
DECISIONS_LOG="$HOOKS_STATE/gate-decisions.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

audit() {
  local action="$1" reason="$2" sub_plan_id="${3:-}" plan_id="${4:-}"
  jq -nc \
    --arg ts "$TS" --arg hook "$HOOK_NAME" --arg action "$action" \
    --arg reason "$reason" --arg sub_plan_id "$sub_plan_id" --arg plan_id "$plan_id" \
    '{ts:$ts, hook:$hook, action:$action, reason:$reason, sub_plan_id:$sub_plan_id, plan_id:$plan_id}' \
    >> "$DECISIONS_LOG" 2>/dev/null || true
}

# === Get just-committed file list ======================================
get_committed_paths() {
  if [[ -n "${POST_COMMIT_DIFF_OVERRIDE:-}" ]]; then
    printf '%s\n' "$POST_COMMIT_DIFF_OVERRIDE"
    return
  fi
  if [[ -d "$FOUNDATION_REPO/.git" ]]; then
    git -C "$FOUNDATION_REPO" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null
  fi
}

# === Match committed path against scope_paths globs =====================
# Bash glob comparison after $HOME / $VAR expansion.
path_matches_scope() {
  local committed="$1" scope_pattern="$2"
  # Expand $HOME (most common var in scope_paths)
  scope_pattern="${scope_pattern//\$HOME/$HOME}"

  # Convert /** to /* + recursive match approximation
  local prefix="${scope_pattern%/\*\*}"
  if [[ "$prefix" != "$scope_pattern" ]]; then
    # /** glob: prefix must be a leading subpath of committed
    [[ "$committed" == "$prefix"/* || "$committed" == "$prefix" ]] && return 0
  fi

  # /* glob: only direct children
  prefix="${scope_pattern%/\*}"
  if [[ "$prefix" != "$scope_pattern" ]]; then
    [[ "$committed" == "$prefix"/* ]] || return 1
    # No deeper slash after prefix
    local rest="${committed#$prefix/}"
    [[ "$rest" != */* ]] && return 0
  fi

  # Literal match
  [[ "$committed" == "$scope_pattern" ]] && return 0
  return 1
}

# === Main =============================================================
COMMITTED=$(get_committed_paths)
if [[ -z "$COMMITTED" ]]; then
  audit "noop" "no-committed-paths-resolved"
  exit 0
fi

# Foundation-repo paths in commits are repo-relative; convert to absolute
# for scope_paths comparison.
abs_committed=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if [[ "$p" == /* ]]; then
    abs_committed+=("$p")
  else
    abs_committed+=("$FOUNDATION_REPO/$p")
  fi
done <<< "$COMMITTED"

invalidate_count=0

while IFS= read -r manifest; do
  [[ -z "$manifest" ]] && continue

  # Check sub-plan has live_mutation_scope.scope_paths AND harness_validated[]
  scope_paths=$(jq -r '(.live_mutation_scope.scope_paths // [])[]' "$manifest" 2>/dev/null) || continue
  [[ -z "$scope_paths" ]] && continue

  has_validated=$(jq -r '(.harness_validated // []) | length' "$manifest" 2>/dev/null)
  [[ -z "$has_validated" || "$has_validated" -eq 0 ]] && continue

  # Determine sub-plan id for this manifest
  sub_plan_id=$(jq -r '.sub_plan_id // ""' "$manifest" 2>/dev/null)
  [[ -z "$sub_plan_id" || "$sub_plan_id" == "null" ]] && sub_plan_id=$(basename "$(dirname "$manifest")")

  # Determine plan id (parent or self if top-level)
  plan_id=$(jq -r '.parent_plan // .project // ""' "$manifest" 2>/dev/null)

  # Check intersection
  intersected=0
  while IFS= read -r scope; do
    [[ -z "$scope" ]] && continue
    for committed in "${abs_committed[@]}"; do
      if path_matches_scope "$committed" "$scope"; then
        intersected=1
        break 2
      fi
    done
  done <<< "$scope_paths"

  if (( intersected == 1 )); then
    "$CAP" invalidate "$manifest" "$sub_plan_id" >/dev/null 2>&1 \
      && audit "invalidate" "scope-intersection-with-committed-paths" "$sub_plan_id" "$plan_id" \
      && invalidate_count=$((invalidate_count + 1))
  fi
done < <(find "$PLANS_ROOT" -maxdepth 4 -name 'manifest.json' -type f 2>/dev/null)

if (( invalidate_count > 0 )); then
  echo "$HOOK_NAME: invalidated $invalidate_count harness_validated[] entries due to scope intersection" >&2
fi

exit 0

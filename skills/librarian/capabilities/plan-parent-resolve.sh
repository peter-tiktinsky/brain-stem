#!/bin/bash
# plan-parent-resolve — Walk parent_plan: chain for sub-task files, resolve
# inherited state, and emit drift findings.
#
# Wraps the parent-plan resolver algorithm as a CLI-invocable capability.
# Enforcement layer for R-28 (parent_plan: chain integrity).
# Test harness: tests/plan-parent-resolve.sh.
#
# Usage:
#   plan-parent-resolve.sh                 # full corpus walk
#   plan-parent-resolve.sh --file <path>   # resolve chain for one file
#   plan-parent-resolve.sh --parent <slug> # list files whose chain includes <slug>
#   plan-parent-resolve.sh --dry-run       # (no-op — resolver is already read-only)
#
# Scope: sub-task files at depth >= 3 under $PLANS_DIR, excluding:
#   - plan-root files at depth 2 (spec.md, tasks.md, handoff.md,
#     00-ideation-brief.md, README.md, manifest.json)
#   - handoff.md at any depth (append-only session records)
#   - tests/**, _orchestrator/**, baselines/**, corpus/**,
#     regression-baseline/**, _research/** (ephemeral diagnostic artifacts)
#
# Findings emitted (per SKILL.md L567-575):
#   parent-plan-inferred     — info  — missing field, parent from path
#   parent-plan-unresolvable — warn  — missing field, path yields nothing
#   parent-plan-broken-pointer — warn — parent slug does not exist
#   parent-plan-cycle        — error — visited set hit
#   parent-plan-chain-too-deep — error — chain exceeded depth 6
#   parent-plan-path-drift   — warn  — explicit field disagrees with path
#
# Read-only. Never writes. Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/frontmatter.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/frontmatter.sh"; } \
  || source "$_REPO_LIB/frontmatter.sh"

MODE="corpus"
FILE_ARG=""
PARENT_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    MODE="single"; FILE_ARG="$2"; shift 2 ;;
    --parent)  MODE="parent"; PARENT_FILTER="$2"; shift 2 ;;
    --dry-run) shift ;;  # No-op; accepted for chain-cleanliness
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "plan-parent-resolve: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_ROOT="${PLANS_DIR_OVERRIDE:-$PLANS_DIR}"

if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "plan-parent-resolve: PLANS_DIR not found: $PLANS_ROOT" >&2
  exit 3
fi

resolve_chain() {
  local file="$1"
  local visited=""
  local chain=""
  local depth=0
  local max_depth=6
  local parent
  # For manifest.json files, parse the JSON for top-level parent_plan.
  # For Markdown files, use the standard YAML frontmatter helper.
  if [[ "$file" == *.json ]]; then
    parent=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get('parent_plan', '') if isinstance(d, dict) else ''
    print(v if isinstance(v, str) else '')
except Exception:
    pass
" "$file" 2>/dev/null)
  else
    parent=$(fm_get_field "$file" "parent_plan")
  fi

  if [[ -z "$parent" ]]; then
    local rel="${file#$PLANS_ROOT/}"
    local top="${rel%%/*}"
    if [[ -n "$top" ]] && [[ -e "$PLANS_ROOT/$top" ]]; then
      echo "inferred:$top"
      return
    else
      echo "unresolvable"
      return
    fi
  fi

  while [[ -n "$parent" ]] && [[ $depth -lt $max_depth ]]; do
    case " $visited " in
      *" $parent "*)
        echo "cycle:$chain|$parent"
        return
        ;;
    esac
    visited="$visited $parent"
    if [[ -z "$chain" ]]; then
      chain="$parent"
    else
      chain="$chain|$parent"
    fi

    # Lookup: direct match, flat .md plan, or NN-<slug> form (per CLAUDE.md
    # rule #5: parent_plan value is the slug without numeric prefix).
    local parent_dir=""
    local resolved=0
    if [[ -d "$PLANS_ROOT/$parent" ]]; then
      parent_dir="$PLANS_ROOT/$parent"
      resolved=1
    elif [[ -f "$PLANS_ROOT/$parent.md" ]]; then
      resolved=1
    else
      for c in "$PLANS_ROOT"/*-"$parent"; do
        if [[ -d "$c" ]]; then
          parent_dir="$c"
          resolved=1
          break
        fi
      done
    fi
    if [[ "$resolved" -eq 0 ]]; then
      echo "broken:$parent"
      return
    fi

    local next_parent=""
    if [[ -n "$parent_dir" ]]; then
      if [[ -f "$parent_dir/spec.md" ]]; then
        next_parent=$(fm_get_field "$parent_dir/spec.md" "parent_plan")
      fi
      if [[ -z "$next_parent" ]] && [[ -f "$parent_dir/README.md" ]]; then
        next_parent=$(fm_get_field "$parent_dir/README.md" "parent_plan")
      fi
    fi
    parent="$next_parent"
    depth=$((depth + 1))
  done

  if [[ $depth -ge $max_depth ]]; then
    echo "too-deep:$depth"
    return
  fi

  echo "ok:$chain"
}

in_scope() {
  local file="$1"
  local rel="${file#$PLANS_ROOT/}"
  local rest="$rel" depth=1
  while [[ "$rest" == */* ]]; do
    rest="${rest#*/}"
    depth=$((depth + 1))
  done
  [[ $depth -ge 3 ]] || return 1

  [[ "$(basename "$file")" == "handoff.md" ]] && return 1

  # Test/fixture/research artifacts are not subject to R-28 inheritance —
  # they are ephemeral diagnostic outputs, not plan-state files.
  # tests/ + _orchestrator/ per CLAUDE.md rule #5; baselines/ + corpus/ +
  # regression-baseline/ + _research/ are likewise exempt (test-fixture
  # artifacts produce false positives otherwise).
  case "/$rel/" in
    */tests/*|*/_orchestrator/*|*/baselines/*|*/corpus/*|*/regression-baseline/*|*/_research/*) return 1 ;;
  esac

  return 0
}

emit_resolution() {
  local file="$1"
  TOTAL=$((TOTAL + 1))
  local rel="${file#$PLANS_ROOT/}"
  local result
  result=$(resolve_chain "$file")

  case "$result" in
    ok:*)
      EXPLICIT=$((EXPLICIT + 1))
      local chain="${result#ok:}"
      local explicit_parent="${chain%%|*}"
      local path_top="${rel%%/*}"
      if [[ "$explicit_parent" != "$path_top" ]] && [[ -n "$path_top" ]] && [[ -e "$PLANS_ROOT/$path_top" ]]; then
        local path_top_slug="${path_top#*-}"
        if [[ "$explicit_parent" != "$path_top_slug" ]] && [[ "$explicit_parent" != "$path_top" ]]; then
          emit_finding "parent-plan-path-drift" "$rel" \
            "explicit" "$explicit_parent" \
            "path_top" "$path_top" \
            "level" "warn"
        fi
      fi
      ;;
    inferred:*)
      INFERRED=$((INFERRED + 1))
      emit_finding "parent-plan-inferred" "$rel" \
        "parent" "${result#inferred:}" \
        "level" "info"
      ;;
    unresolvable)
      UNRESOLVABLE=$((UNRESOLVABLE + 1))
      emit_finding "parent-plan-unresolvable" "$rel" "level" "warn"
      ;;
    broken:*)
      BROKEN=$((BROKEN + 1))
      emit_finding "parent-plan-broken-pointer" "$rel" \
        "parent" "${result#broken:}" \
        "level" "warn"
      ;;
    cycle:*)
      CYCLE=$((CYCLE + 1))
      emit_finding "parent-plan-cycle" "$rel" \
        "chain" "${result#cycle:}" \
        "level" "error"
      ;;
    too-deep:*)
      TOODEEP=$((TOODEEP + 1))
      emit_finding "parent-plan-chain-too-deep" "$rel" \
        "depth" "${result#too-deep:}" \
        "level" "error"
      ;;
  esac

  if [[ "$MODE" == "parent" ]]; then
    case "$result" in
      ok:*|inferred:*)
        local chain
        case "$result" in
          ok:*) chain="${result#ok:}" ;;
          inferred:*) chain="${result#inferred:}" ;;
        esac
        case "|$chain|" in
          *"|$PARENT_FILTER|"*) echo "$rel" ;;
        esac
        ;;
    esac
  fi
}

TOTAL=0
EXPLICIT=0
INFERRED=0
UNRESOLVABLE=0
BROKEN=0
CYCLE=0
TOODEEP=0

if [[ "$MODE" == "single" ]]; then
  if [[ ! -f "$FILE_ARG" ]]; then
    echo "plan-parent-resolve: --file not found: $FILE_ARG" >&2
    exit 3
  fi
  resolve_chain "$FILE_ARG"
  exit 0
fi

while IFS= read -r -d '' file; do
  if in_scope "$file"; then
    emit_resolution "$file"
  fi
done < <(find "$PLANS_ROOT" -type f \( -name '*.md' -o -name '*.json' \) -print0)

if [[ "$MODE" == "corpus" ]]; then
  printf "## plan-parent-resolve (%d files scanned)\n\n" "$TOTAL"
  printf -- "- Explicit parent_plan: %d\n" "$EXPLICIT"
  printf -- "- Path-inferred: %d\n" "$INFERRED"
  printf -- "- Unresolvable: %d\n" "$UNRESOLVABLE"
  printf -- "- Broken pointers: %d\n" "$BROKEN"
  printf -- "- Cycles detected: %d\n" "$CYCLE"
  printf -- "- Chain too deep: %d\n" "$TOODEEP"
fi

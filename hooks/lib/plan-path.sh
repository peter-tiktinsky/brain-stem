# plan-path.sh — Canonical plan-root path/slug identification + walker.
#
# Eliminates the R-27 hook ↔ plan-index librarian drift surface
# by extracting the depth-aware plan-root classification into a single source
# of truth sourced by both layers.
#
# First consumers: pre-write-guard.sh (R-27 block), drift-sweep.sh,
# people-audit.sh, and the spec pseudocode for SKILL.md capabilities that
# walk or classify $PLANS_DIR (plan-index, stale-detect, placement-validate,
# sync-check, plan-parent-resolve).
#
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/plan-path.sh"
#   if is_plan_root_file "$file"; then ...
#   slug=$(plan_root_of "$file")
#   info=$(classify_plan_path "$file")  # returns is_plan|is_manifest|top_segment
#   for slug in $(walk_plan_roots); do ...
#
# Plan-root file scope (R-27 enforced types):
#   $PLANS_DIR/*.md                         (depth-1 flat root plans)
#   $PLANS_DIR/*/spec.md
#   $PLANS_DIR/*/00-ideation-brief.md
#   $PLANS_DIR/*/README.md
#   $PLANS_DIR/*/manifest.json              (top-level status field)
#
# Whitelisted (NOT plan roots, even though they sit at $PLANS_DIR root):
#   $PLANS_DIR/ENFORCEMENT-MAP.md
#   $PLANS_DIR/_index.md
#
# Bash 3.2 clean per R-23 (macOS /bin/bash compatibility).
# Depends on $PLANS_DIR — caller must source hooks/lib/paths.sh first OR
# export PLANS_DIR.

# Source paths.sh if PLANS_DIR not already exported (idempotent).
if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
fi

# plan_root_of <file> — print the top-level segment (= plan slug) for any
# path under $PLANS_DIR. Returns empty + non-zero if file is outside.
plan_root_of() {
  local file="$1"
  case "$file" in
    "$PLANS_DIR/"*) ;;
    *) return 1 ;;
  esac
  local rel="${file#$PLANS_DIR/}"
  echo "${rel%%/*}"
}

# is_plan_root_file <file> — return 0 if file is one of the R-27 enforced
# plan-root types. Whitelisted registries return 1 (not a plan root).
is_plan_root_file() {
  local file="$1"
  case "$file" in
    "$PLANS_DIR/"*) ;;
    *) return 1 ;;
  esac
  local rel="${file#$PLANS_DIR/}"
  case "$rel" in
    ENFORCEMENT-MAP.md|_index.md) return 1 ;;
  esac
  if [[ "$rel" != */* ]] && [[ "$rel" == *.md ]]; then
    return 0
  fi
  if [[ "$rel" == */* ]] && [[ "${rel#*/}" != */* ]]; then
    case "$(basename "$file")" in
      spec.md|00-ideation-brief.md|README.md|manifest.json) return 0 ;;
    esac
  fi
  return 1
}

# plan_depth <file> — print integer segment count under $PLANS_DIR.
# 1 = flat root file, 2 = spec/manifest in plan dir, 3+ = sub-task files.
# Prints -1 + non-zero exit if file is outside $PLANS_DIR.
plan_depth() {
  local file="$1"
  case "$file" in
    "$PLANS_DIR/"*) ;;
    *) echo "-1"; return 1 ;;
  esac
  local rel="${file#$PLANS_DIR/}"
  local rest="$rel" depth=1
  while [[ "$rest" == */* ]]; do
    rest="${rest#*/}"
    depth=$((depth + 1))
  done
  echo "$depth"
}

# classify_plan_path <file> — print is_plan|is_manifest|top_segment.
# Single-call form intended for the R-27 hook block; replaces ~25 lines of
# inline string ops with one helper invocation. Whitelisted registries return
# 0|0|<segment> (segment preserved for diagnostics; is_plan flag is the gate).
classify_plan_path() {
  local file="$1"
  case "$file" in
    "$PLANS_DIR/"*) ;;
    *) echo "0|0|"; return ;;
  esac
  local rel="${file#$PLANS_DIR/}"
  local top="${rel%%/*}"
  case "$rel" in
    ENFORCEMENT-MAP.md|_index.md) echo "0|0|${top}"; return ;;
  esac
  if [[ "$rel" != */* ]] && [[ "$rel" == *.md ]]; then
    echo "1|0|${top}"; return
  fi
  if [[ "$rel" == */* ]] && [[ "${rel#*/}" != */* ]]; then
    case "$(basename "$file")" in
      spec.md|00-ideation-brief.md|README.md) echo "1|0|${top}"; return ;;
      manifest.json) echo "1|1|${top}"; return ;;
    esac
  fi
  echo "0|0|${top}"
}

# walk_plan_roots — print plan slugs (top-level dirs + flat *.md), one per
# line. Excludes _index.md, ENFORCEMENT-MAP.md, and anything starting with _.
# Used by plan-index, stale-detect, sync-check, plan-parent-resolve.
walk_plan_roots() {
  local entry slug
  for entry in "$PLANS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    slug=$(basename "$entry")
    case "$slug" in
      _*|ENFORCEMENT-MAP.md|_index.md) continue ;;
    esac
    echo "$slug"
  done
}

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
# NOT plan roots, even though they sit at $PLANS_DIR root (root_namespace registry
# surfaces, derived from the pillar via classify_root_entry — no longer hard-coded):
#   $PLANS_DIR/_index.md  $PLANS_DIR/_backlog.md
#   $PLANS_DIR/_inbox/    $PLANS_DIR/_projects/   $PLANS_DIR/_library/
# (ENFORCEMENT-MAP.md — the historical rule map — was relocated out of the plans root and
#  its transitional root_namespace.grandfathered entry removed in the same change: it now
#  classifies `nonconforming` like any other non-enumerated root name. The grandfathered
#  list is EMPTY; the mechanism remains for any future still-present file pending relocation.)
#
# Bash 3.2 clean per R-23 (macOS /bin/bash compatibility).
# Depends on $PLANS_DIR — caller must source hooks/lib/paths.sh first OR
# export PLANS_DIR.

# Source paths.sh if PLANS_DIR not already exported (idempotent).
if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" ] && source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"; } \
    || { [ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh" ] && source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"; }
fi

# --- root_namespace single-SoT classifier (plans-rules.json :: root_namespace) ----------
# The plans-tree root is a CLOSED namespace. classify_root_entry is the single classifier
# the write-time root-allowlist guard (hooks/pre-write-guard.sh) and the placement-validate
# sweep both read, and the SAME derivation the three plan-root functions below (is_plan_root_file
# classify_plan_path / walk_plan_roots) reconcile onto — retiring the drifting hard-coded
# registry whitelists (the since-relocated ENFORCEMENT-MAP.md / _index.md) each carried
# independently.

# _root_ns_registry_members — print the enumerated NON-plan-root registry surfaces
# (root_files members + funnel/registry dir members) from root_namespace, one per line,
# PLUS any transitional root_namespace.grandfathered entries (still-present root files
# pending relocation; the guard must never deny writes to them while they live at the
# root — the grandfather is removed by the same change that relocates the file).
# Read order: composed foundation-master (.plans.root_namespace) -> raw plans-rules.json
# pillar -> hard default (fail-safe to the shipped enumeration; deliberately WITHOUT the
# grandfathered entries so the pillar stays their single removal point). Cached per process.
_root_ns_registry_members() {
  if [[ -n "${_ROOT_NS_REG_CACHE:-}" ]]; then printf '%s' "$_ROOT_NS_REG_CACHE"; return; fi
  local out="" master pillar
  master="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
  pillar="${PLANS_RULES_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json}"
  if command -v jq >/dev/null 2>&1; then
    [[ -f "$master" ]] && out=$(jq -r '.plans.root_namespace | ((.allowed_entry_classes.root_files.members[]?), (.allowed_entry_classes.funnel_registry_surfaces.members[]?), (.grandfathered[]?))' "$master" 2>/dev/null)
    [[ -z "$out" && -f "$pillar" ]] && out=$(jq -r '.root_namespace | ((.allowed_entry_classes.root_files.members[]?), (.allowed_entry_classes.funnel_registry_surfaces.members[]?), (.grandfathered[]?))' "$pillar" 2>/dev/null)
  fi
  [[ -z "$out" ]] && out=$'_index.md\n_backlog.md\n_inbox\n_projects\n_library'
  _ROOT_NS_REG_CACHE="$out"
  printf '%s' "$out"
}

# _root_ns_plan_patterns — print the plan-class regexes (plan_dirs.pattern +
# legacy_flat_plans.pattern) from root_namespace, one per line. SAME read posture + fallback
# as _root_ns_registry_members: composed foundation-master -> raw pillar -> the literal
# fallback (byte-identical to the pillar's declared patterns / slug_rules.pattern), so the
# plan leg is NOT a third independently-hardcoded looser regex — it is pillar-derived, and the
# literals live ONLY as the fail-open fallback when the master is unreadable.
_root_ns_plan_patterns() {
  if [[ -n "${_ROOT_NS_PAT_CACHE:-}" ]]; then printf '%s' "$_ROOT_NS_PAT_CACHE"; return; fi
  local out="" master pillar
  master="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
  pillar="${PLANS_RULES_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json}"
  if command -v jq >/dev/null 2>&1; then
    [[ -f "$master" ]] && out=$(jq -r '.plans.root_namespace.allowed_entry_classes | ((.plan_dirs.pattern), (.legacy_flat_plans.pattern)) | select(. != null)' "$master" 2>/dev/null)
    [[ -z "$out" && -f "$pillar" ]] && out=$(jq -r '.root_namespace.allowed_entry_classes | ((.plan_dirs.pattern), (.legacy_flat_plans.pattern)) | select(. != null)' "$pillar" 2>/dev/null)
  fi
  [[ -z "$out" ]] && out=$'^[0-9]{2,}-[a-z][a-z0-9-]+$\n^[0-9]{2,}-[a-z][a-z0-9-]+\\.md$'
  _ROOT_NS_PAT_CACHE="$out"
  printf '%s' "$out"
}

# classify_root_entry <entry-name> — classify a single plans-root ENTRY (basename) against
# root_namespace. Prints exactly one of: plan | registry | dot | nonconforming.
#   dot           — leading-dot entry (class-exempt: .git/.gitignore/.DS_Store/.active-plan/…)
#   registry      — an enumerated root_files / funnel-registry surface (not a plan root),
#                   or a TRANSITIONAL root_namespace.grandfathered entry (a still-present
#                   root file pending relocation — never write-denied while it lives here)
#   plan          — NN-<slug> plan dir or NN-<slug>.md flat plan
#   nonconforming — anything else (ad-hoc root stock; denied at write-time + swept)
# ENFORCEMENT-MAP.md (the historical rule map) is neither enumerated nor grandfathered —
# its transitional grandfather entry was removed when the file relocated out of the plans
# root, so it classifies `nonconforming` like any other non-enumerated root name.
classify_root_entry() {
  local entry="$1" m members oldIFS
  case "$entry" in
    .*) echo "dot"; return ;;
  esac
  members="$(_root_ns_registry_members)"
  oldIFS="$IFS"; IFS=$'\n'
  for m in $members; do
    if [[ "$entry" == "$m" ]]; then IFS="$oldIFS"; echo "registry"; return; fi
  done
  IFS="$oldIFS"
  # plan-class: match the entry against the pillar-declared patterns (plan_dirs +
  # legacy_flat_plans) rather than a third hardcoded looser regex — a sub-pillar-shape name
  # (single-digit prefix, single-char slug) now classifies nonconforming, matching the pillar.
  local pat oldIFS2="$IFS"
  IFS=$'\n'
  for pat in $(_root_ns_plan_patterns); do
    if [[ "$entry" =~ $pat ]]; then IFS="$oldIFS2"; echo "plan"; return; fi
  done
  IFS="$oldIFS2"
  echo "nonconforming"
}

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
  local top="${rel%%/*}"
  # Reconciled to root_namespace: registry surfaces + dot entries are NOT plan roots, and
  # a flat *.md at root is a plan ONLY when it classifies `plan` (i.e. matches the pillar's
  # legacy_flat_plans pattern). A nonconforming bare .md (any _-prefixed name, or any name
  # outside the legacy_flat_plans pattern) is NOT a plan here — three-site agreement with
  # classify_root_entry + walk_plan_roots (Finding 3: the permissive fallback used to
  # mis-classify a de-sanctioned root .md 1|1|0).
  local _cls
  _cls="$(classify_root_entry "$top")"
  case "$_cls" in
    registry|dot) return 1 ;;
  esac
  if [[ "$rel" != */* ]] && [[ "$rel" == *.md ]] && [[ "$_cls" == "plan" ]]; then
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
  # Reconciled to root_namespace: registry surfaces + dot entries are NOT plan roots, and a
  # flat *.md at root is a plan ONLY when it classifies `plan` (pillar legacy_flat_plans
  # pattern). A nonconforming bare .md (any _-prefixed name, or any name outside the
  # legacy_flat_plans pattern) is NOT a plan here — three-site agreement (Finding 3).
  local _cls
  _cls="$(classify_root_entry "$top")"
  case "$_cls" in
    registry|dot) echo "0|0|${top}"; return ;;
  esac
  if [[ "$rel" != */* ]] && [[ "$rel" == *.md ]] && [[ "$_cls" == "plan" ]]; then
    echo "1|0|${top}"; return
  fi
  # Depth-2 plan-root-file branch. The `$top != _*` carve-out keeps an _inbox / _projects /
  # _library funnel-registry surface (e.g. an _inbox note slugged `spec` ->)
  # from being mis-classified as a plan root by the spec.md basename match — those top
  # segments are registry surfaces, never plan roots (plans-rules.json :: root_namespace).
  if [[ "$rel" == */* ]] && [[ "${rel#*/}" != */* ]] && [[ "$top" != _* ]]; then
    case "$(basename "$file")" in
      spec.md|00-ideation-brief.md|README.md) echo "1|0|${top}"; return ;;
      manifest.json) echo "1|1|${top}"; return ;;
    esac
  fi
  echo "0|0|${top}"
}

# walk_plan_roots — print plan slugs (top-level dirs + flat *.md), one per
# line. Excludes registry surfaces (_index.md, _backlog.md, funnel/registry dirs),
# dot entries, and nonconforming ad-hoc names — anything not plan-class.
# Used by plan-index, stale-detect, sync-check, plan-parent-resolve.
walk_plan_roots() {
  local entry slug
  for entry in "$PLANS_DIR"/*; do
    [[ -e "$entry" ]] || continue
    slug=$(basename "$entry")
    # Reconciled to root_namespace: emit ONLY plan-class entries (NN-<slug> dirs + flat
    # NN-*.md plans). Registry surfaces, dot entries, and nonconforming ad-hoc stock
    # are skipped via the single classifier.
    case "$(classify_root_entry "$slug")" in
      plan) echo "$slug" ;;
    esac
  done
}

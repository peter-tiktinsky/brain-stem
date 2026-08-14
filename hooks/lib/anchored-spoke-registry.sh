#!/bin/bash
# hooks/lib/anchored-spoke-registry.sh — the ONE resolver for
# governance/anchored-spoke-registry.json, plus the write-target coherence guard
# that keeps a resolved registry and a resolved write target in the same tree.
#
# Source it — do not execute it:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/anchored-spoke-registry.sh"
#   SPOKE_REG="$(spoke_registry_resolve "$fallback_governance_dir")"
#   spoke_registry_assert_coherent "$SPOKE_REG" "$write_target" "<label>" || exit 1
#
# WHY ONE RESOLVER. Four shipped consumers each carried their own copy of the
# same three-candidate chain, and the prose above three of those copies described
# a different order than the code below it ran. A chain that lives in four places
# drifts in four places. The order is stated once, here, and every consumer reads
# it from here.
#
# RESOLUTION ORDER — LIVE-FIRST (the order the consumers already ran):
#   1. $SPOKE_REGISTRY_PATH — explicit override (test isolation).
#   2. ${CLAUDE_HOME:-$HOME/.claude}/governance/anchored-spoke-registry.json —
#      the install the caller is executing against. This is the sibling-component
#      resolution of hooks/README.md "Sibling-resolution contract" clause 1.
#   3. the caller-supplied fallback governance dir(s), in the order given (a repo
#      or bundle copy). Reached ONLY when candidate 2 misses.
# The LAUNCH DIRECTORY is not a factor at any step, and the foundation copy is a
# fallback, never a first choice.
#
# WRITE-TARGET COHERENCE — the enforcement arm of that contract's clause 1.
# A capability can resolve its WRITE TARGET from $HOME and its REGISTRY from
# $CLAUDE_HOME in the same breath, and nothing made the two agree. When
# CLAUDE_HOME points at some other tree that happens to have a governance/ dir —
# a worktree, a ship tree, a harness's copy of the foundation — the capability
# writes the LIVE plan corpus while reading THAT tree's registry. Because an
# unresolvable spoke renders as the graceful empty rather than an error, the file
# still renders, and it is silently wrong on every row the other tree's registry
# does not know. spoke_registry_assert_coherent refuses that pairing loudly,
# before anything renders. A tree with no governance/plans-rules.json already
# fails closed upstream in the consumers that require it; this guard covers the
# case that upstream check cannot see — a fully foundation-shaped tree.
#
# Bash 3.2 clean per R-23. No side effects: nothing here reads, writes, or
# creates a file; the resolver tests for existence and the guard compares paths.

# spoke_registry_resolve [<fallback-governance-dir> ...]
# Prints the resolved registry path, or NOTHING when no candidate exists on disk
# (the consumers' documented graceful-empty input). Always returns 0 so a
# `set -e` caller can assign the result directly.
spoke_registry_resolve() {
  local claude_home_res cand
  claude_home_res="${CLAUDE_HOME:-$HOME/.claude}"
  if [ -n "${SPOKE_REGISTRY_PATH:-}" ]; then
    printf '%s\n' "$SPOKE_REGISTRY_PATH"
    return 0
  fi
  for cand in "$claude_home_res/governance" "$@"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/anchored-spoke-registry.json" ]; then
      printf '%s\n' "$cand/anchored-spoke-registry.json"
      return 0
    fi
  done
  return 0
}

# spoke_registry_resolve_or_default [<fallback-governance-dir> ...]
# As above, but when no candidate exists print the live-install candidate anyway,
# for callers whose contract is "always print a path" (the reader then reports the
# path it could not open instead of an empty string).
spoke_registry_resolve_or_default() {
  local resolved
  resolved="$(spoke_registry_resolve "$@")"
  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  printf '%s\n' "${CLAUDE_HOME:-$HOME/.claude}/governance/anchored-spoke-registry.json"
  return 0
}

# spoke_registry_assert_coherent <registry-path> <write-target> [<label>]
# Returns 0 when the pair is coherent or when there is nothing to judge (no write
# target declared, no registry resolved, or a write target outside the live plan
# corpus — the isolated-sandbox case every test harness runs in).
# Returns 1, after a loud stderr diagnostic, when the write target IS the live
# plan corpus and the resolved registry belongs to a different tree.
#
# SCOPE — the guard judges AMBIENT resolution, not a named one. A registry the
# caller named through $SPOKE_REGISTRY_PATH is a deliberate, visible choice (the
# documented isolation seam every consumer's header declares), and a harness that
# mirrors the live layout inside its own sandbox depends on it. The defect this
# guard closes is the SILENT one: a registry nobody asked for, inherited through
# CLAUDE_HOME and bound behind a graceful-empty render.
spoke_registry_assert_coherent() {
  local reg="${1:-}" target="${2:-}" label="${3:-anchored-spoke-registry}"
  local live_install="$HOME/.claude" live_plans="$HOME/.claude-plans"
  [ -n "$target" ] || return 0
  [ -n "$reg" ] || return 0
  if [ -n "${SPOKE_REGISTRY_PATH:-}" ] && [ "$reg" = "$SPOKE_REGISTRY_PATH" ]; then
    return 0
  fi
  case "$target" in
    "$live_plans"|"$live_plans"/*) ;;
    *) return 0 ;;
  esac
  case "$reg" in
    "$live_install"/*) return 0 ;;
  esac
  printf '%s: REFUSING — the write target and the anchored-spoke registry belong to different trees.\n' "$label" >&2
  printf '%s:   write target: %s (the live plan corpus)\n' "$label" "$target" >&2
  printf '%s:   registry:     %s (not under %s)\n' "$label" "$reg" "$live_install" >&2
  printf '%s:   CLAUDE_HOME:  %s\n' "$label" "${CLAUDE_HOME:-<unset>}" >&2
  printf '%s: another tree'"'"'s registry knows another tree'"'"'s spokes, so this run would blank every row it cannot resolve instead of failing. Unset CLAUDE_HOME (or aim the write target at the tree the registry belongs to) and re-run.\n' "$label" >&2
  return 1
}

#!/bin/bash
# hooks/lib/vault-view-walk.sh — the single shared scoped-followlinks vault-view
# walker primitive. One traversal library the symlink-inertia
# consumers source, replacing the 6-8 per-capability os.walk re-implementations the
# audit found.
#
# BINDING SHAPE — (129/spec.md §Solution-Approach-Amendment): "a single shared
# scoped-followlinks vault-view walker (realpath cycle-guard, restricted to the known
# Plans/Projects/Wiki/Work/Skills symlink set) consumed by ~6 capabilities". Both
# parenthetical clauses are requirements: (1) a realpath cycle-guard so a
# self-referential/circular symlink cannot hang the walk; (2) reach across the FIVE
# symlink surfaces — Plans/ Projects/ Wiki/ Work/ Skills/ — plus the
# Vault Writers/ subtree (which a followlinks=False walk misses).
#
# The ~/Documents/brain view is a symlink view: Plans/ Projects/ Wiki/ Work/ Skills/
# are symlinks onto external roots. A followlinks=False walk (Python os.walk default,
# BSD/GNU `find` without -L) NEVER descends them, so a consumer scanning the vault
# root reaches only the handful of real top-level files and misses every file behind
# a surface symlink. This walker FOLLOWS symlinks (os.walk(followlinks=True) parity)
# with a realpath visited-set cycle-guard mirroring
# skills/librarian/capabilities/index-maintain.sh:283-290 (the established
# bash-3.2-safe pattern) so a circular symlink terminates instead of hanging.
#
# API (FROZEN — consumers source this read-only; do not churn):
#   vault_view_walk <scope-root> [exempt-glob ...]
#     scope-root   : the walk root (the vault view, or any subtree of it). Required.
#     exempt-glob* : zero or more scope-RELATIVE globs; a directory whose
#                    scope-relative path matches an exempt glob is PRUNED (not
#                    emitted, not descended) so a caller can bound its reach.
#                    `*` spans path segments (case-pattern semantics); a `/**` glob
#                    also prunes its own base directory (fnmatch parity with
#                    index-maintain.sh's _glob_match). Dotfiles/dotdirs are skipped.
#   Emits, one ABSOLUTE path per line to stdout, every REGULAR FILE reachable under
#   scope-root along the followed symlink view. Paths are emitted in the vault-view
#   (logical) shape — Work/<spoke>/... — not the physical symlink target, so a
#   caller's scope-relative predicates keep working across the symlink boundary.
#   Directory realpaths drive ONLY the cycle-guard; emission + exempt matching use
#   the logical path.
#
# Bash 3.2 clean (R-23): indexed arrays only (NO declare -A / readarray / mapfile),
# no ${var,,}, no &>>. Sourced library — defines functions only, no top-level
# execution, no set -e/set -u side effects on the caller.

# --- internal: membership test against the realpath visited set (linear scan;
#     bash-3.2-safe indexed-array idiom, empty-safe under a caller's set -u) -------
_vvw_seen() {
  local _needle="$1" _v
  for _v in ${_VVW_VISITED[@]+"${_VVW_VISITED[@]}"}; do
    [ "$_v" = "$_needle" ] && return 0
  done
  return 1
}

# --- internal: is <scope-relative-dir> covered by a caller exempt glob? ----------
_vvw_is_exempt() {
  local _rel="$1" _g _base
  for _g in ${_VVW_EXEMPT[@]+"${_VVW_EXEMPT[@]}"}; do
    [ -n "$_g" ] || continue
    # `*` in a case pattern spans '/', so Foo/** matches Foo/a/b (fnmatch-ish).
    case "$_rel" in
      $_g) return 0 ;;
    esac
    # A `/**` glob also matches its own base dir (index-maintain _glob_match parity).
    case "$_g" in
      */'**')
        _base="${_g%/**}"
        case "$_rel" in
          $_base) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

# --- internal: recursive descent. $1 = logical dir; $2 = logical scope root. ------
_vvw_walk() {
  local _dir="$1" _root="$2" _rp _rel _entry _bn
  # realpath resolves symlinks -> the physical dir; this is the cycle-guard key
  # (a self-referential/circular symlink resolves to an already-visited physical
  # dir and is pruned). Mirrors index-maintain.sh:284 os.path.realpath(dirpath).
  _rp="$(cd "$_dir" 2>/dev/null && pwd -P)" || return 0
  _vvw_seen "$_rp" && return 0
  _VVW_VISITED[${#_VVW_VISITED[@]}]="$_rp"
  # scope-relative LOGICAL path (keeps the Work/<spoke>/... vault-view shape across
  # the symlink boundary — the exempt globs are authored against this shape).
  _rel="${_dir#$_root}"
  _rel="${_rel#/}"
  if [ -n "$_rel" ] && _vvw_is_exempt "$_rel"; then
    return 0
  fi
  for _entry in "$_dir"/*; do
    [ -e "$_entry" ] || continue          # literal glob (empty dir) — skip
    _bn="${_entry##*/}"
    case "$_bn" in .*) continue ;; esac    # skip dotfiles/dotdirs
    if [ -f "$_entry" ]; then              # -f follows symlinks-to-files
      printf '%s\n' "$_entry"
    elif [ -d "$_entry" ]; then            # -d follows symlinks-to-dirs (followlinks)
      _vvw_walk "$_entry" "$_root"
    fi
  done
}

# --- public entry point ----------------------------------------------------------
vault_view_walk() {
  local _root="${1:-}"
  shift 2>/dev/null || true
  [ -n "$_root" ] && [ -d "$_root" ] || return 0
  # Normalize the root to an existing absolute path once; children logical paths are
  # built by string-appending basenames to it (glob of "$_root"/*), so the
  # scope-relative computation in _vvw_walk stays consistent across the walk.
  local _root_abs
  _root_abs="$(cd "$_root" 2>/dev/null && pwd -P)" || return 0
  _VVW_EXEMPT=("$@")
  _VVW_VISITED=()
  _vvw_walk "$_root_abs" "$_root_abs"
  unset _VVW_EXEMPT _VVW_VISITED
}

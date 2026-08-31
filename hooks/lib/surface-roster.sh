#!/bin/bash
# hooks/lib/surface-roster.sh — the ONE machine-readable roster of live and
# retired corpus surfaces. Source this file — do not execute it:
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/surface-roster.sh"
#   surface_roster_json            # full roster as JSON on stdout
#   surface_roster_live_roots      # existing live root paths, one per line
#   surface_roster_retired_roots   # retired (denylisted) roots, one per line
#   surface_roster_is_retired <p>  # rc 0 iff <p> falls under a retired root
#
# WHY ONE ROSTER. Every capability that walks, link-checks, or enumerates
# corpus surfaces used to hand-code its own root set, and each copy rotted
# independently: mounted surfaces silently excluded while the headline read
# corpus-wide, live corpora (per-project memory, registered note spokes) that
# no walker covered at all, and a retired vault that still resolves on disk
# counting as live. The root set is stated once, here, and every walker reads
# it from here. A surface this file does not emit is NOT walked; a surface on
# the retired list is NEVER counted as live.
#
# WHAT THE ROSTER RESOLVES (all data-driven — nothing here hardcodes an
# operator-specific path):
#   live roots
#     - vault-root:      $VAULT_ROOT (when configured)
#     - vault-mount:<m>: every top-level symlink under $VAULT_ROOT, with its
#                        physical target. Mounts are enumerated from disk, not
#                        from a fixed name list, so a newly-minted mount is
#                        tracked without editing this file.
#     - memory:<slug>:   every $CLAUDE_HOME/projects/<slug>/memory dir
#     - rules:           $CLAUDE_HOME/rules
#     - spoke:<key>:     every cwd_anchor of an anchored-spoke-registry entry
#                        that opts in with "corpus_surface": true (note-corpus
#                        spokes; code/work spokes stay out unless flagged)
#   retired roots (the DENYLIST — surfaces that may still resolve on disk but
#   must never count as live)
#     - .paths.retired_surface_roots[] in user-manifest.json, or the
#       $SURFACE_ROSTER_RETIRED env override (colon-separated; test isolation)
#
# CONSUMER CONTRACT. Shell consumers call the functions directly. Embedded-
# python consumers receive the emitted JSON via argv or a temp file (data via
# argv, never a piped stdin). Enumeration downstream of the roster must be
# ignore-immune (python os.walk or `command grep`) — a gitignore-honoring
# wrapper must never narrow a census the roster granted.
#
# GRACEFUL DEGRADE. No jq -> the minimal empty roster (capabilities that need
# the roster already require jq). Unconfigured vault -> no vault entries.
# Missing registry/manifest -> those tiers are simply absent. `exists` is
# emitted per live entry; surface_roster_live_roots prints existing roots only.
#
# Bash 3.2 clean per R-23: no associative arrays, no bash-4 builtins. No side
# effects: nothing here writes or creates a file.

# Idempotent paths.sh source guard — keyed on CLAUDE_STATE_ROOT, which
# paths.sh always exports non-empty (VAULT_LOGS is a legacy-conditional export
# and is NOT a reliable sourced-sentinel).
if [ -z "${CLAUDE_STATE_ROOT:-}" ]; then
  # shellcheck source=/dev/null
  { [ -r "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" ] && source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"; } \
    || { [ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh" ] && source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"; }
fi

# Sibling resolver for the anchored-spoke registry (spoke_registry_resolve).
if ! command -v spoke_registry_resolve >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  { [ -r "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/anchored-spoke-registry.sh" ] && source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/anchored-spoke-registry.sh"; } \
    || { [ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/anchored-spoke-registry.sh" ] && source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/anchored-spoke-registry.sh"; }
fi

# _surface_roster_entry <tier> <id> <class> <path> [<target>]
# Emits one compact JSON entry line for the jq -s assembler below.
_surface_roster_entry() {
  local _sr_tier="$1" _sr_id="$2" _sr_class="$3" _sr_path="$4" _sr_target="${5:-}"
  local _sr_exists=false
  [ -e "$_sr_path" ] && _sr_exists=true
  jq -n -c \
    --arg tier "$_sr_tier" --arg id "$_sr_id" --arg class "$_sr_class" \
    --arg path "$_sr_path" --arg target "$_sr_target" --argjson exists "$_sr_exists" \
    '{tier:$tier,id:$id,class:$class,path:$path,exists:$exists}
     + (if $target != "" then {target:$target} else {} end)'
}

# _surface_roster_expand_tilde <path> — expand a leading ~ / ~/ to $HOME.
_surface_roster_expand_tilde() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# surface_roster_retired_roots — the denylist, one absolute root per line.
# $SURFACE_ROSTER_RETIRED (colon-separated) wins; else the manifest array.
surface_roster_retired_roots() {
  local _sr_manifest _sr_r
  if [ -n "${SURFACE_ROSTER_RETIRED:-}" ]; then
    printf '%s\n' "$SURFACE_ROSTER_RETIRED" | tr ':' '\n'
  else
    _sr_manifest="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
    if [ -r "$_sr_manifest" ] && command -v jq >/dev/null 2>&1; then
      jq -r '(.paths.retired_surface_roots // [])[]' "$_sr_manifest" 2>/dev/null
    fi
  fi | while IFS= read -r _sr_r; do
    [ -n "$_sr_r" ] || continue
    _surface_roster_expand_tilde "$_sr_r"
  done
}

# surface_roster_is_retired <path> — rc 0 iff <path> is, or is under, a
# retired root. Denylist semantics apply whether or not the root exists.
surface_roster_is_retired() {
  local _sr_p="${1:-}" _sr_root
  [ -n "$_sr_p" ] || return 1
  while IFS= read -r _sr_root; do
    [ -n "$_sr_root" ] || continue
    case "$_sr_p" in
      "$_sr_root"|"$_sr_root"/*) return 0 ;;
    esac
  done <<EOF
$(surface_roster_retired_roots)
EOF
  return 1
}

# surface_roster_json — the full roster as one JSON document on stdout:
#   {"roster_version":1,
#    "live":    [{"id","class","path","exists"[,"target"]}...],
#    "retired": [{"id","path"}...]}
surface_roster_json() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"roster_version":1,"live":[],"retired":[]}\n'
    return 0
  fi
  local _sr_m _sr_d _sr_reg _sr_row _sr_key _sr_anchor _sr_target _sr_n _sr_r
  {
    # --- vault root + its mounts (top-level symlinks, enumerated from disk) ---
    if [ -n "${VAULT_ROOT:-}" ]; then
      _surface_roster_entry live vault-root vault-root "$VAULT_ROOT"
      if [ -d "$VAULT_ROOT" ]; then
        for _sr_m in "$VAULT_ROOT"/*; do
          [ -L "$_sr_m" ] || continue
          _sr_target="$(cd "$_sr_m" 2>/dev/null && pwd -P)" || _sr_target=""
          _surface_roster_entry live "vault-mount:$(basename "$_sr_m")" vault-mount "$_sr_m" "$_sr_target"
        done
      fi
    fi
    # --- per-project memory corpora + the rules corpus ---
    for _sr_d in "${CLAUDE_HOME:-$HOME/.claude}"/projects/*/memory; do
      [ -d "$_sr_d" ] || continue
      _surface_roster_entry live "memory:$(basename "$(dirname "$_sr_d")")" memory-corpus "$_sr_d"
    done
    _surface_roster_entry live rules rules-corpus "${CLAUDE_HOME:-$HOME/.claude}/rules"
    # --- corpus-flagged spoke anchors (opt-in: "corpus_surface": true) ---
    _sr_reg="$(spoke_registry_resolve 2>/dev/null)" || _sr_reg=""
    if [ -n "$_sr_reg" ] && [ -f "$_sr_reg" ]; then
      jq -r '.spokes[]? | select(.corpus_surface == true)
             | .spoke_key as $k | (.cwd_anchors // [])[] | $k + "\t" + .' \
        "$_sr_reg" 2>/dev/null \
      | while IFS="$(printf '\t')" read -r _sr_key _sr_anchor; do
          [ -n "$_sr_anchor" ] || continue
          _surface_roster_entry live "spoke:$_sr_key" spoke-corpus \
            "$(_surface_roster_expand_tilde "$_sr_anchor")"
        done
    fi
    # --- retired denylist ---
    _sr_n=0
    while IFS= read -r _sr_r; do
      [ -n "$_sr_r" ] || continue
      _sr_n=$((_sr_n + 1))
      jq -n -c --arg id "retired:$_sr_n" --arg path "$_sr_r" \
        '{tier:"retired",id:$id,path:$path}'
    done <<EOF
$(surface_roster_retired_roots)
EOF
  } | jq -s '{roster_version:1,
              live:    [.[] | select(.tier=="live")    | del(.tier)],
              retired: [.[] | select(.tier=="retired") | del(.tier)]}'
}

# surface_roster_live_roots — existing live root paths, one per line (the
# walkers' plain-shell entry point).
surface_roster_live_roots() {
  surface_roster_json | jq -r '.live[] | select(.exists) | .path'
}

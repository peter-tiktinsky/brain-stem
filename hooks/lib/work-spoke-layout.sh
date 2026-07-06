#!/bin/bash
# work-spoke-layout.sh — shared shape-detection for Work project spokes.
# A Work spoke can be FLAT (its own deliverables/ + reference/ at the top level)
# or a MASTER (no top-level deliverables/reference; each sub-project is a direct
# child dir owning its OWN deliverables/ + reference/). A master may ALSO hold
# plain top-level folders that are NOT sub-projects (e.g. shared assets, a
# People/ roster).
# The single discriminator, shared by every librarian work capability so it can
# never drift between them: a top-level directory is a SUB-PROJECT if and only if
# it owns its own deliverables/ or reference/ subdir. A top-level dir that is
# neither deliverables/ nor reference/ AND owns neither is a plain "other" folder.
# Public surface (source this file, then call):
#   RESERVED                    the reserved subdir names ("deliverables reference")
#   is_subproject DIR NAME      rc 0 iff DIR/NAME owns deliverables/ or reference/
#   classify_top_level DIR      scan DIR's top level; sets these globals:
#       WSL_IS_MASTER    0|1   1 iff >=1 shape-qualified sub AND the spoke owns
#                              neither top-level deliverables/ nor reference/
#       WSL_HAS_DELIV    0|1   1 iff DIR owns a top-level deliverables/
#       WSL_HAS_REF      0|1   1 iff DIR owns a top-level reference/
#       WSL_SUBPROJECTS  newline-delimited names of the shape-qualified subs
#       WSL_OTHER_DIRS   newline-delimited names of the plain (non-sub) folders
# The classification values cross into a consumer's python3 heredoc via argv
# (the consumer sources this helper, calls classify_top_level, and passes the
# resulting globals through — no reliance on exported python state).
# bash 3.2 clean: no `declare -A`, no `mapfile`, no `${var,,}`.

# Idempotent-source guard.
if [ -n "${_WORK_SPOKE_LAYOUT_SH:-}" ]; then
  return 0 2>/dev/null || true
fi
_WORK_SPOKE_LAYOUT_SH=1

# The reserved top-level subdir names that mark a dir as owning a deliverables/
# reference shape. Space-delimited literal (bash 3.2 — word-split on use).
RESERVED="deliverables reference"

# is_subproject DIR NAME
# rc 0 iff DIR/NAME owns its own deliverables/ or reference/ subdir. This is the
# shape predicate — byte-semantically the "owns deliverables/ or reference/" test
# every walker converges on (mirrors index-maintain's _has_deliverables_or_reference).
is_subproject() {
  local spoke_dir="$1" name="$2" r
  for r in $RESERVED; do
    if [ -d "$spoke_dir/$name/$r" ]; then
      return 0
    fi
  done
  return 1
}

# classify_top_level DIR
# Scan DIR's top level (non-recursive; dotfiles ignored) and populate the WSL_*
# globals. Every top-level dir that is not itself deliverables/ or reference/ is
# classified by is_subproject into WSL_SUBPROJECTS (owns a reserved subdir) or
# WSL_OTHER_DIRS (owns neither). is_master is the tightened rule: at least one
# shape-qualified sub AND the spoke owns neither top-level deliverables/ nor
# reference/ (a flat spoke that happens to carry a plain folder is NOT a master).
classify_top_level() {
  local spoke_dir="$1" path name
  WSL_IS_MASTER=0
  WSL_HAS_DELIV=0
  WSL_HAS_REF=0
  WSL_SUBPROJECTS=""
  WSL_OTHER_DIRS=""
  [ -d "$spoke_dir" ] || return 0
  [ -d "$spoke_dir/deliverables" ] && WSL_HAS_DELIV=1
  [ -d "$spoke_dir/reference" ] && WSL_HAS_REF=1
  for path in "$spoke_dir"/*; do
    [ -d "$path" ] || continue
    name=$(basename "$path")
    case "$name" in
      .*) continue ;;
      deliverables|reference) continue ;;
    esac
    if is_subproject "$spoke_dir" "$name"; then
      WSL_SUBPROJECTS="${WSL_SUBPROJECTS}${name}
"
    else
      WSL_OTHER_DIRS="${WSL_OTHER_DIRS}${name}
"
    fi
  done
  if [ -n "$WSL_SUBPROJECTS" ] && [ "$WSL_HAS_DELIV" = "0" ] && [ "$WSL_HAS_REF" = "0" ]; then
    WSL_IS_MASTER=1
  fi
  return 0
}

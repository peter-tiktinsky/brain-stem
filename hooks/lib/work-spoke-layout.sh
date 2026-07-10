#!/bin/bash
# work-spoke-layout.sh — shared shape-detection for Work project spokes.
#
# A Work spoke can be FLAT (its own deliverables/ + reference/ at the top level)
# or a MASTER (no top-level deliverables/reference; each sub-project is a direct
# child dir owning its OWN deliverables/ + reference/). A master may ALSO hold
# plain top-level folders that are NOT sub-projects (e.g. shared assets, a
# People/ roster).
#
# The discriminator, shared by every librarian work capability so it can never
# drift between them, is DECLARATION-FIRST with a SHAPE fallback: a top-level dir
# is a SUB-PROJECT if it owns the persistent declaration marker (.claude-subproject)
# OR, failing that, owns its own deliverables/ or reference/ subdir. Shape stays the
# zero-config DEFAULT; the marker is an ADDITIVE opt-in override (an undeclared dir is
# classified by shape exactly as before). A top-level dir that is neither deliverables/
# nor reference/ AND is neither declared nor shape-qualified is a plain "other" folder.
#
# Public surface (source this file, then call):
#   RESERVED                    the reserved subdir names ("deliverables reference")
#   SUBPROJECT_MARKER           the declaration marker filename (".claude-subproject")
#   declared_subproject DIR NAME  rc 0 iff DIR/NAME owns the declaration marker
#   is_subproject DIR NAME      rc 0 iff DIR/NAME owns deliverables/ or reference/
#   classify_top_level DIR      scan DIR's top level; sets these globals:
#       WSL_IS_MASTER    0|1   1 iff >=1 shape-qualified sub AND the spoke owns
#                              neither top-level deliverables/ nor reference/
#       WSL_HAS_DELIV    0|1   1 iff DIR owns a top-level deliverables/
#       WSL_HAS_REF      0|1   1 iff DIR owns a top-level reference/
#       WSL_SUBPROJECTS  newline-delimited names of the shape-qualified subs
#       WSL_OTHER_DIRS   newline-delimited names of the plain (non-sub) folders
#
# The classification values cross into a consumer's python3 heredoc via argv
# (the consumer sources this helper, calls classify_top_level, and passes the
# resulting globals through — no reliance on exported python state).
#
# bash 3.2 clean: no `declare -A`, no `mapfile`, no `${var,,}`.

# Idempotent-source guard.
if [ -n "${_WORK_SPOKE_LAYOUT_SH:-}" ]; then
  return 0 2>/dev/null || true
fi
_WORK_SPOKE_LAYOUT_SH=1

# The reserved top-level subdir names that mark a dir as owning a deliverables/
# reference shape. Space-delimited literal (bash 3.2 — word-split on use).
RESERVED="deliverables reference"

# The persistent sub-project DECLARATION marker filename. A top-level folder that
# owns this file is a declared sub-project, recognized regardless of shape. The
# marker is an ADDITIVE opt-in override to the shape default; its PRESENCE is the
# declaration (content is advisory, never read). Written at the /govern register
# front door (project.sh --add-sub / create-path first-sub). bash 3.2: plain string.
SUBPROJECT_MARKER=".claude-subproject"

# declared_subproject DIR NAME
# rc 0 iff DIR/NAME owns the persistent declaration marker. This is the
# declaration-FIRST predicate; is_subproject remains the shape FALLBACK. Kept a
# separate pure predicate so the shape test stays untouched and the precedence is
# explicit in classify_top_level. Mirrored in python by index-maintain.sh's
# _is_declared_subproject (bash lib vs python capability — kept in parity, not shared).
declared_subproject() {
  local spoke_dir="$1" name="$2"
  [ -f "$spoke_dir/$name/$SUBPROJECT_MARKER" ]
}

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
# classified DECLARATION-FIRST then by SHAPE: a dir owning the declaration marker
# (declared_subproject) OR, failing that, owning a reserved subdir (is_subproject)
# lands in WSL_SUBPROJECTS; otherwise WSL_OTHER_DIRS. is_master: at least one sub
# (declared or shape-qualified) AND the spoke owns neither top-level deliverables/
# nor reference/ (a flat spoke that happens to carry a plain folder is NOT a master).
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
    if declared_subproject "$spoke_dir" "$name" || is_subproject "$spoke_dir" "$name"; then
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

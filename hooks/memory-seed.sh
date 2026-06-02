#!/bin/bash
# hooks/memory-seed.sh — SessionStart: lazily seed the type-grouped MEMORY.md
# skeleton into the RESOLVED project memory dir when absent.
#
# Replaces install.sh's earlier eager seed, which wrote to a
# $CLAUDE_HOME-derived slug ($CLAUDE_HOME | tr '/' '-' | leading-dash-stripped)
# that (a) mis-encoded the slug vs the harness and (b) keyed off ~/.claude — a
# dir nobody launches sessions from. The skeleton reached no adopter.
#
# This hook instead seeds at SessionStart into resolve_memory_dir()'s output —
# the exact dir the running harness reads (git-repo-root slug, or the flat
# autoMemoryDirectory when set). Per-project, lazy, no-clobber.
#
# No-clobber: an existing MEMORY.md (template-shipped or user-curated) is
# preserved unconditionally. Failure-isolation mirrors session-start.sh:
# set -uo pipefail (NO -e); mandatory exit 0 (a non-zero SessionStart hook can
# break the user's session); Bash 3.2 + R-23 compatible.

set -uo pipefail  # NO -e — graceful-degrade on every failure

PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

main() {
  command -v resolve_memory_dir >/dev/null 2>&1 || return 0

  local mem_dir target template tmp
  mem_dir="$(resolve_memory_dir 2>/dev/null || echo "")"
  [ -n "$mem_dir" ] || return 0

  target="$mem_dir/MEMORY.md"
  # No-clobber: present, or a symlink (incl. dangling) → leave it.
  if [ -e "$target" ] || [ -L "$target" ]; then return 0; fi

  template="${CLAUDE_HOME:-$HOME/.claude}/templates/MEMORY.md.template"
  [ -r "$template" ] || return 0   # nothing to seed from — silent

  mkdir -p "$mem_dir" 2>/dev/null || return 0
  tmp="$mem_dir/.MEMORY.md.seed.$$"
  if cp "$template" "$tmp" 2>/dev/null && mv -f "$tmp" "$target" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

main
exit 0

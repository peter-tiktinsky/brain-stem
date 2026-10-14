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
# Throwaway-cwd skip: a session launched from a temp dir (a project dir whose slug is
# -private-tmp*, -tmp*, -private-var-folders-* or -var-folders-*) gets no seeded MEMORY.md;
# an explicit MEMORY_DIR, a flat override and every other slug seed as before.
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
# BOUNDED drain: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook chain hangs with zero output. The
# bound is PER READ: a stream that keeps delivering is never truncated, only silence
# is. HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE; do :; done
  unset _STDIN_WAIT _STDIN_LINE
fi

main() {
  command -v resolve_memory_dir >/dev/null 2>&1 || return 0

  local mem_dir target template tmp
  mem_dir="$(resolve_memory_dir 2>/dev/null || echo "")"
  [ -n "$mem_dir" ] || return 0

  # Skip: a throwaway temp-dir slug (-private-tmp, -tmp, -private-var-folders, -var-folders) is never seeded.
  # Applies only to the default projects/<slug>/memory resolution (MEMORY_DIR unset).
  if [ -z "${MEMORY_DIR:-}" ]; then
    local slug_dir slug
    slug_dir="$(dirname "$mem_dir")"
    if [ "$(basename "$(dirname "$slug_dir")")" = "projects" ]; then
      slug="$(basename "$slug_dir")"
      case "$slug" in
        -private-tmp|-private-tmp-*|-tmp|-tmp-*|-private-var-folders-*|-var-folders-*) return 0 ;;
      esac
    fi
  fi

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

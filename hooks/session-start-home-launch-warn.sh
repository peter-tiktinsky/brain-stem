#!/bin/bash
# Hook: SessionStart — advisory warning when Claude Code is launched from $HOME.
# Launching from the home directory itself is an anti-pattern on three axes:
#   1. workspace scope — the ENTIRE home tree (~/.ssh, credentials, Downloads, …)
#      is in the agent's file-operation scope;
#   2. config conflation — the project-level `.claude/` resolves onto the global
#      `~/.claude`, collapsing project and global scope;
#   3. catch-all bloat — every home launch writes to the anchorless `home` spoke's
#      catch-all project slug instead of a bounded, owned spoke.
# The `home` spoke is a fallback IDENTITY for an anchorless cwd, NOT a sanctioned
# launch anchor (anchored-spoke-registry.json: home.cwd_anchors == []). This hook
# fires ONLY when the launch cwd is EXACTLY $HOME (never a subdir) and surfaces an
# advisory naming the three harms + the remedy. It has NO deny surface (SessionStart
# cannot block), so it is advisory BY CONSTRUCTION — it injects additionalContext
# and exits 0 always. Fail-open on any parse/lib error; bash 3.2 clean (R-23).
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR. registry.sh provides
# format_output_allow (+ sources paths.sh). Prefer the repo-local lib (dev/test),
# then the live install. Fail-open: if we cannot source paths.sh, exit clean.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null \
  || source "$CLAUDE_HOME_RES/hooks/lib/registry.sh" 2>/dev/null

# --- Read the SessionStart payload .cwd (the launch dir — NOT $CLAUDE_PROJECT_DIR).
# Read the payload once and keep it to parse .cwd.
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line accumulates as it arrives, so a stream that keeps
# delivering is never truncated; blank lines are PRESERVED and the trailing-newline
# trim reproduces `$(cat)` exactly, so the payload reaches jq byte-identical.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
# The two reference implementations under skills/librarian/capabilities/ are NOT
# equivalent and this is neither: handoff-disposition-check.sh re-arms per read but
# DROPS blank lines; rename-cascade.sh bounds only the FIRST read, then free-runs an
# unbounded `cat`. This is the byte-preserving form the other hook drains carry.
INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    INPUT="${INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${INPUT%$'\n'}" != "$INPUT" ]; do INPUT="${INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
fi

# No jq -> cannot parse the payload -> nothing to warn on (fail-open).
command -v jq >/dev/null 2>&1 || exit 0

CWD=""
if [ -n "$INPUT" ]; then
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi

# Silent on missing/empty .cwd (no launch dir to judge).
[ -z "$CWD" ] && exit 0

# --- Normalize both sides (strip trailing slashes) and require an EXACT match.
# Exact $HOME only — a $HOME subdir (~/Code/..., ~/work/...) must stay SILENT.
_norm() {
  local p="$1"
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}
CWD_NORM="$(_norm "$CWD")"
HOME_NORM="$(_norm "$HOME")"
[ "$CWD_NORM" = "$HOME_NORM" ] || exit 0

# --- Fire the advisory (exact cwd == $HOME).
msg="[launch-anchor] This session was launched from your home directory (\$HOME) — an anti-pattern on three axes:
  1. Workspace scope: the ENTIRE home tree (~/.ssh, credentials, Downloads, …) is now in the agent's file-operation scope.
  2. Config conflation: the project-level .claude/ resolves onto the global ~/.claude, collapsing project and global scope.
  3. Catch-all bloat: this session writes to the anchorless 'home' catch-all identity instead of a bounded, owned spoke.
Remedy: launch from a registered spoke (a code repo, or a ~/work project). For cross-cutting personal-system work, create a dedicated bounded directory (e.g. ~/system) and register it as a spoke — a registry entry plus a one-line identity CLAUDE.md — the same way a code-tree spoke is registered; then launch from there, never from \$HOME.
This is ADVISORY only — the session continues normally."

if command -v format_output_allow >/dev/null 2>&1; then
  format_output_allow "SessionStart" "$msg" || true
else
  printf '%s\n' "$msg" >&2
fi

exit 0

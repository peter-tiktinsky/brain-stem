#!/bin/bash
# hooks/memory-globalize-auto.sh — PostToolUse (Edit|Write): the fully-auto
# promotion surface. When the operator opts into fully-auto, a
# `scope: global` memory write is promoted to ~/.claude/rules/ AT THE WRITE —
# no in-session confirm, no presence dependency.
#
# PostToolUse hook. Fires at the exact
# moment of the write, clones the proven memory-auto-stamp.sh path filter, is
# fully HOME-jail testable, and carries zero launchctl tax. The existing
# weekday librarian cron (memory-globalize is a registered capability) remains
# the complementary manual/scheduled surface; this hook is the deterministic
# auto path.
#
# Toggle (default = propose-then-confirm, NO silent writes):
#   settings.json env.MEMORY_GLOBALIZE_MODE
#     "auto"  -> promote on write (this hook acts)
#     absent / anything else (default "propose") -> no-op (propose-only)
#   The MEMORY_GLOBALIZE_MODE env var (set by settings.json `env`) wins; a jq
#   read of settings.json is the fallback so the gate is deterministic even if
#   the env did not propagate.
#
# Gate sequence (cheapest first; every miss is a silent exit 0):
#   1. write targets a project memory topic-file (not MEMORY.md)
#   2. toggle == auto
#   3. the written memory is `scope: global` AND not already `promoted_to:`
#   4. fire memory-globalize.sh --scope <dir> --apply with MEMORY_GLOBALIZE_AUTO=1
#
# This hook is USER-SCOPE ONLY and is deliberately NOT extended to the
# capability's `--target project` destination: choosing to bind a rule to one
# project (and to the `paths:` globs that activate it there) is a judgment call
# that belongs behind the confirm gate, never on an automatic write path.
#
# Re-entrancy: the capability's writes (the rules/ file + the `promoted_to:`
# stamp on the source memory) are subprocess filesystem writes, NOT Edit/Write
# tool calls — they do not re-trigger PostToolUse. The `promoted_to:` gate makes
# a re-fire a no-op regardless.
#
# NEVER fail-hard: set -uo pipefail (NO -e); mandatory exit 0 — a non-zero
# PostToolUse hook must never break the user's turn. Bash 3.2 + R-23 compatible.

set -uo pipefail  # NO -e — graceful-degrade on every failure

# Read the PostToolUse payload (the written file path).
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

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# 1. Project memory topic-file only; exclude the MEMORY.md index.
case "$FILE_PATH" in
  "$HOME"/.claude/projects/*/memory/*.md) ;;
  *) exit 0 ;;
esac
[ "${FILE_PATH##*/}" = "MEMORY.md" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

# 2. Toggle gate — env wins, settings.json jq fallback. Default => propose-only.
MODE="${MEMORY_GLOBALIZE_MODE:-}"
if [ -z "$MODE" ]; then
  SETTINGS="${CLAUDE_HOME:-$HOME/.claude}/settings.json"
  if [ -f "$SETTINGS" ]; then
    MODE=$(jq -r '.env.MEMORY_GLOBALIZE_MODE // empty' "$SETTINGS" 2>/dev/null || echo "")
  fi
fi
[ "$MODE" = "auto" ] || exit 0

# 3. scope:global + not-already-promoted pre-filter (mirrors the capability's
#    default predicate; keeps the heavier capability off the hot path).
command -v python3 >/dev/null 2>&1 || exit 0
# python exits 0 only for an unpromoted scope:global memory (the candidate);
# any other state (or any error) exits 1 -> hook no-ops. Heredoc attached to
# `if` (not $()) to dodge the bash 3.2 heredoc-in-command-substitution quirk.
if python3 - "$FILE_PATH" <<'PY' 2>/dev/null
import re, sys
try:
    c = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(1)
if not c.startswith("---\n"):
    sys.exit(1)
end = c.find("\n---\n", 4)
if end < 0:
    sys.exit(1)
scope, promoted = "", False
for line in c[4:end].split("\n"):
    m = re.match(r'^scope:\s*(.*)$', line)
    if m:
        scope = m.group(1).strip().strip('"').strip("'")
    if re.match(r'^promoted_to:\s*\S', line):
        promoted = True
sys.exit(0 if (scope == "global" and not promoted) else 1)
PY
then
  :  # candidate — fall through to promotion
else
  exit 0
fi

# 4. Promote — single dir, --apply, dedicated auto-bypass.
CAP="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/memory-globalize.sh"
[ -f "$CAP" ] || exit 0
MEM_DIR=$(dirname "$FILE_PATH")
MEMORY_GLOBALIZE_AUTO=1 bash "$CAP" --scope "$MEM_DIR" --apply >/dev/null 2>&1 || true

exit 0

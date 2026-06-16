#!/bin/bash
# Hook: PostToolUse (Edit|Write) — R-44 _index regen entry-point.
# C1-owned body (canonical/PostToolUse Edit|Write fire-order #2:
# track-vault-write -> post-write-verify -> memory-auto-stamp ->
# memory-globalize-auto;.4/.6 R-44 _index Tier-1 vehicle).
# DOUBLE load-bearing (gap-register):
#   1. body — the wired-but-unauthored PostToolUse Edit|Write body.
#   2. R-44 _index Tier-1 vehicle — the regen entry-point is invocable here; the
#      session-close CHAINING of it is/(out of scope).
# A normal PostToolUse fire (no --index-regen flag) is now a no-op: the prior
# vault Logs/ write-time auto-govern branch was retired when the vault stopped
# shipping a Logs/ folder (operational-exhaust relocation, G3).
# NEVER deny, NEVER fail-hard; exit 0 always.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR. paths.sh provides
# CLAUDE_HOME resolution for the index-maintain delegate below.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || exit 0

# --- R-44 Tier-1 _index regen entry-point (invocable; chaining =) ------
# The vault-health _index regen vehicle. The session-close chain (R-44 /)
# invokes this; here it is authored as an invocable entry-point only. Delegates
# to the librarian index-maintain capability when present (Tier-2), else no-op.
post_write_verify_index_regen() {
  local target="${1:-}"
  local cap="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/index-maintain.sh"
  if [ -x "$cap" ]; then
    "$cap" "$target" >/dev/null 2>&1 || true
  fi
  return 0
}

# Internal entry-point so the regen vehicle is directly invocable (wiring
# target): `post-write-verify.sh --index-regen [path]`.
if [ "${1:-}" = "--index-regen" ]; then
  post_write_verify_index_regen "${2:-}"
  exit 0
fi

# A normal PostToolUse fire is a no-op (graceful-degrade — see header).
exit 0

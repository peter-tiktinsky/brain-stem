#!/bin/bash
# Hook: post-work-map-refresh — PostToolUse Edit|Write — re-derive the affected work
# spoke's work-map directory-map block the instant a file under a work spoke is
# written, so the work CLAUDE.md's "what lives where" map stays fresh BETWEEN
# session-closes. This is the work-side counterpart to the binder-refresh hook
# (post-manifest-binder-refresh.sh): that hook keys on plan-tree manifest writes;
# THIS hook keys on a write anywhere under $WORK_HOME/<spoke>/ and re-maps that spoke.
# PostToolUse fires on EVERY Edit|Write — so this hook GATES HARD to writes under a
# work spoke ($WORK_HOME/) and is a fast no-op on everything else; an ungated work-map
# re-derive on every write would be prohibitively costly.
# On a gated work-spoke write it:
#   1. reads the PostToolUse payload .tool_input.file_path (the written file),
#   2. confirms the path is under $WORK_HOME/ (gate),
#   3. resolves the OWNING SPOKE = the first path component under $WORK_HOME,
#   4. re-derives THAT spoke's work-map (work-map-generate --spoke <spoke>), which
#      writes ONLY the marker block inside $WORK_HOME/<spoke>/CLAUDE.md.
# The generator writes via os.replace (NOT the Edit/Write tool), so its own write
# does NOT re-trigger this PostToolUse hook — no refresh loop. The leave-orphan
# defensive skip in the generator means a spoke whose CLAUDE.md lacks the markers
# (or is absent) is left untouched.
# ============================ OUTPUT CONTRACT =================================
# Files written (INDIRECTLY — this hook writes nothing itself; it delegates to the
#   librarian capability, which owns its own atomic block-write):
#   $WORK_HOME/<spoke>/CLAUDE.md  (work-map marker block ONLY — work-map-generate)
#   audit log  $HOOKS_STATE/post-work-map-refresh.log (append).
# Schema gate: none here — the delegated capability owns its own validation +
#   block-and-log; this hook only resolves the spoke + dispatches.
# Pre-write validation: the written path must be under $WORK_HOME/ AND resolve a
#   non-empty first path component (the spoke); else block-and-log, no dispatch.
# Failure mode: BLOCK-AND-LOG, never write-and-hope; EXIT 0 ALWAYS (PostToolUse must
#   never block a write or halt the session). Idempotent (re-derive without a disk
#   change == byte-identical, per the capability's own idempotency).
# Non-mutating signals: keys on the written path being under $WORK_HOME/; fast no-op
#   otherwise (no spoke to refresh).
# Bash 3.2 clean (R-23). Honors HOOKS_STATE_OVERRIDE + WORK_HOME/BRAIN_STEM_WORK_HOME
# for isolation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

# Audit log (test-isolatable). HOOKS_STATE_OVERRIDE wins so harnesses never touch
# the live runtime state dir.
STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
LOG="$STATE_DIR/post-work-map-refresh.log"

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# Fail-open prerequisites.
command -v python3 >/dev/null 2>&1 || exit 0

# Work home (the work spokes root). The scaffold.sh resolution order: WORK_HOME ->
# BRAIN_STEM_WORK_HOME -> $HOME/work. Honored for test isolation.
WORK_HOME="${WORK_HOME:-${BRAIN_STEM_WORK_HOME:-$HOME/work}}"
case "$WORK_HOME" in */) WORK_HOME="${WORK_HOME%/}" ;; esac

# --- read the PostToolUse payload (the written file path) ---------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

FILE_PATH=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
fi
# Direct-invocation path (harness / re-exec): first arg is the written file path.
[ -z "$FILE_PATH" ] && [ -n "${1:-}" ] && FILE_PATH="$1"
[ -z "$FILE_PATH" ] && exit 0

# --- GATE: fire ONLY on a write under $WORK_HOME/ (a fast no-op otherwise) ------
# PostToolUse fires on every Edit|Write — this gate keeps an ungated work-map
# re-derive from running on unrelated writes.
case "$FILE_PATH" in
  "$WORK_HOME"/*) ;;
  *) exit 0 ;;
esac

# --- resolve the OWNING SPOKE = the first path component under $WORK_HOME -------
REL="${FILE_PATH#"$WORK_HOME"/}"
# A bare file directly in $WORK_HOME (no spoke subdir) -> nothing to refresh.
case "$REL" in
  */*) ;;                # REL is <spoke>/<...> — has a spoke component, proceed
  *) log "block-and-log: write at work-home root ($FILE_PATH), no spoke to refresh"; exit 0 ;;
esac
SPOKE="${REL%%/*}"
if [ -z "$SPOKE" ]; then
  log "block-and-log: empty spoke component under work-home for $FILE_PATH"
  exit 0
fi

# --- re-derive THAT spoke's work-map (scoped via --spoke) ----------------------
# The capability is block-and-log + idempotent + writes ONLY the marker block in
# $WORK_HOME/<spoke>/CLAUDE.md (os.replace, not the Edit/Write tool — no re-trigger
# loop). Findings suppressed; rc ignored so a defensive skip never derails. WORK_HOME
# carries through for test isolation.
CAPS_DIR_REPO="$_REPO_ROOT/skills/librarian/capabilities"
CAPS_DIR_LIVE="$CLAUDE_HOME_RES/skills/librarian/capabilities"

CAP=""
for c in "$CAPS_DIR_REPO/work-map-generate.sh" "$CAPS_DIR_LIVE/work-map-generate.sh"; do
  if [ -f "$c" ]; then CAP="$c"; break; fi
done
if [ -z "$CAP" ]; then
  log "skip: capability work-map-generate not found (spoke=$SPOKE file=$FILE_PATH)"
  exit 0
fi

if WORK_HOME="$WORK_HOME" FINDINGS_OUTPUT="/dev/null" \
     bash "$CAP" --spoke "$SPOKE" >/dev/null 2>&1; then
  log "ok: work-map-generate --spoke $SPOKE (file=$FILE_PATH)"
else
  log "block-and-log: work-map-generate --spoke $SPOKE non-zero (file=$FILE_PATH)"
fi

exit 0

#!/bin/bash
# Hook: post-manifest-binder-refresh — PostToolUse Edit|Write — re-derive the
# affected spoke's binder surfaces the instant a plan manifest is written, so the
# binder stays fresh BETWEEN session-closes (T-10). This is the in-session
# counterpart to the SessionStart refresh-from-disk (T-11): the SessionStart hook
# catches out-of-band edits at the next session start; THIS hook catches in-session
# manifest writes immediately.
# PostToolUse fires on EVERY Edit|Write — so this hook GATES HARD to plan-manifest
# paths only (a plan-tree manifest.json) and is a fast no-op on everything else; an
# ungated binder re-derive on every write would be prohibitively costly.
# On a gated manifest write it:
#   1. reads the PostToolUse payload .tool_input.file_path (the written file),
#   2. confirms the path is a plan manifest.json under the plans tree (gate),
#   3. resolves the OWNING SPOKE from the manifest's `project:` key (the owning-
#      spoke machine identity — the same key the binder generators group on),
#   4. re-derives THAT spoke's binder, scoped via --spoke: the 3 binder generators
#      (plan-research-index / plan-decision-log / plan-handoff-index) + the situating
#      card (project-context-situating). All writes land ONLY under
#      {PLANS_ROOT}/_projects/<spoke>/ — NO work-root boundary conflict.
# ============================ OUTPUT CONTRACT =================================
# Files written (INDIRECTLY — this hook writes nothing itself; it delegates to the
#   librarian capabilities, which own their own atomic writes):
#   {PLANS_ROOT}/_projects/<spoke>/research-index.md     (plan-research-index)
#   {PLANS_ROOT}/_projects/<spoke>/decision-log.md       (plan-decision-log)
#   {PLANS_ROOT}/_projects/<spoke>/handoff-chronicle.md  (plan-handoff-index)
#   {PLANS_ROOT}/_projects/<spoke>/_situating.md         (project-context-situating)
#   {PLANS_ROOT}/_projects/<spoke>/research/ symlink farm (plan-research-index)
#   audit log  $HOOKS_STATE/post-manifest-binder-refresh.log (append).
# Schema gate: none here — the delegated capabilities own their own manifest read +
#   block-and-log; this hook only resolves the spoke + dispatches.
# Pre-write validation: the written path must be a plan-manifest.json under the
#   plans tree (gate); the manifest must carry a non-empty `project:` key (else
#   block-and-log, no dispatch). Each delegated capability is block-and-log internally.
# Failure mode: BLOCK-AND-LOG, never write-and-hope; EXIT 0 ALWAYS (PostToolUse must
#   never block a write or halt the session). Idempotent (re-derive without source
#   change == byte-identical, per the capabilities' own idempotency).
# Non-mutating signals: keys on the written path being a plan-tree manifest.json;
#   fast no-op otherwise.
# Bash 3.2 clean (R-23). Argv-based Python heredoc per R-24 (the spoke read passes
# data via argv). Honors HOOKS_STATE_OVERRIDE + PLANS_ROOT/PLANS_DIR for isolation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

# Audit log (test-isolatable). HOOKS_STATE_OVERRIDE wins so harnesses never touch
# the live runtime state dir.
STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
LOG="$STATE_DIR/post-manifest-binder-refresh.log"

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# Fail-open prerequisites.
command -v python3 >/dev/null 2>&1 || exit 0

# Plans home (the binder root). PLANS_ROOT/PLANS_DIR override, else default.
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

# --- read the PostToolUse payload (the written file path) ---------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

FILE_PATH=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
fi
# Direct-invocation path (harness / re-exec): first arg is the written manifest path.
[ -z "$FILE_PATH" ] && [ -n "${1:-}" ] && FILE_PATH="$1"
[ -z "$FILE_PATH" ] && exit 0

# --- GATE: fire ONLY on a plan-tree manifest.json (a fast no-op otherwise) -----
# The file must be named manifest.json AND sit under the plans tree (a plan dir or
# sub-plan dir under $PLANS_ROOT). PostToolUse fires on every Edit|Write — this gate
# keeps an ungated binder re-derive from running on unrelated writes.
case "$FILE_PATH" in
  */manifest.json) ;;
  *) exit 0 ;;
esac
case "$FILE_PATH" in
  "$PLANS_ROOT"/*|*/.claude-plans/*) ;;
  *) exit 0 ;;
esac
[ -f "$FILE_PATH" ] || exit 0

# --- resolve the owning spoke from the manifest `project:` key ----------------
# All inputs via argv (R-24). Prints the spoke key on stdout, or "" when the
# manifest cannot be parsed / carries no project: key (block-and-log, no dispatch).
SPOKE=$(python3 - "$FILE_PATH" <<'PY'
import json, sys
mp = sys.argv[1]
try:
    with open(mp, encoding="utf-8") as fh:
        man = json.load(fh)
except Exception:
    print("")
    sys.exit(0)
spoke = man.get("project")
print(str(spoke).strip() if isinstance(spoke, str) else "")
PY
)

if [ -z "$SPOKE" ]; then
  log "block-and-log: no project: key in $FILE_PATH (no spoke to refresh)"
  exit 0
fi

# --- re-derive THAT spoke's binder (scoped via --spoke) -----------------------
# The 3 binder generators FIRST (research/decision/handoff source), THEN the card
# (it reads their output — the card-after-generators ordering). Each is block-and-log + idempotent +
# writes ONLY under _projects/<spoke>/. Findings suppressed; rc ignored so one
# capability's defensive skip never derails the rest. PLANS_ROOT carries through.
CAPS_DIR_REPO="$_REPO_ROOT/skills/librarian/capabilities"
CAPS_DIR_LIVE="$CLAUDE_HOME_RES/skills/librarian/capabilities"

run_cap() {
  local name="$1" cap=""
  for c in "$CAPS_DIR_REPO/$name.sh" "$CAPS_DIR_LIVE/$name.sh"; do
    if [ -f "$c" ]; then cap="$c"; break; fi
  done
  if [ -z "$cap" ]; then
    log "skip: capability $name not found (plan=$FILE_PATH spoke=$SPOKE)"
    return 0
  fi
  if PLANS_ROOT="$PLANS_ROOT" FINDINGS_OUTPUT="/dev/null" \
       bash "$cap" --spoke "$SPOKE" >/dev/null 2>&1; then
    log "ok: $name --spoke $SPOKE (plan=$FILE_PATH)"
  else
    log "block-and-log: $name --spoke $SPOKE non-zero (plan=$FILE_PATH)"
  fi
}

run_cap plan-research-index
run_cap plan-decision-log
run_cap plan-handoff-index
run_cap project-context-situating

exit 0

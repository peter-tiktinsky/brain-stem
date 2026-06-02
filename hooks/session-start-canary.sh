#!/bin/bash
# SessionStart hook: legacy plans-dir tripwire + active-plans.txt writer.
#
# Two responsibilities composed in one hook (matches Claude Code SessionStart
# event-binding shape; one event → one hook):
#
#   (1) Plans-dir tripwire (the plans directory migration, 2026-04-13):
#       Detect resurrection of ~/.claude/plans/ stub with unexpected contents.
#       Plans dir migrated to ~/.claude-plans/ on 2026-04-13. Any non-README.md
#       content under the legacy path is a stale-reference bug; capture
#       forensics, log, preserve placeholder for manual investigation.
#
#   (2) Active-plans writer:
#       Walk plan manifests under $PLANS_ROOT (default $HOME/.claude-plans;
#       override via PLANS_ROOT_OVERRIDE). For each plan whose
#       top_level_status ∈ {aligned, in_progress} OR whose live_mutation_scope
#       is enabled-and-not-retired, emit one plan-slug line to
#       $HOOKS_STATE/<session-id>/active-plans.txt. Tier-2 deterministic
#       detection-signal source consumed by live-guard.sh; replaces
#       transcript-tail-grep as the primary content-aware detection mechanism
#       (closes the live-mutation-detection stochasticity at the source).
#
# Invocation contract (Claude Code SessionStart):
#   stdin: JSON {session_id, source, ...}
#   env:   HOOKS_STATE_OVERRIDE (test isolation), PLANS_ROOT_OVERRIDE,
#          CLAUDE_SESSION_ID (fallback if stdin empty)
#
# Failure mode: best-effort. Tripwire portion is read-only forensics; writer
# portion logs to gate-decisions audit and exits 0 even if jq/paths fail.
# Hook MUST NOT block SessionStart on internal errors.

set -uo pipefail

# === Path resolution (foundation-repo dev: self-contained; live deploy: paths.sh-equivalent) ===
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}}"
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-${PLANS_DIR:-$HOME/.claude-plans}}"
PLANS_DIR_DEAD="${PLANS_DIR_DEAD:-${CLAUDE_HOME:-$HOME/.claude}/plans}"

mkdir -p "$HOOKS_STATE" 2>/dev/null || true

# === Read stdin JSON (matches live hook pattern: session-register.sh INPUT=$(cat))
# Stdin gate: skip cat when invoked from a terminal (interactive ad-hoc) — cat
# would block on read. Hook-mediated invocation always pipes stdin.
SESSION_ID="${CLAUDE_SESSION_ID:-}"
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT=$(cat 2>/dev/null || true)
fi
if [[ -n "$INPUT" ]]; then
  PARSED_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  [[ -n "$PARSED_ID" ]] && SESSION_ID="$PARSED_ID"
fi
SESSION_ID="${SESSION_ID:-no-session}"

# ============================================================================
# Part (1): Plans-dir tripwire
# ============================================================================
LOG="$HOOKS_STATE/tripwire.log"

UNEXPECTED=""
if [[ -d "$PLANS_DIR_DEAD" ]]; then
  UNEXPECTED=$(/bin/ls -A "$PLANS_DIR_DEAD" 2>/dev/null | grep -v '^README\.md$' || true)
fi
if [[ -n "$UNEXPECTED" ]]; then
  TS="$(date -Iseconds)"
  FORENSICS="$HOOKS_STATE/tripwire-forensics.log"
  {
    echo "=========="
    echo "$TS REAPPEARANCE — capturing forensics (canary pid $$)"
    echo "-- ancestor chain (pid → ppid → ...):"
    pid=$$
    depth=0
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $depth -lt 12 ]]; do
      ps -o pid=,ppid=,etime=,command= -p "$pid" 2>/dev/null
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      depth=$((depth + 1))
    done
    echo "-- dir contents:"
    ls -la@ "$PLANS_DIR_DEAD" 2>&1
    echo "-- dir stat:"
    stat -f "birth=%SB ctime=%Sc mtime=%Sm uid=%Su" "$PLANS_DIR_DEAD" 2>&1
    echo "-- lsof on dir:"
    lsof +D "$PLANS_DIR_DEAD" 2>&1 | head -20
    echo "-- recent claude/node/bun/python/mcp processes:"
    ps -axo pid=,ppid=,etime=,command= 2>/dev/null | grep -E '(claude|node|bun|python|mcp)' | grep -v grep | head -30
    echo "-- launchd jobs (claude / cron / librarian / digest / meeting / plan-exec / backlog / architect):"
    launchctl list 2>&1 | grep -E 'claude|cron|librarian|digest|meeting|plan-exec|backlog|architect' | head -20
    echo ""
  } >> "$FORENSICS"
  echo "$TS TRIPWIRE: $PLANS_DIR_DEAD has unexpected contents — see tripwire-forensics.log" >> "$LOG"
  echo "$TS   unexpected files: $(echo "$UNEXPECTED" | tr '\n' ' ')" >> "$LOG"
  echo "$TS   action: NONE (manual investigation required — placeholder README preserved)" >> "$LOG"
fi

# ============================================================================
# Part (2): Active-plans writer
# ============================================================================
# Tier-2 deterministic detection signal: enumerate currently-active plans at
# SessionStart, persist to a single file under the session's state dir.
# live-guard.sh tier-2 reads this file (single deterministic read; no mtime
# races, no transcript-tail stochasticity).
#
# Active = top_level_status ∈ {aligned, in_progress} OR (live_mutation_scope
# present, enabled=true, sunset.phase != retired). Closed/superseded/complete
# plans are excluded — their gate (if any) is in retirement, not enforcement.
# Orchestrator manifests without top_level_status fall back to legacy `status`
# field (excluded if status ∈ {complete, closed, superseded, archived}).

ACTIVE_PLANS_DIR="$HOOKS_STATE/$SESSION_ID"
ACTIVE_PLANS_FILE="$ACTIVE_PLANS_DIR/active-plans.txt"
mkdir -p "$ACTIVE_PLANS_DIR" 2>/dev/null || true

# Write atomically via tmp-file + mv (one-shot per session; subsequent
# SessionStart fires in the same session-id are idempotent overwrites).
TMP_FILE="$ACTIVE_PLANS_FILE.tmp.$$"
: > "$TMP_FILE" 2>/dev/null || exit 0

if [[ -d "$PLANS_ROOT" ]]; then
  for manifest in "$PLANS_ROOT"/*/manifest.json; do
    [[ -e "$manifest" ]] || continue
    plan_dir=$(dirname "$manifest")
    plan_slug=$(basename "$plan_dir")

    # Read `.status` as the canonical PRIMARY field (one 8-state vocabulary).
    # `.top_level_status` is RETIRED and read only as an at-most legacy fallback
    # when `.status` is absent (NOT primary, NOT mislabeled as the canonical
    # field).
    status_data=$(jq -r '
      {
        status: (.status // null),
        legacy_top_level_status: (.top_level_status // null),
        lms_enabled: (.live_mutation_scope.enabled // false),
        sunset_phase: (.live_mutation_scope.sunset.phase // null)
      } | "\(.status)\t\(.legacy_top_level_status)\t\(.lms_enabled)\t\(.sunset_phase)"
    ' "$manifest" 2>/dev/null || echo "null\tnull\tfalse\tnull")

    IFS=$'\t' read -r status legacy_top_status lms_enabled sunset_phase <<< "$status_data"

    is_active=0
    # Canonical 8-state vocabulary: researching → planned → in-progress ⇄
    # paused → completed → verified → closed → archived (+ superseded terminal).
    case "$status" in
      researching|planned|in-progress|in_progress|paused|completed|verified)
        is_active=1
        ;;
      closed|archived|superseded)
        is_active=0
        ;;
      null|"")
        # `.status` absent → fall back to the RETIRED top_level_status alias only.
        case "$legacy_top_status" in
          aligned|in_progress|in-progress|active|on-hold|on_hold|null|"") is_active=1 ;;
          complete|closed|superseded|archived|done)                       is_active=0 ;;
          *)                                                                is_active=1 ;;
        esac
        ;;
      *)
        is_active=1  # unknown enum → fail-active (visible in active-plans.txt)
        ;;
    esac

    # Override: live_mutation_scope still enabled but sunset is in retire-helper
    # phase. A plan between gate-teardown phases hits this — the gate entry is
    # still active even though the plan is "closed". Include in active-plans.
    if [[ "$lms_enabled" == "true" ]] && [[ "$sunset_phase" != "retired" ]]; then
      is_active=1
    fi

    if [[ "$is_active" == "1" ]]; then
      printf '%s\n' "$plan_slug" >> "$TMP_FILE"
    fi
  done
fi

# Atomic publish
mv -f "$TMP_FILE" "$ACTIVE_PLANS_FILE" 2>/dev/null || rm -f "$TMP_FILE"

exit 0

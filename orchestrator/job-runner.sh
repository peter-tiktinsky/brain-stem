#!/bin/bash
# job-runner.sh — Freeform prompt executor for jobs without manifests.
# Same patterns as cron wrappers: PATH, portable timeout, log format, claude -p flags.
# Usage:
#   job-runner.sh --name "Job Name" --prompt-file ~/.claude/orchestrator/jobs/foo.md \
#     [--model sonnet] [--timeout 3600] [--budget 10] [--trigger-type on-demand] [--requested-by session_id]

set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/lockf.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/claude-p.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/verifier.sh"

# --- PATH (launchd provides minimal PATH) ---
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- Defaults (initialized empty; resolved after arg parsing via:
#     CLI override > orchestration.json job config > hardcoded fallback)
NAME=""
PROMPT_FILE=""
MODEL=""
TIMEOUT_SEC=""
BUDGET=""
TRIGGER_TYPE="on-demand"
REQUESTED_BY="manual"
CLAUDE="$HOME/.local/bin/claude"
VERIFY=1
NO_MUTATION_EXPECTED=0
WATCHED_REPOS_OVERRIDE=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --trigger-type) TRIGGER_TYPE="$2"; shift 2 ;;
    --requested-by) REQUESTED_BY="$2"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    --no-mutation-expected) NO_MUTATION_EXPECTED=1; shift ;;
    --watched-repos) WATCHED_REPOS_OVERRIDE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]] || [[ -z "$PROMPT_FILE" ]]; then
  echo "Usage: job-runner.sh --name 'Name' --prompt-file path.md [--model sonnet] [--timeout 3600] [--budget N]" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# --- Derive slug for log naming + orchestration.json lookup key ---
SLUG=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

# --- Single-instance lock (per slug) via lib/lockf.sh ---
# Outer call re-execs under /usr/bin/lockf and exits; inner call returns
# immediately. Caller-set $LOG_DIR drives skip-log path; we set it from
# CLAUDE_LOG_DIR so contention messages land alongside other logs.
LOG_DIR="$CLAUDE_LOG_DIR"
mkdir -p "$HOOKS_STATE" 2>/dev/null || true
claude_lockf_reexec "$HOOKS_STATE/job-runner-${SLUG}.lock" "$@"

# --- Resolve job-runtime defaults from orchestration.json ---
# CLI args win; orchestration.json fills missing slots; hardcoded fallback
# is last-resort. Schema gap:-shipped orchestration-schema.json
# (commit b64e425) does not yet declare timeout_seconds / model / budget_usd
# at the per-job level. T-9 amendment will add them. Until then, jq lookup
# returns empty and hardcoded fallback applies — forward-compatible.
_orch_get() {
  if [ -r "$ORCHESTRATION_JSON" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg id "$SLUG" --arg field "$1" \
      '.jobs[]? | select(.id == $id) | .[$field] // empty' \
      "$ORCHESTRATION_JSON" 2>/dev/null
  fi
}

if [ -z "$TIMEOUT_SEC" ]; then TIMEOUT_SEC="$(_orch_get timeout_seconds)"; fi
if [ -z "$TIMEOUT_SEC" ]; then TIMEOUT_SEC="3600"; fi

if [ -z "$MODEL" ]; then MODEL="$(_orch_get model)"; fi
if [ -z "$MODEL" ]; then MODEL="sonnet"; fi

if [ -z "$BUDGET" ]; then BUDGET="$(_orch_get budget_usd)"; fi
# BUDGET stays empty if not in manifest — passed conditionally below.

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/job-${SLUG}-$(date +%Y%m%d-%H%M%S).log"

# --- Portable timeout (macOS has no coreutils timeout) ---
run_with_timeout() {
  local timeout=$1; shift
  "$@" &
  local pid=$!
  ( sleep "$timeout" && kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  if wait "$pid" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    return 0
  else
    local rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    if [ "$rc" -eq 143 ] || ! kill -0 "$pid" 2>/dev/null; then
      return 124
    fi
    return "$rc"
  fi
}

# --- Read prompt ---
PROMPT=$(cat "$PROMPT_FILE")

# --- Log header with trigger metadata ---
{
  echo "=== job-runner start: $(date -Iseconds) ==="
  echo "trigger_type: $TRIGGER_TYPE"
  echo "requested_by: $REQUESTED_BY"
  echo "job_name: $NAME"
  echo "prompt_file: $PROMPT_FILE"
  echo "model: $MODEL"
  echo "timeout: ${TIMEOUT_SEC}s"
  [[ -n "$BUDGET" ]] && echo "budget: \$$BUDGET"
  echo "---"
} >> "$LOG_FILE"

# --- Prepend trigger context to prompt so the session knows how it was invoked ---
PROMPT="## Execution Context
- **Trigger:** ${TRIGGER_TYPE} (not overnight cron)
- **Requested by:** session ${REQUESTED_BY}
- **Timestamp:** $(date -Iseconds)
- **Budget:** \$${BUDGET:-unlimited}

When writing logs, notes, or backlog updates, describe this as an \"on-demand execution\" if trigger is on-demand, or \"scheduled overnight execution\" if trigger is scheduled. Use the actual timestamp above, not generic phrasing.

---

${PROMPT}"

# --- Build claude command ---
CLAUDE_ARGS=(
  -p "$PROMPT"
  --add-dir "$HOME"
  --add-dir "$VAULT_ROOT"
  --permission-mode bypassPermissions
  --model "$MODEL"
  --output-format json
)
[[ -n "$BUDGET" ]] && CLAUDE_ARGS+=(--max-budget-usd "$BUDGET")

# --- Pre-dispatch HEAD snapshot (Tier 1 verifier) ---
# Captured BEFORE claude -p runs so post-dispatch comparison can detect
# whether any actual work landed. Even when --no-verify is set, the snapshot
# is still captured so the log carries diagnostic context.
PRE_SNAPSHOT_FILE=""
POST_SNAPSHOT_FILE=""
RESULT_TEXT_FILE=""
VERIFICATION_JSON='null'
VERIFICATION_VERDICT="not-run"
if [[ -n "$WATCHED_REPOS_OVERRIDE" ]]; then
  WATCHED_REPOS=$(echo "$WATCHED_REPOS_OVERRIDE" | tr ',' '\n')
else
  WATCHED_REPOS=$(verifier_default_repos)
fi
PRE_SNAPSHOT_FILE=$(mktemp "${TMPDIR:-/tmp}/job-pre-snap.XXXXXX.json")
echo "$WATCHED_REPOS" | verifier_snapshot_heads > "$PRE_SNAPSHOT_FILE"

# --- Execute ---
EXEC_STATUS="success"
OUTPUT_FILE=$(mktemp)

if run_with_timeout "$TIMEOUT_SEC" "$CLAUDE" "${CLAUDE_ARGS[@]}" > "$OUTPUT_FILE" 2>&1; then
  EXEC_STATUS="success"
else
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 124 ]; then
    EXEC_STATUS="timeout"
  else
    EXEC_STATUS="error"
  fi
fi

# --- Post-run claude -p classification (timeout/error path only) ---
# classify_claude_p_exit fingerprints cold-start-hang vs stalled-mid-run
# from $OUTPUT_FILE size + SessionEnd-hook signature. Diagnostic only —
# does not change EXEC_STATUS. Skipped on success because the classifier's
# output ("claude-p-stalled-mid-run") is misleading for normal completions.
CLAUDE_P_CLASSIFICATION=""
if [ "$EXEC_STATUS" != "success" ] && [ -f "$OUTPUT_FILE" ]; then
  CLAUDE_P_CLASSIFICATION=$(classify_claude_p_exit "$OUTPUT_FILE" 2>/dev/null || echo "classifier-error")
fi

# --- Parse JSON output for cost/turns/session ---
COST="0"
NUM_TURNS="0"
SESSION_ID=""

JSON_LINE=""
if [[ -f "$OUTPUT_FILE" ]]; then
  # SessionEnd hooks emit non-JSON text AFTER the claude -p result line, so the
  # whole file often doesn't parse as JSON. Extract the result line specifically.
  JSON_LINE=$(grep -m1 '^{"type":"result"' "$OUTPUT_FILE" 2>/dev/null)
  # Fallback: if claude -p shape shifts, try first line that parses as JSON.
  if [[ -z "$JSON_LINE" ]] && head -1 "$OUTPUT_FILE" | jq empty 2>/dev/null; then
    JSON_LINE=$(head -1 "$OUTPUT_FILE")
  fi
fi

RESULT_TEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/job-result-text.XXXXXX")
if [[ -n "$JSON_LINE" ]] && echo "$JSON_LINE" | jq empty 2>/dev/null; then
  COST=$(echo "$JSON_LINE" | jq -r '(.total_cost_usd // .cost_usd // 0)' 2>/dev/null || echo "0")
  NUM_TURNS=$(echo "$JSON_LINE" | jq -r '.num_turns // 0' 2>/dev/null || echo "0")
  SESSION_ID=$(echo "$JSON_LINE" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  # Capture result text for both verifier scan and log append
  echo "$JSON_LINE" | jq -r '.result // ""' > "$RESULT_TEXT_FILE" 2>/dev/null || cp "$OUTPUT_FILE" "$RESULT_TEXT_FILE"
  cat "$RESULT_TEXT_FILE" >> "$LOG_FILE"
else
  cat "$OUTPUT_FILE" > "$RESULT_TEXT_FILE" 2>/dev/null || true
  cat "$OUTPUT_FILE" >> "$LOG_FILE" 2>/dev/null
fi

rm -f "$OUTPUT_FILE"

# --- Post-dispatch verifier (Tier 1 + Tier 2) ---
# Runs unconditionally (snapshot is cheap) so the log carries diagnostic
# context even on timeout/error. Verdict only re-classifies EXEC_STATUS
# when:
#   1. Original exit was clean (success), AND
#   2. --no-verify was NOT set, AND
#   3. --no-mutation-expected was NOT set, AND
#   4. Verdict is FALSE-SUCCESS-NO-MUTATIONS.
# For other cases (timeout, error, --no-verify, --no-mutation-expected,
# PASS-WITH-WARNINGS), verifier output is captured but EXEC_STATUS is
# preserved.
POST_SNAPSHOT_FILE=$(mktemp "${TMPDIR:-/tmp}/job-post-snap.XXXXXX.json")
echo "$WATCHED_REPOS" | verifier_snapshot_heads > "$POST_SNAPSHOT_FILE"

if VERIFICATION_JSON=$(verifier_check "$PRE_SNAPSHOT_FILE" "$POST_SNAPSHOT_FILE" "$RESULT_TEXT_FILE" 2>&1); then
  VERIFIER_RC=0
else
  VERIFIER_RC=$?
fi
VERIFICATION_VERDICT=$(echo "$VERIFICATION_JSON" | jq -r '.verdict // "VERIFIER-ERROR"' 2>/dev/null || echo "VERIFIER-ERROR")

# Re-classify status on verdict failure (gated by exit + flags)
if [ "$EXEC_STATUS" = "success" ] && [ "$VERIFY" = "1" ] && [ "$NO_MUTATION_EXPECTED" = "0" ] && [ "$VERIFICATION_VERDICT" = "FALSE-SUCCESS-NO-MUTATIONS" ]; then
  EXEC_STATUS="false-success-no-mutations"
fi

# --- Log footer ---
{
  echo "---"
  echo "cost_usd: $COST"
  echo "num_turns: $NUM_TURNS"
  echo "session_id: $SESSION_ID"
  echo "verification_verdict: $VERIFICATION_VERDICT"
  echo "verification_json:"
  echo "$VERIFICATION_JSON" | jq .
  if [ -n "$CLAUDE_P_CLASSIFICATION" ]; then
    echo "claude_p_classification: $CLAUDE_P_CLASSIFICATION"
  fi
  echo "=== job-runner end: $(date -Iseconds) status=$EXEC_STATUS ==="
} >> "$LOG_FILE"

# --- Cleanup snapshot/result temps ---
rm -f "$PRE_SNAPSHOT_FILE" "$POST_SNAPSHOT_FILE" "$RESULT_TEXT_FILE"

# --- F0: Circuit-breaker (T-0 — INLINE; natural-streak core) ---
# Persist verdict to recent-verdicts.jsonl (rolling last 50). On N=2
# consecutive silent-failure verdicts, write dispatch-halted.sentinel.
# dispatch.sh checks for the sentinel pre-flight and refuses new dispatches
# when present. Reads the BASE verifier's EXEC_STATUS (false-success-no-mutations
# at :255-256, set from orchestrator/lib/verifier.sh verifier_check, T-12)
# — NOT any DEFER enhancement verdict (fork-1).
# OMITTED (DEFER, fork-1): the T-4 STREAK_BREACH
# single-occurrence retry-escalation branch (it fires only from the deferred
# retry-dispatch.sh mechanical-only-retry path) and the DEFER enhancement
# verdict maps (false-success-missing-artifacts / -missing-session-close /
# acceptance-fail / brief-version-drift) — the BASE verifier emits none of
# them, so they are absent here. The natural-streak core ships WITHOUT the
# retry escalation. No retry-dispatch.sh linkage.
F0_STATE_DIR="${ORCHESTRATOR_STATE_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/runtime}"
F0_VERDICTS_LOG="$F0_STATE_DIR/recent-verdicts.jsonl"
F0_SENTINEL="$F0_STATE_DIR/dispatch-halted.sentinel"
F0_MAX_RECORDS=50
F0_STREAK_THRESHOLD=2

mkdir -p "$F0_STATE_DIR" 2>/dev/null || true

# Map EXEC_STATUS to F0 verdict class. The BASE verifier emits
# FALSE-SUCCESS-NO-MUTATIONS (job-runner.sh:255-256); PASS / TIMEOUT / ERROR
# reset the streak (timeouts/errors are loud failures already visible to
case "$EXEC_STATUS" in
  false-success-no-mutations) F0_VERDICT="FALSE-SUCCESS-NO-MUTATIONS" ;;
  success)                    F0_VERDICT="PASS" ;;
  timeout)                    F0_VERDICT="TIMEOUT" ;;
  *)                          F0_VERDICT="ERROR" ;;
esac

# Append verdict record (atomic via temp + mv); cap at last F0_MAX_RECORDS.
F0_RECORD=$(jq -nc \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg slug "$SLUG" \
  --arg verdict "$F0_VERDICT" \
  --arg verifier_verdict "$VERIFICATION_VERDICT" \
  --arg log "$LOG_FILE" \
  '{ts:$ts, slug:$slug, verdict:$verdict, verifier_verdict:$verifier_verdict, log:$log}')

F0_TMP="${F0_VERDICTS_LOG}.tmp.$$"
{
  if [[ -f "$F0_VERDICTS_LOG" ]]; then
    tail -n $((F0_MAX_RECORDS - 1)) "$F0_VERDICTS_LOG" 2>/dev/null
  fi
  printf '%s\n' "$F0_RECORD"
} > "$F0_TMP" 2>/dev/null

if mv -f "$F0_TMP" "$F0_VERDICTS_LOG" 2>/dev/null; then
  : # appended cleanly
else
  echo "F0 WARNING: verdict-log write failed at $F0_VERDICTS_LOG — circuit-breaker may not detect streak" >&2
  rm -f "$F0_TMP" 2>/dev/null
fi

# Natural-streak check: last F0_STREAK_THRESHOLD records all silent-failure
# verdicts (FALSE-SUCCESS-* family OR ACCEPTANCE-FAIL — the BASE verifier
# emits FALSE-SUCCESS-NO-MUTATIONS) → write dispatch-halted.sentinel.
# Skip when sentinel already present (no double-fire).
if [[ -f "$F0_VERDICTS_LOG" ]] && [[ ! -f "$F0_SENTINEL" ]]; then
  F0_STREAK=$(tail -n $F0_STREAK_THRESHOLD "$F0_VERDICTS_LOG" 2>/dev/null \
    | jq -s --argjson n $F0_STREAK_THRESHOLD \
        'map(.verdict) | if length >= $n and all(test("^FALSE-SUCCESS|^ACCEPTANCE-FAIL")) then "halt" else "ok" end' 2>/dev/null \
    | tr -d '"')
  if [[ "$F0_STREAK" == "halt" ]]; then
    F0_LAST_RECORDS=$(tail -n $F0_STREAK_THRESHOLD "$F0_VERDICTS_LOG")
    F0_SENT_TMP="${F0_SENTINEL}.tmp.$$"
    F0_REASON="$F0_STREAK_THRESHOLD consecutive silent-failure verdicts (FALSE-SUCCESS-*)"
    {
      echo "F0 — Queue circuit-breaker triggered"
      echo "Reason: $F0_REASON"
      echo "Triggered at: $(date -Iseconds)"
      echo ""
      echo "Last $F0_STREAK_THRESHOLD records:"
      echo "$F0_LAST_RECORDS"
      echo ""
      echo "Dispatcher will refuse new --plan/--job/--cron/--batch invocations until cleared."
      echo ""
      echo "To investigate, read each dispatch's log_file. Then clear via:"
      echo "  dispatch.sh --clear-circuit-breaker"
      echo "or:"
      echo "  rm '$F0_SENTINEL'"
    } > "$F0_SENT_TMP" 2>/dev/null

    if mv -f "$F0_SENT_TMP" "$F0_SENTINEL" 2>/dev/null; then
      echo "F0: circuit-breaker engaged — sentinel written: $F0_SENTINEL" >&2
    else
      echo "F0 CRITICAL: sentinel-write failed — dispatcher will NOT halt on next call. Investigate $F0_STATE_DIR" >&2
      rm -f "$F0_SENT_TMP" 2>/dev/null
    fi
  fi
fi
# --- end F0 ---

# --- Output structured result to stdout (for dispatch.sh to capture) ---
# verification block is purely additive — existing parsers continue to work.
jq -n \
  --arg name "$NAME" \
  --arg status "$EXEC_STATUS" \
  --arg trigger "$TRIGGER_TYPE" \
  --arg requested_by "$REQUESTED_BY" \
  --arg cost "$COST" \
  --arg turns "$NUM_TURNS" \
  --arg session "$SESSION_ID" \
  --arg log "$LOG_FILE" \
  --arg classification "$CLAUDE_P_CLASSIFICATION" \
  --argjson verification "$VERIFICATION_JSON" \
  --argjson verify_enabled "$VERIFY" \
  --argjson no_mutation_expected "$NO_MUTATION_EXPECTED" \
  '{name: $name, status: $status, trigger_type: $trigger, requested_by: $requested_by, cost_usd: $cost, num_turns: $turns, session_id: $session, log_file: $log, claude_p_classification: $classification, verification: $verification, verify_enabled: ($verify_enabled == 1), no_mutation_expected: ($no_mutation_expected == 1)}'

# --- Exit code ---
case "$EXEC_STATUS" in
  success) exit 0 ;;
  timeout) exit 124 ;;
  *) exit 1 ;;
esac

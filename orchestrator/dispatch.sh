#!/bin/bash
# dispatch.sh — Unified entry point for on-demand and scheduled execution.
# Routes to plan-runner.sh or job-runner.sh based on job type.
# Adds trigger metadata to all logs.
#
# Usage:
#   dispatch.sh --plan <slug> [--immediate|--overnight|--delay <spec>]
#   dispatch.sh --job <name> [--immediate|--overnight|--delay <spec>]
#   dispatch.sh --cron <cron-name> [--immediate]
#   dispatch.sh --batch <file.json> [--immediate]
#   dispatch.sh --list-pending
#   dispatch.sh --cancel <name>
#   dispatch.sh --hold <name>
#   dispatch.sh --unhold <name>
#   dispatch.sh --queue-status
#   dispatch.sh --circuit-breaker-status         (F0)
#   dispatch.sh --clear-circuit-breaker          (F0)
#
# Options:
#   --model <model>      Override model (default: sonnet)
#   --timeout <seconds>  Override timeout
#   --budget <dollars>   Override budget cap
#   --trigger-type <t>   Override trigger type (default: on-demand)

set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

# --- PATH ---
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- Locations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$SCRIPT_DIR/jobs"
CRON_DIR="$CRON_WRAPPERS"
QUEUE_LIB="$HOOKS_DIR/lib/execution-queue.sh"
PENDING_FILE="$HOOKS_STATE/pending-dispatch.json"
PLAN_RUNNER="$SCRIPT_DIR/plan-runner.sh"
JOB_RUNNER="$SCRIPT_DIR/job-runner.sh"
BACKLOG="$VAULT_ROOT/System Backlog.md"

# --- Source queue library ---
source "$QUEUE_LIB"

# --- Parse args ---
MODE=""        # plan | job | cron | batch | list-pending | cancel | hold | unhold | queue-status
TARGET=""
TIMING="immediate"  # immediate | overnight | delay
DELAY_SPEC=""
MODEL="sonnet"
TIMEOUT=""
BUDGET=""
TRIGGER_TYPE="on-demand"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)     MODE="plan"; TARGET="$2"; shift 2 ;;
    --job)      MODE="job"; TARGET="$2"; shift 2 ;;
    --cron)     MODE="cron"; TARGET="$2"; shift 2 ;;
    --batch)    MODE="batch"; TARGET="$2"; shift 2 ;;
    --list-pending) MODE="list-pending"; shift ;;
    --cancel)   MODE="cancel"; TARGET="$2"; shift 2 ;;
    --hold)     MODE="hold"; TARGET="$2"; shift 2 ;;
    --unhold)   MODE="unhold"; TARGET="$2"; shift 2 ;;
    --queue-status) MODE="queue-status"; shift ;;
    --circuit-breaker-status) MODE="circuit-breaker-status"; shift ;;  # F0
    --clear-circuit-breaker) MODE="clear-circuit-breaker"; shift ;;    # F0
    --immediate)   TIMING="immediate"; shift ;;
    --overnight)   TIMING="overnight"; shift ;;
    --delay)       TIMING="delay"; DELAY_SPEC="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --budget)      BUDGET="$2"; shift 2 ;;
    --trigger-type) TRIGGER_TYPE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: dispatch.sh --plan|--job|--cron|--batch <target> [--immediate|--overnight|--delay <spec>]" >&2
  echo "       dispatch.sh --list-pending | --cancel <name> | --hold <name> | --unhold <name> | --queue-status" >&2
  exit 1
fi

# --- Utility: derive slug from name ---
to_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# --- Utility: parse delay spec into seconds from now ---
delay_to_seconds() {
  local spec="$1"
  case "$spec" in
    *m) echo $(( ${spec%m} * 60 )) ;;
    *h) echo $(( ${spec%h} * 3600 )) ;;
    *s) echo "${spec%s}" ;;
    *)
      # Try parsing as a time (e.g., "10pm", "tomorrow 1am")
      local target_epoch
      target_epoch=$(date -j -f "%Y-%m-%d %I:%M %p" "$(date +%Y-%m-%d) $(echo "$spec" | sed 's/am/ AM/;s/pm/ PM/')" +%s 2>/dev/null || echo "")
      if [[ -z "$target_epoch" ]]; then
        # Try "tomorrow" prefix
        if [[ "$spec" == tomorrow* ]]; then
          local time_part="${spec#tomorrow }"
          local tomorrow
          tomorrow=$(date -v+1d +%Y-%m-%d)
          target_epoch=$(date -j -f "%Y-%m-%d %I:%M %p" "$tomorrow $(echo "$time_part" | sed 's/am/ AM/;s/pm/ PM/')" +%s 2>/dev/null || echo "")
        fi
      fi
      if [[ -n "$target_epoch" ]]; then
        local now_epoch
        now_epoch=$(date +%s)
        local diff=$(( target_epoch - now_epoch ))
        if (( diff < 0 )); then
          # Time already passed today — assume tomorrow
          diff=$(( diff + 86400 ))
        fi
        echo "$diff"
      else
        echo "ERROR: Cannot parse delay spec: $spec" >&2
        return 1
      fi
      ;;
  esac
}

# --- Utility: add to pending-dispatch.json ---
add_pending() {
  local name="$1" type="$2" ref="$3" fire_at="$4" pid="${5:-}"
  local pending now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ ! -f "$PENDING_FILE" ]] || [[ ! -s "$PENDING_FILE" ]]; then
    printf '{"pending":[]}\n' > "$PENDING_FILE"
  fi

  pending=$(cat "$PENDING_FILE")
  pending=$(echo "$pending" | jq \
    --arg n "$name" --arg t "$type" --arg r "$ref" --arg fa "$fire_at" --arg p "$pid" --arg ts "$now" \
    '.pending += [{"name": $n, "type": $t, "ref": $r, "fire_at": $fa, "pid": (if $p == "" then null else ($p | tonumber) end), "queued_at": $ts}]')

  local tmp="${PENDING_FILE}.tmp.$$"
  printf '%s\n' "$pending" > "$tmp"
  mv "$tmp" "$PENDING_FILE"
}

# --- Utility: remove from pending-dispatch.json ---
remove_pending() {
  local name="$1"
  if [[ ! -f "$PENDING_FILE" ]]; then return; fi
  local pending
  pending=$(cat "$PENDING_FILE")
  pending=$(echo "$pending" | jq --arg n "$name" '.pending |= [.[] | select(.name != $n)]')
  local tmp="${PENDING_FILE}.tmp.$$"
  printf '%s\n' "$pending" > "$tmp"
  mv "$tmp" "$PENDING_FILE"
}

# --- Resolve plan target → manifest path ---
resolve_plan() {
  local slug="$1"
  local manifest="$PLANS_DIR/$slug/manifest.json"
  if [[ -f "$manifest" ]]; then
    echo "$manifest"
    return 0
  fi
  # Try flat file
  manifest="$PLANS_DIR/${slug}-manifest.json"
  if [[ -f "$manifest" ]]; then
    echo "$manifest"
    return 0
  fi
  echo "ERROR: No manifest found for plan '$slug'" >&2
  return 1
}

# --- Resolve job target → prompt file path ---
resolve_job() {
  local name="$1"
  local slug
  slug=$(to_slug "$name")

  # Check jobs directory
  local prompt_file="$JOBS_DIR/${slug}.md"
  if [[ -f "$prompt_file" ]]; then
    echo "$prompt_file"
    return 0
  fi

  # Try exact name
  prompt_file="$JOBS_DIR/${name}.md"
  if [[ -f "$prompt_file" ]]; then
    echo "$prompt_file"
    return 0
  fi

  echo "ERROR: No job file found for '$name' (tried: $JOBS_DIR/${slug}.md)" >&2
  return 1
}

# --- Execute immediately ---
run_immediate() {
  local type="$1" target="$2"

  case "$type" in
    plan)
      local manifest
      manifest=$(resolve_plan "$target") || exit 1
      echo "Executing plan: $target (manifest: $manifest)"
      exec bash "$PLAN_RUNNER" "$manifest"
      ;;
    job)
      local prompt_file
      prompt_file=$(resolve_job "$target") || exit 1
      local timeout_arg="${TIMEOUT:-3600}"
      local args=(--name "$target" --prompt-file "$prompt_file" --model "$MODEL" --timeout "$timeout_arg" --trigger-type "$TRIGGER_TYPE" --requested-by "$$")
      [[ -n "$BUDGET" ]] && args+=(--budget "$BUDGET")
      echo "Executing job: $target (prompt: $prompt_file)"
      exec bash "$JOB_RUNNER" "${args[@]}"
      ;;
  esac
}

# --- Queue for overnight ---
run_overnight() {
  local type="$1" target="$2"
  local ref=""

  case "$type" in
    plan)
      ref=$(resolve_plan "$target") || exit 1
      ;;
    job)
      ref=$(resolve_job "$target") || exit 1
      ;;
  esac

  local timeout_val="${TIMEOUT:-3600}"
  if exec_queue_add "$target" "$type" "$ref" "$MODEL" "$timeout_val" "$BUDGET" "normal" "manual"; then
    echo "Queued '$target' ($type) for overnight execution."
  else
    echo "WARNING: '$target' already in queue or queue full." >&2
    exit 1
  fi
}

# --- Schedule with delay ---
run_delayed() {
  local type="$1" target="$2" delay_spec="$3"
  local ref=""

  case "$type" in
    plan)
      ref=$(resolve_plan "$target") || exit 1
      ;;
    job)
      ref=$(resolve_job "$target") || exit 1
      ;;
  esac

  local delay_seconds
  delay_seconds=$(delay_to_seconds "$delay_spec") || exit 1

  local fire_at
  fire_at=$(date -v+"${delay_seconds}S" -Iseconds 2>/dev/null || date -d "+${delay_seconds} seconds" -Iseconds 2>/dev/null)

  if (( delay_seconds < 14400 )); then
    # Short delay (< 4 hours): sleep + dispatch
    (
      sleep "$delay_seconds"
      bash "$0" "--$type" "$target" --immediate --model "$MODEL" ${TIMEOUT:+--timeout "$TIMEOUT"} ${BUDGET:+--budget "$BUDGET"} --trigger-type "$TRIGGER_TYPE"
      remove_pending "$target"
    ) &
    disown
    local bg_pid=$!
    add_pending "$target" "$type" "$ref" "$fire_at" "$bg_pid"
    echo "Scheduled '$target' to run at $fire_at (pid: $bg_pid, delay: ${delay_seconds}s)"
  else
    # Long delay: one-shot launchd plist
    local slug
    slug=$(to_slug "$target")
    local plist_name="com.claude.dispatch-onetime-${slug}"
    local plist_path="$HOME/Library/LaunchAgents/${plist_name}.plist"

    # Parse target time components
    local fire_hour fire_min fire_day fire_month
    fire_hour=$(date -v+"${delay_seconds}S" +%H 2>/dev/null)
    fire_min=$(date -v+"${delay_seconds}S" +%M 2>/dev/null)
    fire_day=$(date -v+"${delay_seconds}S" +%d 2>/dev/null)
    fire_month=$(date -v+"${delay_seconds}S" +%m 2>/dev/null)

    cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${plist_name}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BASH_SOURCE[0]}</string>
    <string>--${type}</string>
    <string>${target}</string>
    <string>--immediate</string>
    <string>--model</string>
    <string>${MODEL}</string>
    <string>--trigger-type</string>
    <string>${TRIGGER_TYPE}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Month</key>
    <integer>${fire_month#0}</integer>
    <key>Day</key>
    <integer>${fire_day#0}</integer>
    <key>Hour</key>
    <integer>${fire_hour#0}</integer>
    <key>Minute</key>
    <integer>${fire_min#0}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${CLAUDE_LOG_DIR}/dispatch-${slug}-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${CLAUDE_LOG_DIR}/dispatch-${slug}-stderr.log</string>
</dict>
</plist>
PLIST

    launchctl load "$plist_path" 2>/dev/null || true
    add_pending "$target" "$type" "$ref" "$fire_at" ""
    echo "Scheduled '$target' via launchd at $fire_at (plist: $plist_path)"
  fi
}

# ============================================================
# F0 Circuit-breaker pre-flight (INLINE)
# Refuse new dispatches when sentinel is present. job-runner.sh writes
# the sentinel after N=2 consecutive FALSE-SUCCESS-NO-MUTATIONS (the BASE
# verifier's silent-failure verdict). Skipped for non-dispatch
# modes (status / list / hold / unhold / cancel / clear-circuit-breaker —
# they don't initiate new work). Reads ONLY the sentinel file. The F0
# pre-flight gates plan|job|cron|batch INCLUDING --plan, so the
# plan-runner dispatch path is governed end-to-end.
# ============================================================
F0_STATE_DIR="${ORCHESTRATOR_STATE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/orchestrator/state}"
F0_SENTINEL="$F0_STATE_DIR/dispatch-halted.sentinel"
F0_VERDICTS_LOG="$F0_STATE_DIR/recent-verdicts.jsonl"
case "$MODE" in
  plan|job|cron|batch)
    if [[ -f "$F0_SENTINEL" ]]; then
      {
        echo "================================================================"
        echo "DISPATCH HALTED — F0 circuit-breaker engaged"
        echo "================================================================"
        cat "$F0_SENTINEL"
        echo "================================================================"
      } >&2
      exit 1
    fi
    ;;
esac

# ============================================================
# Pre-dispatch scoping wire-in (extracted module)
# Invokes the standalone orchestrator/lib/pre-dispatch-scoping.sh at the
# --job boundary. Advisory by default; blocks (exit 12) only when
# ORCHESTRATOR_SP04_T2_BLOCKING=1. Scoped to --job mode only (--plan uses
# manifests, --cron uses wrappers, --batch recurses through dispatch.sh —
# per-job enforcement happens at recursion). Legacy briefs (no scoping
# fields) skip entirely inside the module (backwards-compatible). The 6-filter
# scoping SHAPE lives in lib/brief-meta.py.
# ============================================================
SCOPING="$SCRIPT_DIR/lib/pre-dispatch-scoping.sh"
case "$MODE" in
  job)
    if [[ -f "$SCOPING" ]]; then
      _SCOPE_BRIEF=$(resolve_job "$TARGET") || exit 1
      bash "$SCOPING" "$_SCOPE_BRIEF" "$TARGET"
      _SCOPE_RC=$?
      # exit 12 = BLOCKING-mode filter-fail refusal;
      # any other rc is advisory/legacy-skip — proceed.
      if (( _SCOPE_RC == 12 )); then
        exit 12
      fi
    fi
    ;;
esac

# ============================================================
# Brief-quality lint wire-in (advisory)
# Pre-dispatch Haiku call scores brief quality across 5 failure modes.
# Advisory ONLY — never blocks dispatch. Gated by
# ORCHESTRATOR_BRIEF_LINT=1 env (default OFF). Cost log
# at $ORCHESTRATOR_STATE_DIR/governance/brief-lint-cost.jsonl. Scoped to
# --job mode (plan/cron/batch don't read a single brief file). brief-lint.sh
# exits 0 on all paths including API failure (graceful degradation).
# ============================================================
BRIEF_LINT="$SCRIPT_DIR/lib/brief-lint.sh"
case "$MODE" in
  job)
    if [[ -x "$BRIEF_LINT" ]] && [[ "${ORCHESTRATOR_BRIEF_LINT:-}" == "1" ]]; then
      _BL_BRIEF=$(resolve_job "$TARGET") || exit 1
      bash "$BRIEF_LINT" "$_BL_BRIEF" || true
    fi
    ;;
esac

# ============================================================
# Main dispatch
# ============================================================

case "$MODE" in
  plan|job)
    case "$TIMING" in
      immediate)  run_immediate "$MODE" "$TARGET" ;;
      overnight)  run_overnight "$MODE" "$TARGET" ;;
      delay)      run_delayed "$MODE" "$TARGET" "$DELAY_SPEC" ;;
    esac
    ;;

  cron)
    # Run a cron wrapper's selection + execution logic immediately
    CRON_SCRIPT="$CRON_DIR/${TARGET}-cron.sh"
    if [[ ! -f "$CRON_SCRIPT" ]]; then
      echo "ERROR: Cron script not found: $CRON_SCRIPT" >&2
      exit 1
    fi
    echo "Running cron: $TARGET (script: $CRON_SCRIPT)"
    exec bash "$CRON_SCRIPT"
    ;;

  batch)
    # Sequential execution of a JSON job list
    if [[ ! -f "$TARGET" ]]; then
      echo "ERROR: Batch file not found: $TARGET" >&2
      exit 1
    fi
    BATCH_COUNT=$(jq 'length' "$TARGET")
    echo "Batch execution: $BATCH_COUNT jobs"
    for i in $(seq 0 $(( BATCH_COUNT - 1 ))); do
      JOB_TYPE=$(jq -r ".[$i].type" "$TARGET")
      JOB_NAME=$(jq -r ".[$i].name" "$TARGET")
      JOB_MODEL=$(jq -r ".[$i].model // \"$MODEL\"" "$TARGET")
      JOB_TIMEOUT=$(jq -r ".[$i].timeout // \"3600\"" "$TARGET")
      JOB_BUDGET=$(jq -r ".[$i].budget // \"\"" "$TARGET")

      echo "--- Batch item $(( i + 1 ))/$BATCH_COUNT: $JOB_NAME ($JOB_TYPE) ---"
      bash "$0" "--$JOB_TYPE" "$JOB_NAME" --immediate --model "$JOB_MODEL" \
        ${JOB_TIMEOUT:+--timeout "$JOB_TIMEOUT"} \
        ${JOB_BUDGET:+--budget "$JOB_BUDGET"} \
        --trigger-type "$TRIGGER_TYPE" || echo "FAILED: $JOB_NAME"
    done
    echo "Batch complete."
    ;;

  list-pending)
    if [[ ! -f "$PENDING_FILE" ]] || [[ ! -s "$PENDING_FILE" ]]; then
      echo "No pending delayed jobs."
      exit 0
    fi
    COUNT=$(jq '.pending | length' "$PENDING_FILE")
    if (( COUNT == 0 )); then
      echo "No pending delayed jobs."
    else
      echo "Pending delayed jobs ($COUNT):"
      jq -r '.pending[] | "  \(.name) (\(.type)) — fires at \(.fire_at)"' "$PENDING_FILE"
    fi
    ;;

  cancel)
    # Kill sleep process if still running
    if [[ -f "$PENDING_FILE" ]]; then
      PID=$(jq -r --arg n "$TARGET" '.pending[] | select(.name == $n) | .pid // empty' "$PENDING_FILE")
      if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
        echo "Killed pending process (pid: $PID)"
      fi
    fi

    # Remove one-shot launchd plist if exists
    SLUG=$(to_slug "$TARGET")
    PLIST="$HOME/Library/LaunchAgents/com.claude.dispatch-onetime-${SLUG}.plist"
    if [[ -f "$PLIST" ]]; then
      launchctl unload "$PLIST" 2>/dev/null || true
      rm -f "$PLIST"
      echo "Removed launchd plist: $PLIST"
    fi

    remove_pending "$TARGET"
    echo "Cancelled: $TARGET"
    ;;

  hold)
    exec_queue_hold "$TARGET"
    echo "Held: $TARGET (will be skipped by overnight execution)"
    ;;

  unhold)
    exec_queue_unhold "$TARGET"
    echo "Unheld: $TARGET (will be picked up by next execution)"
    ;;

  queue-status)
    echo "=== Execution Queue ==="
    QUEUED=$(exec_queue_list "queued" | jq 'length')
    HELD=$(exec_queue_list "held" | jq 'length')
    RUNNING=$(exec_queue_list "running" | jq 'length')
    echo "Queued: $QUEUED | Held: $HELD | Running: $RUNNING"
    echo ""
    exec_queue_list | jq -r '.[] | "  [\(.status)] \(.name) (\(.type)) — queued \(.queued_at) by \(.queued_by)"'
    ;;

  circuit-breaker-status)
    # F0 — show sentinel state + last 5 verdicts
    if [[ -f "$F0_SENTINEL" ]]; then
      echo "=== F0 CIRCUIT-BREAKER: ENGAGED ==="
      cat "$F0_SENTINEL"
      echo ""
    else
      echo "=== F0 CIRCUIT-BREAKER: clear ==="
    fi
    if [[ -f "$F0_VERDICTS_LOG" ]]; then
      echo ""
      echo "Last 5 verdicts ($(wc -l < "$F0_VERDICTS_LOG" | tr -d ' ') total in log):"
      tail -n 5 "$F0_VERDICTS_LOG" | jq -r '"  \(.ts)  \(.verdict)  \(.slug)"' 2>/dev/null \
        || tail -n 5 "$F0_VERDICTS_LOG"
    else
      echo ""
      echo "No verdict log yet at $F0_VERDICTS_LOG"
    fi
    ;;

  clear-circuit-breaker)
    # F0 — clear the sentinel. The flag itself is the explicit
    # operator-intervention confirmation; no y/N prompt to avoid TTY issues
    # in scripted use.
    if [[ -f "$F0_SENTINEL" ]]; then
      echo "Clearing F0 circuit-breaker sentinel:"
      cat "$F0_SENTINEL"
      echo ""
      rm -f "$F0_SENTINEL"
      echo "Sentinel cleared. Dispatcher resumes."
    else
      echo "No active sentinel at $F0_SENTINEL — nothing to clear."
      exit 0
    fi
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac

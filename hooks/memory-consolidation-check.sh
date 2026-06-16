#!/bin/bash
# Hook: SessionEnd — Evaluate consolidation gates and spawn background runner.
# Must complete in <100ms. Actual consolidation runs detached.
#   - Decay = re-validation prompt, never deletion. A SINGLE 180-day interval
#     applies to all non-episodic memory (per-type half-lives deferred to v1.1);
#     episodic NEVER decays. last_validated is the SOLE decay input (required
#     per schema 2.0.0); `updated` does NOT reset the clock. States are
#     FRESH (<180d → none) / STALE (180-360d → propose revalidate) / EXPIRED
#     (≥360d → propose {revalidate|supersede|archive}); ALL propose-only —
#     nothing is auto-deleted/auto-archived (.4).
#   - The consolidation lock uses lockf (sourced from hooks/lib/lockf.sh,
#     hand-rolled PID-lock TOCTOU window (.6). The kernel
#     releases the advisory lock on process death — no stale-lock class.
#   - SessionEnd gate (≥24h AND ≥5 sessions) + audit log preserved (incl. a
#     ## Skipped entry on opt-out so absence is observable).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/lockf.sh"
MEMORY_DIR="$(resolve_memory_dir)"
STATE_FILE="$MEMORY_DIR/.consolidation-state.json"
LOG_FILE="${CLAUDE_LOG_DIR:-$MEMORY_DIR}/.consolidation-log.md"  # G6: LOG → state/logs/; state STAYS in MEMORY_DIR
RUNNER="$(cd "$(dirname "$0")" && pwd)/memory-consolidation-run.sh"

# Single re-validation interval (.4). All non-episodic memory
# shares one 180-day interval; episodic never decays.
REVALIDATION_INTERVAL_DAYS=180
STALE_DAYS=180
EXPIRED_DAYS=360

# Parse stdin for session_id
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Audit log entry so absence-of-runs is observable.
hook_enabled="$(_manifest_get .behavioral.hook_preferences.memory_consolidation_enabled 2>/dev/null || true)"
if [ "$hook_enabled" = "false" ]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '\n## Skipped — %s\n- Reason: user-manifest hook_preferences.memory_consolidation_enabled=false\n' \
    "$(date +"%Y-%m-%d %H:%M")" >> "$LOG_FILE" 2>/dev/null || true
  exit 0
fi

# --- Ensure state file exists (bootstrap) ---
if [[ ! -f "$STATE_FILE" ]]; then
  mkdir -p "$MEMORY_DIR"
  cat > "$STATE_FILE" <<'INIT'
{
  "config": {"hours_threshold": 24, "sessions_threshold": 5, "revalidation_interval_days": 180},
  "last_consolidation": "1970-01-01T00:00:00Z",
  "sessions_since": 5,
  "last_session_id": "",
  "total_consolidations": 0,
  "last_result": null,
  "last_error": null
}
INIT
fi

# --- Read state ---
STATE=$(cat "$STATE_FILE")

SESSIONS_SINCE=$(echo "$STATE" | jq -r '.sessions_since // 0')
LAST_CONSOLIDATION=$(echo "$STATE" | jq -r '.last_consolidation // "1970-01-01T00:00:00Z"')
HOURS_THRESHOLD=$(echo "$STATE" | jq -r '.config.hours_threshold // 24')
SESSIONS_THRESHOLD=$(echo "$STATE" | jq -r '.config.sessions_threshold // 5')

# --- Increment session counter and write back ---
SESSIONS_SINCE=$((SESSIONS_SINCE + 1))
STATE=$(echo "$STATE" | jq \
  --argjson s "$SESSIONS_SINCE" \
  --arg sid "${SESSION_ID:-unknown}" \
  --argjson rev "$REVALIDATION_INTERVAL_DAYS" \
  '.sessions_since = $s | .last_session_id = $sid | .config.revalidation_interval_days = $rev')

printf '%s\n' "$STATE" > "$STATE_FILE"

# --- Evaluate gates (≥24h AND ≥5 sessions) ---
NOW_EPOCH=$(date +%s)
LAST_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$LAST_CONSOLIDATION" +%s 2>/dev/null || echo 0)
HOURS_ELAPSED=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))

GATE_A=false
GATE_B=false
[[ "$HOURS_ELAPSED" -ge "$HOURS_THRESHOLD" ]] && GATE_A=true
[[ "$SESSIONS_SINCE" -ge "$SESSIONS_THRESHOLD" ]] && GATE_B=true

if [[ "$GATE_A" != "true" ]] || [[ "$GATE_B" != "true" ]]; then
  exit 0
fi

# --- Both gates met — spawn the runner under an exclusive lockf advisory lock.
# lockf provides single-instance guarantee with kernel-released locks (no
# stale-lock TOCTOU). The runner re-execs itself under lockf; contention is a
# clean no-op skip (another consolidation is already running). The interval +
# state-tier vars are exported so the detached runner inherits the decay
# contract.
export REVALIDATION_INTERVAL_DAYS STALE_DAYS EXPIRED_DAYS
LOCK_FILE="$MEMORY_DIR/.consolidation.lock"
mkdir -p "$MEMORY_DIR"

nohup bash "$RUNNER" > /dev/null 2>&1 &
disown 2>/dev/null || true

exit 0

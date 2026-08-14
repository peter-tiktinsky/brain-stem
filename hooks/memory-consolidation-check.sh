#!/bin/bash
# Hook: SessionEnd — Evaluate consolidation gates and spawn background runner.
# Must complete in <100ms. Actual consolidation runs detached.
#   - Decay = re-validation prompt, never deletion. A SINGLE 180-day interval
#     applies to all non-episodic memory (per-type half-lives are not modelled);
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
# FAIL-GRACEFUL SOURCE GUARD. Under the `set -euo pipefail` above, a bare `source` of a missing
# or unreadable lib ABORTS this SessionEnd hook with a bash error on stderr and a non-zero exit —
# a half-installed or partially-copied tree turns a silent no-op into a visible hook failure at
# every session end. Both libs are REQUIRED (resolve_memory_dir comes from paths.sh, the lockf
# spawn guard from lockf.sh), so the correct degrade is to leave the consolidation gate
# unevaluated and exit clean.
# THE GUARD IS A READABILITY PRE-TEST, NOT `source … || exit 0`, and the difference is measured,
# not stylistic: on bash 3.2 a `.`/`source` whose file does not exist terminates a non-interactive
# shell WHEN ERREXIT IS SET, so the `||` clause never runs and the hook still dies 1. (Verified
# both ways: with `set -e` the trailing `|| exit 0` is unreachable; without it, it fires.) The
# other hooks carrying that shorter form all run WITHOUT errexit, which is why it works there and
# would be inert here. The pre-test form is the tree's own errexit-safe idiom —
# hooks/handoff-chronicle-append.sh, hooks/library-log-append.sh, cron-health-banner.sh.
# The hook is unchanged in every other respect and stays wired: only its FAILURE MODE moves from
# hard-abort to silent no-op.
{ [ -r "$SCRIPT_DIR/lib/paths.sh" ] && source "$SCRIPT_DIR/lib/paths.sh"; } || exit 0
{ [ -r "$SCRIPT_DIR/lib/lockf.sh" ] && source "$SCRIPT_DIR/lib/lockf.sh"; } || exit 0
MEMORY_DIR="$(resolve_memory_dir)"

# --- Detached-spawn env pin (T-3) -----------------------------------
# Sanctioned call-site block, verbatim from hooks/lib/detached-spawn-env.sh's header.
# Re-pins CLAUDE_HOME (the measured escape vector) + MEMORY_DIR to the tree THIS hook was
# loaded from, so the nohup'd runner below never re-resolves them itself
# (memory-consolidation-run.sh calls resolve_memory_dir() independently and
# `mkdir -p`s the result — a WRITE this parent's resolution never reached).
# WHY HERE and not at the top of the file — two reasons, both load-bearing:
#   1. BUDGET (<100ms, stated above). MEMORY_DIR is already resolved on the line above,
#      so the helper REBASES it as pure string work. Pinning before :24 would leave
#      MEMORY_DIR empty at pin time and cost a SECOND resolve_memory_dir (git rev-parse
#      + sed + jq subprocesses). The scrub is env assignment, not work.
#   2. STATE_FILE/LOG_FILE/LOCK_FILE derive from MEMORY_DIR, so the pin must precede
#      them or the hook's own state paths would disagree with the runner's.
# ADDITIVE: the decay-contract exports at the spawn (134) are untouched.
# PLACEMENT: the block resolves $SCRIPT_DIR, so it MUST stay BELOW the SCRIPT_DIR
# assignment. Above it every clause degrades politely and the scrub is INERT while
# grepping identically to a working one (asserted by the T-2/T-3 line-order guards).
_DSE="$SCRIPT_DIR/lib/detached-spawn-env.sh"
# shellcheck source=/dev/null
if "${BASH:-bash}" -n "$_DSE" 2>/dev/null; then . "$_DSE" 2>/dev/null || true; fi
if ! command -v pin_detached_spawn_env >/dev/null 2>&1; then pin_detached_spawn_env() { :; }; fi
pin_detached_spawn_env || true

STATE_FILE="$MEMORY_DIR/.consolidation-state.json"
LOG_FILE="${CLAUDE_LOG_DIR:-$MEMORY_DIR}/.consolidation-log.md"  # G6: LOG → state/logs/; state STAYS in MEMORY_DIR
RUNNER="$(cd "$(dirname "$0")" && pwd)/memory-consolidation-run.sh"

# Single re-validation interval (.4). All non-episodic memory
# shares one 180-day interval; episodic never decays.
REVALIDATION_INTERVAL_DAYS=180
STALE_DAYS=180
EXPIRED_DAYS=360

# Parse stdin for session_id
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
# A corrupt/truncated state file is quarantined and re-initialized: under set -e
# an invalid-JSON state would otherwise crash every subsequent SessionEnd with
# nothing ever healing the file.
if [[ -f "$STATE_FILE" ]] && ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  mv -f "$STATE_FILE" "${STATE_FILE}.corrupt" 2>/dev/null || rm -f "$STATE_FILE"
  echo "memory-consolidation-check: corrupt state file quarantined to ${STATE_FILE}.corrupt — re-initializing" >&2
fi
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

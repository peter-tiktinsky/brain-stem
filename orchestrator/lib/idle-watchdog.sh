# orchestrator/lib/idle-watchdog.sh — size-based stream-json silence
# watchdog for backgrounded `claude -p` calls. Source this file — do not
# execute it.
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/claude-p.sh"
#   source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/idle-watchdog.sh"
#   "$CLAUDE" -p "$prompt" --output-format stream-json ... > "$call_log" 2>&1 &
#   pid=$!
#   watchdog_idle "$pid" "$call_log" 180
#   rc=$?
#
# Extracted from an earlier cron pipeline. Watches the ndjson artifact a
# backgrounded
# `claude -p` is writing to. Every $WATCHDOG_SAMPLE_INTERVAL seconds (10s
# default), samples file size; if the file has not grown for `timeout`
# accumulated seconds, escalates SIGTERM → 2s grace → SIGKILL if still
# alive, then dispatches the post-kill classifier (lib/claude-p.sh) and
# returns 124. On natural exit, returns the pid's wait status.
#
# Composition with lib/claude-p.sh:
#   The watchdog calls `classify_claude_p_exit` post-kill to produce the
#   observability classification. Caller MUST have sourced claude-p.sh
#   before invoking watchdog_idle, OR the watchdog falls back to a
#   degraded "(classifier unavailable)" classification line. The two
#   helpers are siblings — neither auto-sources the other to keep the
#   sourcing graph explicit.
#
# Log target resolution:
#   $LOG_FILE env var, when set and writable, receives:
#     - "IDLE-WATCHDOG-FIRED ndjson=<basename> idle=Ns last_bytes=N"
#     - "--- last 20 lines of <ndjson_path> ---"
#     - 20-line tail of the ndjson artifact
#     - "    classification: <result>" (from claude-p.sh classifier)
#     - "--- watchdog-fire end: <iso> rc=124 ---"  (or rc=$rc on natural exit)
#   When $LOG_FILE is unset/empty, the helper writes to stderr instead so
#   the watchdog never silently drops observability output.
#
# pid contract: caller must have backgrounded the pid in the same shell
# that calls watchdog_idle (i.e., `pid=$!` after `&`). `wait $pid` only
# reaps children of the calling shell. If the helper is sourced into a
# foreign shell that did not spawn the pid, natural-exit reap returns
# the wait-no-such-child error rather than the pid's true rc.
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile, no [[ =~ ]]
# in production paths, no parameter-expansion case conversion.

# Sample interval (seconds). Production cron wrappers run with the 10s
# default. Tests override via WATCHDOG_SAMPLE_INTERVAL=1 to keep runtime
# short. Idle accumulator increments by this interval each loop.
: "${WATCHDOG_SAMPLE_INTERVAL:=10}"

# _watchdog_log_target — resolves where observability lines go. Returns
# the path on stdout. Empty output means "stderr only" (handled by callers
# via a separate branch).
_watchdog_log() {
  if [ -n "${LOG_FILE:-}" ]; then
    echo "$1" >> "$LOG_FILE" 2>/dev/null || echo "$1" >&2
  else
    echo "$1" >&2
  fi
}

_watchdog_tail() {
  # Tails 20 lines of $1 to the same target as _watchdog_log.
  if [ -n "${LOG_FILE:-}" ]; then
    tail -20 "$1" >> "$LOG_FILE" 2>/dev/null || true
  else
    tail -20 "$1" >&2 2>/dev/null || true
  fi
}

# watchdog_idle <pid> <ndjson_path> <timeout_seconds>
#
# Returns 124 if the watchdog fired (pid was killed for stream-json
# silence). Returns the pid's wait status on natural completion. Returns
# 2 if required args are missing.
watchdog_idle() {
  local pid="$1"
  local ndjson_path="$2"
  local timeout="${3:-180}"

  if [ -z "$pid" ] || [ -z "$ndjson_path" ]; then
    echo "watchdog_idle: missing required args (pid, ndjson_path)" >&2
    return 2
  fi

  local sample_interval="$WATCHDOG_SAMPLE_INTERVAL"
  local last_size=0
  local idle=0
  local cur_size

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$sample_interval"
    cur_size=$(stat -f%z "$ndjson_path" 2>/dev/null || echo 0)
    if [ "$cur_size" -gt "$last_size" ]; then
      last_size=$cur_size
      idle=0
    else
      idle=$((idle + sample_interval))
    fi

    if [ "$idle" -ge "$timeout" ]; then
      local base
      base=$(basename "$ndjson_path")
      _watchdog_log "IDLE-WATCHDOG-FIRED ndjson=$base idle=${idle}s last_bytes=$cur_size"
      _watchdog_log "--- last 20 lines of $ndjson_path ---"
      _watchdog_tail "$ndjson_path"

      # Escalation: SIGTERM, 2s grace, SIGKILL if still alive. Source
      # librarian-cron.sh used a single `kill` then `wait`; the SIGKILL
      # fallback is a forward improvement called out in the spec for
      # processes that ignore SIGTERM.
      kill "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true

      # Classifier dispatch — composes with claude-p.sh.
      local classification
      if command -v classify_claude_p_exit >/dev/null 2>&1; then
        classification=$(classify_claude_p_exit "$ndjson_path")
      else
        classification="(classifier unavailable: claude-p.sh not sourced)"
      fi
      _watchdog_log "    classification: $classification"
      _watchdog_log "--- watchdog-fire end: $(date -Iseconds) rc=124 ---"
      return 124
    fi
  done

  # Natural completion — pid exited before idle threshold tripped.
  wait "$pid" 2>/dev/null
  local rc=$?
  _watchdog_log "--- watchdog-watch end: $(date -Iseconds) rc=$rc ---"
  return "$rc"
}

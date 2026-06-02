# orchestrator/lib/claude-p.sh — post-kill `claude -p` exit classifier.
# Source this file — do not execute it.
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/claude-p.sh"
#   classification=$(classify_claude_p_exit "$call_log")
#   echo "    classification: $classification" >> "$LOG_FILE"
#
# Extracted from librarian-cron.sh L196-204 (pinned source SHA d087b4b in
# orchestrator/MANIFEST.txt). Reads the ndjson artifact left by a watchdog-
# killed `claude -p` invocation and emits one of two classifications to
# stdout. Caller is responsible for writing the result to the observability
# error-file surface (morning-brief consumes; tripwire trilayer).
#
# Two-bucket fingerprint:
#   - "claude-p-never-emitted-output (cold-start-hang)"
#       File ≤120 bytes AND contains "SessionEnd hook.*Hook cancelled".
#       This is the cold-start-hang death-rattle (Gap #6) — the launchd-fired
#       process never produced real output before the hook scaffold tore it
#       down. 120 bytes is the empirically observed ceiling for the death-
#       rattle line plus framing.
#   - "claude-p-stalled-mid-run (bytes=N)"
#       Anything else. The call got into real work but the stream-json tap
#       went silent past the idle-watchdog threshold; partial output is on
#       disk for forensic tail.
#
# Bash 3.2 clean (R-23): no associative arrays, no mapfile, no [[ =~ ]] in
# production paths, no parameter-expansion case conversion.

# classify_claude_p_exit <ndjson_path>
#
# Emits the classification string to stdout. Always returns 0 — the helper
# is a pure observation primitive, not a flow-control gate. Missing or
# unreadable ndjson is treated as "never-emitted-output" (size=0 satisfies
# the ≤120 branch; grep on a missing file fails the AND so we fall through
# to stalled-mid-run with bytes=0). Caller decides whether to log or act.
classify_claude_p_exit() {
  local ndjson_path="$1"
  if [ -z "$ndjson_path" ]; then
    echo "classify_claude_p_exit: missing ndjson_path arg" >&2
    return 2
  fi

  local final_size
  final_size=$(stat -f%z "$ndjson_path" 2>/dev/null || echo 0)

  if [ "$final_size" -le 120 ] \
     && grep -q "SessionEnd hook.*Hook cancelled" "$ndjson_path" 2>/dev/null; then
    echo "claude-p-never-emitted-output (cold-start-hang)"
  else
    echo "claude-p-stalled-mid-run (bytes=$final_size)"
  fi
}

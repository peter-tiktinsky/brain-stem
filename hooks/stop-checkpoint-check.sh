#!/bin/bash
# Hook: Stop — Enforce a checkpoint at high context. Stop fires at every turn end,
# not only at session exit, so each band below gates every turn end in its range.
# Exit 2 = force continuation. Exit 0 = allow stop.
set -euo pipefail

# hook-portability — source the journal peer via $SCRIPT_DIR
# ([DRIFT] 3). hook-journal.sh is a hooks/lib/ peer
# (named in registry.sh's peer-source loop as landing at/); source it
# only when present and provide a no-op journal_emission fallback so the hook
# never hard-fails before the peer lands (matches registry.sh graceful-degrade).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh"
[ -r "$SCRIPT_DIR/lib/hook-journal.sh" ] && source "$SCRIPT_DIR/lib/hook-journal.sh"
if ! command -v journal_emission >/dev/null 2>&1; then
  journal_emission() { :; }
fi
# the context-pressure writer (the .pct producer the bands below read).
[ -r "$SCRIPT_DIR/lib/context-pressure.sh" ] && source "$SCRIPT_DIR/lib/context-pressure.sh"
# The shared "is this a Session Continuity Block?" test the 48-80% band reads.
[ -r "$SCRIPT_DIR/lib/checkpoint-guard.sh" ] && source "$SCRIPT_DIR/lib/checkpoint-guard.sh"

# T-3: the Stop turn-boundary heartbeat needs the registry RMW primitives +
# REGISTRY_LOCK, so source the coordination lib (graceful-degrade like the peers above;
# env-wins paths.sh re-source is idempotent). This covers a long AUTONOMOUS single-turn
# run that emits no new UserPromptSubmit — the gap per-prompt refresh alone leaves open.
[ -r "$SCRIPT_DIR/lib/registry.sh" ] && source "$SCRIPT_DIR/lib/registry.sh"

# Internal lockf re-exec target. `stop-checkpoint-check.sh --do-heartbeat <sid>` refreshes
# ONLY that session's last_heartbeat while holding REGISTRY_LOCK across the
# read_registry..write_registry span (heartbeat_row from registry.sh), then exits — before
# the stdin drain + gate logic below, so the re-exec never blocks and never gates.
if [ "${1:-}" = "--do-heartbeat" ]; then
  command -v heartbeat_row >/dev/null 2>&1 && heartbeat_row "${2:-}"
  exit 0
fi

# Drain the Stop payload from stdin ONCE, early. The stopping session's id and the
# transcript_path both arrive as stdin JSON (the Stop hook contract). Non-blocking:
# with no stdin (tests pipe </dev/null) STOP_INPUT stays empty and every reader
# degrades gracefully. This is the single drain for the whole hook — the session-id
# resolve and the stop-time pressure refresh below both read $STOP_INPUT.
# BOUNDED capture: `[ -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the Stop gate hangs with zero output. The
# timeout is on EVERY read and each line is accumulated as it arrives, so a stream
# that keeps delivering is never truncated and an expiry mid-stream keeps what already
# arrived; the trailing-newline trim reproduces `$(cat)` exactly, and absent input
# still reads as empty (tests pipe </dev/null). HOOKS_STDIN_WAIT overrides (whole
# seconds); a zero/non-numeric value falls back rather than reaching `read -t 0`,
# which on bash 3.2 arms no timer at all.
STOP_INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    STOP_INPUT="${STOP_INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${STOP_INPUT%$'\n'}" != "$STOP_INPUT" ]; do STOP_INPUT="${STOP_INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
fi

# Per-session checkpoint/pressure dir roots at $CLAUDE_STATE_ROOT (/
# /), via the paths.sh SoT (sourced above) — NOT $HOOKS_STATE.
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"
CLEARING_WINDOW_SEC=600

# T-2: per-session checkpoint paths.
# T-3 (2026-05-11): per-session pressure file paths.
# The stopping session's id arrives as stdin JSON (.session_id — the Stop hook
# contract); the env var is retained only as the test-injection seam. Resolve
# env-then-stdin, and graceful-degrade (allow stop) when neither is present.
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID=$(printf '%s' "$STOP_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
fi
if [[ -z "$SESSION_ID" ]]; then
  # Cannot determine session — allow stop (graceful degrade; we cannot enforce
  # per-session checkpoint freshness without knowing which session is stopping).
  exit 0
fi

# Library promotion: offer a newly completed plan's research for the shared library.
# The arm runs only where the ladder below would otherwise allow the stop (after the
# >90% valve, every checkpoint gate and the memory-review CONFLICT block, whether or
# not memory review is opted out), so it never changes a gate's outcome. It reads the
# mode first: unset or `off` means no scan and no model call. Every state write stays
# in the library-scrub.sh modes it calls, under that capability's lock; the claim
# through --next is the one-shot marker, so a candidate is offered once.
_DSE="$SCRIPT_DIR/lib/detached-spawn-env.sh"
# shellcheck source=/dev/null
if "${BASH:-bash}" -n "$_DSE" 2>/dev/null; then . "$_DSE" 2>/dev/null || true; fi
if ! command -v pin_detached_spawn_env >/dev/null 2>&1; then pin_detached_spawn_env() { :; }; fi
LP_QUESTION="This plan is now complete. The research artifacts attached to this plan likely have universal value. Would you like to promote these research artifacts to universal reference material?"
library_promotion_stop() {
  local host="" c mode slug="" untriaged
  for c in "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/library-scrub.sh" \
           "$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)/skills/librarian/capabilities/library-scrub.sh"; do
    if [ -f "$c" ]; then host="$c"; break; fi
  done
  [ -n "$host" ] || return 0
  mode="$(bash "$host" --mode get 2>/dev/null </dev/null || true)"
  case "$mode" in prompt|auto) ;; *) return 0 ;; esac
  # Re-entry: a stop that a Stop hook already continued is never blocked again.
  if [ "$(printf '%s' "$STOP_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || true)" = "true" ]; then
    return 0
  fi
  # Headless (nobody to answer): the candidate stays queued and the next attended
  # SessionStart names it. CLAUDE_CODE_SESSION_ATTENDED reads 0 headless and 1
  # attended; where it is absent, an sdk-* entrypoint marks a headless run.
  if [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "0" ]; then return 0; fi
  if [ -z "${CLAUDE_CODE_SESSION_ATTENDED:-}" ]; then
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) return 0 ;; esac
  fi
  # Pin before the detached chain below. The call sits at column 0, the sanctioned
  # call-site form that the spawn-roster checks read; it runs only on this path, so the
  # ladder above keeps its own resolution.
pin_detached_spawn_env || true
  # A pre-filtered file scan with no model call: it catches Bash, script, other-session
  # and vault-spelled writes that no PostToolUse payload saw.
  bash "$host" --candidates >/dev/null 2>&1 </dev/null || true
  # Ordering contract: the capability's state-writing modes share one non-blocking lock,
  # and a contended call logs a skip and exits 0, so its verdict or answer is lost. This
  # Stop therefore never runs two of them at once, and auto mode never splits a claim
  # from its answer: the combined --claim-answer mode claims and answers under ONE
  # lock acquisition, so contention degrades to "never claimed" — which the next Stop
  # re-offers — instead of a claimed-but-unanswered record stranded past its one-shot
  # claim. The claim-and-answer runs first in the detached chain (the record the
  # SessionStart banner reads), then the triage loop, one small-model call per plan.
  # The chain is spawned before every exit that follows it.
  untriaged="$(bash "$host" --pending 2>/dev/null </dev/null \
    | awk -F'\t' '$2 == "state=pending" && $5 == "reason=awaiting triage" { print $1 }' || true)"
  # The foreground --next claim is the PROMPT-mode surface only (auto mode claims
  # inside the chain's combined mode below), so a claimed slug can never dangle
  # past this Stop waiting for an answer a contended chain would lose.
  if [ "$mode" != "auto" ]; then
    slug="$(bash "$host" --next "$SESSION_ID" 2>/dev/null </dev/null | head -n 1 || true)"
  fi
  if [ "$mode" = "auto" ]; then
    mkdir -p "$HOOKS_STATE" 2>/dev/null || true
  fi
  if [ -n "$untriaged" ] || [ "$mode" = "auto" ]; then
    ( {
      # The capability's output is the record the SessionStart banner reads: its
      # promoted line is printed only after the library_refs stamps are re-read.
      # Only auto mode answers unasked: in prompt mode the user answers the blocked
      # question, so the chain never claims or answers a second ready plan.
      if [ "$mode" = "auto" ]; then
        bash "$host" --claim-answer "$SESSION_ID" yes </dev/null >>"$HOOKS_STATE/library-promotion-auto.log" 2>&1 || true
      fi
      for t in $untriaged; do bash "$host" --triage "$t" </dev/null >/dev/null 2>&1 || true; done
    } </dev/null >/dev/null 2>&1 & ) || true
  fi
  [ -n "$slug" ] || return 0
  {
    echo "Library promotion: plan $slug is complete, and triage judged its research worth offering to the shared library."
    echo "Before stopping, ask the user with AskUserQuestion, using exactly this question: \"$LP_QUESTION\""
    echo "Offer exactly these three answers as the option labels: \"Yes\", \"No\", \"Yes, and promote automatically from now on\"."
    echo "Then run: bash $host --answer $slug yes|no|always (Yes = yes, No = no, the third answer = always)."
    echo "The answer is recorded only when $slug no longer appears in: bash $host --pending. If it still appears, the library lock was busy and the answer was skipped; run the same --answer command once more."
  } >&2
  journal_emission "Stop" "deny-stop:library-promotion:prompt:plan=${slug}" 2
  exit 2
}
# The ladder's allow exits below call this in place of a bare `exit 0`.
allow_stop() {
  library_promotion_stop || true
  exit 0
}

CHECKPOINT_FILE="$STATE_DIR/sessions/$SESSION_ID/checkpoint.md"
PRESSURE_FILE="$STATE_DIR/sessions/$SESSION_ID/context-pressure.json"

# T-3: refresh this session's last_heartbeat at the Stop turn-boundary so a
# long autonomous single-turn run (no new UserPromptSubmit to trigger the per-prompt
# refresh) still keeps its heartbeat fresh and is not reaped by the T-1 verdict. Holds
# REGISTRY_LOCK across the RMW via the --do-heartbeat lockf re-exec. A
# lockf timeout (rc 75) DEFERS the row — one skip line, never an unlocked write
# (non-75 keeps the silent swallow); the skipped heartbeat self-heals at the
# next Stop fire. Every path can NEVER non-zero-exit and wrongly force-continue the
# Stop gate under `set -euo pipefail`.
if command -v heartbeat_row >/dev/null 2>&1; then
  ensure_coord_dir 2>/dev/null || true
  if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
    _scc_rc=0
    lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-heartbeat "$SESSION_ID" >/dev/null 2>&1 || _scc_rc=$?
    if [ "$_scc_rc" -eq 75 ]; then
      _scc_dir="${LOG_DIR:-}"
      if [ -z "$_scc_dir" ] || [ ! -d "$_scc_dir" ]; then _scc_dir="${HOOKS_STATE:-$(dirname "$REGISTRY_LOCK")}"; fi
      echo "$(date -Iseconds) stop-checkpoint-check.sh skip: registry lock contention on $REGISTRY_LOCK (row update deferred; next fire retries)" \
        >> "$_scc_dir/stop-checkpoint-check-skip.log" 2>/dev/null || true
    fi
  else
    heartbeat_row "$SESSION_ID" || true
  fi
fi

# refresh .pct from the transcript at stop time so the gate sees the pressure
# AFTER the just-completed tool chain (a stale last-prompt pct would under-protect).
# The transcript_path was drained with the session id from the early Stop-payload
# read above; reuse $STOP_INPUT (empty in tests → the writer no-ops and any existing
# pressure file is preserved).
_cp_tp=$(printf '%s' "$STOP_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
# --- Cause-2: compact-boundary-aware recompute guard -------------
# session-register.sh reset .pct=0 + dropped a .compact-pending marker (the
# usage-block count at the compaction boundary). Until the transcript advances
# PAST that boundary (a genuine post-compact usage block appears), do NOT
# re-derive .pct from the stale pre-compact block — recomputing would re-write
# the stale-high value and false-fire the R-26 mandate (the session-register-only
# reset is provably inert without this guard). On advance: clear the marker +
# resume the normal recompute so real post-compact pressure (incl. a genuinely
# high one) is written and the mandate fires. write_context_pressure()
# (hooks/lib/context-pressure.sh) stays byte-frozen.
# This is the SECOND write_context_pressure call site (stop-time refresh);
# it is guarded IDENTICALLY to prompt-context.sh:65-68 so the Stop-side recompute
# cannot false-fire the mandate on the first post-compact turn (T-2 (a)).
_cp_marker="$STATE_DIR/sessions/$SESSION_ID/.compact-pending"
_cp_skip=0
if [ -f "$_cp_marker" ]; then
  _cp_boundary=$(cat "$_cp_marker" 2>/dev/null || true)
  case "$_cp_boundary" in ''|*[!0-9]*) _cp_boundary="" ;; esac
  _cp_now=""
  if [ -n "$_cp_tp" ] && [ -r "$_cp_tp" ] && command -v jq >/dev/null 2>&1; then
    _cp_now=$(jq -rs '[ .[]? | objects | ((.message? | objects | .usage?) // .usage?) | objects ] | length' "$_cp_tp" 2>/dev/null || true)
  fi
  case "$_cp_now" in ''|*[!0-9]*) _cp_now="" ;; esac
  if [ -n "$_cp_boundary" ] && [ -n "$_cp_now" ] && [ "$_cp_now" -gt "$_cp_boundary" ]; then
    rm -f "$_cp_marker" 2>/dev/null || true
  else
    _cp_skip=1
  fi
fi
if [ "$_cp_skip" -eq 0 ] && command -v write_context_pressure >/dev/null 2>&1; then
  write_context_pressure "$_cp_tp" "$PRESSURE_FILE" 2>/dev/null || true
fi

# Read context percentage
pct=0
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
fi
pct_int=${pct%.*}

# Safety valve: >90% always allows stop (context too full to continue productively).
# The memory-review band YIELDS to this valve unconditionally.
if (( pct_int > 90 )); then
  exit 0
fi

# Below 48%: no R-26 enforcement band. This is the ONLY point the memory-
# review Stop-block may fire — and ONLY for HIGH-SEVERITY CONFLICTS. The
# memory-review band NEVER competes with or overrides session-continuity: the
# R-26 48-80%/80-90% gates and the >90% valve all take precedence (they are
# evaluated above and below this branch and win). Even a genuine contradiction
# defers to the checkpoint Stop-block (canonical/escalation ladder; C2).
if (( pct_int < 48 )); then
  # memory-review Stop-block for high-severity CONFLICTS only.
  # Reads the review queue via hooks/lib/review-queue.sh (block-and-log); fires
  # only when a high-severity CONFLICT item is unaddressed AND the operator has
  # not opted out. The memory-review thresholds it consults are resolved env >
  # user-manifest.json :: hooks.memory_review > default inside review-queue.sh
  #. Advisory degrade: if the queue lib is absent, no-op.
  _rq_lib="$SCRIPT_DIR/lib/review-queue.sh"
  if [ -r "$_rq_lib" ]; then
    source "$_rq_lib"
    if command -v memory_review_opt_out >/dev/null 2>&1 && memory_review_opt_out; then
      allow_stop
    fi
    if command -v review_queue_has_high_severity_conflict >/dev/null 2>&1 \
       && review_queue_has_high_severity_conflict; then
      echo "Unaddressed HIGH-SEVERITY memory CONFLICT in the review queue. Run /librarian review to confirm or reject-with-reason before stopping. (memory-review Stop-block — yields to R-26)" >&2
      journal_emission "Stop" "deny-stop:memory-review:high-severity-conflict:pct=${pct}" 2
      exit 2
    fi
  fi
  allow_stop
fi

# Compute checkpoint freshness
ckpt_exists=false
ckpt_age=999999
if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
  ckpt_exists=true
  ckpt_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  ckpt_age=$(( now - ckpt_mtime ))
fi

# 48-80% band: allow the stop over a checkpoint younger than CLEARING_WINDOW_SEC, or
# over one that carries a Session Continuity Block at any age. Because Stop fires at
# every turn end, a freshness-only test forced a new write at every turn end past the
# window, over a handoff record already on disk. A stale stub, a stale panic fallback
# or a missing checkpoint still blocks.
if (( pct_int < 80 )); then
  if $ckpt_exists && (( ckpt_age < CLEARING_WINDOW_SEC )); then
    allow_stop
  fi
  if command -v checkpoint_has_block >/dev/null 2>&1 && checkpoint_has_block "$CHECKPOINT_FILE"; then
    allow_stop
  fi
  echo "Context at ${pct}%. Cannot stop — checkpoint stale (mtime age ${ckpt_age}s, limit ${CLEARING_WINDOW_SEC}s) and carries no Session Continuity Block." >&2
  echo "Invoke /session-checkpoint first to refresh $CHECKPOINT_FILE (per-session path). After checkpoint is written, stop will be allowed. (R-26 48-80% band)" >&2
  journal_emission "Stop" "deny-stop:48-80-band:checkpoint-stale:age=${ckpt_age}s:pct=${pct}" 2
  exit 2
fi

# 80-90% band: checkpoint must at minimum exist (pre-existing rule, preserved)
if $ckpt_exists; then
  allow_stop
fi

echo "Context at ${pct}%. You must save a checkpoint before stopping. Invoke /session-checkpoint to write $CHECKPOINT_FILE (per-session path). (R-26 80-90% band)" >&2
journal_emission "Stop" "deny-stop:80-90-band:checkpoint-missing:pct=${pct}" 2
exit 2

#!/bin/bash
# Hook: UserPromptSubmit — Inject context pressure warnings + peer awareness.
# Silent (no output) when solo and context is low.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"
# The single owner of "may I overwrite this checkpoint?" (the passive band below is
# one of its two consumers). Sourced UNCONDITIONALLY — a graceful-degrade guard here
# would silently restore the bare-overwrite path this lib exists to close.
source "$SCRIPT_DIR/lib/checkpoint-guard.sh"
# the memory-review re-firing band reads the review queue. Source
# the producer/reader API when present (graceful-degrade — advisory band).
[ -r "$SCRIPT_DIR/lib/review-queue.sh" ] && source "$SCRIPT_DIR/lib/review-queue.sh"
# the context-pressure writer (the .pct producer the R-26 bands read).
[ -r "$SCRIPT_DIR/lib/context-pressure.sh" ] && source "$SCRIPT_DIR/lib/context-pressure.sh"

# T-3: internal lockf re-exec target. `prompt-context.sh --do-heartbeat <sid>`
# refreshes ONLY that session's last_heartbeat while holding REGISTRY_LOCK across the
# read_registry..write_registry span (heartbeat_row from registry.sh, sourced above),
# then exits. Placed BEFORE the bounded stdin capture below — which replaced an unbounded
# `INPUT=$(cat)` — so the re-exec (which carries its sid as an arg, not a stdin payload)
# never blocks on the read.
if [ "${1:-}" = "--do-heartbeat" ]; then
  heartbeat_row "${2:-}"
  exit 0
fi

# This file has TWO contention surfaces — the heartbeat re-exec
# below and the locked registry read further down — and both route through this ONE
# local helper so the skip-line literal occurs exactly once per file, the same
# single-site shape every registry-writing hook carries. Appends the
# lockf.sh-convention line to <basename>-skip.log in the first existing of $LOG_DIR,
# $HOOKS_STATE, the lockfile's dir. Never non-zero: this hook runs under
# `set -euo pipefail` and a deferred row must never abort the R-26 valve.
log_registry_skip() {
  local _sl_dir="${LOG_DIR:-}"
  if [ -z "$_sl_dir" ] || [ ! -d "$_sl_dir" ]; then
    _sl_dir="${HOOKS_STATE:-}"
    if [ -z "$_sl_dir" ] || [ ! -d "$_sl_dir" ]; then
      _sl_dir="$(dirname "$REGISTRY_LOCK")"
    fi
  fi
  echo "$(date -Iseconds) prompt-context.sh skip: registry lock contention on $REGISTRY_LOCK (row update deferred; next fire retries)" \
    >> "$_sl_dir/prompt-context-skip.log" 2>/dev/null || true
}

# Per-session checkpoint/pressure dir roots at $CLAUDE_STATE_ROOT (/
# /), via the paths.sh SoT — NOT $HOOKS_STATE. registry.sh (sourced
# above) sources paths.sh, so SESSION_STATE_ROOT is exported here.
STATE_DIR="${SESSION_STATE_ROOT:-${HOOKS_STATE_OVERRIDE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}}}"

# T-2: per-session checkpoint paths.
# T-3 (2026-05-11): per-session pressure file paths
# (`sessions/<sid>/context-pressure.json`). PRESSURE_FILE construction moved
# AFTER SESSION_ID resolution. Empty SID → PRESSURE_FILE="" → existence checks
# fall through to default-pct-0 path; the R-26 bands stay silent without a session.
# Read stdin once up-front so we can resolve the per-session checkpoint path
# before the pressure block (which reads CHECKPOINT_FILE mtime).
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
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="${CLAUDE_SESSION_ID:-}"
fi
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# T-3: refresh this session's last_heartbeat on EVERY UserPromptSubmit (solo
# sessions too), BEFORE any early-exit path below, so a live session's heartbeat stays
# fresh and the heartbeat-authoritative verdict keeps it — closing the
# inverse under-count. UPSERTS if a peer's reconcile reaped the row. Holds
# REGISTRY_LOCK across the RMW via the --do-heartbeat lockf re-exec. A
# lockf timeout (rc 75) DEFERS the row — one skip line via the shared helper above,
# never an unlocked write (non-75 keeps the silent swallow); the skipped
# heartbeat self-heals at the next UserPromptSubmit. Never non-zero-propagates under
# this hook's `set -euo pipefail` to abort the R-26 safety valve.
if [[ -n "$SESSION_ID" ]]; then
  ensure_coord_dir 2>/dev/null || true
  if [ -n "${REGISTRY_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
    _pc_hb_rc=0
    lockf -k -t 2 "$REGISTRY_LOCK" "$0" --do-heartbeat "$SESSION_ID" >/dev/null 2>&1 || _pc_hb_rc=$?
    if [ "$_pc_hb_rc" -eq 75 ]; then
      log_registry_skip
    fi
  else
    heartbeat_row "$SESSION_ID" || true
  fi
fi

if [[ -n "$SESSION_ID" ]]; then
  SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
  CHECKPOINT_FILE="$SESSION_DIR/checkpoint.md"
  PRESSURE_FILE="$SESSION_DIR/context-pressure.json"
  BAND_MARKER="$SESSION_DIR/.pressure-band-warned"
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
  # compute + write the .pct the bands below read (no-op if no transcript).
  _cp_tp="$TRANSCRIPT_PATH"
  # --- Cause-2: compact-boundary-aware recompute guard -------------
  # session-register.sh reset .pct=0 + dropped a .compact-pending marker (the
  # usage-block count at the compaction boundary). Until the transcript advances
  # PAST that boundary (a genuine post-compact usage block appears), do NOT
  # re-derive .pct from the stale pre-compact block — recomputing would re-write
  # the stale-high value and false-fire the R-26 banner (the session-register-only
  # reset is provably inert without this guard). On advance: clear the marker +
  # resume the normal recompute so real post-compact pressure (incl. a genuinely
  # high one) is written and the banner fires. write_context_pressure()
  # (hooks/lib/context-pressure.sh) stays byte-frozen.
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
else
  # No session ID — checkpoint + pressure operations skipped (per-session path unavailable).
  # Existence checks against "" return false, so the pressure bands default to pct=0.
  CHECKPOINT_FILE=""
  PRESSURE_FILE=""
  BAND_MARKER=""
fi

# --- Context pressure banner (R-26) ---
# Two bands, warn (WARN_PCT) and mandate (MANDATE_PCT), measured on band_pct (the
# SEMANTICS note below). Entering either raises a banner in the top-level systemMessage field, which Claude
# Code shows to the USER, not the model: whether to checkpoint and compact, or start a
# fresh session, is the user's call, and the Stop gate (stop-checkpoint-check.sh) stays
# the enforcement backstop. The banner fires once per band entry: the marker
# sessions/<sid>/.pressure-band-warned holds the last band warned, a later prompt in
# the same band stays silent, a move into the other band warns again, and falling
# below WARN_PCT removes the marker so the next entry warns afresh. The compaction
# guard above holds .pct at its reset until the transcript advances, which keeps a
# stale pre-compact value from raising the banner.
# Clearing window: a checkpoint.md younger than 600s (10 min) throttles the passive
# capture below.
CLEARING_WINDOW_SEC=600

# --- T-13 (G3): manifest-driven thresholds for hooks.context_pressure ---
# Reads warn_pct/mandate_pct from $CLAUDE_HOME/user-manifest.json (defaults 45/48
# when absent or null). These are the ONLY context_pressure thresholds any hook
# consumes: this hook raises the warn and mandate banners from them.
#
# SEMANTICS: warn_pct/mandate_pct are percentages of the window the harness compacts
# against, so the bands and the harness's compaction share one window. The .pct in
# context-pressure.json is `used / model-window` (the writer resolves the window per
# model family — Haiku 200k, the 1M fleet 1,000,000), while the harness auto-compacts
# against its own auto-compact window, which can sit far below the model window. The
# bands therefore compare band_pct = input_tokens * 100 / basis, the basis being the
# first positive integer among the CLAUDE_CODE_AUTO_COMPACT_WINDOW env var,
# .autoCompactWindow in $CLAUDE_HOME/settings.json and the .window the writer
# recorded, capped at that .window. With no input_tokens (the compaction reset writes
# {"pct":0}) or no basis, band_pct is the .pct itself. The 35% passive capture keeps
# the raw .pct and its own range, below WARN_PCT.
#
# The stop-gate's 48/80/90 boundaries are FIXED constants in stop-checkpoint-check.sh
# by design (a safety gate is not weakened by misconfig). `hard_pct` is schema-parity
# vocabulary only and is intentionally NOT read here or by the stop-gate
# (neither this hook nor the stop-gate reads that field).
USER_MANIFEST="${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json"
WARN_PCT=45
MANDATE_PCT=48
if [[ -f "$USER_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
  _ctxp_read() {
    local jq_path="$1" default="$2"
    local val
    val=$(jq -r "${jq_path} // empty" "$USER_MANIFEST" 2>/dev/null)
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s' "$val"
    else
      printf '%s' "$default"
    fi
  }
  WARN_PCT=$(_ctxp_read '.hooks.context_pressure.warn_pct' 45)
  MANDATE_PCT=$(_ctxp_read '.hooks.context_pressure.mandate_pct' 48)
fi

pressure_context=""
r26_banner=""
r26_banner_fired=false
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
  pct_int=${pct%.*}

  # Compute checkpoint freshness (mtime age in seconds; large number if absent)
  if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
    ckpt_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    ckpt_age=$(( now - ckpt_mtime ))
  else
    ckpt_age=999999
  fi
  checkpoint_fresh=false
  if (( ckpt_age < CLEARING_WINDOW_SEC )); then
    checkpoint_fresh=true
  fi

  # band_pct: the banner bands measured against the auto-compact window (SEMANTICS
  # above). A candidate that is not a positive integer is skipped.
  _bb_pos_int() { case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; esac; return 0; }
  _bb_in=$(jq -r '.input_tokens // empty' "$PRESSURE_FILE" 2>/dev/null || true)
  _bb_win=$(jq -r '.window // empty' "$PRESSURE_FILE" 2>/dev/null || true)
  _bb_pos_int "$_bb_win" || _bb_win=""
  _bb_settings="${CLAUDE_HOME:-$HOME/.claude}/settings.json"
  _bb_set=""
  if [[ -r "$_bb_settings" ]]; then
    _bb_set=$(jq -r '.autoCompactWindow // empty' "$_bb_settings" 2>/dev/null || true)
  fi
  _bb_basis=""
  for _bb_cand in "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" "$_bb_set" "$_bb_win"; do
    if _bb_pos_int "$_bb_cand"; then _bb_basis="$_bb_cand"; break; fi
  done
  if [[ -n "$_bb_basis" && -n "$_bb_win" ]] && (( _bb_basis > _bb_win )); then
    _bb_basis="$_bb_win"
  fi
  band_pct=$pct_int
  if [[ -n "$_bb_basis" && -n "$_bb_in" && "$_bb_in" != *[!0-9]* ]]; then
    band_pct=$(( 10#$_bb_in * 100 / _bb_basis ))
  fi

  r26_band=""
  if (( band_pct >= MANDATE_PCT )); then
    r26_band=mandate
  elif (( band_pct >= WARN_PCT )); then
    r26_band=warn
  fi

  if (( pct_int >= 35 && pct_int < WARN_PCT )); then
    # 35% silent passive checkpoint — preserves prior behavior as PreCompact feed.
    # Don't clobber manual ones: that clause is now enforced by predicate, not by
    # prose. checkpoint_guarded_write (hooks/lib/checkpoint-guard.sh) preserves a
    # RICH checkpoint at ANY age and refuses to put this stub over a structured
    # block; mtime freshness is retained only as a write THROTTLE, never as the
    # clobber guard it used to be (this stub carries no state to trade for a
    # manual /session-checkpoint, and age raises that record's value). rc 10 =
    # preserved, a normal outcome, so the call is guarded under `set -e`.
    if ! $checkpoint_fresh && [[ -n "$CHECKPOINT_FILE" ]]; then
      checkpoint_guarded_write "$CHECKPOINT_FILE" <<CKPT || true
# Auto-checkpoint at ${pct}% context — $(date -Iseconds)
# Passive 35% silent capture — feeds PreCompact hook
CKPT
    fi
  fi

  if [[ -n "$r26_band" ]]; then
    _last_band=$(cat "$BAND_MARKER" 2>/dev/null || true)
    if [[ "$r26_band" != "$_last_band" ]]; then
      if [[ "$r26_band" == mandate ]]; then
        r26_banner="CONTEXT PRESSURE ${band_pct}% — context use is high. Run /session-checkpoint now, then /compact to continue from a model-authored restore, or start a fresh session."
      else
        r26_banner="CONTEXT PRESSURE ${band_pct}% — context use is climbing. At the next natural break, run /session-checkpoint, then /compact to continue from a model-authored restore, or start a fresh session."
      fi
      printf '%s\n' "$r26_band" > "$BAND_MARKER" 2>/dev/null || true
      r26_banner_fired=true
    fi
  else
    rm -f "$BAND_MARKER" 2>/dev/null || true
  fi
fi

# One stdout JSON object per prompt: the user-facing banner (when this prompt raised
# one) and the model-facing context compose into a single payload on every exit path.
emit_prompt_output() {
  local ctx="${1:-}"
  if [[ -n "$r26_banner" ]]; then
    format_output_user_notice "UserPromptSubmit" "$r26_banner" "$ctx"
  elif [[ -n "$ctx" ]]; then
    format_output "UserPromptSubmit" "$ctx"
  fi
}

# ---: memory-review re-firing band — YIELDS to R-26 ---
# Escalates a UserPromptSubmit mandate for aged (high-severity pending >3d) or
# defer_count≥2 review items. The band NEVER competes with the R-26 pressure
# banner: it stays silent on a prompt that raised the banner (r26_banner_fired) and
# fires ONLY when pressure_context is empty. Clear-condition: the item leaves the
# queue only on explicit confirm OR reject-with-reason (never silent dismiss /
# session-exit / bare defer) — enforced at the queue layer, so the mandate re-fires
# every prompt until then.
# The aged/defer thresholds are resolved env > user-manifest.json ::
# hooks.memory_review > default inside review-queue.sh.
if [[ -z "$pressure_context" ]] && ! $r26_banner_fired \
   && command -v review_queue_has_aged_or_deferred >/dev/null 2>&1; then
  if ! { command -v memory_review_opt_out >/dev/null 2>&1 && memory_review_opt_out; }; then
    if review_queue_has_aged_or_deferred; then
      pressure_context="MEMORY REVIEW MANDATE — one or more aged/high-severity memory-review items are pending (>3d high-severity, or deferred ≥2 times). At the next natural task boundary, run /librarian review to address them: each item clears ONLY on explicit confirm OR reject-with-reason. This mandate re-fires every prompt until the queue clears, and YIELDS to the R-26 context-pressure banner + the ≥80% context-pressure valve (session-continuity always wins)."
    fi
  fi
fi

# stdin + SESSION_ID parsed at top (T-2). Re-check empty case here:
if [[ -z "$SESSION_ID" ]]; then
  # No session ID but we may still have pressure / memory-review context
  emit_prompt_output "$pressure_context"
  exit 0
fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

# Read registry under lock (2s timeout — skip on contention). An rc 75
# appends ONE skip line via the shared helper above so the degrade is diagnosable;
# any other rc — e.g. cat on a missing registry file, a normal early-session state
# with the lock free — keeps today's silent pressure-only degrade with NO contention
# line (only contention may name itself).
reg=$(lockf -k -t 2 "$REGISTRY_LOCK" cat "$REGISTRY_FILE" 2>/dev/null) || {
  _pc_read_rc=$?
  if [ "$_pc_read_rc" -eq 75 ]; then
    log_registry_skip
  fi
  # Registry unavailable — still emit pressure warnings
  emit_prompt_output "$pressure_context"
  exit 0
}

# Apply the PID-liveness view ONCE, immediately after the locked read, so the
# fast-path peer count, the lib peer/overlap summaries, AND the is_close close-mode
# active_count all see only sessions whose recorded pid is actually alive. Dead/null-
# pid `active` rows are removed view-only (the registry file is NOT rewritten;
# physical reaping stays with reconcile-sessions.sh). Degrades to `reg` unchanged
# when jq is absent or no rows are stale.
reg=$(registry_live_view "$reg")

# Fast path: only our own session → silent
peer_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
  '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active" or .value.status == "closing" or .value.status == "closed-pending-reconciliation")] | length')
if (( peer_count == 0 )); then
  # No peers, but may still have pressure context
  emit_prompt_output "$pressure_context"
  exit 0
fi

# Detect session-close in prompt for enhanced context
is_close=false
if echo "$PROMPT" | grep -qi 'session-close\|/librarian.*close'; then
  is_close=true
fi

context=""

# Pending reconciliation check
pending_info=$(get_pending_info "$reg" "$SESSION_ID")
if [[ -n "$pending_info" ]]; then
  context="$pending_info"
fi

# Peer summary
peer_summary=$(get_peer_summary "$reg" "$SESSION_ID")
if [[ -n "$peer_summary" ]]; then
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}${peer_summary}"
fi

# File overlaps
overlaps=$(get_file_overlaps "$reg" "$SESSION_ID")
if [[ -n "$overlaps" ]]; then
  overlap_list=$(echo "$overlaps" | head -10 | tr '\n' ', ' | sed 's/,$//')
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}Warning: Overlapping files with peer sessions: ${overlap_list}. Re-read before editing."
fi

# Enhanced context for session-close
if $is_close; then
  # Full peer detail for close coordination
  close_detail=$(echo "$reg" | jq -r --arg sid "$SESSION_ID" '
    .sessions | to_entries[] | select(.key != $sid) |
    "- \(.key[0:8])... status=\(.value.status) files=\(.value.touched_files | length) close_summary=\"\(.value.close_summary // "")\""
  ')

  active_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active")] | length')
  pending_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "closed-pending-reconciliation")] | length')

  # Recommend close mode
  if (( active_count > 0 )); then
    mode="scoped (other sessions still active)"
  elif (( pending_count > 0 )); then
    mode="reconciler (last active session, pending peers need reconciliation)"
  else
    mode="solo (no coordination needed)"
  fi

  context="${context}

SESSION CLOSE COORDINATION:
Peer sessions:
${close_detail}
Recommended close mode: ${mode}
pending_reconciliation: $(echo "$reg" | jq -r '.pending_reconciliation')"
fi

# Merge pressure context with peer context
if [[ -n "$pressure_context" ]]; then
  if [[ -n "$context" ]]; then
    context="${pressure_context}

${context}"
  else
    context="$pressure_context"
  fi
fi

emit_prompt_output "$context"

exit 0

#!/bin/bash
# Hook: SessionStart — memory-review banner.
# Names pending review-queue counts + the /librarian review command. Reads
# .review-queue.json via hooks/lib/review-queue.sh.
#
# Surfacing contract:
#   - Names pending counts + the /librarian review command.
#   - Revalidation (STALE ≥180d, low-severity) surfaces as a SINGLE aggregated
#     banner line ("N memories due for revalidation"); revalidation is EXEMPT
#     from the 3-strike auto-suppress; at ≥360d EXPIRED it escalates to
#     medium-severity itemized {revalidate|supersede|archive} (handled at
#     enqueue time by the producer — the banner counts what is open).
#   - Anti-fatigue: low-severity hygiene findings auto-suppress after 3 ignores
#     (suppression is applied at the queue layer; the banner is advisory and
#     never blocks).
#
# NEVER fail-hard: the final `exit 0` is mandatory — a SessionStart hook that
# non-zero exits can break the user's session. The banner is advisory only.
set -uo pipefail

# Portability: source lib via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/registry.sh" 2>/dev/null || true
[ -r "$SCRIPT_DIR/lib/review-queue.sh" ] && source "$SCRIPT_DIR/lib/review-queue.sh"

# Drain stdin (SessionStart JSON payload) so we never block; we don't read it.
# BOUNDED drain: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook chain hangs with zero output. The
# bound is PER READ: a stream that keeps delivering is never truncated, only silence
# is. HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE; do :; done
  unset _STDIN_WAIT _STDIN_LINE
fi

# Emit one SessionStart object via the additionalContext helper when available; else
# a plain stderr advisory. Never block; never deny.
emit_banner() {
  if command -v format_output_allow >/dev/null 2>&1; then
    format_output_allow "SessionStart" "$1" || true
  else
    printf '%s\n' "$1" >&2
  fi
}

# Library promotion line, composed before the early exits below so it surfaces with
# no review items and with memory review opted out. It reads the library-scrub.sh
# modes only: the mode, then --pending for queued and failed candidates. A promoted
# plan is named from the capability's own output of an automatic promotion, whose
# promoted line is printed only after the library_refs stamps are re-read; that log
# is renamed once shown, so each plan is named once. While the mode reads `off`
# (unset included) nothing is scanned, and the only output is a one-time notice.
lp_line=""
_lp_host=""
for _c in "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/library-scrub.sh" \
          "$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)/skills/librarian/capabilities/library-scrub.sh"; do
  if [ -f "$_c" ]; then _lp_host="$_c"; break; fi
done
unset _c
if [ -n "$_lp_host" ]; then
  _lp_state="${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-$HOME/.local/state/brain-stem}/hooks-state}"
  case "$(bash "$_lp_host" --mode get 2>/dev/null </dev/null)" in
    prompt|auto)
      _lp_pending="$(bash "$_lp_host" --pending 2>/dev/null </dev/null)"
      _lp_queued="$(printf '%s\n' "$_lp_pending" | awk -F'\t' '
        NF >= 5 && $5 !~ /^reason=(triage failed|promotion incomplete|answer )/ {
          st = substr($2, 7); if (st == "pending") st = "awaiting triage"
          if ($3 != "claimed=-") st = st ", offered"
          out = out (out == "" ? "" : ", ") $1 " (" st ")"
        } END { print out }')"
      _lp_failed="$(printf '%s\n' "$_lp_pending" | awk -F'\t' '
        NF >= 5 && $5 ~ /^reason=(triage failed|promotion incomplete|answer )/ {
          out = out (out == "" ? "" : "; ") $1 " (" substr($5, 8) ")"
        } END { print out }')"
      _lp_promoted=""
      _lp_log="$_lp_state/library-promotion-auto.log"
      if [ -f "$_lp_log" ] && mv -f "$_lp_log" "$_lp_log.shown" 2>/dev/null; then
        _lp_promoted="$(sed -n 's/^library-scrub: \([^ ]*\) promoted (.*stamps verified$/\1/p' "$_lp_log.shown" \
          | awk '{ out = out (out == "" ? "" : ", ") $0 } END { print out }')"
      fi
      if [ -n "$_lp_queued$_lp_failed$_lp_promoted" ]; then
        lp_line="[Library promotion]"
        [ -n "$_lp_queued" ] && lp_line="${lp_line} Queued: ${_lp_queued}."
        [ -n "$_lp_promoted" ] && lp_line="${lp_line} Promoted to the shared library: ${_lp_promoted}."
        [ -n "$_lp_failed" ] && lp_line="${lp_line} Failed: ${_lp_failed}."
        [ -n "$_lp_queued$_lp_failed" ] && lp_line="${lp_line} Answer with: bash $_lp_host --answer <plan> yes|no|always."
      fi ;;
    *)
      if [ ! -e "$_lp_state/library-promotion-notice-shown" ]; then
        lp_line="[Library promotion] Off. When on, a newly completed plan's research can be offered for the shared library: run bash $_lp_host --mode set prompt (or auto). This notice shows once."
        mkdir -p "$_lp_state" 2>/dev/null && : > "$_lp_state/library-promotion-notice-shown" 2>/dev/null
      fi ;;
  esac
fi
# The early exits below still print the library-promotion line, as one object.
exit_banner() {
  [ -n "$lp_line" ] && emit_banner "$lp_line"
  exit 0
}

# Opt-out check (user-manifest.json :: hooks.memory_review.enabled == false).
if command -v memory_review_opt_out >/dev/null 2>&1 && memory_review_opt_out; then
  exit_banner
fi

# The queue lib must be present to surface anything; degrade silently otherwise.
command -v review_queue_pending_count >/dev/null 2>&1 || exit_banner

pending="$(review_queue_pending_count 2>/dev/null || echo 0)"
reval="$(review_queue_revalidation_count 2>/dev/null || echo 0)"

# Nothing open → no memory-review banner.
if [ "${pending:-0}" -le 0 ]; then
  exit_banner
fi

# Compose the advisory banner. Revalidation is aggregated into one line; the
# remaining (hygiene/conflict/promotion) pending count is named separately.
non_reval=$(( pending - reval ))
[ "$non_reval" -lt 0 ] && non_reval=0

banner="[Memory review] ${pending} item(s) awaiting review. Run /librarian review to address them (confirm or reject-with-reason; deferring is capped)."
if [ "${reval:-0}" -gt 0 ]; then
  banner="${banner}
- ${reval} memory(ies) due for revalidation."
fi
if [ "$non_reval" -gt 0 ]; then
  banner="${banner}
- ${non_reval} consolidation/promotion/conflict item(s) pending."
fi
if [ -n "$lp_line" ]; then
  banner="${banner}
${lp_line}"
fi

emit_banner "$banner"

exit 0

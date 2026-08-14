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

# Opt-out check (user-manifest.json :: hooks.memory_review.enabled == false).
if command -v memory_review_opt_out >/dev/null 2>&1 && memory_review_opt_out; then
  exit 0
fi

# The queue lib must be present to surface anything; degrade silently otherwise.
command -v review_queue_pending_count >/dev/null 2>&1 || exit 0

pending="$(review_queue_pending_count 2>/dev/null || echo 0)"
reval="$(review_queue_revalidation_count 2>/dev/null || echo 0)"

# Nothing open → no banner.
if [ "${pending:-0}" -le 0 ]; then
  exit 0
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

# Emit via the SessionStart additionalContext helper when available; else a
# plain stderr advisory. Never block; never deny.
if command -v format_output_allow >/dev/null 2>&1; then
  format_output_allow "SessionStart" "$banner" || true
else
  printf '%s\n' "$banner" >&2
fi

exit 0

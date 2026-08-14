#!/bin/bash
# Hook: statusLine — orchestrator/worker status string.
# C3/S2-owned body in a C2 slot (canonical/statusLine ->
# worker-statusline.sh). Emits a SINGLE status line describing the
# orchestrator/worker state (load-bearing + cosmetic; shipped in v1.0.0).
# Claude Code renders stdout as the status
# line, so the body must print exactly one line and exit 0 — even when there is
# no active worker.
# State read (best-effort, machine-local): the F0 circuit-breaker sentinel +
# the recent-verdicts log under the orchestrator state dir. NEVER fail-hard.
set -uo pipefail

# Portability (LOCK): resolve libs via $SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || true

# Drain stdin (statusLine JSON payload: model/cwd/etc.) so we never block; the
# status here is orchestrator-global, not prompt-derived.
# BOUNDED drain: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the status line never renders. The bound is
# PER READ: a stream that keeps delivering is never truncated, only silence is.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE; do :; done
  unset _STDIN_WAIT _STDIN_LINE
fi

STATE_DIR="${ORCHESTRATOR_STATE_DIR:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/runtime}"
SENTINEL="$STATE_DIR/dispatch-halted.sentinel"
VERDICTS="$STATE_DIR/recent-verdicts.jsonl"

# Circuit-breaker engaged takes precedence — surface it loudly.
if [ -f "$SENTINEL" ]; then
  printf 'orchestrator: HALTED (F0 circuit-breaker engaged — dispatch.sh --circuit-breaker-status)\n'
  exit 0
fi

# Recent dispatch activity: report the count of recorded verdicts if the log
# exists + is non-empty. No-active-worker -> idle line.
if [ -f "$VERDICTS" ] && [ -s "$VERDICTS" ]; then
  n=$(wc -l < "$VERDICTS" 2>/dev/null | tr -d ' ')
  [ -z "$n" ] && n=0
  printf 'orchestrator: ok (%s recent verdict(s))\n' "$n"
  exit 0
fi

# Default: no active worker / clean idle.
printf 'orchestrator: idle (no active workers)\n'
exit 0

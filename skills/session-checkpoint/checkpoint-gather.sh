#!/bin/bash
# skills/session-checkpoint/checkpoint-gather.sh — the mechanical steps of /session-checkpoint as one command.
#
#   checkpoint-gather.sh [--path FILE] < fields
#   checkpoint-gather.sh --help
#
# The model writes the nine session fields on stdin (three `<name>: <value>` lines and six
# `## <name>` sections: plan_id, phase, task_id, completed_steps, files_modified, key_decisions,
# next_steps, ac_status, current_blocker). This command resolves the per-session directory,
# reads context pressure for the tenth field, stamps the block header and the Action Required
# tail, validates the fields, stages the block beside the target, renames it into place and
# verifies the result. A missing, duplicated or empty field is a refusal naming that field; a
# partial checkpoint is never written.
#
# Target: $CLAUDE_STATE_ROOT/sessions/<sid>/checkpoint.md, where <sid> is the first non-empty of
# CLAUDE_SESSION_ID and CLAUDE_CODE_SESSION_ID. --path FILE replaces it (and the session id is
# then not consulted): an absolute path ending in /sessions/<sid>/checkpoint.md, <sid> one plain
# directory name. The pressure file is context-pressure.json in the target's directory.
#
# The write is a plain overwrite, not checkpoint_guarded_write: a second checkpoint in one
# session replaces the first, and no dated variant is made.
#
# Exit codes: 0 written and verified; 1 staging, rename or verify failed (the prior checkpoint is
# left in place); 2 refused (bad option, unresolved target, empty or malformed fields; nothing
# written, no directory created). Refusal precedence, first hit wins: option parse, paths.sh
# readable, target resolution, stdin, fields.
#
# HOOKS_STDIN_WAIT bounds each stdin read in whole seconds; unset, zero or non-numeric falls
# back to the built-in wait (a zero would arm no timer on bash 3.2). The bound is per read: a
# stream that delivers its fields and then stalls is validated as received, and a stream with
# nothing on it is a refusal, never a hang.
#
# No derivation is bound to this file: the checkpoint is ephemeral per-session state, and the
# command touches no plan manifest, handoff or tasks.md, so it calls no hook and no capability.
#
# Bash 3.2 clean. Fields are copied through temp files, never held in a shell variable, so
# backslashes, $, backticks, %s, blank lines and leading or trailing spaces survive byte for byte.
set -u

PROG="checkpoint-gather"
FIELDS_TMP=""
STAGE=""

cleanup() {
  if [ -n "$FIELDS_TMP" ]; then rm -f "$FIELDS_TMP"; fi
  if [ -n "$STAGE" ]; then rm -f "$STAGE"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

refuse() { printf '%s: refused: %s\n' "$PROG" "$1" >&2; exit 2; }
write_failed() { printf '%s: write failed: %s\n' "$PROG" "$1" >&2; exit 1; }
verify_failed() { printf '%s: verify failed: %s\n' "$PROG" "$1" >&2; exit 1; }

# ---- option parse -------------------------------------------------------------------
PATH_ARG=""
PATH_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help)
      printf '%s\n' 'usage: checkpoint-gather.sh [--path FILE] < fields'
      printf '%s\n' '  Reads the nine session fields from stdin and writes the Session Continuity Block'
      printf '%s\n' '  to $CLAUDE_STATE_ROOT/sessions/<sid>/checkpoint.md, then prints one line.'
      printf '%s\n' '  --path FILE  write FILE instead: absolute, ending in /sessions/<sid>/checkpoint.md'
      printf '%s\n' '  exit: 0 written and verified, 1 write or verify failed, 2 refused'
      exit 0
      ;;
    --path)
      if [ "$PATH_GIVEN" -ne 0 ]; then refuse '--path given more than once'; fi
      PATH_GIVEN=1
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse '--path needs a non-empty value'; fi
      PATH_ARG="$2"
      shift 2
      ;;
    *)
      refuse "unknown option '$1'"
      ;;
  esac
done

# ---- paths.sh -----------------------------------------------------------------------
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ ! -r "$PATHS_SH" ]; then refuse "$PATHS_SH is not readable"; fi
if ! . "$PATHS_SH"; then refuse "$PATHS_SH failed to load"; fi

# ---- target resolution --------------------------------------------------------------
if [ -n "$PATH_ARG" ]; then
  BAD_PATH='--path must be an absolute path ending in /sessions/<sid>/checkpoint.md'
  case "$PATH_ARG" in /*) ;; *) refuse "$BAD_PATH" ;; esac
  case "$PATH_ARG" in */checkpoint.md) ;; *) refuse "$BAD_PATH" ;; esac
  case "/$PATH_ARG/" in */../*) refuse "$BAD_PATH" ;; esac
  DIR="${PATH_ARG%/checkpoint.md}"
  case "${DIR##*/}" in ''|.|..) refuse "$BAD_PATH" ;; esac
  case "${DIR%/*}" in */sessions) ;; *) refuse "$BAD_PATH" ;; esac
  TARGET="$PATH_ARG"
else
  SID="${CLAUDE_SESSION_ID:-}"
  if [ -z "$SID" ]; then SID="${CLAUDE_CODE_SESSION_ID:-}"; fi
  if [ -z "$SID" ]; then
    refuse 'session id unresolved (CLAUDE_SESSION_ID and CLAUDE_CODE_SESSION_ID are empty); pass --path with the exact sessions/<sid>/checkpoint.md path from the Stop-gate message'
  fi
  case "$SID" in .|..|*/*) refuse "session id '$SID' does not name one directory" ;; esac
  DIR="$CLAUDE_STATE_ROOT/sessions/$SID"
  TARGET="$DIR/checkpoint.md"
fi
PRESSURE_FILE="$DIR/context-pressure.json"

# ---- stdin: every read bounded, to a temp file -------------------------------------
WAIT="${HOOKS_STDIN_WAIT:-}"
case "$WAIT" in ''|0|*[!0-9]*) WAIT=5 ;; esac
if ! FIELDS_TMP=$(mktemp "${TMPDIR:-/tmp}/checkpoint-gather-fields.XXXXXX" 2>/dev/null); then
  FIELDS_TMP=""
  write_failed "cannot create a temp file under ${TMPDIR:-/tmp}"
fi
LINE=""
{
  while IFS= read -r -t "$WAIT" LINE; do
    printf '%s\n' "$LINE"
    LINE=""
  done
  # A timed-out read leaves the variable untouched on bash 3.2, so it was cleared above; a last
  # line with no newline arrives here and gets exactly one.
  if [ -n "$LINE" ]; then printf '%s\n' "$LINE"; fi
} > "$FIELDS_TMP"
if [ ! -s "$FIELDS_TMP" ]; then
  refuse "no fields arrived on stdin within ${WAIT}s; nothing was written"
fi

# ---- fields -------------------------------------------------------------------------
# Lines the command writes itself are checked first: a model-supplied one would change what
# the block is (a mechanical-provenance Source line would make it a refreshable snapshot).
while IFS= read -r LINE; do
  case "$LINE" in
    '# Session Continuity Block'*) SELF='# Session Continuity Block' ;;
    '**Generated:**'*) SELF='**Generated:**' ;;
    '**Source:**'*) SELF='**Source:**' ;;
    '**context_pct_at_checkpoint:**'*) SELF='**context_pct_at_checkpoint:**' ;;
    '## Action Required'*) SELF='## Action Required' ;;
    *) continue ;;
  esac
  refuse "the command writes the '$SELF' line itself; remove it from the fields"
done < "$FIELDS_TMP"

# Names in template order: the first defective field wins. The first three are one-line
# scalars, the other six are `## <name>` sections whose body runs to the next `## ` line.
NAMES=(plan_id phase task_id completed_steps files_modified key_decisions next_steps ac_status current_blocker)
COUNT=(0 0 0 0 0 0 0 0 0)
FILLED=(0 0 0 0 0 0 0 0 0)
CUR=-1
while IFS= read -r LINE; do
  case "$LINE" in
    '## '*)
      CUR=-1
      I=3
      while [ "$I" -le 8 ]; do
        if [ "$LINE" = "## ${NAMES[$I]}" ]; then
          COUNT[$I]=$(( ${COUNT[$I]} + 1 ))
          CUR=$I
        fi
        I=$(( I + 1 ))
      done
      ;;
    *)
      case "$LINE" in
        *[![:space:]]*) if [ "$CUR" -ge 0 ]; then FILLED[$CUR]=1; fi ;;
      esac
      I=0
      while [ "$I" -le 2 ]; do
        N="${NAMES[$I]}"
        case "$LINE" in
          "$N:"|"$N: "*)
            COUNT[$I]=$(( ${COUNT[$I]} + 1 ))
            REST="${LINE#"$N:"}"
            case "$REST" in *[![:space:]]*) FILLED[$I]=1 ;; esac
            ;;
        esac
        I=$(( I + 1 ))
      done
      ;;
  esac
done < "$FIELDS_TMP"
I=0
while [ "$I" -le 8 ]; do
  N="${NAMES[$I]}"
  if [ "${COUNT[$I]}" -eq 0 ]; then refuse "field '$N' is missing"; fi
  if [ "${COUNT[$I]}" -gt 1 ]; then refuse "field '$N' appears more than once"; fi
  if [ "$N" != current_blocker ] && [ "${FILLED[$I]}" -eq 0 ]; then
    refuse "field '$N' is empty; write [MISSING] or []"
  fi
  I=$(( I + 1 ))
done

# ---- context pressure (the tenth field) ---------------------------------------------
PCT=""
if [ -f "$PRESSURE_FILE" ]; then
  # jq prints the value before it reaches trailing garbage, so a non-zero exit voids the read.
  PCT=$(jq -r '.pct' "$PRESSURE_FILE" 2>/dev/null)
  if [ $? -ne 0 ]; then PCT=""; fi
fi
case "$PCT" in ''|*[!0-9]*) PCT='[MISSING]' ;; esac

# ---- stage, rename, verify ----------------------------------------------------------
if ! mkdir -p "$DIR" 2>/dev/null; then write_failed "cannot stage $DIR"; fi
STAGE="$DIR/checkpoint.md.tmp.$$"
# The status is read on the next line, not negated with `if !`: on bash 3.2 a failed redirect on a
# negated group reports success.
{
  printf '%s\n' '# Session Continuity Block' &&
  printf '**Generated:** %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" &&
  printf '%s\n' '**Source:** /session-checkpoint skill — manual or enforcement invocation' &&
  printf '**context_pct_at_checkpoint:** %s\n' "$PCT" &&
  printf '\n' &&
  cat "$FIELDS_TMP" &&
  printf '\n' &&
  printf '%s\n' '## Action Required' &&
  printf '%s\n' '- Resume from this checkpoint in a fresh session' &&
  printf '%s\n' '- Re-read files listed under files_modified before continuing edits' &&
  printf '%s\n' '- Verify next_steps still valid against current plan state'
} 2>/dev/null > "$STAGE"
if [ $? -ne 0 ]; then
  write_failed "cannot stage $DIR"
fi
if ! mv "$STAGE" "$TARGET" 2>/dev/null; then write_failed "cannot rename $STAGE"; fi

if [ ! -f "$TARGET" ]; then verify_failed "$TARGET does not exist"; fi
if [ ! -s "$TARGET" ]; then verify_failed "$TARGET is empty"; fi
MTIME=$(stat -f %m "$TARGET" 2>/dev/null)
case "$MTIME" in
  ''|*[!0-9]*) MTIME=$(stat -c %Y "$TARGET" 2>/dev/null) ;;
esac
case "$MTIME" in ''|*[!0-9]*) verify_failed 'cannot read mtime' ;; esac
AGE=$(( $(date +%s) - MTIME ))
if [ "$AGE" -lt 0 ]; then AGE=$(( 0 - AGE )); fi
if [ "$AGE" -gt 5 ]; then verify_failed "$TARGET mtime is ${AGE}s from now"; fi

printf '%s: wrote %s (context_pct_at_checkpoint: %s)\n' "$PROG" "$TARGET" "$PCT"
exit 0

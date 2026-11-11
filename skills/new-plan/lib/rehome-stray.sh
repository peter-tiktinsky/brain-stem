#!/usr/bin/env bash
# rehome-stray.sh - re-home one stray plans-root entry (an open placement finding) into the
# `_research/` of the plan that owns it, then run what a session close would have run and
# re-sweep.
#
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/rehome-stray.sh <entry> --into <plan-key> [--plans-root DIR]
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/rehome-stray.sh <entry> --mint <slug> --disposition <value> --body <text> \
#        [--title T] [--absorbed-into K] [--release-class C --size S] [--reopen-gate ID] [--project P] [--plans-root DIR]
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/rehome-stray.sh <entry> --discard --reason <text> [--plans-root DIR]
#
# <entry> is relative to the plans root exactly as the SessionStart banner prints it: a bare name,
# or _projects/<spoke>/<name>. --into names an existing plan (NN-<slug> or NN-<slug>/SS-<sub>, a
# directory under the root holding manifest.json). --mint first captures a decided idea note,
# triages it (NOVEL, the entry named as the rationale; a graduation needs a triaged note) and
# graduates it into a new plan through promote-from-inbox.sh, then re-homes the entry into that plan.
#
# CHECKS, in order, the first that fails is the one reported: (1) the arguments; (2) the entry
# shape; (3) for --into, the plan key resolving; (4) the source state (a source that is absent with
# --into and <plan>/_research/<name> present is the resume branch, which skips (5); any other absent
# source is refused); (5) a present source must be an open placement finding, read from a
# placement-validate sweep of the plans root; (6) for --into, the destination must not exist.
#
# THEN, in order: the move into <plan>/_research/<name> (a PATH-resolved plain mv, never over an
# existing path); plan-research-declare.sh --spoke <project> (the session-close declare);
# post-manifest-binder-refresh.sh <absolute destination> with stdin from /dev/null (the PostToolUse
# artifact trigger); and the sweep again, after which the entry must be absent. A derivation that
# fails or is missing prints a NOTE and the command goes on. Every child call carries PLANS_ROOT and
# PLANS_DIR both equal to the resolved root.
#
# RESUME: with the source gone and <plan>/_research/<name> present, --into skips the move and runs
# the derivations and one sweep. A call stopped after a --mint capture or graduation is finished
# with the printed re-run command.
#
# DISCARD: --discard --reason <text> is for an entry that is not a durable artifact. It is exclusive
# with --into and --mint and takes no mint flag. It runs checks (1) to (5) (no resume branch: an
# absent entry is refused), then moves the entry with a PATH-resolved plain mv, never over an
# existing path, to $CLAUDE_STATE_ROOT/discarded-strays/<UTC YYYYmmddTHHMMSSZ>-<entry with each /
# replaced by __>, appends one JSON line {entry, reason, discarded_at, moved_to} to
# $CLAUDE_STATE_ROOT/discarded-strays/log.jsonl, and sweeps again, after which the entry must be
# absent. Nothing is deleted: the entry stays recoverable from the state tier. No research declare
# and no binder refresh run. A call whose state root cannot be resolved (paths.sh missing and
# CLAUDE_STATE_ROOT unset or empty) is refused before any check.
#
# EXIT CODES: 0 done; 2 refused with every byte unchanged; 1 stopped after a partial step, the
# message naming the resume command. A refusal prints `rehome-stray: refused: <reason>`.
#
# The plans root is --plans-root, else PLANS_ROOT, else PLANS_DIR as hooks/lib/paths.sh resolves it,
# else $HOME/.claude-plans; a trailing slash is stripped and the resolved root is exported as both
# PLANS_ROOT and PLANS_DIR before any child runs. No lock is taken. This command never runs
# backlog-index and never writes _backlog.md: run /librarian backlog-index to refresh it.
#
# Bash 3.2 clean. Event lines are read with jq; no python, no piped stdin to an interpreter.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$0"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../hooks/lib/paths.sh" 2>/dev/null || true
set -u

TD=""

usage() {
  printf 'usage: rehome-stray <entry> --into <plan-key> | --mint <slug> --disposition <value> --body <text> [--title T] [--absorbed-into K] [--release-class C --size S] [--reopen-gate ID] [--project P] [--plans-root DIR] | --discard --reason <text> [--plans-root DIR]\n'
  printf 'exit: 0 re-homed; 2 refused (nothing changed); 1 stopped (the message names the re-run)\n'
  printf 'run /librarian backlog-index afterwards to refresh _backlog.md\n'
}

finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$TD" ]; then rm -rf -- "$TD"; fi
  TD=""
  exit "$rc"
}
trap finish EXIT INT TERM HUP

refuse() {
  printf 'rehome-stray: refused: %s\n' "$1" >&2
  exit 2
}

note() {
  printf 'NOTE: %s\n' "$1" >&2
}

ENTRY=""; GOT_ENTRY=0
INTO=""; MINT=""; DISP=""; BODY=""; TITLE=""; ABSORB=""; RCLASS=""; SIZE=""; GATE=""; PROJ=""; ROOT_FLAG=""
DISCARD=0; REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --discard) DISCARD=1; shift ;;
    --into|--mint|--disposition|--body|--title|--absorbed-into|--release-class|--size|--reopen-gate|--project|--plans-root|--reason)
      FLAG="$1"
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "$FLAG needs a non-empty value"; fi
      case "$FLAG" in
        --into) INTO="$2" ;;
        --mint) MINT="$2" ;;
        --disposition) DISP="$2" ;;
        --body) BODY="$2" ;;
        --title) TITLE="$2" ;;
        --absorbed-into) ABSORB="$2" ;;
        --release-class) RCLASS="$2" ;;
        --size) SIZE="$2" ;;
        --reopen-gate) GATE="$2" ;;
        --project) PROJ="$2" ;;
        --plans-root) ROOT_FLAG="$2" ;;
        --reason) REASON="$2" ;;
      esac
      shift 2 ;;
    -*) refuse "unknown flag '$1'" ;;
    *)
      if [ "$GOT_ENTRY" = 1 ]; then refuse "unexpected argument '$1'"; fi
      ENTRY="$1"; GOT_ENTRY=1; shift ;;
  esac
done
if [ "$GOT_ENTRY" != 1 ]; then refuse "needs an entry"; fi
if [ "$DISCARD" = 1 ]; then
  if [ -n "$INTO" ]; then refuse "--discard and --into are exclusive"; fi
  if [ -n "$MINT" ]; then refuse "--discard and --mint are exclusive"; fi
  if [ -n "$DISP$BODY$TITLE$ABSORB$RCLASS$SIZE$GATE$PROJ" ]; then refuse "--discard takes only --reason and --plans-root"; fi
  if [ -z "$REASON" ]; then refuse "--discard needs --reason"; fi
  if [ -z "${CLAUDE_STATE_ROOT:-}" ]; then refuse "CLAUDE_STATE_ROOT is unresolved"; fi
else
  if [ -n "$INTO" ] && [ -n "$MINT" ]; then refuse "--into and --mint are exclusive"; fi
  if [ -z "$INTO" ] && [ -z "$MINT" ]; then refuse "needs --into or --mint"; fi
  if [ -n "$INTO" ] && [ -n "$DISP$BODY$TITLE$ABSORB$RCLASS$SIZE$GATE$PROJ" ]; then refuse "--into takes no mint flags"; fi
  if [ -n "$MINT" ] && { [ -z "$DISP" ] || [ -z "$BODY" ]; }; then refuse "--mint needs --disposition and --body"; fi
fi
command -v jq >/dev/null 2>&1 || refuse "jq is required"

# (2) the entry shape: a bare name, or _projects/<spoke>/<name>
entry_ok() {
  local e="$1" r b n
  [ -n "$e" ] || return 1
  case "$e" in /*) return 1 ;; esac
  case "/$e/" in */../*|*/./*|*//*) return 1 ;; esac
  case "$e" in
    */*)
      [ "${e%%/*}" = "_projects" ] || return 1
      r="${e#*/}"
      case "$r" in */*) ;; *) return 1 ;; esac
      b="${r%%/*}"; n="${r#*/}"
      [ -n "$b" ] && [ -n "$n" ] || return 1
      case "$n" in */*) return 1 ;; esac ;;
  esac
  return 0
}
entry_ok "$ENTRY" || refuse "entry must be a bare name or _projects/<spoke>/<name>, relative to the plans root"

ROOT="${ROOT_FLAG:-${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}}"
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac
while [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done
export PLANS_ROOT="$ROOT" PLANS_DIR="$ROOT"
unset FINDINGS_OUTPUT

CH="${CLAUDE_HOME:-$HOME/.claude}"
PV="$CH/skills/librarian/capabilities/placement-validate.sh"
DECL="$CH/skills/librarian/capabilities/plan-research-declare.sh"
HOOK="$CH/hooks/post-manifest-binder-refresh.sh"
HELPER="$CH/skills/new-plan/lib/promote-from-inbox.sh"
TRIAGE="$CH/skills/backlog-triage/scripts/triage-apply.sh"

NAME="${ENTRY##*/}"
SRC="$ROOT/$ENTRY"
PLAN=""; DEST=""; RESUME=0; MINTED=0

# (3) for --into, the plan key resolving
if [ -n "$INTO" ]; then
  case "$INTO" in
    ''|/*|*/|*//*|.*|_*|*/.*|*/_*|*..*) refuse "plan '$INTO' does not resolve to a plan dir" ;;
  esac
  case "$INTO" in */*/*) refuse "plan '$INTO' does not resolve to a plan dir" ;; esac
  [ -f "$ROOT/$INTO/manifest.json" ] || refuse "plan '$INTO' does not resolve to a plan dir"
  PLAN="$INTO"
  DEST="$ROOT/$PLAN/_research/$NAME"
fi

# (4) the source state
if [ ! -e "$SRC" ] && [ ! -L "$SRC" ]; then
  if [ -n "$INTO" ] && { [ -e "$DEST" ] || [ -L "$DEST" ]; }; then
    RESUME=1
  else
    refuse "no such entry '$ENTRY'"
  fi
fi

[ -f "$PV" ] || refuse "placement-validate capability not found at $PV"
if [ -n "$MINT" ] && [ ! -f "$HELPER" ]; then refuse "promote-from-inbox helper not found at $HELPER"; fi
if [ -n "$MINT" ] && [ ! -f "$TRIAGE" ]; then refuse "triage-apply not found at $TRIAGE"; fi

TD="$(mktemp -d "${TMPDIR:-/tmp}/rehome-stray.XXXXXX")" || refuse "could not create a temp directory"

# sweep <findings file>: one placement sweep of the plans root; the capability's rc
sweep() {
  : > "$1"
  FINDINGS_OUTPUT="$1" bash "$PV" --scope "$ROOT" </dev/null >/dev/null 2>"$TD/sweep.err"
}
# open_count <findings file> <entry>: how many findings name the entry
open_count() {
  local n
  n="$(jq -rR --arg e "$2" 'fromjson? | select(type == "object" and .entry == $e) | .entry' "$1" 2>/dev/null | grep -c .)"
  printf '%s\n' "${n:-0}"
}
# stray_count <findings file>: the findings that are open strays (an advisory kind is not counted)
stray_count() {
  local n
  n="$(jq -rR 'fromjson? | select(type == "object" and (.finding == "plans-root-namespace-violation" or .finding == "binder-root-stray-entry")) | .finding' "$1" 2>/dev/null | grep -c .)"
  printf '%s\n' "${n:-0}"
}
# event_field <file> <finding> <field>: the first value of the field on that event
event_field() {
  jq -rR --arg f "$2" --arg k "$3" 'fromjson? | select(type == "object" and .finding == $f) | .[$k] // empty' "$1" 2>/dev/null | head -1
}

# (5) a present source must be an open placement finding
if [ "$RESUME" = 0 ]; then
  sweep "$TD/pre.ndjson" || refuse "the placement sweep failed (exit $?); nothing was changed"
  if [ "$(open_count "$TD/pre.ndjson" "$ENTRY")" -lt 1 ]; then
    refuse "'$ENTRY' is not an open placement finding"
  fi
  # (6) for --into, the destination must not exist
  if [ -n "$INTO" ] && { [ -e "$DEST" ] || [ -L "$DEST" ]; }; then
    refuse "$PLAN/_research/$NAME already exists"
  fi
fi

# --discard: the entry is not a durable artifact. Move it to the state tier, log it, sweep again. The
# research declare and the binder refresh do not run: nothing was re-homed into a plan.
if [ "$DISCARD" = 1 ]; then
  DISCARD_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  DISCARD_STAMP="$(printf '%s' "$DISCARD_ISO" | tr -d ':-')"
  DISCARD_FLAT="$(printf '%s' "$ENTRY" | sed 's|/|__|g')"
  DISCARD_DIR="$CLAUDE_STATE_ROOT/discarded-strays"
  DISCARD_DEST="$DISCARD_DIR/$DISCARD_STAMP-$DISCARD_FLAT"
  if [ -e "$DISCARD_DEST" ] || [ -L "$DISCARD_DEST" ]; then
    printf "rehome-stray: could not move '%s' to %s: that path already exists; nothing changed\n" "$ENTRY" "$DISCARD_DEST" >&2
    exit 1
  fi
  if ! mkdir -p "$DISCARD_DIR" || ! mv "$SRC" "$DISCARD_DEST"; then
    printf "rehome-stray: could not move '%s' to %s; nothing changed\n" "$ENTRY" "$DISCARD_DEST" >&2
    exit 1
  fi
  DISCARD_LINE="$(jq -nc --arg e "$ENTRY" --arg r "$REASON" --arg t "$DISCARD_ISO" --arg p "$DISCARD_DEST" '{entry: $e, reason: $r, discarded_at: $t, moved_to: $p}')"
  if [ -z "$DISCARD_LINE" ] || ! printf '%s\n' "$DISCARD_LINE" >> "$DISCARD_DIR/log.jsonl"; then
    printf "rehome-stray: stopped: '%s' was moved to %s but its log line was not written to %s/log.jsonl\n" "$ENTRY" "$DISCARD_DEST" "$DISCARD_DIR" >&2
    exit 1
  fi
  if ! sweep "$TD/post.ndjson"; then
    printf "rehome-stray: stopped: '%s' was discarded to %s but the placement sweep failed; run /librarian placement-validate --scope %s\n" "$ENTRY" "$DISCARD_DEST" "$ROOT" >&2
    exit 1
  fi
  if [ "$(open_count "$TD/post.ndjson" "$ENTRY")" -ge 1 ]; then
    printf 'rehome-stray: discarded %s to %s but the sweep still lists it; run /librarian placement-validate --scope %s\n' "$ENTRY" "$DISCARD_DEST" "$ROOT" >&2
    exit 1
  fi
  printf 'rehome-stray: discarded %s to %s\n' "$ENTRY" "$DISCARD_DEST"
  exit 0
fi

# --mint: capture a decided idea note, triage it, then graduate it into a plan
if [ -n "$MINT" ]; then
  capture() {
    set -- --capture "$MINT" --disposition "$DISP"
    if [ -n "$ABSORB" ]; then set -- "$@" --absorbed-into "$ABSORB"; fi
    if [ -n "$RCLASS" ]; then set -- "$@" --release-class "$RCLASS"; fi
    if [ -n "$SIZE" ]; then set -- "$@" --size "$SIZE"; fi
    if [ -n "$GATE" ]; then set -- "$@" --reopen-gate "$GATE"; fi
    if [ -n "$TITLE" ]; then set -- "$@" --title "$TITLE"; fi
    if [ -n "$PROJ" ]; then set -- "$@" --project "$PROJ"; fi
    printf '%s\n' "$BODY" | FINDINGS_OUTPUT="$TD/capture.ndjson" bash "$HELPER" "$@" >/dev/null
  }
  : > "$TD/capture.ndjson"
  capture || refuse "the capture was refused; nothing was written"
  FINAL="$(event_field "$TD/capture.ndjson" idea-captured inbox_slug)"
  if [ -z "$FINAL" ]; then
    printf 'rehome-stray: stopped: the capture reported no idea-captured event; nothing was moved\n' >&2
    exit 1
  fi
  triage() {
    bash "$TRIAGE" "$FINAL" --classification NOVEL --rationale "minted by rehome-stray for '$ENTRY'" </dev/null >/dev/null
  }
  if ! triage; then
    printf "rehome-stray: stopped after the capture: '%s' is captured but not triaged; run: bash %s %s --classification NOVEL --rationale \"<one line>\", then bash %s %s, then re-run: bash %s %s --into <plan>\n" \
      "$FINAL" "$TRIAGE" "$FINAL" "$HELPER" "$FINAL" "$SELF" "$ENTRY" >&2
    exit 1
  fi
  graduate() {
    set -- "$FINAL"
    if [ -n "$PROJ" ]; then set -- "$@" --project "$PROJ"; fi
    : > "$TD/grad.ndjson"
    FINDINGS_OUTPUT="$TD/grad.ndjson" bash "$HELPER" "$@" </dev/null >/dev/null
  }
  if ! graduate; then
    printf "rehome-stray: stopped after the capture: '%s' is captured but not graduated; run: bash %s %s, then re-run: bash %s %s --into <plan>\n" \
      "$FINAL" "$HELPER" "$FINAL" "$SELF" "$ENTRY" >&2
    exit 1
  fi
  PD="$(event_field "$TD/grad.ndjson" idea-graduated plan_dir)"
  case "$PD" in
    "$ROOT"/*) PLAN="${PD#"$ROOT"/}" ;;
    /*) PLAN="${PD##*/}" ;;
    *) PLAN="$PD" ;;
  esac
  if [ -z "$PLAN" ] || [ ! -f "$ROOT/$PLAN/manifest.json" ]; then
    printf "rehome-stray: stopped after the graduation: the minted plan directory '%s' is not under %s; re-run: bash %s %s --into <plan>\n" \
      "$PD" "$ROOT" "$SELF" "$ENTRY" >&2
    exit 1
  fi
  MINTED=1
  DEST="$ROOT/$PLAN/_research/$NAME"
fi

# the move
if [ "$RESUME" = 0 ]; then
  MADE=0
  if [ ! -d "$ROOT/$PLAN/_research" ]; then MADE=1; fi
  mkdir -p "$ROOT/$PLAN/_research" 2>/dev/null
  if ! mv "$SRC" "$DEST"; then
    if [ "$MADE" = 1 ]; then rmdir "$ROOT/$PLAN/_research" 2>/dev/null; fi
    if [ "$MINTED" = 1 ]; then
      printf "rehome-stray: could not move '%s' to %s/_research/%s; the plan %s was minted and the entry is unmoved; re-run: bash %s %s --into %s\n" \
        "$ENTRY" "$PLAN" "$NAME" "$PLAN" "$SELF" "$ENTRY" "$PLAN" >&2
    else
      printf "rehome-stray: could not move '%s' to %s/_research/%s; nothing changed\n" "$ENTRY" "$PLAN" "$NAME" >&2
    fi
    exit 1
  fi
fi

# the derivations a session close and a tool-event write would have run
PROJECT="$(jq -r '.project // empty' "$ROOT/$PLAN/manifest.json" 2>/dev/null)"
if [ -z "$PROJECT" ]; then
  note "research declare skipped (the plan manifest names no project)"
elif [ ! -f "$DECL" ]; then
  note "research declare skipped ($DECL is missing)"
else
  : > "$TD/declare.ndjson"
  FINDINGS_OUTPUT="$TD/declare.ndjson" bash "$DECL" --spoke "$PROJECT" </dev/null >/dev/null 2>"$TD/declare.err"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    note "research declare skipped (exit status $RC$(head -1 "$TD/declare.err" 2>/dev/null | sed 's/^/: /'))"
  fi
fi
if [ ! -f "$HOOK" ]; then
  note "binder refresh skipped ($HOOK is missing)"
else
  bash "$HOOK" "$DEST" </dev/null >/dev/null 2>"$TD/refresh.err"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    note "binder refresh skipped (exit status $RC$(head -1 "$TD/refresh.err" 2>/dev/null | sed 's/^/: /'))"
  fi
fi

# the sweep again: the entry must now be absent
if ! sweep "$TD/post.ndjson"; then
  printf "rehome-stray: stopped: the placement sweep failed; re-run: bash %s %s --into %s\n" "$SELF" "$ENTRY" "$PLAN" >&2
  exit 1
fi
if [ "$(open_count "$TD/post.ndjson" "$ENTRY")" -ge 1 ]; then
  printf "rehome-stray: stopped: '%s' is still an open placement finding; re-run: bash %s %s --into %s\n" "$ENTRY" "$SELF" "$ENTRY" "$PLAN" >&2
  exit 1
fi

printf '%s\n' "rehome-stray: re-homed '$ENTRY' -> $PLAN/_research/$NAME"
printf 'rehome-stray: placement sweep: %s open finding(s)\n' "$(stray_count "$TD/post.ndjson")"
printf 'rehome-stray: run /librarian backlog-index to refresh the backlog\n' >&2
exit 0

#!/usr/bin/env bash
# active-plan.sh - set or clear the active-plan pointer of one spoke.
#
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/active-plan.sh set <plan-key> [<sp>|.] [--project <spoke-key>] [--plans-root DIR]
#   bash ${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/active-plan.sh clear [--project <spoke-key>] [--plans-root DIR]
#
# The pointer is <plans-root>/_projects/<spoke>/.active-plan: one line, the plan key. Every reader of
# hooks/lib/active-plan-resolve.sh resolves "the armed plan of this spoke" from it. <plan-key> is
# NN-slug and must name a directory under the plans root whose manifest.json parses as a JSON object.
# <sp>, when given, is `.` (the plan root) or a sub-plan directory holding a manifest.json; it is written
# to <plans-root>/<plan-key>/.active-sp, and an omitted <sp> leaves that file as it is.
#
# THE SPOKE is --project, else the plan manifest's own `project`, either one checked against the
# anchored-spoke registry (spoke_validate_override in spoke-resolve.sh). `clear` without --project takes
# the spoke the working directory resolves to (spoke_resolve_from_cwd).
#
# STATUS. `set` stamps the plan in-progress through hooks/lib/field-set.sh plan set (never a direct
# manifest write), so the setter's lifecycle rules apply. The manifest it stamps is the one the pointer will
# resolve to: <plan>/<sp>/manifest.json for a named sub-plan, <plan>/manifest.json for `.`, and for an
# omitted <sp> the one an existing .active-sp names, else the plan's own. That manifest's top-level
# `status` decides: planned or paused is stamped (a resume drops paused_reason, the setter's rule);
# in-progress makes no setter call and no write, so a second `set` changes nothing; completed or
# superseded is refused as terminal; any other value, a missing `status` or a manifest that does not
# parse is refused as not ready to arm. The setter's stdout goes to this command's stderr, so stdout
# holds only this command's own line. `clear` leaves status alone. This command has no gate or arming
# semantics: it reads no ledger, digest or lane record and runs no arm tool.
#
# ORDER OF EFFECTS. Every refusal comes first, with every byte unchanged; then the stamp, then .active-sp
# (when <sp> is given), then the pointer. A pointer failure after a stamp keeps the stamp, and a re-run
# converges because an in-progress plan takes no write.
#
# WRITE: the text goes to a temp file `<name>.tmp.<pid>` beside its target, a PATH-resolved plain `mv`
# places it, and a trap on EXIT, INT, TERM and HUP removes the temp file. A failed write or move exits 1
# with the last stderr line `active-plan: write failed: <path>` and the old target unchanged.
#
# STDOUT: `active-plan: <spoke> -> <plan-key>` (with ` (sub-plan <sp>)` appended when <sp> was given),
# `active-plan: <spoke> cleared`, or `active-plan: <spoke> is already clear`.
# EXIT CODES: 0 done; 2 refused with every byte unchanged (the last stderr line is
# `active-plan: refused: <reason>`); 1 a write failed.
#
# The plans root is --plans-root, else PLANS_ROOT, else PLANS_DIR, else $HOME/.claude-plans; a trailing
# slash is stripped and the resolved root is exported as both PLANS_ROOT and PLANS_DIR before any child
# runs. The plans rules the setter reads come from PLANS_RULES_PATH or the home's governance/plans-rules.json.
#
# Bash 3.2 clean.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../hooks/lib/paths.sh" 2>/dev/null || true
set -u

TMP_A=""

usage() {
  printf 'usage: active-plan set <plan-key> [<sp>|.] [--project <spoke-key>] [--plans-root DIR]\n'
  printf '       active-plan clear [--project <spoke-key>] [--plans-root DIR]\n'
  printf 'exit: 0 done; 2 refused (nothing changed); 1 a write failed\n'
}

finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$TMP_A" ]; then rm -f -- "$TMP_A"; fi
  TMP_A=""
  exit "$rc"
}
trap finish EXIT INT TERM HUP

refuse() {
  printf 'active-plan: refused: %s\n' "$1" >&2
  exit 2
}

wfail() {
  printf 'active-plan: write failed: %s\n' "$1" >&2
  exit 1
}

VERB=""; KEY=""; SP=""; GOT_SP=0; PROJECT=""; ROOT_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --project|--plans-root)
      flag="$1"
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "$flag needs a non-empty value"; fi
      if [ "$flag" = "--project" ]; then PROJECT="$2"; else ROOT_FLAG="$2"; fi
      shift 2 ;;
    -*) refuse "unknown flag '$1'" ;;
    *)
      if [ -z "$VERB" ]; then
        case "$1" in
          set|clear) VERB="$1" ;;
          *) refuse "unknown verb '$1'" ;;
        esac
      elif [ "$VERB" = "set" ] && [ -z "$KEY" ]; then
        KEY="$1"
      elif [ "$VERB" = "set" ] && [ "$GOT_SP" = 0 ]; then
        SP="$1"; GOT_SP=1
      else
        refuse "unexpected argument '$1'"
      fi
      shift ;;
  esac
done
[ -n "$VERB" ] || refuse "needs a verb (set or clear)"
if [ "$VERB" = "set" ] && [ -z "$KEY" ]; then refuse "set needs a plan key"; fi
command -v jq >/dev/null 2>&1 || refuse "jq is required"

ROOT="${ROOT_FLAG:-${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}}"
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac
while [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done
export PLANS_ROOT="$ROOT" PLANS_DIR="$ROOT"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/spoke-resolve.sh" || { printf 'active-plan: spoke-resolve.sh not found beside this script\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../hooks/lib/active-plan-resolve.sh" || { printf 'active-plan: hooks/lib/active-plan-resolve.sh not found\n' >&2; exit 1; }

# write_file <dest> <text>: temp file beside the target, PATH-resolved mv, the trap removes a leftover temp.
write_file() {
  local dest="$1" text="$2" dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || wfail "$dest"
  TMP_A="$dir/$(basename "$dest").tmp.$$"
  printf '%s\n' "$text" > "$TMP_A" || wfail "$dest"
  mv "$TMP_A" "$dest" || wfail "$dest"
  TMP_A=""
}

if [ "$VERB" = "clear" ]; then
  if [ -n "$PROJECT" ]; then
    SPOKE="$(spoke_validate_override "$PROJECT")" || refuse "'$PROJECT' is not a registered spoke key"
  else
    SPOKE="$(spoke_resolve_from_cwd "$PWD")" || refuse "the working directory resolves to no spoke; pass --project <spoke-key>"
  fi
  PTR="$(active_plan_pointer_path "$ROOT" "$SPOKE")"
  if [ -e "$PTR" ] || [ -L "$PTR" ]; then
    rm -f -- "$PTR"
    if [ -e "$PTR" ] || [ -L "$PTR" ]; then wfail "$PTR"; fi
    printf 'active-plan: %s cleared\n' "$SPOKE"
  else
    printf 'active-plan: %s is already clear\n' "$SPOKE"
  fi
  exit 0
fi

# ---- set: every refusal before any write ---------------------------------------------------------------
KEY_RE='^[0-9]{2,}-[a-z][a-z0-9-]+$'
[[ "$KEY" =~ $KEY_RE ]] || refuse "'$KEY' is not a plan key (NN-slug)"
PDIR="$ROOT/$KEY"
[ -d "$PDIR" ] || refuse "no plan directory $PDIR"
jq -e 'type == "object"' "$PDIR/manifest.json" >/dev/null 2>&1 || refuse "$KEY/manifest.json is missing or not a JSON object"

SPOKE_SRC="$PROJECT"
if [ -z "$SPOKE_SRC" ]; then
  SPOKE_SRC="$(jq -r 'if (.project | type) == "string" then .project else "" end' "$PDIR/manifest.json")"
fi
[ -n "$SPOKE_SRC" ] || refuse "the plan manifest carries no project; pass --project <spoke-key>"

# sub_ok <name>: a plain directory name under the plan that holds a manifest.json.
sub_ok() {
  case "$1" in ""|.|..|*/*) return 1 ;; esac
  [ -d "$PDIR/$1" ] && [ -f "$PDIR/$1/manifest.json" ]
}
# The target is the manifest the pointer will resolve to: a named sub-plan, `.`, or what .active-sp names.
TSP="."
if [ "$GOT_SP" = 1 ]; then
  if [ "$SP" != "." ]; then
    sub_ok "$SP" || refuse "'$SP' is not a sub-plan of $KEY"
    TSP="$SP"
  fi
elif [ -f "$PDIR/.active-sp" ]; then
  CUR="$(tr -d '[:space:]' < "$PDIR/.active-sp")"
  if [ -n "$CUR" ] && [ "$CUR" != "." ]; then
    sub_ok "$CUR" || refuse "'$CUR' is not a sub-plan of $KEY"
    TSP="$CUR"
  fi
fi

SPOKE="$(spoke_validate_override "$SPOKE_SRC")" || refuse "'$SPOKE_SRC' is not a registered spoke key"

if [ "$TSP" = "." ]; then
  TMAN="$PDIR/manifest.json"; LABEL="$KEY"
else
  TMAN="$PDIR/$TSP/manifest.json"; LABEL="$KEY/$TSP"
fi
STATUS="$(jq -r 'if type == "object" and (.status | type) == "string" then .status else "" end' "$TMAN" 2>/dev/null)"
case "$STATUS" in
  planned|paused) STAMP=1 ;;
  in-progress) STAMP=0 ;;
  completed|superseded) refuse "$LABEL is terminal ($STATUS)" ;;
  *) refuse "$LABEL is not ready to arm (${STATUS:-no status})" ;;
esac

PTR="$(active_plan_pointer_path "$ROOT" "$SPOKE")"

# ---- the effects: stamp, .active-sp, pointer ---------------------------------------------------------------
if [ "$STAMP" = 1 ]; then
  FS="$SCRIPT_DIR/../../../hooks/lib/field-set.sh"
  [ -f "$FS" ] || { printf 'active-plan: hooks/lib/field-set.sh not found\n' >&2; exit 1; }
  if ! bash "$FS" plan set "$TMAN" status=in-progress >&2; then wfail "$TMAN"; fi
fi
if [ "$GOT_SP" = 1 ]; then write_file "$PDIR/.active-sp" "$SP"; fi
write_file "$PTR" "$KEY"

if [ "$GOT_SP" = 1 ]; then
  printf 'active-plan: %s -> %s (sub-plan %s)\n' "$SPOKE" "$KEY" "$SP"
else
  printf 'active-plan: %s -> %s\n' "$SPOKE" "$KEY"
fi
exit 0

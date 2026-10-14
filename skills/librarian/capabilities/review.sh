#!/bin/bash
# review — works through the memory review queue (.review-queue.json) as commands.
#
# The queue holds the items that need an operator decision: a memory due for revalidation,
# a hygiene finding, a conflict between two memories and a promotion proposal. This
# capability runs the mechanical part of that walk: it lists the open items in a fixed order
# and pages them, suppresses a low-severity hygiene item that was dismissed three times,
# applies the write that goes with a confirm, and records each decision through the queue
# primitives of hooks/lib/review-queue.sh. Reading an item's impact and choosing confirm,
# reject or defer stays with the operator; the SKILL.md section for this capability holds
# those judgment steps.
#
# The OPEN set is every item whose state is open or deferred. A bare defer keeps an item in
# the queue, so `list` and `report` count it and `confirm`, `reject` and `defer` accept it.
#
# Derivations (what else must run when this capability writes a memory file): after the
# revalidation stamp and after a promotion's --written file, the two memory-write hooks run
# from <root>/hooks/, memory-auto-stamp.sh and then memory-globalize-auto.sh, each fed the
# one-line PostToolUse payload a Write of that file would send. A missing hook is a NOTE and
# the run goes on, and so is a hook that exits non-zero. No hook is bound to the queue file
# itself, so a queue-only write (reject, defer, a conflict resolution, a hygiene confirm,
# a suppression) runs none, and no session-close step applies.
#
# Root: <root> is ${CLAUDE_HOME:-$HOME/.claude} when <root>/hooks/lib/review-queue.sh is a
# regular file, otherwise the tree that holds this script (three directories above
# capabilities/). CLAUDE_HOME is exported as <root> before the lib is sourced and before each
# hook runs, so a called hook or lib reads the root this script resolved, never an ambient
# CLAUDE_HOME that differs from it.
#
# Output Contract:
#   Files written:
#     - <memory dir>/.review-queue.json  (every decision, through the lib primitives; a
#       conflict resolution as payload.resolution by one temp-and-replace)
#     - <memory dir>/<topic>.md  (revalidation: last_validated stamped by one
#       temp-and-replace, <memory dir>/.<topic>.md.review-tmp; promotion: the file the
#       operator composed and named with --written, written before this script runs)
#   stdout: the list rows and footer, the item for `show`, the report lines, or one success
#     line: `review: confirmed <id> (<class>)`, `review: rejected <id>`,
#     `review: deferred <id> (defer_count <n>)`, `review: suppressed <id> (...)` (list).
#   stderr: every refusal is one line `review: refused: <why>`; a derivation problem is
#     `review: NOTE: <hook> skipped (hook missing)` or `review: NOTE: <hook> failed (rc <n>)`.
#   Exit codes: 0 done; 2 refused with the queue unchanged (and the memory directory
#     unchanged, except the one refusal that follows a write: a memory file whose
#     frontmatter lost name, description or type during the derivations, which leaves the
#     file as they left it and the item unconfirmed); 3 a write or a primitive failed.
#   Schema: items follow schemas/review-queue-schema.json (class, summary, memory_ref,
#     state open|deferred|confirmed|rejected|suppressed); a memory file keeps the name,
#     description and type frontmatter keys of schemas/memory-schema.json.
#   Failure mode: block-and-log. Nothing is written once a refusal is decided.
#
# CLI:
#   review.sh list [--limit N]                                  # default 20
#   review.sh show <id>
#   review.sh confirm <id> [--written <memory-file>] [--resolution <text>]
#   review.sh reject <id> --reason <text>
#   review.sh defer <id> --reason <text>
#   review.sh report
#
# Environment: MEMORY_DIR pins the memory directory (the lib's resolve_memory_dir);
# REVIEW_TODAY pins the revalidation date (default: today, UTC).
#
# Bash 3.2 clean. Data reaches jq and Python through --arg and argv, never a piped stdin.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "$SELF_DIR/../../.." && pwd)"

refuse() { printf 'review: refused: %s\n' "$*" >&2; exit 2; }
fail3()  { printf 'review: refused: %s\n' "$*" >&2; exit 3; }
note()   { printf 'review: NOTE: %s\n' "$*" >&2; }

# --- arguments ---------------------------------------------------------------
[ $# -ge 1 ] || refuse "no subcommand (list, show, confirm, reject, defer, report)"
SUB="$1"; shift
case "$SUB" in
  list|show|confirm|reject|defer|report) ;;
  *) refuse "unknown subcommand '$SUB'" ;;
esac

takes_flag() {
  case "$SUB:$1" in
    list:--limit|confirm:--written|confirm:--resolution|reject:--reason|defer:--reason) return 0 ;;
  esac
  return 1
}

ID=""; HAVE_ID=0
LIMIT_RAW="20"
WRITTEN=""; HAVE_WRITTEN=0
RESOLUTION=""; HAVE_RESOLUTION=0
REASON=""; HAVE_REASON=0
while [ $# -gt 0 ]; do
  case "$1" in
    -*)
      takes_flag "$1" || refuse "unknown flag '$1'"
      if [ $# -lt 2 ] || [ -z "$2" ]; then refuse "$1 needs a value"; fi
      case "$1" in
        --limit)      LIMIT_RAW="$2" ;;
        --written)    WRITTEN="$2"; HAVE_WRITTEN=1 ;;
        --resolution) RESOLUTION="$2"; HAVE_RESOLUTION=1 ;;
        --reason)     REASON="$2"; HAVE_REASON=1 ;;
      esac
      shift 2 ;;
    *)
      case "$SUB" in
        show|confirm|reject|defer)
          if [ "$HAVE_ID" -eq 0 ]; then ID="$1"; HAVE_ID=1; shift; else refuse "unknown flag '$1'"; fi ;;
        *) refuse "unknown flag '$1'" ;;
      esac ;;
  esac
done

LIMIT=20
if [ "$SUB" = list ]; then
  case "$LIMIT_RAW" in
    ''|*[!0-9]*) refuse "--limit must be a positive integer" ;;
  esac
  LIMIT="$LIMIT_RAW"
  while [ "${LIMIT#0}" != "$LIMIT" ]; do LIMIT="${LIMIT#0}"; done
  [ -n "$LIMIT" ] || refuse "--limit must be a positive integer"
  [ "${#LIMIT}" -le 9 ] || LIMIT=999999999
fi

# --- root, lib, queue --------------------------------------------------------
R="${CLAUDE_HOME:-${HOME:-}/.claude}"
if [ ! -f "$R/hooks/lib/review-queue.sh" ]; then
  if [ -f "$TREE/hooks/lib/review-queue.sh" ]; then
    R="$TREE"
  else
    refuse "review-queue.sh not found under $TREE/hooks/lib"
  fi
fi
export CLAUDE_HOME="$R"
# shellcheck disable=SC1091
source "$R/hooks/lib/review-queue.sh"

MEM_DIR="$(resolve_memory_dir)"
QF="$(_rq_queue_file)"

if [ -f "$QF" ] && ! jq -e 'type=="object"' "$QF" >/dev/null 2>&1; then
  fail3 "queue read failed"
fi

# qjq <jq args...> — run jq over the queue; an absent queue reads as an empty one
qjq() {
  if [ -f "$QF" ]; then
    jq "$@" "$QF"
  else
    printf '{"version":1,"items":[]}\n' | jq "$@"
  fi
}

item_exists() {
  qjq -e --arg i "$1" '[.items[]? | select(.id==$i)] | length > 0' >/dev/null 2>&1
}

# item_str <id> <jq expr over the item> — print the expression's value for the first match
item_str() {
  qjq -r --arg i "$1" "[.items[]? | select(.id==\$i)] | if length==0 then empty else (.[0] | ($2)) end"
}

check_cleared() { # <id> <state>
  case "$2" in
    confirmed|rejected|suppressed) refuse "$1 is already $2" ;;
  esac
}

# --- memory file helpers ------------------------------------------------------
PYSRC='
import os, re, sys

def split_fm(data):
    lines = data.split(b"\n")
    if not lines or lines[0].rstrip(b"\r") != b"---":
        return lines, None
    for i in range(1, len(lines)):
        if lines[i].rstrip(b"\r") == b"---":
            return lines, i
    return lines, None

cmd = sys.argv[1]
if cmd == "fmkey":
    with open(sys.argv[2], "rb") as fh:
        lines, close = split_fm(fh.read())
    keys = set()
    if close is not None:
        for ln in lines[1:close]:
            m = re.match(rb"([A-Za-z_][A-Za-z0-9_-]*):", ln)
            if m:
                keys.add(m.group(1).decode())
    for k in ("name", "description", "type"):
        if k not in keys:
            print(k)
            break
elif cmd == "stamp":
    path, tmp, today = sys.argv[2], sys.argv[3], sys.argv[4]
    with open(path, "rb") as fh:
        lines, close = split_fm(fh.read())
    if close is None:
        sys.exit(3)
    eol = b"\r" if lines[0].endswith(b"\r") else b""
    new = b"last_validated: " + today.encode() + eol
    for i in range(1, close):
        if re.match(rb"last_validated:", lines[i]):
            lines[i] = new
            break
    else:
        lines.insert(close, new)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(b"\n".join(lines))
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
'

NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*[.]md$'
TOPIC_FILE=""

# resolve_topic <value> — a topic file name (with or without .md) or an absolute path whose
# directory is the memory directory; sets TOPIC_FILE. Returns 1 when it names no topic file.
resolve_topic() {
  local v="$1" name
  case "$v" in
    /*) [ "${v%/*}" = "${MEM_DIR%/}" ] || return 1; name="${v##*/}" ;;
    */*) return 1 ;;
    *) name="$v" ;;
  esac
  case "$name" in *.md) ;; *) name="$name.md" ;; esac
  [ "$name" != "MEMORY.md" ] || return 1
  [[ "$name" =~ $NAME_RE ]] || return 1
  TOPIC_FILE="$name"
  return 0
}

fm_check() { # <file path> <file name> — refuse when name, description or type is missing
  local key
  key="$(python3 -c "$PYSRC" fmkey "$1" 2>/dev/null)"
  [ -z "$key" ] || refuse "$2 frontmatter lacks $key"
}

stamp_file() { # <file path> <file name>
  local tmp="$MEM_DIR/.$2.review-tmp" today
  today="${REVIEW_TODAY:-$(date -u +%Y-%m-%d)}"
  if ! python3 -c "$PYSRC" stamp "$1" "$tmp" "$today" 2>/dev/null; then
    rm -f "$tmp"
    fail3 "stamp of $2 failed"
  fi
  if ! mv -f "$tmp" "$1"; then
    rm -f "$tmp"
    fail3 "stamp of $2 failed"
  fi
}

run_derivations() { # <file path> — the two memory-write hooks, in the PostToolUse fire order
  local payload h rc
  payload="$(jq -cn --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p}}')"
  for h in memory-auto-stamp.sh memory-globalize-auto.sh; do
    if [ ! -f "$R/hooks/$h" ]; then
      note "$h skipped (hook missing)"
      continue
    fi
    bash "$R/hooks/$h" >/dev/null 2>&1 <<<"$payload"
    rc=$?
    [ "$rc" -eq 0 ] || note "$h failed (rc $rc)"
  done
}

write_resolution() {
  local tmp="$QF.review-tmp"
  if ! jq --arg i "$ID" --arg r "$RESOLUTION" \
      '.items = [.items[]? | if .id==$i then .payload = ((.payload // {}) + {resolution: $r}) else . end]' \
      "$QF" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail3 "resolution write failed"
  fi
  if ! mv -f "$tmp" "$QF"; then
    rm -f "$tmp"
    fail3 "resolution write failed"
  fi
}

# --- subcommands -------------------------------------------------------------
cmd_list() {
  local cands cid cdc rc
  cands="$(qjq -r '.items[]? | select((.state=="open" or .state=="deferred") and .class=="hygiene" and .severity=="low" and ((.dismiss_count // 0) >= 3)) | [.id, ((.dismiss_count // 0) | tostring)] | join("\t")')"
  if [ -n "$cands" ]; then
    while IFS=$'\t' read -r cid cdc; do
      suppress_item "$cid"
      rc=$?
      [ "$rc" -eq 0 ] || fail3 "suppress_item failed (rc $rc)"
      printf 'review: suppressed %s (low-severity hygiene, dismiss_count %s)\n' "$cid" "$cdc"
    done <<<"$cands"
  fi
  qjq -r --argjson lim "$LIMIT" '
    [.items[]? | select(.state=="open" or .state=="deferred")]
    | sort_by([(if .severity=="high" then 0 elif .severity=="medium" then 1 elif .severity=="low" then 2 else 3 end),
               (.enqueued_at // "1970-01-01T00:00:00Z"), .id]) as $s
    | ($s | length) as $t
    | ($s[:$lim] | to_entries[]
       | [(.key + 1), .value.id, .value.severity, .value.class, (.value.defer_count // 0),
          (.value.memory_ref // ""), (.value.summary // "")] | @tsv),
      "review: showing \([$t, $lim] | min) of \($t) open item(s); \([$t - $lim, 0] | max) remaining"'
}

cmd_show() {
  item_exists "$ID" || refuse "no item with id $ID"
  qjq --arg i "$ID" '.items[] | select(.id==$i)'
}

cmd_report() {
  qjq -r '
    def n($c; $s): [.items[]? | select(.class==$c and .state==$s)] | length;
    ([.items[]? | select(.state=="open" or .state=="deferred")] | length) as $total
    | (("revalidation", "hygiene", "conflict", "promotion") as $c
       | "review: class=\($c) confirmed=\(n($c; "confirmed")) rejected=\(n($c; "rejected")) deferred=\(n($c; "deferred")) suppressed=\(n($c; "suppressed")) open=\(n($c; "open") + n($c; "deferred"))"),
      "review: open total=\($total)"'
}

cmd_disposition() { # reject | defer
  local st rc prim dc
  [ "$HAVE_REASON" -eq 1 ] || refuse "$SUB needs --reason"
  item_exists "$ID" || refuse "no item with id $ID"
  st="$(item_str "$ID" '.state // ""')"
  check_cleared "$ID" "$st"
  if [ "$SUB" = reject ]; then
    prim=reject_item
    reject_item "$ID" "$REASON"
  else
    prim=defer_item
    defer_item "$ID" "$REASON"
  fi
  rc=$?
  [ "$rc" -eq 0 ] || fail3 "$prim failed (rc $rc)"
  if [ "$SUB" = reject ]; then
    printf 'review: rejected %s\n' "$ID"
  else
    dc="$(item_str "$ID" '(.defer_count // 0) | tostring')"
    printf 'review: deferred %s (defer_count %s)\n' "$ID" "$dc"
  fi
}

cmd_confirm() {
  local st cls mf file written_msg rc
  written_msg="--written must name a .md topic file directly inside the memory directory (not MEMORY.md)"
  item_exists "$ID" || refuse "no item with id $ID"
  st="$(item_str "$ID" '.state // ""')"
  check_cleared "$ID" "$st"
  cls="$(item_str "$ID" '.class // ""')"
  if [ "$HAVE_WRITTEN" -eq 1 ] && [ "$cls" != promotion ]; then
    refuse "--written is not used by a $cls item"
  fi
  if [ "$HAVE_RESOLUTION" -eq 1 ] && [ "$cls" != conflict ]; then
    refuse "--resolution is not used by a $cls item"
  fi
  case "$cls" in
    promotion)
      [ "$HAVE_WRITTEN" -eq 1 ] || refuse "promotion needs --written"
      case "$WRITTEN" in *.md) ;; *) refuse "$written_msg" ;; esac
      resolve_topic "$WRITTEN" || refuse "$written_msg"
      file="$MEM_DIR/$TOPIC_FILE"
      [ -f "$file" ] || refuse "$written_msg"
      fm_check "$file" "$TOPIC_FILE"
      run_derivations "$file"
      fm_check "$file" "$TOPIC_FILE"
      ;;
    conflict)
      [ "$HAVE_RESOLUTION" -eq 1 ] || refuse "conflict needs --resolution"
      write_resolution
      ;;
    revalidation)
      mf="$(item_str "$ID" '(.memory_ref // "") | tostring')"
      [ -n "$mf" ] || refuse "$ID has no memory_ref"
      resolve_topic "$mf" || refuse "$ID memory_ref '$mf' does not name a topic file in the memory directory"
      file="$MEM_DIR/$TOPIC_FILE"
      [ -f "$file" ] || refuse "memory file $TOPIC_FILE not found"
      fm_check "$file" "$TOPIC_FILE"
      stamp_file "$file" "$TOPIC_FILE"
      run_derivations "$file"
      fm_check "$file" "$TOPIC_FILE"
      ;;
  esac
  confirm_item "$ID"
  rc=$?
  [ "$rc" -eq 0 ] || fail3 "confirm_item failed (rc $rc)"
  printf 'review: confirmed %s (%s)\n' "$ID" "$cls"
}

case "$SUB" in
  list)         cmd_list ;;
  show)         cmd_show ;;
  report)       cmd_report ;;
  reject|defer) cmd_disposition ;;
  confirm)      cmd_confirm ;;
esac

#!/bin/bash
# handoff-entry — stamps a new session entry into a plan's handoff.md, newest-first.
#
# A plan's handoff.md is an append-only session record whose newest entry sits at the top.
# This verb opens the next entry so its identity is script-stamped, never hand-typed:
#   1. the heading      ## Session <N> — <YYYY-MM-DD> (<title>)
#   2. directly under it, one identity header line
#        <!-- session: {"plan":"<NNN>","n":<N>,"at":"<ISO-8601 local date-time with offset>","kind":"<token>"} -->
#   3. one `### ` heading per governance/file-type-contracts/handoff.md.json
#      section_subsections entry (the subsection skeleton, bodies left empty).
# The entry goes after the preamble and before the first existing H2 session heading;
# with no session heading yet, it goes at the end of the file. Every byte from the old
# first session heading onward is unchanged.
#
# N is the highest session ordinal any session heading carries, plus one (1 when no
# heading carries an ordinal). Headings and ordinals are read with the one shared
# recognizer, hooks/lib/handoff-recognizer.sh (HANDOFF_SESSION_HEADING_PY +
# HANDOFF_SESSION_NUM_PY), so a date-only heading adds no ordinal. <NNN> is the leading
# digit run of the plan directory's name (the whole name when it has none). kind is a free
# token, default `session`. The header carries identity only; the entry body stays free
# prose, and the chronicle writers drop the header line before they harvest a summary.
#
# Output Contract:
#   Files written: <plan-dir>/handoff.md (the new entry inserted; atomic temp + os.replace
#     in the same directory). Nothing else.
#   stdout: one line `handoff-entry: <handoff path> Session <N>`.
#   Schema: governance/file-type-contracts/handoff.md.json (section_schema heading shape;
#     section_subsections skeleton), read from .file_type_contracts["handoff.md"] of the
#     merged foundation + overlay view, else the repo contract file.
#   Pre-write validation: <plan-dir>/handoff.md exists; --title is one non-empty line;
#     --kind matches ^[A-Za-z0-9][A-Za-z0-9._-]*$; the contract lists at least one
#     subsection. Any miss exits 2 with a stderr reason and writes nothing.
#   Failure mode: block-and-log (exit 2, no write). Never write-and-hope.
#
# CLI:
#   handoff-entry.sh <plan-dir> --title "<text>" [--kind <token>]
#   handoff-entry.sh --help
#
# Env overrides (testing):
#   CLAUDE_HOME              where the recognizer lib and the composed master are read first
#   FOUNDATION_MASTER_PATH   the composed master to read the handoff contract from
#
# Bash 3.2 clean. Data reaches Python through argv and the environment, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

# The session-heading recognizer. Unreadable in both homes: exit 2 naming the lib.
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/handoff-recognizer.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/handoff-recognizer.sh"; } \
  || { [ -r "$_REPO_LIB/handoff-recognizer.sh" ] && source "$_REPO_LIB/handoff-recognizer.sh"; } \
  || { echo "handoff-entry: hooks/lib/handoff-recognizer.sh unreadable under $CLAUDE_HOME_RES and $_REPO_LIB" >&2; exit 2; }

PLAN_DIR=""
TITLE=""
TITLE_SET="false"
KIND="session"
while [ $# -gt 0 ]; do
  case "$1" in
    --title)   TITLE="${2:-}"; TITLE_SET="true"; shift 2 ;;
    --kind)    KIND="${2:-}"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*)        echo "handoff-entry: unknown flag '$1'" >&2; exit 2 ;;
    *)
      if [ -n "$PLAN_DIR" ]; then echo "handoff-entry: one plan directory only (got '$PLAN_DIR' and '$1')" >&2; exit 2; fi
      PLAN_DIR="$1"; shift ;;
  esac
done

[ -n "$PLAN_DIR" ] || { echo "handoff-entry: usage: handoff-entry <plan-dir> --title \"<text>\" [--kind <token>]" >&2; exit 2; }
[ "$TITLE_SET" = "true" ] || { echo "handoff-entry: --title is required" >&2; exit 2; }
PLAN_DIR="${PLAN_DIR%/}"
HANDOFF="$PLAN_DIR/handoff.md"
[ -f "$HANDOFF" ] || { echo "handoff-entry: no handoff.md in $PLAN_DIR" >&2; exit 2; }

# The handoff contract: the merged foundation + overlay view (hooks/lib/foundation-overlay-load.sh,
# the union-load primitive), then the raw bundle if the merger is unavailable, then the repo
# contract file.
CONTRACT=""
MASTER="${FOUNDATION_MASTER_PATH:-$CLAUDE_HOME_RES/governance/foundation-master.json}"
if [ -f "$MASTER" ]; then
  _OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
  [ -x "$_OVL" ] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
  if [ -x "$_OVL" ]; then
    # The loader's exit code and stderr are kept, never discarded: a failed or degraded overlay
    # load is named on stderr (one line, with its rc) before the raw-bundle fallback below.
    _OVL_ERR="$(mktemp -t handoff-entry-ovl-XXXXXX)"; _OVL_RC=0
    _OVL_OUT=$(bash "$_OVL" --foundation-path "$MASTER" \
        --overlay-path "$(dirname "$MASTER")/overlay-master.json" --force-override 2>"$_OVL_ERR") || _OVL_RC=$?
    if [ "$_OVL_RC" -ne 0 ] || [ -s "$_OVL_ERR" ]; then
      echo "handoff-entry: overlay load failed (rc $_OVL_RC): $(grep -v '^[[:space:]]*$' "$_OVL_ERR" | tail -1)" >&2
    fi
    rm -f "$_OVL_ERR"
    # swallow-ok: reports=none a loader failure is reported on stderr above; this jq only extracts one optional key from the output the loader just produced with exit 0, and an absent key reads as empty and falls back to the master read below
    [ "$_OVL_RC" -eq 0 ] && CONTRACT=$(printf '%s' "$_OVL_OUT" \
        | jq -c '.file_type_contracts["handoff.md"] // empty' 2>/dev/null || true)
  fi
  [ -n "$CONTRACT" ] || CONTRACT=$(jq -c '.file_type_contracts["handoff.md"] // empty' "$MASTER" 2>/dev/null || true)
fi
if [ -z "$CONTRACT" ] && [ -f "$_REPO_ROOT/governance/file-type-contracts/handoff.md.json" ]; then
  CONTRACT=$(jq -c '.' "$_REPO_ROOT/governance/file-type-contracts/handoff.md.json" 2>/dev/null || true)
fi
[ -n "$CONTRACT" ] || { echo "handoff-entry: handoff.md contract unreadable (master $MASTER, repo $_REPO_ROOT)" >&2; exit 2; }

python3 - "$HANDOFF" "$TITLE" "$KIND" "$CONTRACT" <<'PY'
import json, os, re, sys, tempfile
from datetime import datetime

path, title, kind, contract_s = sys.argv[1:5]


def refuse(msg):
    sys.stderr.write("handoff-entry: %s\n" % msg)
    sys.exit(2)


title = title.strip()
if not title or "\n" in title or "\r" in title:
    refuse("--title must be one non-empty line")
if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", kind):
    refuse("--kind must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ (got %r)" % kind)
try:
    contract = json.loads(contract_s)
except Exception:
    refuse("handoff.md contract is not JSON")
subs = [str(s) for s in (contract.get("section_subsections") or []) if str(s).strip()]
if not subs:
    refuse("handoff.md contract lists no section_subsections")

HEADING_RE = re.compile(os.environ["HANDOFF_SESSION_HEADING_PY"], re.IGNORECASE)
NUM_RE = re.compile(os.environ["HANDOFF_SESSION_NUM_PY"], re.IGNORECASE)

with open(path, encoding="utf-8") as fh:
    text = fh.read()
lines = text.splitlines(keepends=True)

insert_at = None
top = 0
for i, line in enumerate(lines):
    m = HEADING_RE.match(line.rstrip("\r\n"))
    if not m:
        continue
    if insert_at is None and m.group(1) == "##":
        insert_at = i
    heading = line.rstrip("\r\n").lstrip("#").strip()
    num = NUM_RE.search(heading)
    if num:
        top = max(top, int(num.group(1)))
n = top + 1

base = os.path.basename(os.path.dirname(os.path.abspath(path)))
dm = re.match(r"^([0-9]+)", base)
plan = dm.group(1) if dm else base

now = datetime.now().astimezone()
header = json.dumps({"plan": plan, "n": n, "at": now.isoformat(timespec="seconds"), "kind": kind},
                    ensure_ascii=False, separators=(",", ":"))
entry = ["## Session %d — %s (%s)\n" % (n, now.strftime("%Y-%m-%d"), title),
         "<!-- session: %s -->\n" % header, "\n"]
for s in subs:
    entry += ["### %s\n" % s, "\n"]

if insert_at is None:
    head = lines
    if head and not head[-1].endswith("\n"):
        head = head[:-1] + [head[-1] + "\n"]
    if head and head[-1].strip():
        head = head + ["\n"]
    out = "".join(head + entry)
else:
    out = "".join(lines[:insert_at] + entry + lines[insert_at:])

d = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(dir=d, prefix=".handoff.md.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(out)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
except Exception as exc:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    refuse("write failed: %s" % exc)
print("handoff-entry: %s Session %d" % (path, n))
PY

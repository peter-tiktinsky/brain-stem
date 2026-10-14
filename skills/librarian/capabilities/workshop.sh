#!/bin/bash
# workshop — opens, promotes and re-keys research working dirs under CLAUDE_WORKSHOP_DIR.
#
# The workshop (CLAUDE_WORKSHOP_DIR, resolved by hooks/lib/paths.sh; outside the plans tree) holds
# a plan's research precursors: lane notes, drafts, scratch. Only the one synthesis a plan keeps
# moves into <plan>/_research/, so a plan's declared research carries no working material.
#
#   workshop open <key>
#       Creates <workshop>/<key>/ and prints its absolute path. Idempotent.
#   workshop promote <key> <file> --plan <plan-dir>
#       Moves exactly <workshop>/<key>/<file> to <plan-dir>/_research/<NN>-<file> (NN = the next
#       free two-digit prefix; a leading NN- on <file> is dropped first), then moves the rest of
#       <key>/ to <workshop>/_archive/<key>-<YYYY-MM-DD>/ (-2, -3 ... when taken) and removes
#       <key>/. Refuses a gate-named file (plans-rules :: gate_records: a basename token, split
#       on -, _ or ., equals a keyword or fully matches a keyword pattern), whose place is
#       <plan>/_gates/.
#   workshop rekey <topic> <plan-slug>
#       Renames a pre-plan <topic>/ to <topic>-<plan-slug>/.
#
# Key form: a plan's key is <topic>-<plan-slug> (default topic `research`), never a bare
# <plan-slug>: library-scrub resolves a workshop dir's plan only from a trailing plan-dir suffix
# after a non-empty topic, and a dir with no resolvable plan is block-and-logged there.
# The workshop keeps no index and no vault view.
#
# Refusals (exit 2, stderr reason, no write): a key or topic that is empty, holds a /, or starts
# with . or _; a missing key dir, source file, or plan manifest; a source that is not a file
# directly inside the key dir; a gate-named source; a rekey target that already exists.
#
# Output Contract:
#   Files written: open -> <workshop>/<key>/ (mkdir -p). promote -> <plan-dir>/_research/<NN>-<file>
#     (the source bytes, moved) and <workshop>/_archive/<key>-<date>/ (the rest of the key dir,
#     moved); the key dir is removed. rekey -> the renamed dir. Nothing else.
#   stdout: open -> the absolute key dir. promote -> `workshop: promoted <src> -> <dst>` and
#     `workshop: archived <n> entr(y|ies) -> <dir>` when anything remained. rekey ->
#     `workshop: rekeyed <old> -> <new>`.
#   Pre-write validation: the refusals above. Any miss exits 2 and writes nothing.
#   Failure mode: block-and-log (exit 2, no write). Never write-and-hope.
#
# gate_records is read from the .plans slot of the merged foundation + overlay view
# (hooks/lib/foundation-overlay-load.sh), then the raw bundle; PLANS_RULES_PATH names a pillar
# file directly and wins. An unreadable key refuses promote (the gate check cannot run).
#
# CLI:
#   workshop.sh open <key>
#   workshop.sh promote <key> <file> --plan <plan-dir>
#   workshop.sh rekey <topic> <plan-slug>
#   workshop.sh --help
#
# Bash 3.2 clean. Data reaches Python through argv, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

PLAN_DIR=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    --plan)    [ $# -ge 2 ] || { echo "workshop: --plan needs a value" >&2; exit 2; }
               PLAN_DIR="${2%/}"; shift 2 ;;
    -*)        echo "workshop: unknown flag '$1'" >&2; exit 2 ;;
    *)         ARGS+=("$1"); shift ;;
  esac
done
USAGE='workshop: usage: workshop open <key> | promote <key> <file> --plan <plan-dir> | rekey <topic> <plan-slug>'
[ "${#ARGS[@]}" -ge 1 ] || { echo "$USAGE" >&2; exit 2; }
VERB="${ARGS[0]}"
case "$VERB" in
  open)    [ "${#ARGS[@]}" -eq 2 ] && [ -z "$PLAN_DIR" ] || { echo "$USAGE" >&2; exit 2; } ;;
  promote) [ "${#ARGS[@]}" -eq 3 ] && [ -n "$PLAN_DIR" ] || { echo "$USAGE" >&2; exit 2; } ;;
  rekey)   [ "${#ARGS[@]}" -eq 3 ] && [ -z "$PLAN_DIR" ] || { echo "$USAGE" >&2; exit 2; } ;;
  *)       echo "$USAGE" >&2; exit 2 ;;
esac

if [ -z "${CLAUDE_WORKSHOP_DIR:-}" ]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
WS="${CLAUDE_WORKSHOP_DIR:-}"
[ -n "$WS" ] || { echo "workshop: CLAUDE_WORKSHOP_DIR unresolved; nothing written" >&2; exit 2; }

GATE_RULES=""
if [ "$VERB" = "promote" ]; then
  if [[ -n "${PLANS_RULES_PATH:-}" && -f "${PLANS_RULES_PATH}" ]]; then
    GATE_RULES=$(jq -c '(.gate_records // .plans.gate_records) // empty' "${PLANS_RULES_PATH}" 2>/dev/null || true)
  fi
  if [[ -z "$GATE_RULES" ]]; then
    _MASTER="${FOUNDATION_MASTER_PATH:-$CLAUDE_HOME_RES/governance/foundation-master.json}"
    if [[ -f "$_MASTER" ]]; then
      _OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
      [[ -x "$_OVL" ]] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
      if [[ -x "$_OVL" ]]; then
        # The loader's exit code and stderr are kept, never discarded: a failed or degraded overlay
        # load is named on stderr (one line, with its rc) before the raw-bundle fallback below.
        _OVL_ERR="$(mktemp -t workshop-ovl-XXXXXX)"; _OVL_RC=0
        _OVL_OUT=$(bash "$_OVL" --foundation-path "$_MASTER" \
            --overlay-path "$(dirname "$_MASTER")/overlay-master.json" --force-override 2>"$_OVL_ERR") || _OVL_RC=$?
        if [[ "$_OVL_RC" -ne 0 || -s "$_OVL_ERR" ]]; then
          echo "workshop: overlay load failed (rc $_OVL_RC): $(grep -v '^[[:space:]]*$' "$_OVL_ERR" | tail -1)" >&2
        fi
        rm -f "$_OVL_ERR"
        # swallow-ok: reports=none a loader failure is reported on stderr above; this jq only extracts one optional key from the output the loader just produced with exit 0, and an absent key reads as empty and falls back to the master read below
        [[ "$_OVL_RC" -eq 0 ]] && GATE_RULES=$(printf '%s' "$_OVL_OUT" \
            | jq -c '.plans.gate_records // empty' 2>/dev/null || true)
      fi
      [[ -z "$GATE_RULES" ]] && GATE_RULES=$(jq -c '.plans.gate_records // empty' "$_MASTER" 2>/dev/null || true)
    fi
  fi
  [[ -n "$GATE_RULES" ]] || { echo "workshop: gate_records unreadable, so the gate-name check cannot run; nothing written" >&2; exit 2; }
fi

python3 - "$WS" "$VERB" "${ARGS[1]}" "${ARGS[2]:-}" "$PLAN_DIR" "$GATE_RULES" <<'PY'
import json, os, re, shutil, sys
from datetime import date

ws, verb, a1, a2, plan_dir, gate_s = sys.argv[1:7]


def refuse(msg):
    print("workshop: %s; nothing written" % msg, file=sys.stderr)
    sys.exit(2)


def check_name(kind, v):
    if not v or "/" in v or v.startswith((".", "_")) or v in ("..",):
        refuse("%s '%s' must be a non-empty single name not starting with . or _" % (kind, v))


if verb == "open":
    check_name("key", a1)
    d = os.path.join(ws, a1)
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as exc:
        refuse("cannot create %s (%s)" % (d, exc))
    print(os.path.abspath(d))
    sys.exit(0)

if verb == "rekey":
    check_name("topic", a1)
    check_name("plan-slug", a2)
    src = os.path.join(ws, a1)
    dst = os.path.join(ws, "%s-%s" % (a1, a2))
    if not os.path.isdir(src):
        refuse("no workshop dir %s" % src)
    if os.path.lexists(dst):
        refuse("%s already exists" % dst)
    os.rename(src, dst)
    print("workshop: rekeyed %s -> %s" % (src, dst))
    sys.exit(0)

# ---- promote -----------------------------------------------------------------
check_name("key", a1)
key_dir = os.path.join(ws, a1)
if not os.path.isdir(key_dir):
    refuse("no workshop dir %s" % key_dir)
if not a2 or "/" in a2 or a2 in (".", ".."):
    refuse("'%s' is not a file name directly inside %s" % (a2, key_dir))
src = os.path.join(key_dir, a2)
if not os.path.isfile(src) or os.path.islink(src):
    refuse("no file %s" % src)
if not os.path.isfile(os.path.join(plan_dir, "manifest.json")):
    refuse("no manifest.json in %s" % plan_dir)

gate = json.loads(gate_s)
kws = set(str(k) for k in (gate.get("keywords") or []))
kpats = []
for p in gate.get("keyword_patterns") or []:
    try:
        kpats.append(re.compile(str(p)))
    except re.error:
        pass
for tok in re.split(r"[-_.]", a2):
    if tok in kws or any(p.fullmatch(tok) for p in kpats):
        refuse("'%s' is gate-named; a gate record belongs in <plan>/%s/, not _research/"
               % (a2, gate.get("dir") or "_gates"))
try:
    prefix_re = re.compile(str(gate.get("research_prefix_pattern") or r"^[0-9]{2}-"))
except re.error:
    prefix_re = re.compile(r"^[0-9]{2}-")

rdir = os.path.join(plan_dir, "_research")
taken = []
if os.path.isdir(rdir):
    for n in os.listdir(rdir):
        m = re.match(r"^([0-9]{2})-", n)
        if m:
            taken.append(int(m.group(1)))
nn = max(taken) + 1 if taken else 1
if nn > 99:
    refuse("no free two-digit prefix left in %s" % rdir)
m = prefix_re.match(a2)
stem = a2[m.end():] if m else a2
dst = os.path.join(rdir, "%02d-%s" % (nn, stem))
if os.path.lexists(dst):
    refuse("%s already exists" % dst)

rest = sorted(n for n in os.listdir(key_dir) if n != a2)
arch_root = os.path.join(ws, "_archive")
arch = os.path.join(arch_root, "%s-%s" % (a1, date.today().isoformat()))
i = 2
while os.path.lexists(arch):
    arch = os.path.join(arch_root, "%s-%s-%d" % (a1, date.today().isoformat(), i))
    i += 1

os.makedirs(rdir, exist_ok=True)
shutil.move(src, dst)
print("workshop: promoted %s -> %s" % (src, dst))
if rest:
    os.makedirs(arch_root, exist_ok=True)
    shutil.move(key_dir, arch)
    print("workshop: archived %d %s -> %s" % (len(rest), "entry" if len(rest) == 1 else "entries", arch))
else:
    os.rmdir(key_dir)
PY

#!/usr/bin/env bash
# skills/onboarder/scripts/claude-mem-context-set.sh — apply the claude-mem context recipe
# the onboarding gate prints, on request.
#
# claude-mem injects a "recent context" index into every new session. The onboarding gate
# (external-setup-gate.sh) prints the settings that turn it off and never writes third-party
# configuration; this command is the explicit, opt-in write of that same recipe into the
# plugin's own settings file.
#
# USAGE
#   claude-mem-context-set.sh [--apply] [--settings PATH]
#
#   --settings PATH   the claude-mem settings file (default $HOME/.claude-mem/settings.json).
#   --apply           write the file. Without it this is a dry run: it lists each key that
#                     would change as `  <KEY>: <old> -> <new>` and writes nothing.
#
# The recipe: CLAUDE_MEM_CONTEXT_OBSERVATIONS and CLAUDE_MEM_CONTEXT_SESSION_COUNT set to the
# string "0"; CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY, _SHOW_LAST_MESSAGE, _SHOW_READ_TOKENS,
# _SHOW_WORK_TOKENS, _SHOW_SAVINGS_AMOUNT, _SHOW_SAVINGS_PERCENT and _SHOW_TERMINAL_OUTPUT set to
# the string "false", all as flat top-level string values. A key whose value is not exactly that
# string (a number 0, a boolean false) is rewritten to it. Every other key keeps its value and
# position; a missing key is appended in the recipe's order. The command never creates the
# settings file: it belongs to claude-mem, which writes it on its first run.
#
# --apply holds /usr/bin/lockf -k -t 2 on $HOOKS_STATE/claude-mem-context-set.lock across the
# re-check and the write (kernel-backed; absent lockf: unlocked). HOOKS_STATE comes from the
# environment, else from ${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh when it is readable.
# The write goes to a temp file in the settings file's own directory and is renamed over it.
#
# Exit codes:
#   0   done, dry run, or already set (nothing to write)
#   1   the rename failed; nothing changed
#   2   refused (the last stderr line is `claude-mem-context-set: refused: <reason>`)
#   75  lock contention; nothing was written
#
# R-23: bash 3.2 compat. Data reaches python through argv, never a piped stdin.
set -u

PAIRS="CLAUDE_MEM_CONTEXT_OBSERVATIONS=0
CLAUDE_MEM_CONTEXT_SESSION_COUNT=0
CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY=false
CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE=false
CLAUDE_MEM_CONTEXT_SHOW_READ_TOKENS=false
CLAUDE_MEM_CONTEXT_SHOW_WORK_TOKENS=false
CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_AMOUNT=false
CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_PERCENT=false
CLAUDE_MEM_CONTEXT_SHOW_TERMINAL_OUTPUT=false"

# The one python program. argv: <mode> <settings> [<tmp>] <KEY=VALUE>...
#   check  exit 0 when the file parses to a JSON object, else 3
#   diff   print `  <KEY>: <old> -> <new>` for each key that would change
#   write  apply the pairs to the parsed object and write it to <tmp>
CMC_PY='
import json, sys
mode, path = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
tmp = rest.pop(0) if mode == "write" else None
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(3)
if not isinstance(data, dict):
    sys.exit(3)
if mode == "check":
    sys.exit(0)
pairs = [p.split("=", 1) for p in rest]
changed = [(k, v) for k, v in pairs if not (isinstance(data.get(k), str) and data.get(k) == v)]
if mode == "diff":
    for k, v in changed:
        if k not in data:
            old = "absent"
        elif isinstance(data[k], str):
            old = data[k]
        else:
            old = json.dumps(data[k], ensure_ascii=False, separators=(",", ":"))
        print("  %s: %s -> %s" % (k, old, v))
    sys.exit(0)
for k, v in changed:
    data[k] = v
with open(tmp, "w", encoding="utf-8") as out:
    json.dump(data, out, indent=2, ensure_ascii=False)
    out.write("\n")
'

ORIG_ARGS=("$@")
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

refuse() {
  printf 'claude-mem-context-set: refused: %s\n' "$*" >&2
  exit 2
}

apply=0
settings=""
unknown=""
need_path=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --settings)
      if [ $# -lt 2 ]; then need_path=1; shift; else settings="$2"; shift 2; fi
      ;;
    *) [ -n "$unknown" ] || unknown="$1"; shift ;;
  esac
done
[ -z "$unknown" ] || refuse "unknown flag '$unknown'"
[ "$need_path" -eq 0 ] || refuse "--settings needs a path"
[ -n "$settings" ] || settings="$HOME/.claude-mem/settings.json"

command -v python3 >/dev/null 2>&1 || refuse "python3 is required"
[ -f "$settings" ] || refuse "$settings does not exist; start claude-mem once so it creates its settings file"
python3 -c "$CMC_PY" check "$settings" || refuse "$settings is not a JSON object"

if [ "$apply" -eq 1 ] && [ -x /usr/bin/lockf ]; then
  if [ -z "${HOOKS_STATE:-}" ] && [ -r "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" ]; then
    # swallow-ok: reports=exit a paths.sh that sets nothing leaves HOOKS_STATE empty and the next line refuses with exit 2
    . "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" >/dev/null 2>&1 || true
  fi
  [ -n "${HOOKS_STATE:-}" ] || refuse "HOOKS_STATE is unresolved"
fi

# shellcheck disable=SC2086
changes="$(python3 -c "$CMC_PY" diff "$settings" $PAIRS)"
if [ -z "$changes" ]; then
  printf 'claude-mem-context-set: already set; nothing to write\n'
  exit 0
fi
if [ "$apply" -eq 0 ]; then
  printf '%s\n' "$changes"
  printf 'claude-mem-context-set: dry run; pass --apply to write\n'
  exit 0
fi

# --apply: re-run this script under the lock, so the re-check and the write share one hold.
if [ -z "${CLAUDE_MEM_CONTEXT_SET_LOCKED:-}" ] && [ -x /usr/bin/lockf ]; then
  lock="$HOOKS_STATE/claude-mem-context-set.lock"
  mkdir -p "$HOOKS_STATE" || refuse "cannot create the state directory $HOOKS_STATE"
  rc=0
  CLAUDE_MEM_CONTEXT_SET_LOCKED=1 HOOKS_STATE="$HOOKS_STATE" /usr/bin/lockf -k -t 2 "$lock" "${BASH:-bash}" "$SELF" "${ORIG_ARGS[@]}" || rc=$?
  if [ "$rc" -eq 75 ]; then
    printf 'claude-mem-context-set: lock contention on %s (rc 75); nothing was written\n' "$lock" >&2
  fi
  exit "$rc"
fi

tmp="$(mktemp "$(dirname "$settings")/.claude-mem-context-set.XXXXXX")" || refuse "cannot create a temp file beside $settings"
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
cp -p "$settings" "$tmp" || refuse "cannot copy the mode of $settings to its temp file"
# shellcheck disable=SC2086
python3 -c "$CMC_PY" write "$settings" "$tmp" $PAIRS || refuse "$settings is not a JSON object"
if ! mv "$tmp" "$settings"; then
  printf 'claude-mem-context-set: could not write %s; nothing changed\n' "$settings" >&2
  exit 1
fi
trap - EXIT
printf 'claude-mem-context-set: wrote %s\n' "$settings"
exit 0

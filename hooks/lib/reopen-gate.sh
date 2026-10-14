#!/bin/bash
# reopen-gate.sh — read and evaluate the re-open gates a parked NO-BUILD inbox note names.
#
# A NO-BUILD note carries `reopen_gate: <id>`. The id is looked up in the plans pillar's
# `inbox.reopen_gates` registry (an object keyed by gate id, so an overlay ADDs an id). A gate is
#   {"kind": "manual"}
#       an operator re-opens the note; this reader never evaluates it.
#   {"kind": "command", "argv": [<path>, <arg>...], "timeout_s": <n>}
#       argv[0] is an absolute path, or a path relative to the foundation root (no leading
#       slash, no `..` component). The foundation root is the directory two levels above this
#       script: the checkout in a development tree, the install root once installed. The command
#       runs through python subprocess with shell=False, stdin closed and output discarded;
#       exit 0 means the gate is met.
# A gate is never a shell string, and a note's frontmatter only ever names an id.
#
# CLI:
#   reopen-gate.sh --list           print every registered gate id, one per line
#   reopen-gate.sh --eval <id>      evaluate one gate
#   reopen-gate.sh --help
#
# Exit codes for --eval:
#   0  gate met          1  gate not met        3  unknown id
#   4  manual gate       5  error (a malformed gate, an argv[0] with a `..` component, a launch
#                           failure, a timeout, or a command exit status other than 0 or 1)
# Exit 2 is a usage error; --list exits 0, or 5 when the registry cannot be read.
#
# The rules are resolved as backlog-index resolves them: PLANS_RULES_PATH, else the loose pillar
# under $CLAUDE_HOME/governance, else the merged `.plans` view from foundation-overlay-load.sh
# (foundation master plus overlay master, read with --force-override).
#
# Bash 3.2 clean per R-23. Argv-based Python per R-24.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FOUNDATION_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"

MODE=""; GATE_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    --eval)
      if [ $# -lt 2 ]; then echo "reopen-gate: --eval needs a gate id" >&2; exit 2; fi
      MODE="eval"; GATE_ID="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "reopen-gate: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "reopen-gate: usage: reopen-gate.sh --list | --eval <id>" >&2
  exit 2
fi

RULES_PATH="${PLANS_RULES_PATH:-}"
if [ -z "$RULES_PATH" ] && [ -f "$CLAUDE_HOME_RES/governance/plans-rules.json" ]; then
  RULES_PATH="$CLAUDE_HOME_RES/governance/plans-rules.json"
fi
_rt=""
if [ -z "$RULES_PATH" ] || [ ! -f "$RULES_PATH" ]; then
  for _loader in \
    "$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh" \
    "$SCRIPT_DIR/foundation-overlay-load.sh"; do
    [ -x "$_loader" ] || continue
    _rt="$(mktemp 2>/dev/null)" || break
    if bash "$_loader" --query '.plans' --force-override > "$_rt" 2>/dev/null \
         && [ -s "$_rt" ] && [ "$(head -c4 "$_rt" 2>/dev/null)" != null ]; then
      RULES_PATH="$_rt"; break
    fi
    rm -f "$_rt"; _rt=""
  done
fi
trap '[ -z "$_rt" ] || rm -f "$_rt"' EXIT
if [ -z "$RULES_PATH" ] || [ ! -f "$RULES_PATH" ]; then
  echo "reopen-gate: plans rules not found and no foundation-master+overlay bundle (set PLANS_RULES_PATH)" >&2
  exit 5
fi

python3 - "$MODE" "$GATE_ID" "$RULES_PATH" "$FOUNDATION_ROOT" <<'PY'
import json
import os
import subprocess
import sys

mode, gate_id, rules_path, root = sys.argv[1:5]


def die(code, msg):
    print("reopen-gate: %s" % msg, file=sys.stderr)
    sys.exit(code)


try:
    with open(rules_path, encoding="utf-8") as fh:
        rules = json.load(fh)
except (OSError, ValueError) as exc:
    die(5, "cannot read plans rules %s (%s)" % (rules_path, exc))

gates = rules.get("inbox", {}).get("reopen_gates", {}) if isinstance(rules, dict) else {}
if not isinstance(gates, dict):
    die(5, "inbox.reopen_gates is not an object")

if mode == "list":
    for key in sorted(gates):
        if not key.startswith("_"):
            print(key)
    sys.exit(0)

if gate_id not in gates or gate_id.startswith("_"):
    print("reopen-gate: unknown gate '%s'" % gate_id, file=sys.stderr)
    sys.exit(3)
gate = gates[gate_id]
kind = gate.get("kind") if isinstance(gate, dict) else None
if kind == "manual":
    sys.exit(4)
if kind != "command":
    die(5, "gate '%s' has no kind manual or command" % gate_id)

argv = gate.get("argv")
timeout_s = gate.get("timeout_s")
if (not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv)
        or not argv[0] or isinstance(timeout_s, bool)
        or not isinstance(timeout_s, (int, float)) or timeout_s <= 0):
    die(5, "gate '%s' is a malformed command gate" % gate_id)

prog = argv[0]
if not os.path.isabs(prog):
    if ".." in prog.split("/"):
        die(5, "gate '%s' argv[0] has a '..' component; nothing was run" % gate_id)
    prog = os.path.join(root, prog)
cmd = [prog] + argv[1:]

try:
    proc = subprocess.run(cmd, shell=False, timeout=timeout_s, stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except subprocess.TimeoutExpired:
    die(5, "gate '%s' timed out after %ss" % (gate_id, timeout_s))
except OSError as exc:
    die(5, "gate '%s' could not be launched (%s)" % (gate_id, exc))

if proc.returncode == 0:
    sys.exit(0)
if proc.returncode == 1:
    sys.exit(1)
die(5, "gate '%s' command exited %d" % (gate_id, proc.returncode))
PY

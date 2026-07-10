#!/bin/bash
# Hook: tasks-md-autosync — PostToolUse Edit|Write — the WRITE-side consumer of
# the canonical `<!-- task-done: NN/T-M -->` completion marker, re-pointed to the
# manifest SoT (T-05).
# Re-point (NOT the retired satellite behavior): the legacy hook flipped the
# generated tasks.md `**Status:**` line directly off backlog-progress satellites.
# That satellite is retired (0) and editing the generated view is the named
# anti-pattern. The CORRECT target — SAME trigger, correct sink — is:
#   1. a task-done marker lands in a plan's handoff.md (PostToolUse Edit|Write),
#   2. this hook writes manifest.tasks[].status='done' (the task-state SoT), then
#   3. invokes librarian:tasks-render so tasks.md re-renders with strike-through.
# The marker grammar is preserved: `<!-- task-done: NN/T-M -->` (sub-plan form) or
# `<!-- task-done: T-M -->` (plan-root form), one marker per completed task.
# ============================ OUTPUT CONTRACT =================================
# Files written:
#   <plan-dir>/manifest.json  — the matching tasks[].status flipped to "done"
#                               (the task-state SoT). Atomic temp+rename.
#   <plan-dir>/tasks.md       — re-rendered ONLY via librarian:tasks-render (never
#                               edited directly; the read-replica stays generated).
#   audit log                 — $HOOKS_STATE/tasks-md-autosync.log (append).
# Schema gate: the plan manifest is validated against
#   schemas/plan-manifest-schema.json BEFORE the status write (jsonschema when
#   available; structural fallback otherwise) — block-and-log on failure.
# Pre-write validation: resolve <plan-dir> from the written handoff.md; assert
#   manifest.json present + a tasks[] entry matching the marker id; refuse the
#   write (block-and-log) if the resolved task id is absent.
# Failure mode: BLOCK-AND-LOG, never write-and-hope. Any resolution / parse /
#   schema failure is logged and the hook exits 0 (fail-open: never denies a
#   write, never halts the session). The manifest is mutated ONLY on a fully
#   resolved + schema-valid path; tasks.md is touched ONLY by tasks-render.
# Non-mutating signals: keys on the written file path being a handoff.md carrying
#   >=1 task-done marker; no-op otherwise.
# Bash 3.2 clean (R-23). Argv-based Python heredoc (R-24 — data passed via argv,
# never piped to the heredoc). Honors HOOKS_STATE_OVERRIDE for test isolation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Audit log (test-isolatable). HOOKS_STATE_OVERRIDE wins so harnesses never touch
# the live runtime state dir.
STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}"
LOG="$STATE_DIR/tasks-md-autosync.log"

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# Fail-open prerequisites.
command -v python3 >/dev/null 2>&1 || exit 0

# --- read the PostToolUse payload (the written file path) --------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

FILE_PATH=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
fi
# Direct-invocation path (harness / re-exec): first arg is the handoff.md path.
[ -z "$FILE_PATH" ] && [ -n "${1:-}" ] && FILE_PATH="$1"
[ -z "$FILE_PATH" ] && exit 0

# Only a handoff.md carries the relocated task-done marker.
case "$FILE_PATH" in
  */handoff.md|handoff.md) ;;
  *) exit 0 ;;
esac
[ -f "$FILE_PATH" ] || exit 0

# Cheap gate: bail unless the file actually carries a task-done marker.
grep -q 'task-done:' "$FILE_PATH" 2>/dev/null || exit 0

PLAN_DIR="$(cd "$(dirname "$FILE_PATH")" && pwd)"
MANIFEST_PATH="$PLAN_DIR/manifest.json"
if [ ! -f "$MANIFEST_PATH" ]; then
  log "no-op: no manifest.json in $PLAN_DIR (handoff: $FILE_PATH)"
  exit 0
fi

# Resolve the plan-manifest schema (foundation -> live), like tasks-render.sh.
SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-}"
if [ -z "$SCHEMA_PATH" ]; then
  for cand in \
    "${CLAUDE_HOME:-$HOME/.claude}/schemas/plan-manifest-schema.json"; do
    if [ -f "$cand" ]; then SCHEMA_PATH="$cand"; break; fi
  done
fi

# --- flip manifest.tasks[].status='done' for each marked id (SoT write) ------
# All inputs passed via argv (R-24). Prints the comma-separated flipped ids on
# stdout, or "ERR:<reason>" on a block-and-log failure (no mutation in that case).
RESULT=$(python3 - "$MANIFEST_PATH" "$FILE_PATH" "$SCHEMA_PATH" <<'PY'
import json
import os
import re
import sys
import tempfile

manifest_path = sys.argv[1]
handoff_path = sys.argv[2]
schema_path = sys.argv[3]

MARKER_RE = re.compile(r"<!--\s*task-done:\s*(?:[^/\s]+/)?(T-[0-9]+(?:\.[0-9]+)?)\s*-->")

try:
    with open(handoff_path, encoding="utf-8") as fh:
        marked = set(MARKER_RE.findall(fh.read()))
except Exception as exc:
    print("ERR:handoff-read:%s" % exc)
    sys.exit(0)

if not marked:
    print("")  # no markers -> nothing to do
    sys.exit(0)

try:
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
except Exception as exc:
    print("ERR:manifest-parse:%s" % exc)
    sys.exit(0)

# Schema gate BEFORE any write (block-and-log; Output Contract).
if schema_path and os.path.isfile(schema_path):
    try:
        import jsonschema  # type: ignore
        with open(schema_path, encoding="utf-8") as fh:
            schema = json.load(fh)
        jsonschema.Draft202012Validator(schema).validate(manifest)
    except ImportError:
        pass
    except Exception as exc:
        print("ERR:schema:%s" % exc)
        sys.exit(0)

tasks = manifest.get("tasks")
if not isinstance(tasks, list):
    print("ERR:no-tasks-array")
    sys.exit(0)

by_id = {}
for t in tasks:
    if isinstance(t, dict):
        by_id[t.get("id", "")] = t

flipped = []
unknown = []
for tid in sorted(marked):
    t = by_id.get(tid)
    if t is None:
        unknown.append(tid)
        continue
    if t.get("status") != "done":
        t["status"] = "done"
        flipped.append(tid)

if unknown and not flipped:
    # Resolved no real task — refuse to mutate (block-and-log).
    print("ERR:unknown-task-ids:%s" % ",".join(unknown))
    sys.exit(0)

if not flipped:
    print("")  # already done — idempotent no-op
    sys.exit(0)

d = os.path.dirname(manifest_path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, manifest_path)
except Exception as exc:
    if os.path.exists(tmp):
        os.unlink(tmp)
    print("ERR:manifest-write:%s" % exc)
    sys.exit(0)

print(",".join(flipped))
PY
)

case "$RESULT" in
  ERR:*)
    log "block-and-log: $RESULT (plan=$PLAN_DIR)"
    exit 0
    ;;
  "")
    # No new flips (no markers resolved / already done). tasks.md may still be
    # stale on a fresh marker that was already done — nothing to do; exit clean.
    exit 0
    ;;
esac

log "manifest.tasks[].status=done for [$RESULT] (plan=$PLAN_DIR)"

# --- re-render tasks.md from the manifest via librarian:tasks-render ---------
# tasks-render is the ONLY writer of the generated view. It reads the
# flipped manifest status (the SoT) + the handoff marker and renders strike-through.
RENDER="$SCRIPT_DIR/../skills/librarian/capabilities/tasks-render.sh"
[ -f "$RENDER" ] || RENDER="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/tasks-render.sh"
if [ -f "$RENDER" ]; then
  if FOUNDATION_TEST_MODE=1 bash "$RENDER" "$PLAN_DIR" >/dev/null 2>&1; then
    log "tasks-render ok (plan=$PLAN_DIR)"
  else
    log "tasks-render error (plan=$PLAN_DIR)"
  fi
else
  log "tasks-render body not found; manifest flipped but view not re-rendered (plan=$PLAN_DIR)"
fi

exit 0

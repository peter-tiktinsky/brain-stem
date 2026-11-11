#!/bin/bash
# master-rollup.sh — keep a master plan's tasks.md in step with its sub-plans.
#
#   master-rollup.sh <master-NN-slug>        (reached as: new-plan.sh --rollup <master-NN-slug>)
#
# The master manifest's sub_plans[] is a pull-based read-replica of the sub-plan
# manifests (written by the librarian subplan-aggregate capability). The master's tasks.md
# carries a second replica of the same status, the `| Sub-plan | Slug | Status |` table.
# This command pulls the first and rewrites the rows of the second from it, in one locked
# pass, in this order (no step writes before the previous one passed):
#   1. Validate, read-only: the name shape, the plan directory, a parseable manifest of
#      type master, exactly one rollup table in tasks.md, and the aggregator.
#   2. Lock: a blocking exclusive flock(2) on the master directory fd, the lock
#      --add-subplan takes to number a sub-plan, held to the end. No lock file.
#   3. Pull: run the aggregator on the master (its findings go to a scratch file).
#   4. Derive: when the pull changed the manifest bytes, run plan_after_write on it
#      (lib/after-write.sh), before the render.
#   5. Render: one row per sub_plans[] entry, in order, `| <id> | `<dir>` | <status> |`.
#   6. Write: only the consecutive rows after the table's separator row are replaced;
#      every other byte of tasks.md is kept; one atomic temp-file-and-rename that keeps
#      the file's mode; no write when the rows already match.
#
# Output: stdout one JSON line {mode, master_slug, rows, manifest_changed,
# tasks_md_changed}; stderr one human line. Exit 0 done, 1 aborted (a validation refusal
# or a failure that left tasks.md unchanged), 2 usage. A master tasks.md carries no
# tasks:start/end sentinel pair and this command never writes one.
#
# Env: PLANS_ROOT, else PLANS_DIR, else $HOME/.claude-plans (the plans root).
#      CLAUDE_HOME (default $HOME/.claude): the install root the aggregator resolves in.
#
# Bash 3.2 clean (R-23). Data reaches python3 through argv (R-24), never a piped stdin.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
if [[ -z "$ARG" ]]; then
  echo "new-plan: missing <slug> (see --help)" >&2
  exit 2
fi

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
CH="${CLAUDE_HOME:-$HOME/.claude}"

exec python3 - "$ARG" "$PLANS_ROOT" "$CH/skills/librarian/capabilities/subplan-aggregate.sh" \
  "$LIB_DIR/after-write.sh" <<'PY'
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import tempfile

arg, plans_root, aggregator, after_write = sys.argv[1:5]
HEADER = "| Sub-plan | Slug | Status |"
SEP_RE = re.compile(r"^\|[ :|-]*-[ :|-]*\|$")
PLAN_DIR_RE = re.compile(r"^[0-9]{2,}-[a-z][a-z0-9-]+$")


def abort(msg):
    print("new-plan: aborted — %s" % msg, file=sys.stderr)
    sys.exit(1)


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


# 1. Validate, read-only.
if not PLAN_DIR_RE.match(arg):
    abort("invalid plan dir name '%s' (expected NN-slug)" % arg)
master_dir = os.path.join(plans_root, arg)
if not os.path.isdir(master_dir):
    abort("plan dir not found: %s" % master_dir)
manifest_path = os.path.join(master_dir, "manifest.json")
if not os.path.isfile(manifest_path):
    abort("manifest not found: %s" % manifest_path)
try:
    manifest = json.loads(read_bytes(manifest_path).decode("utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("not an object")
except Exception:
    abort("manifest unparseable: %s" % manifest_path)
if manifest.get("type") != "master":
    abort("target manifest type is '%s', expected 'master'" % manifest.get("type"))

tasks_path = os.path.join(master_dir, "tasks.md")


def read_tasks():
    with open(tasks_path, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return fh.read()


def find_table(text):
    """Index of the one rollup header line, or abort when there is not exactly one."""
    lines = text.split("\n")
    heads = [i for i, ln in enumerate(lines) if ln.rstrip() == HEADER]
    if len(heads) > 1:
        abort("more than one '%s' rollup table in %s" % (HEADER, tasks_path))
    if not heads or heads[0] + 1 >= len(lines) or not SEP_RE.match(lines[heads[0] + 1].rstrip()):
        abort("no '%s' rollup table in %s" % (HEADER, tasks_path))
    return lines, heads[0]


if os.path.isfile(tasks_path):
    find_table(read_tasks())
else:
    abort("no '%s' rollup table in %s" % (HEADER, tasks_path))
if not os.path.isfile(aggregator):
    abort("subplan-aggregate not resolved (looked in %s)" % aggregator)

# 2. Lock: blocking, exclusive, on the master directory fd, held to the exit. The
# kernel drops it at exit or death, so no abort path needs an unlock.
lock_fd = os.open(master_dir, os.O_RDONLY)
fcntl.flock(lock_fd, fcntl.LOCK_EX)

# 3. Pull: the aggregator rewrites sub_plans[] (atomically). Its findings go to a
# scratch file so no NDJSON reaches stdout.
before = read_bytes(manifest_path)
env = dict(os.environ, PLANS_ROOT=plans_root, PLANS_DIR=plans_root, SUBPLAN_AGGREGATE_LOCK_HELD=master_dir)
fd, findings = tempfile.mkstemp(prefix="rollup-findings.", suffix=".ndjson")
os.close(fd)
env["FINDINGS_OUTPUT"] = findings
try:
    rc = subprocess.run(["bash", aggregator, master_dir], env=env, stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL).returncode
finally:
    if os.path.exists(findings):
        os.unlink(findings)
if rc != 0:
    abort("subplan-aggregate failed (rc %d); tasks.md not written" % rc)
manifest_changed = read_bytes(manifest_path) != before

# 4. Derive, before the render: a failed tasks.md write still leaves the pulled manifest
# derived. The caller's plans root rides in as a shell variable that plan_after_write
# exports for the two hooks; nothing ambient is trusted.
if manifest_changed:
    subprocess.run(["bash", "-c", 'PLANS_ROOT="$3"; . "$1"; plan_after_write "$2"', "rollup-derive",
                    after_write, manifest_path, plans_root],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)

# 5. Render one row per sub_plans[] entry, from the manifest as the pull left it.
with open(manifest_path, encoding="utf-8") as fh:
    pulled = json.load(fh)
rows = ["| %s | `%s` | %s |" % (sp.get("sub_plan_id", ""), sp.get("slug", ""), sp.get("status", ""))
        for sp in (pulled.get("sub_plans") or []) if isinstance(sp, dict)]

# 6. Write only the rows after the separator row; keep every other byte and the mode.
text = read_tasks()
lines, head = find_table(text)
first = head + 2
last = first
while last < len(lines) and lines[last].startswith("|"):
    last += 1
tasks_changed = lines[first:last] != rows
if tasks_changed:
    new_text = "\n".join(lines[:first] + rows + lines[last:])
    tmp = None
    try:
        mode = stat.S_IMODE(os.stat(tasks_path).st_mode)
        fd, tmp = tempfile.mkstemp(dir=master_dir, prefix=".tasks.md.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(new_text)
        os.chmod(tmp, mode)
        os.replace(tmp, tasks_path)
    except Exception as exc:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        abort("rollup write failed (%s); tasks.md unchanged" % exc)

print("new-plan: rolled up %s (%d sub-plan row(s))" % (arg, len(rows)), file=sys.stderr)
print(json.dumps({"mode": "rollup", "master_slug": arg, "rows": len(rows),
                  "manifest_changed": manifest_changed, "tasks_md_changed": tasks_changed},
                 ensure_ascii=False))
PY

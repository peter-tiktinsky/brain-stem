#!/bin/bash
# trinity-drift-detect — Detect disagreement between spec.md / manifest.json /
# tasks.md / per-task T-N statuses across plan-root and sub-plan-root dirs, AND
# (the extension) between a master's sub_plans[] read-replica and the
# subs' real published status (the master<->sub aggregation axis).
#
# Librarian reconciler (1.1 line 129). Ported from the
# trinity-drift-detect.sh. The trinity axis
# is PARTIALLY RETIRED under DERIVE (manifest is the sole status SoT): the
# `spec-manifest-divergence` + `header-trinity-divergence` sub-axes read the plan
# artifact FRONTMATTER status (spec.md/tasks.md status:) that no longer exists after
# the strip, so they are RETIRED; `trinity-task-ledger-lag` (manifest status + the
# per-task ledger **Status:** lines) is PRESERVED. The master<->sub aggregation axis
# is the NET-NEW extension per §Decision (b) + line 119 — manifest-only,
# unaffected by DERIVE, PRESERVED.
#
# Cross-file invariants live in THIS reconciler, NEVER in a blocking write-time
# path. The PreToolUse substance branch + PostToolUse manifest-verify
# hook are-owned (line 342) — out of scope here.
#
# R-61/62/63 ENFORCED (this body is the trinity-drift-detect consumer;
# the-landed shape: R-61 reconciler aggregation-integrity, R-62 reconciler
# sub-publishes-upward [SEPARATE, not folded], R-63 advisory sub-peer-isolation;
# all enforcement_layer:[librarian], category C3):
#   R-61 master-sub-aggregation-drift  — sub_plans[].status != the sub's real status
#   R-62 sub-publishes-upward          — a sub failed to publish a transition the master shows stale
#   R-63 sub-peer-isolation (advisory) — a sub manifest carries a dependencies edge to a sibling sub
#
# Output Contract
#   Files written: findings to stdout (NDJSON via hooks/lib/findings.sh) or
#     $FINDINGS_OUTPUT. Read-only — never writes manifests (the optional --fix
#     of the aggregation drift lives in drift-sweep.sh, not here).
#   Failure mode: block-and-log; never write-and-hope. Parse failures emit a
#     parse-failure finding and continue the walk.
#
# Finding categories:
#   trinity-status-drift   (the existing spec/manifest/tasks axis, drift_class as before)
#   master-sub-aggregation-drift (R-61)   master sub_plans[] vs sub real status
#   sub-publishes-upward-gap (R-62)       sub transition the master shows stale
#   sub-peer-isolation (R-63, advisory)   sub depends on a sibling sub
#
# CLI:
#   trinity-drift-detect.sh                # emit findings to $FINDINGS_OUTPUT or stdout
#   trinity-drift-detect.sh --scope <path> # limit walk root
#   trinity-drift-detect.sh --dry-run      # summary counts, no emission
#   trinity-drift-detect.sh --axis <a>     # a = all (default) | master-sub | trinity-status
#                                          # request ONE axis so two callers emit DISJOINT axes
#   trinity-drift-detect.sh --help
#
# Bash 3.2 clean per R-23. No declare -A, no =~, no ${var,,}.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"
if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

SCOPE=""
DRY_RUN="false"
# Axis selector. `all` (default) = current full-axis behavior (both the trinity-
# status axis and the master<->sub aggregation axis); `master-sub` = only the
# R-61/62/63 aggregation axis; `trinity-status` = only the trinity axis. Additive:
# a caller that passes no --axis gets the unchanged full-axis behavior.
AXIS="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --axis) AXIS="$2"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "trinity-drift-detect: unknown flag '$1'" >&2; exit 2 ;;
  esac
done
case "$AXIS" in
  all|master-sub|trinity-status) ;;
  *) echo "trinity-drift-detect: unknown --axis '$AXIS' (expected: all|master-sub|trinity-status)" >&2; exit 2 ;;
esac

PLANS_SCOPE="${SCOPE:-${PLANS_DIR:-$HOME/.claude-plans}}"
if [[ ! -d "$PLANS_SCOPE" ]]; then
  echo "trinity-drift-detect: scope not a directory: $PLANS_SCOPE" >&2
  exit 2
fi

python3 - "$PLANS_SCOPE" "$DRY_RUN" "$AXIS" <<'PY'
import json, os, re, sys
from datetime import datetime

plans_scope, dry_run_s, axis = sys.argv[1:4]
dry_run = (dry_run_s == "true")
# Gate the two axes on the selector. `all` runs both (default).
run_trinity = axis in ("all", "trinity-status")
run_master_sub = axis in ("all", "master-sub")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
iso_now = datetime.now().isoformat(timespec="seconds")
TERMINAL = {"completed", "superseded"}

def emit(payload):
    if dry_run:
        return
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return None

def load_manifest(path):
    t = read_text(path)
    if t is None:
        return None, None
    try:
        d = json.loads(t)
    except Exception:
        return None, "parse-failure"
    return (d if isinstance(d, dict) else None), (None if isinstance(d, dict) else "parse-failure")

def parse_manifest_status(path):
    d, err = load_manifest(path)
    if err:
        return "", err
    if d is None:
        return "", None
    v = d.get("status", "")
    return (v if isinstance(v, str) else ""), None

TASK_HEADING = re.compile(r"^###\s+(T-\d+)\s*:", re.MULTILINE)
STATUS_LINE = re.compile(r"^\*\*Status:\*\*\s*(.+?)\s*$", re.MULTILINE)

def parse_task_ledger(path):
    t = read_text(path)
    if t is None:
        return [], None
    body = t
    if t.startswith("---"):
        end = t.find("\n---", 3)
        if end == -1:
            return [], "parse-failure"
        body = t[end + 4:]
    headings = [(m.group(1), m.start()) for m in TASK_HEADING.finditer(body)]
    out = []
    for i, (tid, offset) in enumerate(headings):
        end = headings[i + 1][1] if i + 1 < len(headings) else len(body)
        section = body[offset:end]
        sm = STATUS_LINE.search(section)
        status = ""
        if sm:
            raw = sm.group(1).strip().strip("*").strip("_").strip()
            m2 = re.match(r"([A-Za-z-]+)", raw)
            status = m2.group(1) if m2 else raw
        out.append({"id": tid, "status": status})
    return out, None

def norm(s):
    return (s or "").strip().lower()

COMPLETE_SET = {"complete", "completed", "done", "implemented"}
PENDING_SET = {"not-started", "not started", "pending", "planned", "todo"}

def is_complete(s):
    return norm(s) in COMPLETE_SET

def is_pending(s):
    return norm(s) in PENDING_SET

counts = {"trinity-task-ledger-lag": 0, "parse-failure": 0,
          "master-sub-aggregation-drift": 0, "sub-publishes-upward-gap": 0,
          "sub-peer-isolation": 0}
inspected = 0

def inspect_trinity(dirpath):
    """spec/manifest/tasks/T-N axis. DERIVE: the two artifact-frontmatter sub-axes
    (spec-manifest-divergence, header-trinity-divergence) are RETIRED (they read the
    stripped status: frontmatter); trinity-task-ledger-lag (manifest + per-task
    ledger) is PRESERVED."""
    global inspected
    spec_p = os.path.join(dirpath, "spec.md")
    manifest_p = os.path.join(dirpath, "manifest.json")
    tasks_p = os.path.join(dirpath, "tasks.md")
    if not (os.path.isfile(spec_p) and os.path.isfile(manifest_p)):
        return
    inspected += 1
    rel = os.path.relpath(dirpath, plans_scope)
    manifest_s, manifest_err = parse_manifest_status(manifest_p)
    has_tasks = os.path.isfile(tasks_p)
    ledger, ledger_err = parse_task_ledger(tasks_p) if has_tasks else ([], None)
    errs = [e for e in (manifest_err, ledger_err) if e]
    if errs:
        emit({"finding": "trinity-status-drift", "file": rel, "drift_class": "parse-failure",
              "manifest_status": manifest_s,
              "task_ledger": ledger, "parse_errors": errs, "detected_at": iso_now})
        counts["parse-failure"] += 1
        return
    # RETIRED (DERIVE / manifest-as-sole-status-SoT): the `spec-manifest-divergence` and
    # `header-trinity-divergence` sub-axes compared spec.md/tasks.md FRONTMATTER status
    # against the manifest / each other. Under DERIVE, plan artifacts no longer carry
    # status: frontmatter — the manifest is the single status SoT — so both read a field
    # that no longer exists. They are fully removed: no counters, no artifact-frontmatter
    # parsing, and no spec/tasks status payload fields.
    #
    # PRESERVED: `trinity-task-ledger-lag` reads the MANIFEST status (manifest_s) and
    # the per-task ledger **Status:** lines (parse_task_ledger) — NEITHER is artifact
    # frontmatter — so it is unaffected by DERIVE and stays active.
    if is_complete(manifest_s) and has_tasks:
        lagging = [x for x in ledger if not is_complete(x["status"])]
        if lagging:
            emit({"finding": "trinity-status-drift", "file": rel,
                  "drift_class": "trinity-task-ledger-lag",
                  "manifest_status": manifest_s,
                  "task_ledger": ledger, "lagging_tasks": lagging, "detected_at": iso_now})
            counts["trinity-task-ledger-lag"] += 1

def inspect_master_sub(master_dir):
    """NET-NEW master<->sub aggregation axis (R-61/62/63)."""
    master_p = os.path.join(master_dir, "manifest.json")
    if not os.path.isfile(master_p):
        return
    md, err = load_manifest(master_p)
    if err or md is None:
        return
    subs = md.get("sub_plans")
    is_master = (md.get("type") == "master") or isinstance(subs, list)
    if not is_master:
        # still check R-63 on any sub manifests under this dir below
        pass
    rel_master = os.path.relpath(master_dir, plans_scope)
    replica = {}
    if isinstance(subs, list):
        for sp in subs:
            if isinstance(sp, dict):
                key = sp.get("sub_plan_id") or sp.get("slug")
                if key:
                    replica[str(key)] = sp.get("status", "")
    # walk real sub-plan dirs to compare
    for entry in sorted(os.listdir(master_dir)):
        sub_dir = os.path.join(master_dir, entry)
        if not os.path.isdir(sub_dir) or entry.startswith(".") or entry.startswith("_"):
            continue
        if entry in ("tests", "_orchestrator"):
            continue
        sm_p = os.path.join(sub_dir, "manifest.json")
        if not os.path.isfile(sm_p):
            continue
        sm, serr = load_manifest(sm_p)
        if serr or sm is None:
            continue
        sub_id = str(sm.get("sub_plan_id") or "")
        m = re.match(r"^(?:SP-)?(\d{1,2})", entry)
        ordinal = sub_id or (m.group(1).zfill(2) if m else entry)
        real_status = sm.get("status", "")

        # R-63 sub-peer-isolation (advisory): a sub depends on a sibling sub.
        deps = sm.get("dependencies") or {}
        edges = []
        if isinstance(deps, dict):
            for k in ("blocks", "blocked_by", "depends_on", "parallel_ok"):
                v = deps.get(k)
                if isinstance(v, list):
                    edges += [str(x) for x in v]
        elif isinstance(deps, list):
            edges += [str(x) for x in deps]
        for e in edges:
            if re.match(r"^(?:SP-)?\d", e) and e not in (md.get("slug", ""), rel_master):
                emit({"finding": "sub-peer-isolation", "rule": "R-63", "tier": "advisory",
                      "file": os.path.relpath(sm_p, plans_scope), "sub": entry,
                      "sibling_edge": e, "detected_at": iso_now})
                counts["sub-peer-isolation"] += 1

        if not isinstance(subs, list):
            continue
        # R-61 master-sub-aggregation-drift: replica status != real status.
        rep_status = replica.get(ordinal, replica.get(entry, None))
        if rep_status is None:
            # sub exists but master has no replica entry -> R-62 publish gap.
            emit({"finding": "sub-publishes-upward-gap", "rule": "R-62", "tier": "reconciler",
                  "file": rel_master, "sub": entry, "real_status": real_status,
                  "detail": "sub not present in master sub_plans[]", "detected_at": iso_now})
            counts["sub-publishes-upward-gap"] += 1
        elif norm(rep_status) != norm(real_status):
            emit({"finding": "master-sub-aggregation-drift", "rule": "R-61", "tier": "reconciler",
                  "file": rel_master, "sub": entry, "replica_status": rep_status,
                  "real_status": real_status, "detected_at": iso_now})
            counts["master-sub-aggregation-drift"] += 1

try:
    for entry in sorted(os.listdir(plans_scope)):
        if entry.startswith(".") or entry.startswith("_"):
            continue
        plan_dir = os.path.join(plans_scope, entry)
        if not os.path.isdir(plan_dir):
            continue
        if run_trinity:
            inspect_trinity(plan_dir)
        if run_master_sub:
            inspect_master_sub(plan_dir)
        for sub in sorted(os.listdir(plan_dir)):
            if sub.startswith(".") or sub.startswith("_") or sub in ("tests", "_orchestrator"):
                continue
            sub_dir = os.path.join(plan_dir, sub)
            if os.path.isdir(sub_dir):
                if run_trinity:
                    inspect_trinity(sub_dir)
                # a nested sub can ITSELF be a master-of-subs
                # (master-of-masters, R-61/62/63); check its aggregation axis too (was:
                # inspect_master_sub ran ONLY on the depth-1 top-level plan_dir). Safe
                # no-op on a non-master sub (early-returns without a manifest / sub_plans).
                if run_master_sub:
                    inspect_master_sub(sub_dir)
except FileNotFoundError:
    pass

if dry_run:
    total = sum(counts.values())
    print("trinity-drift-detect: inspected=%d total=%d counts=%s"
          % (inspected, total, dict(counts)))
PY

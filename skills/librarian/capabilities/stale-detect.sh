#!/bin/bash
# stale-detect — Identify files that may need attention based on age or missing processing.
# Sources `lib/manifest.sh`, `lib/plan-path.sh`, `lib/findings.sh`.
# 8 staleness rules per SKILL.md (rule 6 retired at G3 — vault Logs/ no longer ships):
#   1. Daily notes — processed: false AND older than 2 days
#   2. People files — <!-- TODO: enrich context --> marker present
#   3. People files — no Timeline entry in last 30 days (active engagement only)
#   4. Project files — updated older than 14 days (active only)
#   5. Meeting notes — processed: false
#   6. (retired) Residual vault Logs/ — the vault no longer ships a Logs/ folder
#      (operational-exhaust relocation, G3); the run-log home is $CLAUDE_LOG_DIR.
#   7. Plan files — completion marker without verification evidence (R-16)
#      Scope: plan-root files ONLY (flat *.md, */spec.md, */00-ideation-brief.md,
#      */README.md, */manifest.json). Sub-task files (depth ≥ 2) excluded.
#   8. Plan trinity lag — manifest.status == "complete" but any tasks.md T-N
#      **Status:** lags (not-started | in-progress | blocked | pending | planned).
#      Finding category: `trinity-lag`.
#   9. Binder freshness (R-FLOW-MAINT-1) — a per-spoke binder surface
#      (_projects/<spoke>/{research-index,decision-log,handoff-chronicle}.md) whose
#      `updated:` regen date lags the newest constituent-plan activity (the max
#      manifest.json/handoff.md mtime across the plans whose manifest project:
#      matches the spoke) by more than 14 days. Finding category: `binder-stale`,
#      severity: `warn`. WARN-ONLY family (rules #4/#7/#8): degraded-utility with a
#      one-command repair (re-run the binder generator), NO Stop/exit-2 escalation.
#      A binder with no `updated:` date or no contributing plans, or an absent
#      binder (adopter never ran the generators — first-run state, not staleness),
#      yields no finding.
# Verification evidence for plans (any-of-three):
#   a. last_verified: <ISO date> frontmatter within 14 days
#   b. **Last Verified:** <ISO date> header bullet within 14 days
#   c. sibling handoff.md with non-empty acceptance-criteria section
# CLI:
#   stale-detect.sh                    # emit findings to $FINDINGS_OUTPUT or stdout
#   stale-detect.sh --scope <path>     # limit to a vault subtree
#   stale-detect.sh --recent           # files touched in last 7 days only
#   stale-detect.sh --dry-run          # summary counts, no emission
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/plan-path.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/plan-path.sh"; } \
  || source "$_REPO_LIB/plan-path.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || source "$_REPO_LIB/user-manifest-read.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || source "$_REPO_LIB/manifest.sh"

SCOPE=""
RECENT="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --recent) RECENT="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "stale-detect: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

VAULT_SCOPE="${SCOPE:-$VAULT_ROOT}"
PLANS_SCOPE="${PLANS_DIR:-$HOME/.claude-plans}"

# Capture a machine-readable summary subtree the bash layer persists to the
# manifest (drift_findings.stale) via manifest_set — see MANIFEST_SUBTREE_OUT
# below. Kept off stdout so the NDJSON findings stream is never polluted.
MANIFEST_SUBTREE_OUT="$(mktemp -t stale-subtree-XXXXXX)"
export MANIFEST_SUBTREE_OUT

python3 - "$VAULT_SCOPE" "$PLANS_SCOPE" "$RECENT" "$DRY_RUN" <<'PY'
import json, os, re, sys, time
from datetime import datetime, timezone

vault_scope, plans_scope, recent_s, dry_run_s = sys.argv[1:5]
recent = (recent_s == "true")
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
subtree_out = os.environ.get("MANIFEST_SUBTREE_OUT", "")
now = time.time()

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def days_since_mtime(p):
    try:
        return (now - os.path.getmtime(p)) / 86400.0
    except Exception:
        return 0

def parse_fm(path):
    try:
        t = open(path).read()
    except Exception:
        return {}, ""
    if not t.startswith("---"):
        return {}, t
    end = t.find("\n---", 3)
    if end == -1:
        return {}, t
    fm_raw = t[3:end].strip()
    body = t[end+4:]
    fm = {}
    for line in fm_raw.split("\n"):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm, body

# Structural exempt-dir defaults (always exempt; not user-configurable).
EXEMPT_DIRS = ("/Archive/", "/.git/", "/.claude/projects/", "/_test")

counts = {"stale": 0, "todo": 0, "stale-status": 0, "trinity-lag": 0, "binder-stale": 0}
scanned = 0

# ---------- vault walk (rules 1-6) ----------
for dirpath, dirnames, filenames in os.walk(vault_scope):
    dirnames[:] = [d for d in dirnames if not d.startswith('.')]
    if any(ex in dirpath + "/" for ex in EXEMPT_DIRS):
        continue
    for fn in filenames:
        if not fn.endswith(".md"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, vault_scope)
        if recent and days_since_mtime(full) > 7:
            continue
        scanned += 1
        fm, body = parse_fm(full)

        # Rule 1: Daily notes — processed: false AND older than 2 days
        if rel.startswith("Daily/") and fn.endswith(".md") and "Briefing" not in fn:
            if fm.get("processed", "").lower() == "false" and days_since_mtime(full) > 2:
                emit({"finding": "stale", "file": rel,
                      "category": "stale", "reason": "Daily note processed: false and >2d old"})
                counts["stale"] += 1
                continue

        # Rule 2: People file TODO marker
        if "/People/" in rel and "<!-- TODO: enrich context -->" in body:
            emit({"finding": "stale", "file": rel,
                  "category": "todo", "reason": "People file has TODO: enrich context marker"})
            counts["todo"] += 1

        # Rule 3: People file — no Timeline entry in last 30d (active only)
        if "/People/" in rel and fm.get("status", "").lower() not in ("complete", "archived", "historical", "closed"):
            m = re.search(r"^## Timeline.*?\n(.*?)(?=\n## |\Z)", body, re.DOTALL | re.MULTILINE)
            if m:
                timeline = m.group(1)
                dates = re.findall(r"\b(20\d{2}-\d{2}-\d{2})\b", timeline)
                if dates:
                    newest = max(dates)
                    try:
                        dt = datetime.strptime(newest, "%Y-%m-%d")
                        delta = (datetime.now() - dt).days
                        if delta > 30:
                            emit({"finding": "stale", "file": rel,
                                  "category": "stale",
                                  "reason": f"No Timeline entry since {newest} ({delta}d ago)"})
                            counts["stale"] += 1
                    except ValueError:
                        pass

        # Rule 4: Project file — updated older than 14 days (active only)
        if "/Projects/" in rel and fm.get("updated"):
            if fm.get("status", "").lower() in ("", "active", "in-progress"):
                try:
                    dt = datetime.strptime(fm["updated"][:10], "%Y-%m-%d")
                    delta = (datetime.now() - dt).days
                    if delta > 14:
                        emit({"finding": "stale", "file": rel,
                              "category": "stale",
                              "reason": f"Project 'updated' is {delta}d old (active)"})
                        counts["stale"] += 1
                except ValueError:
                    pass

        # Rule 5: Meeting notes — processed: false
        if rel.startswith("Meetings/") and fm.get("processed", "").lower() == "false":
            emit({"finding": "stale", "file": rel,
                  "category": "stale", "reason": "Meeting note processed: false"})
            counts["stale"] += 1

        # Rule 6 (retired at G3): residual vault Logs/ — the vault no longer ships
        # a Logs/ folder; the run-log home is $CLAUDE_LOG_DIR (relocated, G4/G7).

# ---------- plans walk (rule 7) ----------
COMPLETION_FM = re.compile(r"^status:\s*(complete|completed|implemented|done)\s*$", re.IGNORECASE | re.MULTILINE)
COMPLETION_HDR = re.compile(r"^\*\*Status:\*\*\s*(Complete|COMPLETE|Completed|Implemented|Done)\b", re.IGNORECASE | re.MULTILINE)
LAST_VERIFIED_FM = re.compile(r"^last_verified:\s*(20\d{2}-\d{2}-\d{2})\s*$", re.IGNORECASE | re.MULTILINE)
LAST_VERIFIED_HDR = re.compile(r"^\*\*Last Verified:\*\*\s*(20\d{2}-\d{2}-\d{2})\b", re.IGNORECASE | re.MULTILINE)

PLAN_ROOT_BASENAMES = ("spec.md", "00-ideation-brief.md", "README.md", "manifest.json")

def is_plan_root(rel):
    parts = rel.split("/")
    if len(parts) == 1 and parts[0].endswith(".md"):
        return True  # flat plans at root
    if len(parts) == 2 and parts[1] in PLAN_ROOT_BASENAMES:
        return True
    return False

def has_handoff_ac(plan_dir):
    h = os.path.join(plan_dir, "handoff.md")
    if not os.path.isfile(h):
        return False
    try:
        t = open(h).read()
    except Exception:
        return False
    # Non-empty acceptance-criteria section
    m = re.search(r"##+\s*Acceptance\b.*?\n(.*?)(?=\n##|\Z)", t, re.DOTALL | re.IGNORECASE)
    return bool(m and m.group(1).strip())

for dirpath, dirnames, filenames in os.walk(plans_scope):
    dirnames[:] = [d for d in dirnames if not d.startswith('.') and d != "_orchestrator" and not d.startswith("tests")]
    for fn in filenames:
        if not fn.endswith(".md"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, plans_scope)
        if not is_plan_root(rel):
            continue
        try:
            content = open(full).read()
        except Exception:
            continue
        # Split frontmatter + body
        fm_end = content.find("\n---", 3) if content.startswith("---") else -1
        fm_text = content[:fm_end] if fm_end > 0 else ""
        body = content[fm_end+4:] if fm_end > 0 else content
        is_complete = bool(COMPLETION_FM.search(fm_text) or COMPLETION_HDR.search(body))
        if not is_complete:
            continue
        # Check verification evidence
        today = datetime.now()
        has_evidence = False
        for pat in (LAST_VERIFIED_FM, LAST_VERIFIED_HDR):
            m = pat.search(content)
            if m:
                try:
                    dt = datetime.strptime(m.group(1), "%Y-%m-%d")
                    if (today - dt).days <= 14:
                        has_evidence = True
                        break
                except ValueError:
                    pass
        if not has_evidence:
            plan_dir = os.path.dirname(full)
            if has_handoff_ac(plan_dir):
                has_evidence = True
        if not has_evidence:
            slug = rel.split("/")[0]
            emit({"finding": "stale-status", "file": rel,
                  "category": "stale-status",
                  "plan_slug": slug,
                  "reason": "completion marker without verification evidence (R-16)",
                  "resolution_hint": "add last_verified: frontmatter OR **Last Verified:** header bullet with today's ISO date, OR attach sibling handoff.md with acceptance-criteria section"})
            counts["stale-status"] += 1

# ---------- plans walk (check #8 — trinity lag) ----------
# For every manifest.json with .status == "complete", assert every tasks.md
# **Status:** line reads `done`. If any lags, emit finding with severity `warn`
# and payload listing which task IDs lag.
TASK_HEADING_RE = re.compile(r"^###\s+(T-\d+)\s*:", re.MULTILINE)
STATUS_LINE_RE = re.compile(r"^\*\*Status:\*\*\s*(.+?)\s*$", re.MULTILINE)
DONE_SET = {"done", "complete", "completed", "implemented"}

def parse_task_statuses(tasks_path):
    try:
        t = open(tasks_path).read()
    except Exception:
        return None
    body = t
    if t.startswith("---"):
        end = t.find("\n---", 3)
        if end == -1:
            return None
        body = t[end+4:]
    heads = [(m.group(1), m.start()) for m in TASK_HEADING_RE.finditer(body)]
    out = []
    for i, (tid, off) in enumerate(heads):
        end = heads[i+1][1] if i+1 < len(heads) else len(body)
        seg = body[off:end]
        sm = STATUS_LINE_RE.search(seg)
        status = ""
        if sm:
            raw = sm.group(1).strip().strip("*").strip("_").strip().lower()
            # Normalize "done (...)" / "done — ..." trailing annotations to just the head token
            m2 = re.match(r"([a-z-]+)", raw)
            status = m2.group(1) if m2 else raw
        out.append({"id": tid, "status": status})
    return out

def walk_plan_dirs(root):
    try:
        entries = sorted(os.listdir(root))
    except FileNotFoundError:
        return
    for e in entries:
        if e.startswith(".") or e.startswith("_"):
            continue
        p = os.path.join(root, e)
        if not os.path.isdir(p):
            continue
        yield p
        try:
            subs = sorted(os.listdir(p))
        except Exception:
            continue
        for s in subs:
            if s.startswith(".") or s.startswith("_") or s in ("tests", "_orchestrator"):
                continue
            sp = os.path.join(p, s)
            if os.path.isdir(sp):
                yield sp

for plan_dir in walk_plan_dirs(plans_scope):
    man_p = os.path.join(plan_dir, "manifest.json")
    tasks_p = os.path.join(plan_dir, "tasks.md")
    if not (os.path.isfile(man_p) and os.path.isfile(tasks_p)):
        continue
    try:
        mdata = json.loads(open(man_p).read())
    except Exception:
        continue
    if not isinstance(mdata, dict):
        continue
    mstatus = str(mdata.get("status", "")).strip().lower()
    if mstatus not in DONE_SET:
        continue
    ledger = parse_task_statuses(tasks_p)
    if not ledger:
        continue
    lagging = [x for x in ledger if x["status"] not in DONE_SET]
    if not lagging:
        continue
    rel = os.path.relpath(plan_dir, plans_scope)
    slug = rel.split("/")[0]
    emit({"finding": "stale-status", "file": rel + "/tasks.md",
          "category": "trinity-lag", "severity": "warn",
          "plan_slug": slug,
          "manifest_status": mstatus,
          "lagging_tasks": lagging,
          "reason": "manifest.status=complete but task ledger lags (trinity lag)",
          "resolution_hint": "flip lagging T-N **Status:** to `done` if work is actually complete, OR revert manifest.status to in-progress if work remains"})
    counts["trinity-lag"] += 1

# ---------- binder freshness (rule #9 — R-FLOW-MAINT-1) ----------
# Per-spoke binders live at <plans>/_projects/<spoke>/{research-index,decision-log,
# handoff-chronicle}.md (the T-3/4/5 generator outputs). Each carries a generated
# `updated: <ISO date>` frontmatter — the binder regen timestamp. The "max
# constituent-plan activity" is the newest manifest.json/handoff.md mtime among the
# plans whose manifest project: matches the spoke (the SAME spoke-attribution the
# generators use: a plan contributes iff its manifest project: == <spoke>). When the
# regen date lags that activity by more than BINDER_STALE_DAYS, emit a severity:warn
# `binder-stale` finding. WARN-ONLY (rules #4/#7/#8 family): one re-run of the
# generator repairs it; no Stop/exit-2 escalation (binder staleness is degraded-but-
# usable, not the lost-in-flight-state class). An absent binder is first-run state,
# NOT staleness — no finding. Threshold mirrors rule #4 (the project-freshness rule;
# D4 R-FLOW-MAINT-1 names no numeric threshold, so the shipped staleness-family
# convention governs).
BINDER_STALE_DAYS = 14
BINDER_BASENAMES = ("research-index.md", "decision-log.md", "handoff-chronicle.md")
BINDER_UPDATED_RE = re.compile(r"^updated:\s*(20\d{2}-\d{2}-\d{2})\s*$", re.MULTILINE)

projects_root = os.path.join(plans_scope, "_projects")
if os.path.isdir(projects_root):
    # Map spoke -> newest constituent-plan activity (max manifest/handoff mtime).
    # Walk every manifest under the plans tree; attribute to its project: spoke.
    spoke_activity = {}
    for dp, dns, fns in os.walk(plans_scope):
        dns[:] = [d for d in dns if not d.startswith(".")]
        # never descend into the binder home itself (binder mtimes are NOT plan activity)
        if os.path.abspath(dp) == os.path.abspath(projects_root):
            dns[:] = []
            continue
        if "manifest.json" not in fns:
            continue
        mp = os.path.join(dp, "manifest.json")
        try:
            mdata = json.loads(open(mp).read())
        except Exception:
            continue
        if not isinstance(mdata, dict):
            continue
        spoke = str(mdata.get("project", "") or "").strip()
        if not spoke:
            continue
        newest = os.path.getmtime(mp)
        hp = os.path.join(dp, "handoff.md")
        if os.path.isfile(hp):
            try:
                newest = max(newest, os.path.getmtime(hp))
            except Exception:
                pass
        prev = spoke_activity.get(spoke)
        if prev is None or newest > prev:
            spoke_activity[spoke] = newest

    try:
        spoke_dirs = sorted(os.listdir(projects_root))
    except Exception:
        spoke_dirs = []
    for spoke in spoke_dirs:
        binder_home = os.path.join(projects_root, spoke)
        if not os.path.isdir(binder_home):
            continue
        activity = spoke_activity.get(spoke)
        if activity is None:
            # no contributing plans -> not staleness
            continue
        for base in BINDER_BASENAMES:
            bp = os.path.join(binder_home, base)
            if not os.path.isfile(bp):
                # absent binder surface = first-run state, not staleness
                continue
            try:
                btext = open(bp).read()
            except Exception:
                continue
            m = BINDER_UPDATED_RE.search(btext)
            if not m:
                # no regen date to compare against -> no finding
                continue
            try:
                regen_dt = datetime.strptime(m.group(1), "%Y-%m-%d").replace(tzinfo=timezone.utc)
            except ValueError:
                continue
            regen_epoch = regen_dt.timestamp()
            lag_days = (activity - regen_epoch) / 86400.0
            if lag_days > BINDER_STALE_DAYS:
                rel = os.path.relpath(bp, plans_scope)
                emit({"finding": "stale-status", "file": rel,
                      "category": "binder-stale", "severity": "warn",
                      "spoke": spoke,
                      "binder_updated": m.group(1),
                      "constituent_activity_lag_days": round(lag_days, 1),
                      "reason": "binder regen lags max constituent-plan activity by "
                                "%dd (>%dd) — binder is stale (R-FLOW-MAINT-1)" % (int(lag_days), BINDER_STALE_DAYS),
                      "resolution_hint": "re-run the owning librarian binder generator "
                                         "(plan-research-index / plan-decision-log / plan-handoff-index) "
                                         "for spoke '%s' to refresh it" % spoke})
                counts["binder-stale"] += 1

if dry_run:
    total = sum(counts.values())
    print("stale-detect: scanned=%d total=%d counts=%s" % (scanned, total, dict(counts)))

# Write the manifest summary subtree (drift_findings.stale). The bash layer reads
# $MANIFEST_SUBTREE_OUT and calls manifest_set — mirrors xref-check's
# captured-summary / manifest_set '.xref_graph' pattern. Kept off stdout.
if subtree_out:
    subtree = {
        "last_scan": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
        "scanned": scanned,
        "total": sum(counts.values()),
        "counts": dict(counts),
    }
    with open(subtree_out, "w") as f:
        f.write(json.dumps(subtree))
PY

# Persist the stale summary subtree to the librarian-manifest. This makes the
# registry's declared writes_manifest_subtree: "drift_findings.stale" real
# (3-notwired-swallowed-2 fix), mirroring xref-check.sh's manifest_set.
# Review-hardening (empty-VAULT_LOGS contract): with empty VAULT_LOGS the
# manifest_set lockfile resolves to '/.coordination/manifest.lock' (uncreatable)
# and raises under set -e, which a no-vault fresh adopter's session-close logs as
# a spurious capability error — but G2 (plan 110) moved the manifest under
# $CLAUDE_STATE_ROOT/manifests and its lock under $COORD_DIR (always creatable), so
# the persist no longer needs a non-empty VAULT_LOGS. Gate only on content.
if [[ -s "$MANIFEST_SUBTREE_OUT" ]]; then
  manifest_set '.drift_findings.stale' "$(cat "$MANIFEST_SUBTREE_OUT")"
fi
rm -f "$MANIFEST_SUBTREE_OUT"

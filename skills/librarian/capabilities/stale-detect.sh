#!/bin/bash
# stale-detect — Identify files that may need attention based on age or missing processing.
#
# Sources `lib/manifest.sh`, `lib/plan-path.sh`, `lib/findings.sh`.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as
# the declared task-status vocabulary home in the Rule-8 comments (manifests are read with plain
# json.loads); no Draft202012Validator is constructed, so there is no schema-gate degrade path.
#
# 8 staleness rules per SKILL.md (rules 5 + 6 retired — meeting-note extracted,
# ; vault Logs/ no longer ships, G3):
#   1. Daily notes — processed: false AND older than 2 days
#   2. People files — <!-- TODO: enrich context --> marker present
#   3. People files — no Timeline entry in last 30 days (active engagement only)
#   4. Project files — updated older than 14 days (active only)
#   5. (retired) Meeting notes — meeting-note extracted from foundation
#   6. (retired) Residual vault Logs/ — the vault no longer ships a Logs/ folder
#      (operational-exhaust relocation, G3); the run-log home is $CLAUDE_LOG_DIR.
#   7. Plan files — completion marker without verification evidence (R-16)
#      Scope: plan-root files ONLY (flat *.md, */spec.md, */00-ideation-brief.md,
#      */README.md, */manifest.json). Sub-task files (depth ≥ 2) excluded.
#   8. Plan trinity lag — manifest.status is terminal-complete but any
#      manifest.tasks[] row's status lags (outside DONE_SET). Read
#      MANIFEST-DIRECT: manifest.tasks[] is the DERIVE status SoT; tasks.md is a
#      rendered read-replica (tasks-render.sh owns it) and is never a data
#      source here — replica freshness is a separate axis (tasks-render.sh
#      --check and its trinity-drift-detect sweep wiring). The ledger reader is
#      the byte-identical twin of trinity-drift-detect.sh's
#      task_ledger_from_manifest (the two capabilities measure the same axis and
#      move together). Finding category: `trinity-lag`.
#   9. Binder freshness — a per-spoke binder surface
#      (_projects/<spoke>/{research-index,decision-log,handoff-chronicle}.md) whose
#      `updated:` regen date lags the newest constituent-plan activity (the max
#      manifest.json/handoff.md mtime across the plans whose manifest project:
#      matches the spoke) by more than 14 days. Finding category: `binder-stale`,
#      severity: `warn`. POSTURE: the binder is now auto-maintained (session-close +
#      a plan-manifest-write trigger + a session-start refresh-from-disk), so a
#      `binder-stale` finding indicates the AUTO-MAINTENANCE PIPELINE DID NOT RUN —
#      a pipeline-failure signal, not a normal stale state. Investigate the
#      maintenance chain; a one-command generator re-run repairs the surface but does
#      NOT explain why the pipeline missed it. WARN-ONLY family (rules #4/#7/#8):
#      degraded-utility, NO Stop/exit-2 escalation. A binder with no `updated:` date
#      or no contributing plans, or an absent binder (adopter never ran the
#      generators — first-run state, not staleness), yields no finding.
#
# Verification evidence for plans (any-of-three):
#   a. last_verified: <ISO date> frontmatter within 14 days
#   b. **Last Verified:** <ISO date> header bullet within 14 days
#   c. sibling handoff.md with non-empty acceptance-criteria section
#
# CLI:
#   stale-detect.sh                    # emit findings to $FINDINGS_OUTPUT or stdout
#   stale-detect.sh --scope <path>     # limit to a vault subtree
#   stale-detect.sh --recent           # files touched in last 7 days only
#   stale-detect.sh --dry-run          # summary counts, no emission
#
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

# materialize a vault-view walk-list so the python vault walk
# DESCENDS the vault Work/ symlink (-> ~/work) via the shared walker (vault_view_walk).
# os.walk(followlinks=False) refused it AND WORK_HOME was never a root, so the Work/ subtree
# had no stale detector. The python body reads SD_WALK_LIST and FALLS BACK to os.walk when it
# is empty (floor). Mirrors rename-cascade's bounded stdin-capture retrofit.
SD_WALK_LIST=""
_VVW_LIB="${VAULT_VIEW_WALK:-$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh}"
[ -r "$_VVW_LIB" ] || _VVW_LIB="$_REPO_LIB/vault-view-walk.sh"
if [ -n "$VAULT_SCOPE" ] && [ -d "$VAULT_SCOPE" ] && [ -r "$_VVW_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_VVW_LIB"
  if command -v vault_view_walk >/dev/null 2>&1; then
    SD_WALK_LIST="$(mktemp -t sd-walk.XXXXXX)"
    vault_view_walk "$VAULT_SCOPE" >> "$SD_WALK_LIST" 2>/dev/null || true
  fi
fi
export SD_WALK_LIST

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

# work-body freshness rule constants — a Work/<spoke>/ body file
# whose `updated:` regen date lags by more than WORK_STALE_DAYS is stale (threshold mirrors
# rule #4). No `updated:` date -> no finding (same posture as rules #4/#9).
WORK_STALE_DAYS = 14
WORK_BODY_BASENAMES = ("overview.md", "prd.md", "updates.md", "README.md")

counts = {"stale": 0, "todo": 0, "stale-status": 0, "trinity-lag": 0,
          "binder-stale": 0, "work-stale": 0, "binder-conformance": 0,
          "orphan-spoke-binder": 0, "library-article-stale": 0}
scanned = 0

# ---------- vault walk (rules 1-4 + work-body freshness) ----------
# enumerate via the shared vault-view walker (SD_WALK_LIST, built bash-side from
# vault_view_walk) so the vault Work/ symlink is DESCENDED (os.walk followlinks=False
# refused it). The walker emits vault-view LOGICAL paths (Work/<spoke>/...), so the
# rel-keyed rules below reach the Work/ subtree. FALL BACK to os.walk when the list is
# empty (floor) — mirrors rename-cascade.sh's os.walk fallback.
vault_files = []
_wl_path = os.environ.get("SD_WALK_LIST", "")
_wl_lines = []
if _wl_path and os.path.isfile(_wl_path):
    try:
        with open(_wl_path) as _wf:
            _wl_lines = _wf.read().split("\n")
    except Exception:
        _wl_lines = []
for _ln in _wl_lines:
    if not _ln or not _ln.endswith(".md"):
        continue
    if any(ex in _ln + "/" for ex in EXEMPT_DIRS):
        continue
    vault_files.append(_ln)
if not vault_files:
    for dirpath, dirnames, filenames in os.walk(vault_scope):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        if any(ex in dirpath + "/" for ex in EXEMPT_DIRS):
            continue
        for fn in filenames:
            if fn.endswith(".md"):
                vault_files.append(os.path.join(dirpath, fn))

# The vault-view walker normalizes its root via `pwd -P` (physical path), while
# vault_scope is the raw argv value — on macOS these differ (/var -> /private/var), so a
# naive os.path.relpath yields a `../`-traversal instead of the Work/<spoke>/... shape.
# Compute rel against BOTH the raw and the realpath'd scope prefix (the walker emits the
# LOGICAL Work/ prefix, so do NOT realpath `full` — that would resolve the Work symlink).
_vs_raw = vault_scope.rstrip("/")
_vs_rp = os.path.realpath(vault_scope).rstrip("/")
def _to_rel(full):
    if _vs_rp and full.startswith(_vs_rp + "/"):
        return full[len(_vs_rp) + 1:]
    if _vs_raw and full.startswith(_vs_raw + "/"):
        return full[len(_vs_raw) + 1:]
    return os.path.relpath(full, vault_scope)

for full in vault_files:
    fn = os.path.basename(full)
    if not fn.endswith(".md"):
        continue
    rel = _to_rel(full)
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

    # Rule: Work-body freshness — a Work/<spoke>/ body file
    # (overview/prd/updates/README) whose `updated:` regen date lags by more than
    # WORK_STALE_DAYS. Reached only now that the Work/ symlink is descended (the
    # walk-list). No `updated:` date -> no finding (same posture as rules #4/#9).
    parts = rel.split("/")
    if len(parts) >= 3 and parts[0] == "Work" and fn in WORK_BODY_BASENAMES:
        up = fm.get("updated", "")
        if up:
            try:
                dt = datetime.strptime(up[:10], "%Y-%m-%d")
                delta = (datetime.now() - dt).days
                if delta > WORK_STALE_DAYS:
                    emit({"finding": "stale", "file": rel,
                          "category": "work-stale",
                          "spoke": parts[1],
                          "reason": "Work body '%s' updated %dd ago (>%dd)"
                                    % (fn, delta, WORK_STALE_DAYS)})
                    counts["work-stale"] += 1
            except ValueError:
                pass

    # Rule 5 (retired): meeting-note extracted from foundation
    # (type + contract + Meetings/ surface parked to internal/parked/).

    # Rule 6 (retired at G3): residual vault Logs/ — the vault no longer ships
    # a Logs/ folder; the run-log home is $CLAUDE_LOG_DIR (relocated, G4/G7).

# ---------- plans walk (rule 7) ----------
COMPLETION_FM = re.compile(r"^status:\s*(complete|completed|implemented|done)\s*$", re.IGNORECASE | re.MULTILINE)
COMPLETION_HDR = re.compile(r"^\*\*Status:\*\*\s*(Complete|COMPLETE|Completed|Implemented|Done)\b", re.IGNORECASE | re.MULTILINE)
# DERIVE (manifest is the sole status SoT): for manifest-backed plans, rule 7 reads
# completion from the manifest status, not the (now stripped) artifact frontmatter.
# COMPLETION_FM/COMPLETION_HDR are retained ONLY for the flat-root-plan inline path
# (flat single-file plans have no manifest and keep an inline **Status:**/status:).
COMPLETION_MANIFEST_SET = {"completed", "complete", "done", "implemented"}
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

# library-article freshness. is_plan_root filters
# _library/<topic>/*.md articles out of the plans walk, so they had no staleness owner
# (path-gated-predicate). A topic article — depth >= 2 under _library, EXCLUDING _index.md,
# the _raw/ provenance subtree, and log-archive/ — whose `updated:` lags LIBRARY_STALE_DAYS
# emits library-article-stale. No `updated:` -> no finding (same posture as rules #4/#9).
# Threshold: library reference articles are curated knowledge (mirrors the memory
# semantic/procedural 180d interval), slower-decaying than the 14d project/binder family.
LIBRARY_STALE_DAYS = 180

def is_library_article(rel):
    parts = rel.split("/")
    if len(parts) < 3 or parts[0] != "_library":
        return False
    if "_raw" in parts or "log-archive" in parts:
        return False
    base = parts[-1]
    if base == "_index.md" or base.startswith("."):
        return False
    return base.endswith(".md")

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
        # library-article freshness rule (before the is_plan_root
        # gate that filters topic articles out).
        if is_library_article(rel):
            lfm, _lb = parse_fm(full)
            up = str(lfm.get("updated", "")).strip()
            if up:
                try:
                    ldt = datetime.strptime(up[:10], "%Y-%m-%d")
                    ldelta = (datetime.now() - ldt).days
                    if ldelta > LIBRARY_STALE_DAYS:
                        emit({"finding": "library-article-stale", "file": rel,
                              "category": "library-article-stale", "severity": "warn",
                              "reason": "library article 'updated' is %dd old (>%dd)"
                                        % (ldelta, LIBRARY_STALE_DAYS),
                              "resolution_hint": "review + refresh the article, then bump its "
                                                 "updated: frontmatter (or re-validate the topic)"})
                        counts["library-article-stale"] += 1
                except ValueError:
                    pass
            continue
        if not is_plan_root(rel):
            continue
        try:
            content = open(full).read()
        except Exception:
            continue
        # Split frontmatter + body (retained for the flat-plan inline path + the
        # verification-evidence scan below).
        fm_end = content.find("\n---", 3) if content.startswith("---") else -1
        fm_text = content[:fm_end] if fm_end > 0 else ""
        body = content[fm_end+4:] if fm_end > 0 else content
        # DERIVE (manifest is the sole status SoT): plan artifacts no longer carry
        # status: frontmatter. For manifest-backed plans, read completion from the
        # sibling manifest.json status; dedupe to spec.md so a completed plan surfaces
        # once, not once per plan-root artifact. Flat-root plans (no sibling manifest)
        # keep their inline **Status:**/status: marker (COMPLETION_FM/HDR still govern).
        man_p = os.path.join(os.path.dirname(full), "manifest.json")
        if os.path.isfile(man_p):
            if os.path.basename(full) != "spec.md":
                continue
            try:
                _md = json.loads(open(man_p).read())
                _mstatus = str(_md.get("status", "")).strip().lower() if isinstance(_md, dict) else ""
            except Exception:
                _mstatus = ""
            is_complete = _mstatus in COMPLETION_MANIFEST_SET
        else:
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
# For every manifest.json whose .status is terminal-complete, assert every
# manifest.tasks[] row's status is terminal (DONE_SET). If any lags, emit a
# severity-warn finding listing which task IDs lag. MANIFEST-DIRECT: the ledger
# comes from manifest.tasks[] — the DERIVE status SoT — never from tasks.md.
# DONE_SET is deliberately byte-stable (vocabulary closure — the missing `cut`
# class — is the consolidation plan's charter, keyed to the declared vocabulary
# in schemas/plan-manifest-schema.json); membership tests normalize with
# strip().lower(), matching trinity-drift-detect.sh's norm() so the two
# capabilities' counts agree on the same corpus.
DONE_SET = {"done", "complete", "completed", "implemented"}

# KEPT-IN-STEP TWIN: the def block below is byte-identical to
# trinity-drift-detect.sh's task_ledger_from_manifest — the two capabilities
# measure the same axis and must move together. The capabilities are
# self-contained bash-embedded python with no shared python-library surface, so
# the helper is TWINNED rather than imported; byte-parity of the two def blocks
# is fixture-enforced. Edit both sites together or neither.
def task_ledger_from_manifest(d):
    """The task ledger is manifest.tasks[] — the DERIVE status SoT. tasks.md is a
    rendered read-replica owned by tasks-render.sh (its ledger lives between the
    tasks:start/end sentinels) and is deliberately NOT read here: replica husks
    stranded outside the sentinels and hand-era **Status:** line shapes cannot
    reach this axis, and comparing the manifest against its own derivative would
    measure render freshness, not status truth."""
    tasks = d.get("tasks") if isinstance(d, dict) else None
    if not isinstance(tasks, list):
        return []
    out = []
    for t in tasks:
        if not isinstance(t, dict):
            continue
        tid = t.get("id")
        st = t.get("status")
        if st is None:
            st = ""
        elif not isinstance(st, str):
            st = str(st)
        out.append({"id": str(tid) if tid is not None else "?", "status": st})
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
    if not os.path.isfile(man_p):
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
    ledger = task_ledger_from_manifest(mdata)
    if not ledger:
        continue
    lagging = [x for x in ledger if x["status"].strip().lower() not in DONE_SET]
    if not lagging:
        continue
    rel = os.path.relpath(plan_dir, plans_scope)
    slug = rel.split("/")[0]
    emit({"finding": "stale-status", "file": rel + "/manifest.json",
          "category": "trinity-lag", "severity": "warn",
          "plan_slug": slug,
          "manifest_status": mstatus,
          "lagging_tasks": lagging,
          "reason": "manifest.status=complete but task ledger lags (trinity lag)",
          "resolution_hint": "advance the lagging manifest.tasks[].status rows to a terminal value if the work is actually complete, OR revert manifest.status to in-progress if work remains; tasks.md is a rendered read-replica — never hand-edit it (re-render via tasks-render.sh after the manifest moves)"})
    counts["trinity-lag"] += 1

# ---------- binder freshness (rule #9) ----------
# Per-spoke binders live at <plans>/_projects/<spoke>/{research-index,decision-log,
# handoff-chronicle}.md (the binder generator outputs). Each carries a generated
# `updated: <ISO date>` frontmatter — the binder regen timestamp. The "max
# constituent-plan activity" is the newest manifest.json/handoff.md mtime among the
# plans whose manifest project: matches the spoke (the SAME spoke-attribution the
# generators use: a plan contributes iff its manifest project: == <spoke>). When the
# regen date lags that activity by more than BINDER_STALE_DAYS, emit a severity:warn
# `binder-stale` finding.
# POSTURE: the binder is auto-maintained (session-close + a plan-manifest-write
# PostToolUse trigger + a session-start refresh-from-disk). Because the surface
# regenerates on every plan-state change, a `binder-stale` finding means the
# AUTO-MAINTENANCE PIPELINE DID NOT RUN — it is a pipeline-failure signal, not a
# normal stale state. Treat it as a prompt to investigate the maintenance chain
# (which leg dropped the regen), not just a one-off re-run: a manual generator
# re-run repairs THIS surface but does not explain why the pipeline missed it.
# WARN-ONLY (rules #4/#7/#8 family): no Stop/exit-2 escalation (binder staleness is
# degraded-but-usable, not the lost-in-flight-state class). An absent binder is
# first-run state, NOT staleness — no finding. Threshold mirrors rule #4 (the
# project-freshness rule; no binder contract names a numeric threshold, so the
# shipped staleness-family convention governs).
BINDER_STALE_DAYS = 14
# _situating.md joins the binder-staleness net. The situating
# card is force-ingested every session (session-start-project-context.sh) yet carried
# ZERO staleness net (type-table-ceiling); it is a full-file regenerated card carrying
# `updated:` frontmatter, so it participates in rule #9 exactly like the other read-replicas.
BINDER_BASENAMES = ("research-index.md", "decision-log.md", "handoff-chronicle.md", "_situating.md")
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

        # Rule #10: binder read-replica frontmatter conformance.
        # research-index/decision-log/handoff-chronicle/_situating ship schema:null and no
        # VAULT_ROOT validator reaches _projects, so the read-replica surface had no
        # conformance owner (missing-owner). Validate the GENERATOR-EMITTED frontmatter shape
        # (type:index + tags + updated + parent_folder) for each PRESENT read-replica, plus the
        # generated:true sentinel on _situating.md specifically (GROUNDED on disk: only the card
        # carries generated:true; the 3 index binders deliberately omit it, so requiring it
        # universally would false-flag every real binder). NOT a new file-type-contract (the
        # generated bodies stay schema:null by design). Runs for ALL spokes (active + orphan).
        for base in BINDER_BASENAMES:
            bp = os.path.join(binder_home, base)
            if not os.path.isfile(bp):
                continue
            try:
                bfm, _bbody = parse_fm(bp)
            except Exception:
                bfm = {}
            cmissing = [k for k in ("type", "tags", "updated", "parent_folder")
                        if not str(bfm.get(k, "")).strip()]
            tv = str(bfm.get("type", "")).strip()
            if tv and tv != "index":
                cmissing.append("type:index")
            if base == "_situating.md" and str(bfm.get("generated", "")).strip().lower() != "true":
                cmissing.append("generated:true")
            if cmissing:
                crel = os.path.relpath(bp, plans_scope)
                emit({"finding": "binder-conformance", "file": crel,
                      "category": "binder-frontmatter-invalid", "severity": "warn",
                      "spoke": spoke,
                      "missing_or_invalid": sorted(set(cmissing)),
                      "reason": "binder read-replica frontmatter is non-conformant to the "
                                "generated index-type shape (type:index + tags + updated + "
                                "parent_folder; generated:true on _situating.md) — the "
                                "_projects read-replica surface has no other conformance owner",
                      "resolution_hint": "re-run the owning binder generator (plan-research-index"
                                         " / plan-decision-log / plan-handoff-index / "
                                         "project-context-situating) for spoke '%s'" % spoke})
                counts["binder-conformance"] += 1

        activity = spoke_activity.get(spoke)
        if activity is None:
            # Rule #11: orphan-spoke-binder reconciler. A
            # _projects/<spoke>/ dir carrying real binder files but matching NO live manifest
            # project: key (the SAME attribution the generators use — a plan contributes iff
            # its manifest project: == <spoke>) is an ORPHAN (missing-owner): the generators
            # only regenerate spokes WITH contributing plans, so an orphan spoke binder
            # persisted undetected. An empty/absent binder home is first-run state, not an
            # orphan (no finding). MUST run against re-stamped project: keys.
            present = [b for b in BINDER_BASENAMES
                       if os.path.isfile(os.path.join(binder_home, b))]
            if present:
                orel = os.path.relpath(binder_home, plans_scope)
                emit({"finding": "orphan-spoke-binder", "file": orel,
                      "category": "orphan-spoke-binder", "severity": "warn",
                      "spoke": spoke,
                      "binder_files": present,
                      "reason": "a _projects/%s/ binder home carries read-replica files but no "
                                "live plan declares project: %s (no contributing plan) — an "
                                "orphan spoke binder with no reconciling owner" % (spoke, spoke),
                      "resolution_hint": "if spoke '%s' is retired, remove its _projects/ binder "
                                         "home; else confirm a contributing plan carries "
                                         "project: %s" % (spoke, spoke)})
                counts["orphan-spoke-binder"] += 1
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
                                "%dd (>%dd) — the binder is auto-maintained "
                                "(session-close + manifest-write trigger + session-start "
                                "refresh), so this stale surface signals the "
                                "auto-maintenance pipeline did not run"
                                % (int(lag_days), BINDER_STALE_DAYS),
                      "resolution_hint": "investigate the auto-maintenance pipeline (which "
                                         "leg dropped the regen for spoke '%s'), not just a "
                                         "one-off re-run; to repair this surface now, re-run the "
                                         "owning librarian binder generator "
                                         "(plan-research-index / plan-decision-log / plan-handoff-index) "
                                         "for the spoke" % spoke})
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
# a spurious capability error — but G2 moved the manifest under
# $CLAUDE_STATE_ROOT/manifests and its lock under $COORD_DIR (always creatable), so
# the persist no longer needs a non-empty VAULT_LOGS. Gate only on content.
if [[ -s "$MANIFEST_SUBTREE_OUT" ]]; then
  manifest_set '.drift_findings.stale' "$(cat "$MANIFEST_SUBTREE_OUT")"
fi
rm -f "$MANIFEST_SUBTREE_OUT"
[ -n "${SD_WALK_LIST:-}" ] && rm -f "$SD_WALK_LIST"

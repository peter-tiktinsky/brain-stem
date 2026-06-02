#!/bin/bash
# waiver-audit — Audit bypass surfaces for abuse, ad-hoc use, and cluster-to-rule candidates.
#
# Two audits share this capability because both are observational passes over
# bypass logs, emit findings via the same schema, and run at librarian session-close:
# (a) cascade-waivers.json abuse surface; (b) override-fire entries in hook-audit.log.
#
# Sources (paths resolve via $HOOKS_STATE / $CLAUDE_HOME / env overrides):
#   - $HOOKS_STATE/cascade-waivers.json              (R-07 waiver log, 4-shape tolerant)
#   - $CLAUDE_HOME/hooks/doc-dependencies.json       (entry_id registry for ad-hoc check)
#   - $HOOK_AUDIT_LOG (defaults to $HOOKS_STATE/hook-audit.log)  (override-fire append-only log)
#
# CLI:
#   waiver-audit.sh                         # emit findings to $FINDINGS_OUTPUT or stdout
#   waiver-audit.sh --scope waivers         # only cascade-waivers.json
#   waiver-audit.sh --scope overrides       # only hook-audit.log
#   waiver-audit.sh --scope all             # both (default)
#   waiver-audit.sh --report <path>         # write markdown report + summary to <path>
#   waiver-audit.sh --dry-run               # count-only summary to stdout, no emission
#
# Env overrides (testing):
#   CASCADE_WAIVER_PATH, HOOK_AUDIT_LOG, DOC_DEP_FILE, FINDINGS_OUTPUT
#
# Exits non-zero on:
#   - unknown flag
#   - --report path matches the baseline pattern `cascade-waiver-audit-*.md`
#     (baseline-preservation contract — refuses to overwrite an immutable
#     baseline audit report)
#
# Read-only against cascade-waivers.json — audit normalizes shapes on parse,
# does not rewrite. The canonical writer is ~/.claude/hooks/lib/cascade-waiver.sh.
#
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

# Idempotent paths.sh source guard.
if [[ -z "${HOOKS_STATE:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

CASCADE_WAIVER_PATH_EFF="${CASCADE_WAIVER_PATH:-$HOOKS_STATE/cascade-waivers.json}"
HOOK_AUDIT_LOG_EFF="${HOOK_AUDIT_LOG:-$HOOKS_STATE/hook-audit.log}"
DOC_DEP_FILE_EFF="${DOC_DEP_FILE:-$HOME/.claude/hooks/doc-dependencies.json}"

SCOPE="all"
DRY_RUN="false"
REPORT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="$2"; shift 2
      case "$SCOPE" in
        all|waivers|overrides) ;;
        *) echo "waiver-audit: --scope must be all|waivers|overrides" >&2; exit 2 ;;
      esac
      ;;
    --report) REPORT_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "waiver-audit: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Baseline-preservation hard guard — refuse to overwrite a baseline audit report.
if [[ -n "$REPORT_PATH" ]]; then
  RB=$(basename "$REPORT_PATH")
  case "$RB" in
    cascade-waiver-audit-*.md)
      echo "waiver-audit: refusing to write to baseline-pattern path: $REPORT_PATH" >&2
      echo "  (a baseline audit report at this pattern is immutable evidence.)" >&2
      exit 3
      ;;
  esac
fi

python3 - "$CASCADE_WAIVER_PATH_EFF" "$HOOK_AUDIT_LOG_EFF" "$DOC_DEP_FILE_EFF" "$SCOPE" "$DRY_RUN" "$REPORT_PATH" <<'PY'
import json, os, re, sys
from collections import defaultdict, Counter
from datetime import datetime, timezone

waiver_path, audit_path, dep_path, scope, dry_run_s, report_path = sys.argv[1:7]
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# --------- doc-dependency registered entry_id set ---------
registered_ids = set()
try:
    with open(dep_path) as f:
        dep_doc = json.load(f)
    for e in (dep_doc.get("entries", []) or []):
        if isinstance(e, dict) and "id" in e:
            registered_ids.add(e["id"])
except Exception:
    pass

# --------- waiver ingest (4-shape tolerant) ---------
def read_waivers(path):
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception:
        return []
    results = []
    seen = set()
    if isinstance(doc, dict):
        sessions = doc.get("sessions")
        if isinstance(sessions, dict):
            for sid, slot in sessions.items():
                seen.add(sid)
                if isinstance(slot, dict) and isinstance(slot.get("waivers"), list):
                    for w in slot["waivers"]:
                        if isinstance(w, dict):
                            results.append((sid, w.get("entry_id",""), w.get("reason",""),
                                            w.get("ts",""), "canonical"))
                elif isinstance(slot, list):
                    for item in slot:
                        if isinstance(item, dict):
                            if "entry_id" in item:
                                results.append((sid, item.get("entry_id",""),
                                                item.get("reason",""), item.get("ts",""), "drift-A"))
                            elif isinstance(item.get("waivers"), list):
                                for w in item["waivers"]:
                                    if isinstance(w, dict):
                                        results.append((sid, w.get("entry_id",""),
                                                        w.get("reason",""), w.get("ts",""), "drift-A"))
        for sid, slot in doc.items():
            if sid == "sessions" or sid in seen:
                continue
            if isinstance(slot, dict) and isinstance(slot.get("waivers"), list):
                for w in slot["waivers"]:
                    if isinstance(w, dict):
                        results.append((sid, w.get("entry_id",""), w.get("reason",""),
                                        w.get("ts",""), "drift-C"))
            elif isinstance(slot, list):
                for item in slot:
                    if isinstance(item, dict):
                        if "entry_id" in item:
                            results.append((sid, item.get("entry_id",""),
                                            item.get("reason",""), item.get("ts",""), "drift-E"))
                        elif isinstance(item.get("waivers"), list):
                            for w in item["waivers"]:
                                if isinstance(w, dict):
                                    results.append((sid, w.get("entry_id",""),
                                                    w.get("reason",""), w.get("ts",""), "drift-D"))
    return results

# --------- classifier ---------
LEGIT_MARKERS = re.compile(
    r"R-37\s*lockstep|mechanical\s+(backfill|migration|Phase)|additive[-\s]only|"
    r"SCHEMA_KEY|type[_\s-]*map|type:\s*log|log-type|"
    r"hub[-\s]spoke|cascade work|canonical|unchanged|no change|rename[-\s]reflection|"
    r"meeting[-\s]processor|digest[-\s]run|session[-\s]close|additive|"
    r"engagement membership.*(unchanged|unaffected)|directory tree unchanged|"
    r"SCHEMA_KEY\)?\s*case|type_map\s*dict",
    re.IGNORECASE
)

def classify(sid, eid, reason, abuse_keys):
    rs = reason.strip()
    rkey = rs[:120]
    if (eid, rkey) in abuse_keys:
        return "abuse"
    if not rs:
        return "abuse"
    if len(rs) < 30 and not LEGIT_MARKERS.search(rs):
        return "abuse"
    if registered_ids and eid not in registered_ids:
        return "ad-hoc"
    if not LEGIT_MARKERS.search(rs):
        return "ad-hoc"
    return "legitimate"

waivers = read_waivers(waiver_path)

# Pre-pass: identify identical-reason-across-≥3-sessions clusters.
reason_by_eid = defaultdict(lambda: defaultdict(set))
for sid, eid, reason, _ts, _shape in waivers:
    reason_by_eid[eid][reason.strip()[:120]].add(sid)
abuse_keys = set()
for eid, per in reason_by_eid.items():
    for rkey, sids in per.items():
        if len(sids) >= 3 and rkey:
            abuse_keys.add((eid, rkey))

bucket_counts = Counter()
shape_counts = Counter()
ad_hoc_entries = set()
legit_by_eid = Counter()
per_waiver_bucket = []

for sid, eid, reason, ts, shape in waivers:
    b = classify(sid, eid, reason, abuse_keys)
    bucket_counts[b] += 1
    shape_counts[shape] += 1
    if b == "ad-hoc":
        ad_hoc_entries.add(eid)
    if b == "legitimate":
        legit_by_eid[eid] += 1
    per_waiver_bucket.append((sid, eid, reason, ts, shape, b))

# --------- waiver emission ---------
if scope in ("all", "waivers") and not dry_run and not report_path:
    for sid, eid, reason, ts, shape, b in per_waiver_bucket:
        if b in ("abuse", "ad-hoc"):
            emit({"finding": "waiver-" + b, "session_id": sid, "entry_id": eid,
                  "reason_excerpt": reason[:200], "shape": shape, "ts": ts})
    for eid, n in legit_by_eid.items():
        if n >= 5:
            emit({"finding": "waiver-registry-rule-candidate",
                  "entry_id": eid, "legit_hit_count": n,
                  "note": "Cluster candidate — consider doc-dependency registry refinement so the cascade stops firing on structurally safe edits."})

# --------- override log audit ---------
override_fires = []
kind_re = re.compile(
    r"^(?P<ts>\S+)\s*\|\s*pre-write-guard\s*\|\s*(?P<kind>PLAN_STATUS_OK|CLAUDE_MEM_DISABLE_OK) override"
    r"(?:\s*\(prefix\))?\s*\|\s*(?P<path>[^|\n]+?)\s*$"
)
try:
    with open(audit_path) as f:
        for line in f:
            m = kind_re.match(line.rstrip("\n"))
            if m:
                override_fires.append((m.group("ts"), m.group("kind"), m.group("path").strip()))
except Exception:
    pass

# Session attribution — hook-audit.log has no session id; group by date as proxy.
daily = defaultdict(list)
for ts, kind, path in override_fires:
    day = ts[:10] if ts else "unknown"
    daily[day].append((ts, kind, path))

if scope in ("all", "overrides") and not dry_run and not report_path:
    for ts, kind, path in override_fires:
        emit({"finding": "override-fire", "ts": ts, "kind": kind, "file": path})
    for day, fires in daily.items():
        if len(fires) >= 3:
            emit({"finding": "override-rate-warning", "day": day,
                  "fire_count": len(fires),
                  "kinds": sorted(set(k for _, k, _ in fires))})

# --------- dry-run summary ---------
if dry_run:
    total = sum(bucket_counts.values())
    def s(c): return sorted(c.items())
    print("waivers: total=%d buckets=%s shapes=%s ad_hoc_entry_ids=%d registry_rule_candidates=%d" % (
        total, dict(bucket_counts), dict(shape_counts), len(ad_hoc_entries),
        sum(1 for n in legit_by_eid.values() if n >= 5)))
    print("overrides: fires=%d days_with_3plus=%d kinds=%s" % (
        len(override_fires),
        sum(1 for d, f in daily.items() if len(f) >= 3),
        sorted(set(k for _, k, _ in override_fires))))

# --------- markdown report ---------
if report_path:
    # Self-stamp the COMPLETE log contract so a
    # Logs/ audit report is findable (R-47 #log/<subtype> tag) + non-orphan,
    # rather than relying on the post-write-verify.sh autogovern backfill. The
    # log contract = type + log-type + date + timestamp + the R-47 tag.
    _now = datetime.now(timezone.utc).astimezone()
    lines = []
    lines.append("---")
    lines.append("title: Waiver Audit Report")
    lines.append("type: log")
    lines.append("log-type: audit-report")
    lines.append("date: %s" % _now.strftime("%Y-%m-%d"))
    lines.append("timestamp: %s" % _now.isoformat())
    lines.append('tags: ["#log/audit-report"]')
    lines.append("generated: %s" % _now.isoformat())
    lines.append("---")
    lines.append("")
    lines.append("# Waiver Audit Report")
    lines.append("")
    lines.append("## Cascade-waiver bucket counts")
    lines.append("")
    lines.append("| bucket | count |")
    lines.append("|--------|------:|")
    for b in ("legitimate", "stale", "ad-hoc", "abuse", "unclassifiable"):
        lines.append("| %s | %d |" % (b, bucket_counts.get(b, 0)))
    lines.append("| **total** | **%d** |" % sum(bucket_counts.values()))
    lines.append("")
    lines.append("## JSON shape distribution")
    lines.append("")
    for s_k, c in sorted(shape_counts.items(), key=lambda x: -x[1]):
        lines.append("- `%s`: %d" % (s_k, c))
    lines.append("")
    lines.append("## Ad-hoc entry_ids")
    lines.append("")
    if ad_hoc_entries:
        for eid in sorted(ad_hoc_entries):
            lines.append("- `%s`" % eid)
    else:
        lines.append("(none)")
    lines.append("")
    lines.append("## Legitimate-cluster registry-rule candidates (≥5 hits)")
    lines.append("")
    cands = [(e, n) for e, n in legit_by_eid.items() if n >= 5]
    if cands:
        for e, n in sorted(cands, key=lambda x: -x[1]):
            lines.append("- `%s` — %d waivers" % (e, n))
    else:
        lines.append("(none)")
    lines.append("")
    lines.append("## Override-log summary")
    lines.append("")
    lines.append("- Total override fires: %d" % len(override_fires))
    for kind in ("PLAN_STATUS_OK", "CLAUDE_MEM_DISABLE_OK"):
        k = sum(1 for _, k2, _ in override_fires if k2 == kind)
        lines.append("- %s: %d" % (kind, k))
    lines.append("")
    lines.append("## Days with ≥3 override fires")
    lines.append("")
    rate_days = [(d, len(f)) for d, f in daily.items() if len(f) >= 3]
    if rate_days:
        for d, n in sorted(rate_days, key=lambda x: -x[1]):
            lines.append("- %s: %d fires" % (d, n))
    else:
        lines.append("(none)")
    lines.append("")
    lines.append("---")
    lines.append("*Generated by `waiver-audit.sh`.*")
    with open(report_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("report written: %s" % report_path)
PY

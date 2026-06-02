#!/bin/bash
# plan-index — Regenerate <plans-root>/_index.md as a status-grouped navigation
# index over every plan root, READING the master sub_plans[] aggregate so a
# master's row carries its sub-plan rollup (reader cap).
#
# Reader cap with the master
# sub_plans[] read contract. The plan-index.md capability
# contract is governed by the registry output_contract — there is NO
# governance/librarian-capabilities/plan-index.md and NO _index.json pillar-8
# entry; the rules-index renders capabilities via the registry, not the pillar
# JSONs.
#
# Output Contract
#   Files written: <plans-root>/_index.md (single atomic write); findings to
#     stdout (NDJSON via hooks/lib/findings.sh shape).
#   Pre-write validation: the walk must find >0 plan roots (prevents wiping
#     _index.md on a misread); group-count sum assertion.
#   Failure mode: block-and-log; never write-and-hope. Read-only walk + one
#     atomic file write.
#
# Master sub_plans[] read: when a plan manifest declares type:master (or
# carries sub_plans[]), the index row appends a coarse-bucket rollup
# (active/done/verified/closed counts) READ from the master's
# sub_plans[] read-replica that subplan-aggregate.sh populates. The
# reader NEVER writes the aggregate.
#
# CLI:
#   plan-index.sh                 # regenerate _index.md
#   plan-index.sh --dry-run       # produce content + report counts, no write
#   plan-index.sh --parent <slug> # filter to plans whose parent chain includes <slug>
#   plan-index.sh --help
#
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   USER_MANIFEST_PATH       master-initiative whitelist source
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Read-only walk + single atomic file write.

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

DRY_RUN=false
PARENT_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --parent)  PARENT_FILTER="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "plan-index: unknown flag: $1" >&2; exit 2 ;;
  esac
done

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

INDEX_PATH="$PLANS_ROOT/_index.md"
TMP_PATH="${INDEX_PATH}.tmp.$$"
USER_MANIFEST_PATH="${USER_MANIFEST_PATH:-$CLAUDE_HOME_RES/user-manifest.json}"

python3 - "$PLANS_ROOT" "$INDEX_PATH" "$TMP_PATH" "$DRY_RUN" "$PARENT_FILTER" "$USER_MANIFEST_PATH" <<'PY'
import json, os, re, sys, datetime, pathlib

PLANS_DIR = pathlib.Path(sys.argv[1])
INDEX_PATH = pathlib.Path(sys.argv[2])
TMP_PATH = pathlib.Path(sys.argv[3])
DRY_RUN = sys.argv[4] == "true"
PARENT_FILTER = sys.argv[5] or None
USER_MANIFEST_PATH = pathlib.Path(sys.argv[6]) if len(sys.argv) > 6 else None

# Coarse-bucket map for the master sub_plans[] rollup.
COARSE = {
    "researching": "active", "planned": "active", "in-progress": "active", "paused": "active",
    "completed": "done", "verified": "verified",
    "closed": "closed", "archived": "closed", "superseded": "closed",
}

def _load_master_initiative_whitelist():
    if not USER_MANIFEST_PATH or not USER_MANIFEST_PATH.is_file():
        return set()
    try:
        with open(USER_MANIFEST_PATH) as f:
            doc = json.load(f)
    except Exception:
        return set()
    raw = (doc.get("plans") or {}).get("master_initiative_whitelist") or []
    return {s for s in raw if isinstance(s, str)}

MASTER_INITIATIVE_WHITELIST = _load_master_initiative_whitelist()
EXCLUDE_SLUGS = {"_index.md", "ENFORCEMENT-MAP.md"}

ACTIVE_VALUES = {"planned", "briefed", "draft", "in-progress", "in_progress",
                 "review", "researching", "ready", "active", "approved"}
COMPLETE_VALUES = {"complete", "completed", "done", "implemented", "verified"}
ONHOLD_VALUES = {"on-hold", "deferred", "paused"}
SUPERSEDED_VALUES = {"superseded", "replaced", "obsolete", "absorbed", "archived"}
ABANDONED_VALUES = {"abandoned", "abandoned-with-reason", "tombstoned", "cancelled"}
CLOSED_VALUES = {"closed"}

def normalize_status(raw):
    if not raw:
        return "Unknown"
    head = re.split(r"\s+[—\-]\s+", raw.strip(), maxsplit=1)[0]
    head = head.split("(", 1)[0].strip()
    head = head.split(".", 1)[0].strip()
    s = re.sub(r"\s+", "-", head).lower()
    if s in ACTIVE_VALUES or s.startswith("approved-"):
        return "Active"
    if s in COMPLETE_VALUES:
        return "Complete"
    if s in CLOSED_VALUES:
        return "Complete"
    if s in ONHOLD_VALUES:
        return "On-Hold"
    if s in SUPERSEDED_VALUES or s.startswith("absorbed-by-"):
        return "Superseded"
    if s in ABANDONED_VALUES:
        return "Abandoned"
    for v in SUPERSEDED_VALUES:
        if s.startswith(v + "-"):
            return "Superseded"
    for v in ABANDONED_VALUES:
        if s.startswith(v + "-"):
            return "Abandoned"
    for v in COMPLETE_VALUES:
        if s.startswith(v + "-"):
            return "Complete"
    for v in ACTIVE_VALUES:
        if s.startswith(v + "-"):
            return "Active"
    for v in ONHOLD_VALUES:
        if s.startswith(v + "-"):
            return "On-Hold"
    return "Unknown"

def parse_frontmatter(text):
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    body = text[4:end]
    fm = {}
    for line in body.splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm

def read_text(path):
    try:
        return path.read_text(errors="replace")
    except Exception:
        return ""

def read_manifest(entry):
    mp = entry / "manifest.json"
    if mp.is_file():
        try:
            with open(mp) as f:
                return json.load(f)
        except Exception:
            return None
    return None

def extract_status(entry):
    if entry.is_dir():
        doc = read_manifest(entry)
        if doc and doc.get("status"):
            return doc["status"]
        for name in ("spec.md", "00-ideation-brief.md", "README.md"):
            sp = entry / name
            if sp.is_file():
                txt = read_text(sp)
                m = re.search(r"^\*\*Status:\*\*\s*([^\n]+?)\s*$", txt, re.M)
                if m:
                    return m.group(1)
                fm = parse_frontmatter(txt)
                if fm.get("status"):
                    return fm["status"]
        return ""
    if entry.is_file() and entry.suffix == ".md":
        txt = read_text(entry)
        m = re.search(r"^\*\*Status:\*\*\s*([^\n]+?)\s*$", txt, re.M)
        if m:
            return m.group(1)
        fm = parse_frontmatter(txt)
        if fm.get("status"):
            return fm["status"]
    return ""

def extract_title(entry):
    if entry.is_dir():
        for name in ("spec.md", "00-ideation-brief.md", "README.md"):
            sp = entry / name
            if sp.is_file():
                txt = read_text(sp)
                m = re.search(r"^#\s+(.+?)\s*$", txt, re.M)
                if m:
                    t = m.group(1).strip()
                    return re.sub(r"\s*[—\-]\s*(Spec|Plan)\s*$", "", t)
        return entry.name
    if entry.is_file():
        txt = read_text(entry)
        m = re.search(r"^#\s+(.+?)\s*$", txt, re.M)
        if m:
            t = m.group(1).strip()
            return re.sub(r"\s*[—\-]\s*(Spec|Plan)\s*$", "", t)
    return entry.name

def master_rollup(entry):
    """READ the master sub_plans[] read-replica; return a coarse-bucket
    rollup string, or '' if not a master / no sub_plans."""
    if not entry.is_dir():
        return ""
    doc = read_manifest(entry)
    if not doc:
        return ""
    subs = doc.get("sub_plans")
    if not isinstance(subs, list) or not subs:
        return ""
    buckets = {"active": 0, "done": 0, "verified": 0, "closed": 0}
    for sp in subs:
        if isinstance(sp, dict):
            buckets[COARSE.get(sp.get("status", ""), "active")] += 1
    return " · subs: %d active / %d done / %d verified / %d closed" % (
        buckets["active"], buckets["done"], buckets["verified"], buckets["closed"])

def parent_plan_chain(entry):
    chain = []
    slugs_visited = set()
    current = entry
    for _ in range(10):
        sp = (current / "spec.md") if current.is_dir() else current
        if not sp.is_file():
            break
        fm = parse_frontmatter(read_text(sp))
        pp = fm.get("parent_plan", "").strip()
        if not pp or pp in slugs_visited:
            break
        slugs_visited.add(pp)
        chain.append(pp)
        candidates = list(PLANS_DIR.glob("*-%s" % pp)) + list(PLANS_DIR.glob(pp)) + [PLANS_DIR / pp]
        found = next((c for c in candidates if c.exists()), None)
        if not found:
            break
        current = found
    return chain

entries_by_group = {"Active": [], "On-Hold": [], "Complete": [],
                    "Superseded": [], "Abandoned": [], "Unknown": []}
warnings = []
total_counted = 0

if not PLANS_DIR.is_dir():
    print("plan-index: PLANS_ROOT not found: %s" % PLANS_DIR, file=sys.stderr)
    sys.exit(1)

for entry in sorted(PLANS_DIR.iterdir()):
    slug = entry.name
    if slug.startswith("_") or slug.startswith("."):
        continue
    if slug in EXCLUDE_SLUGS:
        continue
    if slug not in MASTER_INITIATIVE_WHITELIST and not re.match(r"^\d+-", slug) \
            and not re.match(r"^SP-\d+", slug):
        print(json.dumps({
            "finding": "plan-prefix-missing", "file": slug,
            "category": "plan-naming-drift",
            "resolution_hint": "rename via `git mv {slug} NN-{slug}`"}))
    if entry.is_dir():
        doc = read_manifest(entry)
        if doc:
            spec_path = doc.get("spec_path", "") or ""
            if spec_path and not (spec_path == "spec.md" or str(entry) in spec_path):
                continue
    if PARENT_FILTER:
        if PARENT_FILTER not in parent_plan_chain(entry):
            continue
    raw_status = extract_status(entry)
    group = normalize_status(raw_status)
    title = extract_title(entry)
    rollup = master_rollup(entry)
    if entry.is_dir():
        line = "- [%s](./%s/) — %s%s" % (slug, slug, title, rollup)
    else:
        line = "- [%s](./%s) — %s" % (slug, slug, title)
    entries_by_group[group].append((slug, line))
    total_counted += 1
    if group == "Unknown":
        warnings.append(slug)

def slug_sort_key(item):
    s = item[0]
    m = re.match(r"^(?:SP-)?(\d+)-(.*)$", s)
    if m:
        return (0, int(m.group(1)), m.group(2))
    return (1, 0, s)

for g in entries_by_group:
    entries_by_group[g].sort(key=slug_sort_key)

group_sum = sum(len(v) for v in entries_by_group.values())
if group_sum != total_counted:
    print("plan-index: group-count assertion failed", file=sys.stderr)
    sys.exit(3)
if total_counted == 0:
    print("plan-index: walk found 0 plan roots; aborting to prevent _index.md wipe",
          file=sys.stderr)
    sys.exit(4)

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
out = ["# Plan Index", "",
       "_Auto-generated by `librarian plan-index`. Do not hand-edit._", "",
       "**Total plans:** %d" % total_counted,
       "**Last regenerated:** %s" % now, ""]
for group_name in ("Active", "On-Hold", "Complete", "Superseded", "Abandoned", "Unknown"):
    items = entries_by_group[group_name]
    out.append("## %s (%d)" % (group_name, len(items)))
    out.append("")
    if group_name == "Unknown":
        out.append("_Plans missing a detectable status._")
        out.append("")
    if items:
        for _, line in items:
            out.append(line)
    out.append("")

content = "\n".join(out).rstrip() + "\n"

print(json.dumps({"plan_index_run": {
    "total": total_counted,
    "active": len(entries_by_group["Active"]),
    "complete": len(entries_by_group["Complete"]),
    "unknown_slugs": warnings, "dry_run": DRY_RUN,
    "parent_filter": PARENT_FILTER or None}}))

if not DRY_RUN:
    TMP_PATH.write_text(content)
    os.replace(TMP_PATH, INDEX_PATH)
else:
    sys.stderr.write(content)
PY

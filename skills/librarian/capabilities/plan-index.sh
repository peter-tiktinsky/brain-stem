#!/bin/bash
# plan-index — Regenerate <plans-root>/_index.md as a status-grouped navigation
# index over every plan root, READING the master sub_plans[] aggregate so a
# master's row carries its sub-plan rollup (a reader cap).
#
# Librarian reader cap: regenerates _index.md and reads the master sub_plans[] aggregate.
# There is NO separate plan-index.md capability contract — the capability is governed by
# the registry output_contract (no _index.json pillar entry; the rules-index renders
# capabilities via the registry, not the pillar JSONs).
#
# Output Contract
#   Files written: <plans-root>/_index.md (single atomic write); findings to
#     stdout (NDJSON via hooks/lib/findings.sh shape).
#   Pre-write validation: the walk must find >0 plan roots (prevents wiping
#     _index.md on a misread); group-count sum assertion.
#   Failure mode: block-and-log; never write-and-hope. Read-only walk + one
#     atomic file write.
#   Sections (render order): the status-grouped roster (Pending / Active / Done /
#     Superseded / Abandoned / Unknown), the collapsed "Archived (N)" view-filter
#     footnote, then `## By project directory` as the FINAL section — one
#     `### <project-home-dir>` group per resolved directory (alphabetical) of
#     one-line plan entries, with a trailing `### (no project directory)` group for
#     empty-resolution rows. The by-project section mirrors the roster's membership
#     (view-filter parity, incl. --all) and is render-only (never re-parsed).
#
# master sub_plans[] read: when a plan manifest declares type:master (or
# carries sub_plans[]), the index row appends a coarse-bucket rollup
# (pending/active/done counts) READ from the master's sub_plans[] read-replica
# that subplan-aggregate.sh populates. The reader NEVER writes the
# aggregate.
#
# CLI:
#   plan-index.sh                 # regenerate _index.md
#   plan-index.sh --dry-run       # produce content + report counts, no write
#   plan-index.sh --parent <slug> # filter to plans whose parent chain includes <slug>
#   plan-index.sh --all           # also show completed plans older than the archival
#                                 #   window (default-hidden into the "Archived (N)"
#                                 #   collapsed section); --archived is an alias
#   plan-index.sh --help
#
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   USER_MANIFEST_PATH       master-initiative whitelist source
#   PLAN_INDEX_TODAY         "today" (YYYY-MM-DD) for deterministic archival-age tests
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
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/anchored-spoke-registry.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/anchored-spoke-registry.sh"; } \
  || { [ -r "$_REPO_LIB/anchored-spoke-registry.sh" ] && source "$_REPO_LIB/anchored-spoke-registry.sh"; } || true

DRY_RUN=false
PARENT_FILTER=""
SHOW_ALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --parent)  PARENT_FILTER="$2"; shift 2 ;;
    --all|--archived) SHOW_ALL=true; shift ;;
    -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "plan-index: unknown flag: $1" >&2; exit 2 ;;
  esac
done
PLAN_INDEX_TODAY="${PLAN_INDEX_TODAY:-}"

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

INDEX_PATH="$PLANS_ROOT/_index.md"
TMP_PATH="${INDEX_PATH}.tmp.$$"
USER_MANIFEST_PATH="${USER_MANIFEST_PATH:-$CLAUDE_HOME_RES/user-manifest.json}"

# Anchored-spoke registry: resolves each plan's manifest `project:` spoke key to
# its project-home directory (cwd_anchors[0]) for the per-row ownership annotation
# (the render-shape ruling is per-row annotation on the bullet row, mirroring the
# master_rollup precedent). The ONE shared resolver
# (hooks/lib/anchored-spoke-registry.sh) owns the order — test override -> the
# $CLAUDE_HOME install -> the repo governance/ copy as a fallback. A
# missing/unreadable registry renders every row's annotation as the graceful empty
# (never a crash).
if ! command -v spoke_registry_resolve >/dev/null 2>&1; then
  echo "plan-index: hooks/lib/anchored-spoke-registry.sh not found (looked under $CLAUDE_HOME_RES/hooks/lib and $_REPO_LIB)" >&2
  exit 1
fi
_REPO_GOV="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/governance"
SPOKE_REG="$(spoke_registry_resolve "$_REPO_GOV")"

# WRITE-TARGET COHERENCE. The index path is resolved from $HOME while the registry
# is resolved from $CLAUDE_HOME; pairing the live plan corpus with another tree's
# registry would rewrite _index.md with a silently blank ownership annotation on
# every row that registry cannot resolve. Refuse before the walk, in the same
# abort-rather-than-write posture that guards the 0-plan wipe.
spoke_registry_assert_coherent "$SPOKE_REG" "$INDEX_PATH" "plan-index" || exit 1

python3 - "$PLANS_ROOT" "$INDEX_PATH" "$TMP_PATH" "$DRY_RUN" "$PARENT_FILTER" "$USER_MANIFEST_PATH" "$SPOKE_REG" "$SHOW_ALL" "$PLAN_INDEX_TODAY" <<'PY'
import json, os, re, sys, datetime, pathlib

PLANS_DIR = pathlib.Path(sys.argv[1])
INDEX_PATH = pathlib.Path(sys.argv[2])
TMP_PATH = pathlib.Path(sys.argv[3])
DRY_RUN = sys.argv[4] == "true"
PARENT_FILTER = sys.argv[5] or None
USER_MANIFEST_PATH = pathlib.Path(sys.argv[6]) if len(sys.argv) > 6 else None
SPOKE_REGISTRY_PATH = pathlib.Path(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else None
SHOW_ALL = len(sys.argv) > 8 and sys.argv[8] == "true"
_TODAY_STR = sys.argv[9] if len(sys.argv) > 9 else ""

# archival view-filter: default-hide `completed` plans older than this many days
# into a collapsed "Archived (N)" section. DISPLAY-ONLY + recomputed at render time
# (no cron, no hook); soft/reversible (`--all` shows them; nothing moves). 14 days is
# safe precisely because archival is soft — a premature hide costs one `--all` flag.
ARCHIVE_WINDOW_DAYS = 14
try:
    TODAY = datetime.date.fromisoformat(_TODAY_STR) if _TODAY_STR else datetime.date.today()
except ValueError:
    TODAY = datetime.date.today()

# Coarse-bucket map for the master sub_plans[] rollup: the pending/active/done
# display vocabulary (Layer 2 coarsening — lossy, never written back). Terminal
# tokens from older manifests (verified/closed/archived) coarsen to `done` for
# robustness; they never render as their own columns.
COARSE = {
    "researching": "pending", "planned": "pending",
    "in-progress": "active", "paused": "active",
    "completed": "done", "superseded": "done",
    "verified": "done", "closed": "done", "archived": "done",
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

def _load_spoke_dir_map():
    """Map each registry spoke_key -> its project-home directory (cwd_anchors[0]),
    the SINGLE resolution point feeding BOTH the per-row ownership annotation and the
    `## By project directory` grouping. The `home` spoke key is EXCLUDED
    unconditionally — skipped even when the registry declares cwd_anchors for it (the
    LIVE registry anchors `home` at ["~", "$HOME"]) — so a `project: home` plan
    resolves to the graceful empty at every consumer, never a useless ` · ~`.
    A missing/unreadable/malformed registry yields an empty map — every row then
    renders the graceful empty annotation (never a crash)."""
    if not SPOKE_REGISTRY_PATH or not SPOKE_REGISTRY_PATH.is_file():
        return {}
    try:
        with open(SPOKE_REGISTRY_PATH) as f:
            doc = json.load(f)
    except Exception:
        return {}
    m = {}
    for sp in doc.get("spokes", []) or []:
        if not isinstance(sp, dict):
            continue
        key = sp.get("spoke_key", "")
        # `home` is the anchorless catch-all identity, not a project directory:
        # exclude it unconditionally here (the single resolution point) so both the
        # per-row annotation and the by-project grouping resolve it to the graceful
        # empty even when the registry declares anchors for it (the live shape).
        if key == "home":
            continue
        anchors = sp.get("cwd_anchors", []) or []
        if key and isinstance(anchors, list) and anchors:
            m[key] = anchors[0]
    return m

SPOKE_DIR_MAP = _load_spoke_dir_map()

# roster groups: pending / active / done + superseded + abandoned. Shared
# pending/active/done core with the rollup, plus the two terminal-without-
# completion groups a roster needs (superseded / abandoned). `archived` groups
# under `done` (completed-then-retired), correcting the prior archived-under-
# Superseded miscategorization. `paused` groups under `active` (parked mid-flight).
PENDING_VALUES = {"researching", "planned", "briefed", "draft", "ready", "approved"}
ACTIVE_VALUES = {"in-progress", "in_progress", "review", "paused", "active"}
DONE_VALUES = {"completed", "complete", "done", "implemented", "verified", "closed", "archived"}
SUPERSEDED_VALUES = {"superseded", "replaced", "obsolete", "absorbed"}
ABANDONED_VALUES = {"abandoned", "abandoned-with-reason", "tombstoned", "cancelled"}

def normalize_status(raw):
    if not raw:
        return "Unknown"
    head = re.split(r"\s+[—\-]\s+", raw.strip(), maxsplit=1)[0]
    head = head.split("(", 1)[0].strip()
    head = head.split(".", 1)[0].strip()
    s = re.sub(r"\s+", "-", head).lower()
    if s in PENDING_VALUES or s.startswith("approved-"):
        return "Pending"
    if s in ACTIVE_VALUES:
        return "Active"
    if s in DONE_VALUES:
        return "Done"
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
    for v in DONE_VALUES:
        if s.startswith(v + "-"):
            return "Done"
    for v in ACTIVE_VALUES:
        if s.startswith(v + "-"):
            return "Active"
    for v in PENDING_VALUES:
        if s.startswith(v + "-"):
            return "Pending"
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
    """: READ the master sub_plans[] read-replica; return a coarse-bucket
    rollup string, or '' if not a master / no sub_plans."""
    if not entry.is_dir():
        return ""
    doc = read_manifest(entry)
    if not doc:
        return ""
    subs = doc.get("sub_plans")
    if not isinstance(subs, list) or not subs:
        return ""
    buckets = {"pending": 0, "active": 0, "done": 0}
    for sp in subs:
        if isinstance(sp, dict):
            buckets[COARSE.get(sp.get("status", ""), "active")] += 1
    return " · subs: %d pending / %d active / %d done" % (
        buckets["pending"], buckets["active"], buckets["done"])

def project_home_dir_bare(entry):
    """Resolve the plan's project-home directory BARE (no ` · ` annotation prefix):
    the group key for the `## By project directory` section. Resolved from the
    manifest `project:` spoke key via SPOKE_DIR_MAP. Uses a FRESH per-entry
    read_manifest (mirroring master_rollup), NEVER the entry-scoped `doc` that leaks
    a stale value across non-dir iterations. Returns '' for a non-dir entry, absent/
    malformed `project:`, the `home` key (excluded at _load_spoke_dir_map — see the
    explicit home-key rule there), or an unresolvable key."""
    if not entry.is_dir():
        return ""
    doc = read_manifest(entry)
    if not doc:
        return ""
    proj = doc.get("project")
    if not proj or not isinstance(proj, str):
        return ""
    return SPOKE_DIR_MAP.get(proj) or ""

def project_home_dir(entry):
    """Render the ` · <dir>` per-row ownership annotation from project_home_dir_bare.
    Absent `project:`, the `home` key (excluded at _load_spoke_dir_map — the registry
    may anchor `home` at ["~", "$HOME"], but it never resolves to a directory here),
    or an unresolvable key renders a graceful empty annotation, never a crash."""
    d = project_home_dir_bare(entry)
    return " · %s" % d if d else ""

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

def completion_date(entry):
    """Completion date for the archival age view-filter: manifest.completed_at,
    falling back to `updated` (legacy manifests predate completed_at). Bare .md plans
    fall back to frontmatter `updated`. Returns a date, or None (not age-sortable ->
    never hidden). Date-only per the completed_at/updated convention (first 10 chars)."""
    raw = ""
    if entry.is_dir():
        doc = read_manifest(entry)
        if doc:
            raw = str(doc.get("completed_at") or doc.get("updated") or "")
        if not raw:
            for name in ("spec.md", "00-ideation-brief.md", "README.md"):
                sp = entry / name
                if sp.is_file():
                    raw = parse_frontmatter(read_text(sp)).get("updated", "")
                    if raw:
                        break
    elif entry.is_file():
        raw = parse_frontmatter(read_text(entry)).get("updated", "")
    try:
        return datetime.date.fromisoformat(raw.strip()[:10])
    except (ValueError, TypeError):
        return None

entries_by_group = {"Pending": [], "Active": [], "Done": [],
                    "Superseded": [], "Abandoned": [], "Unknown": []}
# ## By project directory: per-entry records for the appended by-project
# section — (slug, title, group, rollup, bare_dir, is_dir). Collected in lockstep with
# entries_by_group (same filters), so section membership mirrors the roster exactly.
by_project = []
# view-filter: slugs whose `completed` row is older than the archival window and so
# is default-hidden into the collapsed "Archived (N)" section (empty under --all).
archived_slugs = set()
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
            # a manifest's spec_path may be stored as the
            # bare `spec.md`, an absolute path, or a tilde path
            # (`~/.claude-plans/<slug>/spec.md`, as ~17 live manifests do). The
            # old `str(entry) in spec_path` containment dropped every tilde-stored
            # row (the literal `~` never contains the absolute plan dir) and could
            # substring-admit a foreign plan. Normalize both sides (expanduser +
            # realpath) and match the spec_path's OWN plan dir against `entry`: a
            # self-referential tilde/absolute spec_path admits its row, while a
            # spec_path pointing at a DIFFERENT plan dir is still dropped.
            if spec_path and spec_path != "spec.md":
                spec_plan_dir = os.path.realpath(
                    os.path.dirname(os.path.expanduser(spec_path)))
                if os.path.realpath(str(entry)) != spec_plan_dir:
                    continue
    if PARENT_FILTER:
        if PARENT_FILTER not in parent_plan_chain(entry):
            continue
    raw_status = extract_status(entry)
    group = normalize_status(raw_status)
    title = extract_title(entry)
    rollup = master_rollup(entry)
    projdir = project_home_dir(entry)
    if entry.is_dir():
        line = "- [%s](./%s/) — %s%s%s" % (slug, slug, title, projdir, rollup)
    else:
        line = "- [%s](./%s) — %s" % (slug, slug, title)
    entries_by_group[group].append((slug, line))
    by_project.append((slug, title, group, rollup,
                       project_home_dir_bare(entry), entry.is_dir()))
    total_counted += 1
    if group == "Unknown":
        warnings.append(slug)
    # a Done-group plan (completed / terminal-done) older than the window is
    # default-hidden into the collapsed Archived section (unless --all). DISPLAY ONLY —
    # no status is written; the plan stays exactly where it is (soft/reversible).
    if group == "Done" and not SHOW_ALL:
        cd = completion_date(entry)
        if cd is not None and (TODAY - cd).days >= ARCHIVE_WINDOW_DAYS:
            archived_slugs.add(slug)

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
for group_name in ("Pending", "Active", "Done", "Superseded", "Abandoned", "Unknown"):
    items = entries_by_group[group_name]
    # the Done group hides its archived (completed >= window) rows into the
    # collapsed Archived section below (never under --all, where archived_slugs is empty).
    if group_name == "Done":
        items = [it for it in items if it[0] not in archived_slugs]
    out.append("## %s (%d)" % (group_name, len(items)))
    out.append("")
    if group_name == "Unknown":
        out.append("_Plans missing a detectable status._")
        out.append("")
    if items:
        for _, line in items:
            out.append(line)
    out.append("")

# archival view-filter: a collapsed count-only section for the completed plans older
# than the window (soft/reversible — the plan never moved; `--all` re-shows the rows).
if archived_slugs:
    out.append("## Archived (%d)" % len(archived_slugs))
    out.append("")
    out.append("_%d completed plan(s) older than %d days, hidden from the roster above. "
               "Run `librarian plan-index --all` to show them._"
               % (len(archived_slugs), ARCHIVE_WINDOW_DAYS))
    out.append("")

# ## By project directory: the FINAL section, appended after the Archived
# block. One `### <project-home-dir>` H3 group per resolved directory (alphabetical by
# rendered dir string), a trailing `### (no project directory)` group for the empty-
# resolution entries (absent project:, the home key, an unresolvable key, file-backed
# .md plans). Entry shape: `- [<slug>](./<slug>/) — <title> (<Group>)` + the existing
# master-rollup suffix; NO ` · <dir>` annotation (the group header carries the dir).
# Membership mirrors the roster above exactly — archived-hidden slugs are excluded here
# too (archived_slugs is empty under --all, so the full roster reappears). Render-only:
# derived from by_project this run, never re-parsed from _index.md.
NO_DIR_GROUP = "(no project directory)"
by_project_groups = {}
for slug, title, group, rollup, bare_dir, is_dir in by_project:
    if slug in archived_slugs:
        continue
    key = bare_dir if bare_dir else NO_DIR_GROUP
    link = "./%s/" % slug if is_dir else "./%s" % slug
    row = "- [%s](%s) — %s (%s)%s" % (slug, link, title, group, rollup)
    by_project_groups.setdefault(key, []).append((slug, row))

out.append("## By project directory")
out.append("")
# Groups alphabetical by rendered dir string; the unattributed group ALWAYS last.
dir_keys = sorted(k for k in by_project_groups if k != NO_DIR_GROUP)
if NO_DIR_GROUP in by_project_groups:
    dir_keys.append(NO_DIR_GROUP)
for key in dir_keys:
    out.append("### %s" % key)
    out.append("")
    for _, row in sorted(by_project_groups[key], key=slug_sort_key):
        out.append(row)
    out.append("")

content = "\n".join(out).rstrip() + "\n"

print(json.dumps({"plan_index_run": {
    "total": total_counted,
    "active": len(entries_by_group["Active"]),
    "done": len(entries_by_group["Done"]),
    "unknown_slugs": warnings, "dry_run": DRY_RUN,
    "parent_filter": PARENT_FILTER or None}}))

if not DRY_RUN:
    TMP_PATH.write_text(content)
    os.replace(TMP_PATH, INDEX_PATH)
else:
    sys.stderr.write(content)
PY

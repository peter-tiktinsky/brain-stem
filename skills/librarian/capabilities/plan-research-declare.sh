#!/bin/bash
# plan-research-declare — the A1-clause-4 session-close DECLARATION writer (140).
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as a header shape reference; no Draft202012Validator is constructed, so there is no schema-gate degrade path.
# THE single declaration surface for research_artifacts[] (memo §Amendment-A1 clause 4:
# "declaration DERIVES at session close … no second declaration surface"). At session close this
# RECONCILES each active-spoke plan's manifest.research_artifacts[] from that plan's OWN on-disk
# research homes — the sanctioned graduation home <plan>/_research/ (A1 clause 4: the scratchpad is
# TRANSIT; the sanctioned move is `mv` into <plan>/_research/ at graduation) plus the structured
# in-plan research dirs decisions/ target-state/ deliverables/. It NEVER writes _library
# (universal-only) and NEVER invokes library-scrub --apply (the manual PROMOTION path,
# excluded by design). Routing to the OWNING spoke is DERIVED: this writer writes each plan's OWN
# manifest, and the renderer (plan-research-index.sh) groups by the manifest `project:` key — the
# true owner (139 verified), never the over-attributed brain-stem.
#
# Runs in session-close.sh step2_integrity BEFORE `run_capability plan-research-index --spoke`
# (552) so the render reflects the just-declared artifacts. It is modeled on the drift-sweep
# --plans --fix per-plan manifest read-replica writer (603): block-and-log, exit 0, idempotent,
# single-writer, defensive.
#
# DEFENSIVE / IDEMPOTENT / SINGLE-WRITER contract:
#   - missing research_artifacts field == empty (never an error);
#   - NEVER clobbers an author-curated entry's title/status/path/library_refs — an entry whose
#     path is already declared is preserved BYTE-FOR-BYTE; only NEWLY-discovered on-disk artifacts
#     are APPENDED;
#   - re-running discovers the same on-disk set, all already declared -> a write-no-op (idempotent);
#   - atomic temp-file + os.replace; a plan whose manifest cannot be parsed emits a finding and is
#     skipped (no partial/garbage write, never write-and-hope).
#
# The curation gate is the graduation-move into a research home: an artifact earns a declaration by
# living in one of the scanned research dirs. Exhaust / superseded drafts that live elsewhere in the
# plan (archive-or-in-plan class) are NOT scanned and never declared.
#
# ARTIFACT FILTER — RULED DELIBERATELY NARROW (.md ONLY), STATED HERE SO IT IS NOT READ AS AN
# OVERSIGHT. discover() skips every non-.md file (`if not f.endswith(".md"): continue`), so a
# JSON / CSV / YAML research artifact is STRUCTURALLY UNDECLARABLE by this writer: a declaration
# carries a human `title` derived from the artifact's first H1, which only prose files have. A plan
# that needs a non-.md artifact declared (e.g. an in-plan `_research/*.json` cited by that plan's own
# gate1.validator) declares it BY HAND — the APPEND-only reconcile preserves a hand-authored entry
# verbatim and never removes it, so the narrow walk costs nothing but an automatic first draft.
#
# ANTI-SCOPE GATE (research_closed). When a plan's manifest carries research_closed:true, this writer
# STOPS ratifying by presence: each NEWLY-discovered undeclared artifact under a scanned research home
# yields a research-declare-closed-scope finding (warn) for human adjudication INSTEAD of an append,
# and the manifest is left byte-untouched (existing declared entries preserved). The cap only READS the
# field; it NEVER stamps it. Setter convention (recorded verbatim):
#   research_closed is stamped true by the sanctioned close-out flow when a plan reaches terminal
#   status ({completed, superseded}); the operator may hand-set it on active plans;
#   plan-research-declare only reads it; plans being rehomed by the durable-artifact census are never bulk-stamped.
#
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT):
#   Files written:
#     - each contributing <plan>/manifest.json (research_artifacts[] APPEND-only reconcile;
#         atomic temp+os.replace; never _library, never a vault path).
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: schemas/plan-manifest-schema.json (research_artifacts[] item shape: required
#     id/title/status/path; status enum active|finalized|deferred). Emitted entries seed
#     status=active; author edits to status/title/library_refs are preserved.
#   Pre-write validation: the plans home must resolve to a directory (absent => block-and-log,
#     no write, exit 0); each manifest read defensively; a missing field is empty, never an error.
#   Failure mode: BLOCK-AND-LOG. Never write-and-hope.
#   Maintainer-provenance: this writer touches ONLY plan manifests' research_artifacts[];
#     it NEVER writes _library, research-index.md, the symlink farm (that is plan-research-index's
#     sole scope), or any vault path.
#
# CLI:
#   plan-research-declare.sh                 # reconcile every spoke's plans
#   plan-research-declare.sh --spoke <key>   # reconcile one spoke's plans only (session-close use)
#   plan-research-declare.sh --dry-run       # report would-be declarations, NO write
#   plan-research-declare.sh --help
#
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24. Read-defensive manifest walk +
# atomic per-plan manifest write(s).

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

DRY_RUN="false"
SPOKE_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spoke)   SPOKE_FILTER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "plan-research-declare: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- plans home resolution (robust; the sibling pattern) ---------------------
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

python3 - "$PLANS_ROOT" "$DRY_RUN" "$SPOKE_FILTER" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root, dry_s, spoke_filter = sys.argv[1:4]
dry_run = (dry_s == "true")
spoke_filter = spoke_filter or None
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

# The sanctioned research homes scanned per plan (relative to the plan dir). _research/ is the
# graduation home (A1 clause 4); decisions/ target-state/ deliverables/ are the structured
# in-plan research dirs (class-1). Order is stable for deterministic RA-id assignment.
RESEARCH_DIRS = ["_research", "decisions", "target-state", "deliverables"]


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log: the plans home must resolve -----------------------------
if not plans_root or not os.path.isdir(plans_root):
    emit({"finding": "plan-research-declare-blocked", "file": plans_root or "(unset)",
          "reason": "plans-home-absent", "detected_at": today})
    print("plan-research-declare: plans home absent (%s); nothing to declare"
          % (plans_root or "(unset)"), file=sys.stderr)
    sys.exit(0)

PROJECTS = os.path.join(plans_root, "_projects")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


# --- walk every real plan manifest (mirrors plan-research-index's walk + accept clause) ------
def walk_manifests(root):
    found = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not d.startswith(".")]
        if os.path.abspath(dp) == os.path.abspath(PROJECTS):
            dns[:] = []
            continue
        if "manifest.json" not in fns:
            continue
        mp = os.path.join(dp, "manifest.json")
        man = read_json(mp)
        if man is None:
            emit({"finding": "plan-research-declare-blocked", "file": mp,
                  "reason": "manifest-parse-failed", "detected_at": today})
            continue
        # keep only real plans (a status field OR a sibling spec.md) — the corpus/synthetic
        # fixtures lack both (identical accept clause to plan-research-index).
        if not (("status" in man) or os.path.exists(os.path.join(dp, "spec.md"))):
            continue
        found.append((dp, mp, man))
    return found


def first_heading(path):
    """First markdown H1 (`# Title`) in the file, else None. Read a bounded head."""
    try:
        with open(path, encoding="utf-8") as fh:
            head = fh.read(8192)
    except Exception:
        return None
    m = re.search(r"(?m)^#\s+(.+?)\s*$", head)
    return m.group(1).strip() if m else None


def title_from_stem(name):
    stem = name[:-3] if name.endswith(".md") else name
    return stem.replace("-", " ").replace("_", " ").strip().title() or stem


def discover(plan_dir):
    """Return [(relpath, title)] for every research .md under the scanned dirs, deterministic
    order. Prune dot-dirs; skip dot/underscore-prefixed files (index/scaffold, e.g. _index.md)."""
    hits = []
    for base in RESEARCH_DIRS:
        root = os.path.join(plan_dir, base)
        if not os.path.isdir(root):
            continue
        for dp, dns, fns in os.walk(root):
            dns[:] = sorted(d for d in dns if not d.startswith("."))
            for f in sorted(fns):
                if not f.endswith(".md"):
                    continue
                if f.startswith(".") or f.startswith("_"):
                    continue
                ap = os.path.join(dp, f)
                rel = os.path.relpath(ap, plan_dir)
                title = first_heading(ap) or title_from_stem(f)
                hits.append((rel, title))
    return hits


def next_ra_id(existing):
    mx = 0
    for e in existing:
        if not isinstance(e, dict):
            continue
        m = re.match(r"^RA-(\d+)$", str(e.get("id") or "").strip())
        if m:
            mx = max(mx, int(m.group(1)))
    return mx


def declared_paths(existing):
    s = set()
    for e in existing:
        if isinstance(e, dict):
            p = str(e.get("path") or "").strip()
            if p:
                s.add(p)
    return s


def atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


plans = walk_manifests(plans_root)
plans_touched = 0
entries_added = 0
plans_scanned = 0

for plan_dir, mp, man in plans:
    spoke = str((man.get("project") or "")).strip()
    if spoke_filter and spoke != spoke_filter:
        continue
    plans_scanned += 1
    existing = man.get("research_artifacts")
    if not isinstance(existing, list):
        existing = []
    have = declared_paths(existing)
    nid = next_ra_id(existing)
    discovered = discover(plan_dir)
    # Anti-scope gate: a research_closed:true plan STOPS ratifying by presence.
    # READ-ONLY — the field is never written here (the anti-scope lock: plans
    # being rehomed by the durable-artifact census are never stamped).
    research_closed = (man.get("research_closed") is True)
    new_entries = []
    for rel, title in discovered:
        if rel in have:
            continue                     # already declared — PRESERVE, never clobber
        if research_closed:
            # Emit a finding for the misplaced/undeclared artifact instead of
            # appending it; the manifest stays byte-untouched (parity in dry-run).
            emit({"finding": "research-declare-closed-scope", "file": mp,
                  "plan": os.path.basename(plan_dir.rstrip("/")), "spoke": spoke,
                  "artifact_path": rel, "level": "warn", "detected_at": today})
            continue
        have.add(rel)
        nid += 1
        new_entries.append({
            "id": "RA-%02d" % nid,
            "title": title,
            "status": "active",
            "path": rel,
        })
    if not new_entries:
        continue                          # idempotent: nothing new discovered (or scope closed)
    plans_touched += 1
    entries_added += len(new_entries)
    if dry_run:
        for e in new_entries:
            emit({"finding": "plan-research-declare-would-add", "file": mp,
                  "plan": os.path.basename(plan_dir.rstrip("/")), "spoke": spoke,
                  "artifact_path": e["path"], "id": e["id"], "detected_at": today})
        continue
    # APPEND-only reconcile: preserve every existing entry verbatim; append the new ones.
    man["research_artifacts"] = existing + new_entries
    try:
        atomic_write(mp, json.dumps(man, indent=2, ensure_ascii=False) + "\n")
    except Exception as exc:
        emit({"finding": "plan-research-declare-blocked", "file": mp,
              "reason": "write-failed", "error": str(exc), "detected_at": today})
        continue

print("plan-research-declare: plans_scanned=%d plans_touched=%d entries_added=%d dry_run=%s"
      % (plans_scanned, plans_touched, entries_added, dry_run), file=sys.stderr)
PY

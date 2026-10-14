#!/bin/bash
# plan-research-index — generate the per-spoke binder research surface:
# <plans-root>/_projects/<spoke>/research-index.md,
# re-derived from every plan manifest's research_artifacts[] on every run; it also
# traces the one-sided-promotion-edge contract (this capability is a DETECTOR,
# never a repair-writer — library-scrub owns the promotion write-orchestration).
#
# The plans home resolves robustly the way sibling capabilities resolve it —
# PLANS_ROOT/PLANS_DIR override, else paths.sh, never a hardcoded user-home
# literal. The _projects/ scaffold proper is the install unit's scope; this
# capability mkdir -p's its OWN output home on demand (generation, not install
# scaffolding).
#
# Grouping: the binder is per-spoke — only plans whose manifest
# project: key matches the target spoke contribute rows. Within a spoke, rows are
# grouped by parent_plan: lineage (a top-level plan heads its own lineage group;
# nested plans group under their parent_plan slug). One row per declared
# research_artifacts[] entry of RESEARCH class (declaration is the selectivity
# gate — undeclared artifacts never earn a row).
#
# PARTITION (kind-driven projection, operator-ruled): the artifact's resolved
# KIND — a declared optional `type` wins, else the filename-stem inference —
# routes the projection. Decision-class entries (kind decision|adr) project on
# the DECISION LOG's "Decision artifacts" section, never here; this index emits
# research-class rows only. The promotion-edge detector below still sweeps every
# declared artifact regardless of kind.
#
# row schema: path / type / status (active|finalized|superseded) /
# plan-origin / one-liner, PLUS a Library column populated from the entry's
# library_refs[]. A deferred entry renders no row; the plan's count line takes it.
#
# FOUR-BLOCK ORDER (per plan, one table, then the count line):
#   1. the canonical rows: a declared entry whose path starts with `_research/` and
#      whose status is neither `superseded` nor `deferred`;
#   2. the superseded rows, each forward-linked in its Status cell to the row of its
#      `superseded_by` entry (`superseded → [RA-NN](<link>)`), mirroring
#      plan-decision-log.sh's forward-link rule for superseded records; a target the
#      plan does not declare renders as plain text;
#   3. the remaining declared, non-deferred, research-class rows whose home is outside
#      `_research/` (the RULED VIEWER CONTRACT below keeps every declared home
#      resolving a row);
#   4. one count line: the `.md` files in the plan's declare discovery set (the
#      plan-research-declare walk over _research/, decisions/, target-state/,
#      deliverables/) that have no row shown: deferred entries, decision-class entries
#      and undeclared files.
# A plan with no row to show contributes no table.
#
# row-content selectivity (02:179, "Copy only non-inferable finalized
# findings (> distilled); otherwise emit a pointer"): a row copies a finalized
# finding body inline (a `> ` distilled blockquote line) ONLY when the finding is
# NON-INFERABLE; otherwise it emits a pointer to the artifact path. Operationalized
# here as: an entry is INLINE iff (1) status == finalized AND (2) it carries an
# explicit distilled-finding field (`finding` | `distilled` | `summary`) whose text
# is NOT already inferable from the row's one-liner (not a case-folded substring of,
# nor containing, the one-liner — i.e. it adds content the row's other fields do not
# already convey). Every other entry emits a path POINTER, never the full body.
# Defensive: a missing/empty distilled field => pointer.
#
# Re-derive from frontmatter/manifests every run; missing fields = EMPTY, never an
# error (defensive default). Re-derive surfaces one-sided promotion edges
# as findings (an entry whose library_refs name an article that lacks the
# originating_plan back-stamp, or vice versa) — DETECT + report, never repair-write.
#
# FARM RETIRED (operator-ruled): the former research/<plan-slug>/ dir-symlink
# farm beside the index is RETIRED — it duplicated every _research/ tree under a
# second path with no consumer (agent navigation resolves canonical paths from
# the index rows; the vault viewer deliberately never indexed it). A TRANSITIONAL
# prune-on-regen arm removes a leftover farm on sight: when <binder>/research/
# exists, every SYMLINK entry inside it is unlinked (the LINK only — never
# through a target) and the dir is removed once empty. A NON-symlink entry is a
# stray placed in a binder interior: detect + report, never delete, and the dir
# is left in place until the stray is re-homed. A leftover farm is pruned from
# every spoke binder on any regen: the prune runs once, after the render loop,
# over every _projects/*/research, whatever --spoke names, and a render failure
# on the target spoke does not skip it.
#
# RULED VIEWER CONTRACT (operator-ruled):
#   - Vault-viewer (Obsidian) navigation is carried by the research-index rows'
#     CANONICAL links — the rows carry resolving links for EVERY declared home
#     (decisions/, target-state/, deliverables/ included), so a decisions-only
#     plan is fully navigable through its rows.
#   - No file is ever duplicated into the binder; the index is the ONE
#     projection of a plan's declared artifacts (a second filesystem alias of
#     _research/ is a duplicate hit-plane, not a convenience).
#   - The viewer ignore-filter configuration is an OPERATOR-side step, never
#     executed by this capability.
#
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/research-index.md   (atomic temp+os.replace;
#         full-file regenerate — this is a generated roll-up surface, no
#         survivorship region).
#     - TRANSITIONAL REMOVAL: {PLANS_ROOT}/_projects/*/research/ — a leftover
#         retired farm dir is pruned from every spoke binder on any regen (symlink
#         entries unlinked — the link only, never the target; dir removed when
#         empty; a non-symlink stray blocks the rmdir and is reported, never
#         deleted).
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: null (no JSON Schema governs the generated binder roll-up markdown;
#     research-index.md is a generated human-readable projection — the row shape is
#     fixed by contract, not a shipped schema). Body-structure authority: the
#     research-index artifact contracts (the ratified
#     binder-contract decision).
#   Pre-write validation:
#     - the plans home must resolve to a directory (absent => block-and-log, no
#       write, exit 0 — defensive class, never crash).
#     - each manifest is read defensively; a malformed/missing field is treated as
#       empty, never an error; a plan with zero matching research_artifacts[]
#       contributes no rows (and an empty spoke renders a valid empty binder).
#     - atomic temp-file + os.replace; the transitional farm prune runs once,
#       after the render loop; a render failure does not skip it.
#   Failure mode: BLOCK-AND-LOG. A manifest that cannot be parsed emits a finding
#     and is skipped; no partial/garbage write. Never write-and-hope.
#   Maintainer-provenance: research-index.md is a
#     librarian-maintained artifact (maintainer=librarian);
#     this capability is its sole originating writer. It NEVER writes
#     decision-log.md, handoff-chronicle.md, plan manifests, or any plan _research/
#     content, and NEVER repairs a one-sided promotion edge (it only detects it).
#
# CLI:
#   plan-research-index.sh                 # regenerate every spoke's binder
#   plan-research-index.sh --spoke <key>   # regenerate one spoke's binder only
#                                          #   (the leftover-farm prune still
#                                          #   reaches every spoke)
#   plan-research-index.sh --dry-run       # findings + would-be writes, NO write
#   plan-research-index.sh --help
#
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24. Read-only manifest
# walk + atomic file write(s) + transitional farm prune.

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
    *) echo "plan-research-index: unknown flag '$1'" >&2; exit 2 ;;
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


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log: the plans home must resolve -----------------------------
if not plans_root or not os.path.isdir(plans_root):
    emit({"finding": "plan-research-index-blocked", "file": plans_root or "(unset)",
          "reason": "plans-home-absent", "detected_at": today})
    print("plan-research-index: plans home absent (%s); nothing to index"
          % (plans_root or "(unset)"), file=sys.stderr)
    sys.exit(0)

PROJECTS = os.path.join(plans_root, "_projects")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


# --- walk every manifest under the plans tree -------------------------------
# Each manifest carries project: (the owning-spoke machine identity),
# parent_plan: (lineage), title: (display). The plan slug is the dir basename.
# A plan's _research/ landing is <plan-dir>/_research/.
def walk_manifests(root):
    found = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not d.startswith(".")]
        # do not descend into the binder home itself
        if os.path.abspath(dp) == os.path.abspath(PROJECTS):
            dns[:] = []
            continue
        if "manifest.json" not in fns:
            continue
        mp = os.path.join(dp, "manifest.json")
        man = read_json(mp)
        if man is None:
            # defensive skip + finding — never crash on a bad manifest.
            emit({"finding": "plan-research-index-blocked", "file": mp,
                  "reason": "manifest-parse-failed", "detected_at": today})
            continue
        # Real-plan shape predicate: keep only real plans. A real plan has a `status` field
        # OR a sibling spec.md; a corpus/synthetic fixture has neither. The single
        # accept clause subsumes the corpus_version/slots reject (those fixtures also
        # lack status+spec.md); if a future corpus_version dir ever declares status,
        # revisit — this clause alone would admit it.
        if not (("status" in man) or os.path.exists(os.path.join(dp, "spec.md"))):
            continue
        found.append((dp, man))
    return found


manifests = walk_manifests(plans_root)


def slug_of(plan_dir):
    return os.path.basename(plan_dir.rstrip("/"))


# originating_plan names its plan by plans-root-relative path (<master>/<sub> for a sub-plan); the bare basename is still accepted.
def qual_of(plan_dir):
    return os.path.relpath(plan_dir.rstrip("/"), plans_root)


def field(man, key, default=""):
    v = man.get(key)
    if v is None:
        return default
    return v


# --- build the cross-manifest library_refs / originating_plan maps for the
# one-sided promotion-edge detection (DETECTOR role). ------------
# manifest side: ref-string -> set(plan-slug) that declares it in research_artifacts[].
manifest_refs = {}
for plan_dir, man in manifests:
    slug = slug_of(plan_dir)
    qual = qual_of(plan_dir)
    ras = man.get("research_artifacts")
    if not isinstance(ras, list):
        continue
    for ra in ras:
        if not isinstance(ra, dict):
            continue
        for lr in (ra.get("library_refs") or []):
            manifest_refs.setdefault(str(lr).strip(), set()).update((slug, qual))


# library side: article -> originating_plan back-stamp (read from the library
# home when it exists; absent library => the back-stamp side is simply empty and
# a manifest entry with library_refs is reported as a one-sided edge).
def collect_article_backstamps(library_root):
    stamps = {}   # "<topic>/<article>" (sans .md) -> originating_plan
    if not library_root or not os.path.isdir(library_root):
        return stamps
    for dp, dns, fns in os.walk(library_root):
        dns[:] = [d for d in dns if not d.startswith(".") and d != "_raw"]
        for f in fns:
            if not f.endswith(".md") or f == "_index.md" or f.startswith("."):
                continue
            p = os.path.join(dp, f)
            try:
                with open(p, encoding="utf-8") as fh:
                    head = fh.read(4096)
            except Exception:
                continue
            m = re.search(r"(?m)^originating_plan:\s*(.+?)\s*$", head)
            op = m.group(1).strip() if m else ""
            rel = os.path.relpath(p, library_root)
            key = rel[:-3] if rel.endswith(".md") else rel
            stamps[key] = op
    return stamps


LIBRARY_ROOT = os.path.join(plans_root, "_library")
article_backstamps = collect_article_backstamps(LIBRARY_ROOT)


# --- selectivity: non-inferable finalized finding => inline; else pointer ----
def distilled_inline(ra, one_liner):
    """selectivity (02:179). Return the distilled finding text to inline
    iff the entry is finalized AND carries a non-inferable distilled-finding field;
    else return None (=> the row emits a path pointer). Operationalization:
      - status must be 'finalized'.
      - an explicit distilled field (finding | distilled | summary) must be present.
      - the distilled text must NOT be inferable from the one-liner: it is inferable
        when (case-folded, whitespace-collapsed) it is a substring of the one-liner
        or the one-liner is a substring of it (the row's other fields already convey
        it). Inferable => pointer.
    Defensive: missing/empty field => None (pointer)."""
    status = str(ra.get("status") or "").strip().lower()
    if status != "finalized":
        return None
    distilled = ""
    for k in ("finding", "distilled", "summary"):
        v = ra.get(k)
        if isinstance(v, str) and v.strip():
            distilled = v.strip()
            break
    if not distilled:
        return None
    norm = lambda s: re.sub(r"\s+", " ", (s or "")).strip().lower()
    nd, nl = norm(distilled), norm(one_liner)
    if nd and nl and (nd in nl or nl in nd):
        return None   # inferable from the one-liner => pointer
    return distilled


def derive_type(ra, path):
    """Row 'type' field. The research_artifacts[] item schema carries an OPTIONAL
    'type' (formalized; a declared type always wins); else infer from the path
    stem, else 'research'. LOCKSTEP: plan-decision-log.sh duplicates this
    function byte-for-byte so both projections resolve the same kind for the
    same artifact — edit them together."""
    t = ra.get("type")
    if isinstance(t, str) and t.strip():
        return t.strip()
    base = os.path.basename(str(path or "")).lower()
    if base.endswith(".md"):
        base = base[:-3]
    for kw, label in (("brief", "ideation-brief"), ("survey", "survey"),
                      ("decision", "decision"), ("verdict", "decision"),
                      ("adr", "adr"),
                      ("synthesis", "synthesis"), ("research", "research")):
        if kw in base:
            return label
    return "research"


# PARTITION (kind-driven projection, operator-ruled): a declared artifact whose
# RESOLVED kind is decision-class belongs to the decision log's projected
# "Decision artifacts" section, not the research index. The index emits
# research-class rows ONLY; the promotion-edge detector still sweeps EVERY
# declared artifact (decision-class included) — the crash-window watch is
# kind-agnostic.
DECISION_KINDS = frozenset(("decision", "adr"))


# --- assemble rows per spoke, grouped by parent_plan lineage ----------------
# spoke -> lineage-group -> [row dicts]
def lineage_of(man, slug):
    pp = str(field(man, "parent_plan") or "").strip()
    return pp if pp else slug   # top-level plan heads its own lineage group


spokes = {}             # spoke -> { lineage -> [rows] }
plan_ra_paths = {}      # plan-slug -> { RA id -> declared path } (superseded forward links)

for plan_dir, man in manifests:
    spoke = str(field(man, "project") or "").strip()
    if not spoke:
        # missing project: => cannot attribute to a spoke; skip silently
        # (missing-field-empty; this is not an error).
        continue
    if spoke_filter and spoke != spoke_filter:
        continue
    slug = slug_of(plan_dir)
    ras = man.get("research_artifacts")
    if not isinstance(ras, list) or not ras:
        continue
    lineage = lineage_of(man, slug)
    spokes.setdefault(spoke, {})
    grp = spokes[spoke].setdefault(lineage, [])
    for ra in ras:
        if not isinstance(ra, dict):
            continue
        path = str(field(ra, "path") or "").strip()
        rtype = derive_type(ra, path)
        status = str(field(ra, "status") or "").strip()
        one_liner = str(field(ra, "title") or "").strip()
        lib_refs = [str(x).strip() for x in (ra.get("library_refs") or []) if str(x).strip()]
        inline = distilled_inline(ra, one_liner)
        ra_id = str(field(ra, "id") or "").strip()
        if ra_id and path:
            plan_ra_paths.setdefault(slug, {})[ra_id] = path
        row = {
            "plan_slug": slug, "path": path, "type": rtype, "status": status,
            "one_liner": one_liner, "library_refs": lib_refs, "inline": inline,
            "plan_dir": plan_dir, "ra_id": ra_id,
            "superseded_by": str(field(ra, "superseded_by") or "").strip(),
        }
        # PARTITION: decision-class rows are the decision log's projection —
        # never emitted here. The detector below still runs for them.
        if rtype not in DECISION_KINDS:
            grp.append(row)

        # --- one-sided promotion-edge DETECTOR (detect + report only) ----
        for lr in lib_refs:
            ref = lr[:-3] if lr.endswith(".md") else lr
            back = article_backstamps.get(ref)
            if back is None:
                emit({"finding": "research-index-one-sided-edge", "file": ref,
                      "issue": "manifest-library_ref-without-article-backstamp",
                      "plan": slug, "library_ref": lr,
                      "detector_role": "promotion-edge-crash-window",
                      "detected_at": today})
            elif back and back not in (slug, qual_of(plan_dir)):
                emit({"finding": "research-index-one-sided-edge", "file": ref,
                      "issue": "article-backstamp-disagrees-with-manifest",
                      "plan": slug, "library_ref": lr, "article_originating_plan": back,
                      "detector_role": "promotion-edge-crash-window",
                      "detected_at": today})

# the reverse one-sided edge: an article names an originating_plan whose manifest
# does NOT carry the matching library_ref back.
for ref, op in article_backstamps.items():
    if not op:
        continue
    decls = manifest_refs.get(ref) or manifest_refs.get(ref + ".md") or set()
    if op not in decls:
        emit({"finding": "research-index-one-sided-edge", "file": ref,
              "issue": "article-originating_plan-without-manifest-library_ref",
              "originating_plan": op,
              "manifest_backlinks": ",".join(sorted(decls)) or "(none)",
              "detector_role": "promotion-edge-crash-window",
              "detected_at": today})


# --- render one binder per spoke --------------------------------------------
def md_link(text, target):
    # deterministic relative-path link (binder roll-up class).
    return "[%s](%s)" % (text, target)


def render_library_cell(lib_refs):
    if not lib_refs:
        return "—"
    # wikilink form is NOT used for binder roll-ups; emit the bare
    # <topic>/<article> ref text (the article lives in the library, linked there).
    return ", ".join(lib_refs)


def resolve_pcell(path, plan, plan_dir, binder_home):
    # CANONICAL-ROUTE-ONLY emission (the ruled viewer contract — header block
    # above): EVERY Path cell links binder-relative straight to the plan file,
    # the _research/ home included. A farm-shaped route (research/<plan-slug>/…)
    # is NEVER emitted — the farm is retired, and even while it existed a
    # farm-routed link resolved only through a viewer-excluded subtree, dying
    # for the human while the canonical route resolves for both the filesystem
    # and the viewer. Links derive only from the manifest's DECLARED path, so a
    # later move that repoints the declaration keeps the row resolving with no
    # renderer change.
    if not path or path == "—":
        return "—"
    if plan_dir:
        target = os.path.normpath(os.path.join(plan_dir, path))
        return md_link(path, os.path.relpath(target, binder_home))
    # defensive degenerate — UNREACHABLE from this capability's entry points
    # (every rendered row is built FROM its plan_dir at the manifest walk): emit
    # the declared path as plain text rather than fabricating a route. The
    # retired legacy farm-route fallback is gone; its input population (non-farm
    # research/ dirs) is permanently empty in the corpus.
    return path


def status_cell(row, binder_home):
    # Block 2 forward link: a superseded row points at the row of its superseded_by
    # entry in the same plan (RA ids are per plan); an undeclared target stays text.
    status = row["status"] or "—"
    if status.lower() != "superseded" or not row["superseded_by"]:
        return status
    sb = row["superseded_by"]
    target = plan_ra_paths.get(row["plan_slug"], {}).get(sb)
    if target and row.get("plan_dir"):
        dest = os.path.normpath(os.path.join(row["plan_dir"], target))
        return "%s → %s" % (status, md_link(sb, os.path.relpath(dest, binder_home)))
    return "%s → %s" % (status, sb)


def render_row(row, binder_home):
    path = row["path"] or "—"
    plan = row["plan_slug"]
    pcell = resolve_pcell(row["path"], plan, row.get("plan_dir", ""), binder_home)
    one = row["one_liner"] or "—"
    cells = [
        pcell,
        row["type"] or "—",
        status_cell(row, binder_home),
        plan,
        one.replace("|", "\\|"),
        render_library_cell(row["library_refs"]).replace("|", "\\|"),
    ]
    return "| " + " | ".join(cells) + " |"


def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._research-index.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)


HDR = "| Path | Type | Status | Plan-origin | One-liner | Library |"
SEP = "|---|---|---|---|---|---|"

# The plan's declare discovery set, walked as plan-research-declare walks it: these
# homes, dot-dirs pruned, dot- and underscore-prefixed files skipped, `.md` only.
DISCOVERY_DIRS = ["_research", "decisions", "target-state", "deliverables"]


def discovery_set(plan_dir):
    found = set()
    for base in DISCOVERY_DIRS:
        root = os.path.join(plan_dir, base)
        if not os.path.isdir(root):
            continue
        for dp, dns, fns in os.walk(root):
            dns[:] = sorted(d for d in dns if not d.startswith("."))
            for f in fns:
                if f.endswith(".md") and not f.startswith(".") and not f.startswith("_"):
                    found.add(os.path.normpath(os.path.relpath(os.path.join(dp, f), plan_dir)))
    return found


def plan_blocks(rows):
    """The four-block order for one plan's research-class rows: canonical, superseded,
    the rest (non-deferred, outside _research/). Deferred rows render nowhere."""
    key = lambda r: (r["path"], r["one_liner"])
    canon, sup, rest = [], [], []
    for r in rows:
        st = r["status"].lower()
        if st == "deferred":
            continue
        if st == "superseded":
            sup.append(r)
        elif os.path.normpath(r["path"] or ".").startswith("_research" + os.sep):
            canon.append(r)
        else:
            rest.append(r)
    return sorted(canon, key=key) + sorted(sup, key=key) + sorted(rest, key=key)

spokes_written = 0
links_pruned = 0

# When a --spoke filter names a spoke with no contributing plans, still render an
# empty binder for it (idempotent empty surface).
target_spokes = sorted(spokes.keys())
if spoke_filter and spoke_filter not in spokes:
    target_spokes = [spoke_filter] if not target_spokes else sorted(set(target_spokes) | {spoke_filter})

for spoke in target_spokes:
    lineages = spokes.get(spoke, {})
    binder_home = os.path.join(PROJECTS, spoke)
    research_idx = os.path.join(binder_home, "research-index.md")

    # tags item-pattern: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$
    tag_spoke = re.sub(r"[^a-z0-9-]", "-", spoke.lower()).strip("-") or "spoke"

    body_lines = [
        "---",
        "type: index",
        'tags: ["#project/%s"]' % tag_spoke,
        "updated: %s" % today,
        "parent_folder: _projects",
        "---",
        "",
        "# %s — Research Index" % spoke,
        "",
        "_Auto-generated by `librarian plan-research-index`. Do not hand-edit._",
        "",
        "Project-wide research surface: one row per declared "
        "`research_artifacts[]` entry of RESEARCH class across every `%s`-spoke "
        "plan, grouped by `parent_plan` lineage. Decision-class artifacts "
        "(resolved kind `decision`/`adr`) are projected on the decision log "
        "instead. Each plan's table lists its canonical `_research/` rows first, "
        "then superseded rows (forward-linked to their replacement), then its "
        "other declared homes; a count line after the table covers the research "
        "files with no row (deferred, decision-class or undeclared). Inline `> ` "
        "finding bodies appear only for non-inferable finalized findings; all "
        "other rows point at the artifact." % spoke,
        "",
    ]

    total_rows = 0
    for lineage in sorted(lineages.keys()):
        by_plan = {}
        for r in lineages[lineage]:
            by_plan.setdefault(r["plan_slug"], []).append(r)
        plans = [(p, plan_blocks(by_plan[p])) for p in sorted(by_plan)]
        plans = [(p, rows) for p, rows in plans if rows]
        if not plans:
            continue
        body_lines.append("## Lineage: %s" % lineage)
        body_lines.append("")
        for plan, ordered in plans:
            body_lines.append(HDR)
            body_lines.append(SEP)
            inlines = []
            for row in ordered:
                body_lines.append(render_row(row, binder_home))
                total_rows += 1
                if row["inline"] is not None:
                    inlines.append(row)
            body_lines.append("")
            # non-inferable finalized findings: a `> ` distilled blockquote per row,
            # keyed to the artifact path, AFTER the plan's table (the table cells stay
            # well-formed; the inline body is the copied finding, not a pointer).
            for row in inlines:
                distilled = re.sub(r"\s+", " ", row["inline"]).strip()
                anchor = row["path"] or row["one_liner"] or "(artifact)"
                body_lines.append("**%s** — finalized finding:" % anchor)
                body_lines.append("> %s" % distilled)
                body_lines.append("")
            # block 4: the count line.
            shown = set(os.path.normpath(r["path"]) for r in ordered if r["path"])
            unshown = len(discovery_set(ordered[0]["plan_dir"]) - shown)
            body_lines.append("_%s: %d research file%s with no row (deferred, "
                              "decision-class or undeclared)._"
                              % (plan, unshown, "" if unshown == 1 else "s"))
            body_lines.append("")

    if total_rows == 0:
        body_lines.append("_No declared research artifacts in this spoke yet._")
        body_lines.append("")

    content = "\n".join(body_lines).rstrip() + "\n"

    if not dry_run:
        try:
            os.makedirs(binder_home, exist_ok=True)
        except Exception as exc:
            emit({"finding": "plan-research-index-blocked", "file": binder_home,
                  "reason": "mkdir-failed", "error": str(exc), "detected_at": today})
            continue
        try:
            write_atomic(binder_home, research_idx, content)
        except Exception as exc:
            emit({"finding": "plan-research-index-blocked", "file": research_idx,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            continue
    spokes_written += 1


# --- TRANSITIONAL farm prune (retirement clean-up) ----------------------------
# The research/<plan-slug>/ dir-symlink farm is RETIRED (header block above).
# A leftover farm dir from a pre-retirement regen is pruned on sight: unlink
# every SYMLINK entry (the LINK only — NEVER follow or delete through a
# target), then remove the dir once empty. A NON-symlink entry is a stray
# placed in a binder interior — detect + report, never delete; the dir stays
# until the stray is re-homed. Returns the count of links unlinked (or, under
# --dry-run, that would be).
def prune_farm(spoke, farm_home):
    pruned = 0
    if os.path.islink(farm_home):
        # degenerate: the farm name itself is a symlink — remove the link only.
        if dry_run:
            return 1
        try:
            os.unlink(farm_home)
            pruned += 1
        except Exception as exc:
            emit({"finding": "plan-research-index-blocked", "file": farm_home,
                  "reason": "farm-prune-failed", "error": str(exc),
                  "detected_at": today})
        return pruned
    if not os.path.isdir(farm_home):
        return 0
    try:
        existing = sorted(os.listdir(farm_home))
    except Exception:
        existing = []
    strays = 0
    for name in existing:
        link = os.path.join(farm_home, name)
        if not os.path.islink(link):
            strays += 1
            emit({"finding": "farm-stray-regular-entry", "file": link,
                  "spoke": spoke, "name": name,
                  "reason": "non-symlink entry inside the retired research/ "
                            "farm dir (a stray placed in a binder interior); "
                            "re-home to its owning plan — never auto-deleted",
                  "detected_at": today})
            continue
        if dry_run:
            pruned += 1
        else:
            try:
                os.unlink(link)   # unlink the LINK; target untouched.
                pruned += 1
            except Exception as exc:
                emit({"finding": "plan-research-index-blocked", "file": link,
                      "reason": "farm-prune-failed", "error": str(exc),
                      "detected_at": today})
    if not dry_run and strays == 0:
        try:
            os.rmdir(farm_home)   # empty after the unlinks; rmdir never recurses.
        except OSError:
            pass   # non-empty (unlink failure) — left for the next regen.
    return pruned


# One pass after the render loop, over EVERY spoke binder, whatever --spoke
# named: the farm is pruned from every spoke binder on any regen, and a render
# failure on the target spoke (its `continue` above) does not skip it.
try:
    binder_names = sorted(os.listdir(PROJECTS))
except Exception:
    binder_names = []
for spoke in binder_names:
    binder_home = os.path.join(PROJECTS, spoke)
    if os.path.isdir(binder_home):
        links_pruned += prune_farm(spoke, os.path.join(binder_home, "research"))

print("plan-research-index: spokes=%d rows-source-manifests=%d "
      "links_pruned=%d dry_run=%s"
      % (spokes_written, len(manifests), links_pruned, dry_run),
      file=sys.stderr)
PY

#!/bin/bash
# plan-research-index — generate the per-spoke binder research surface:
# <plans-root>/_projects/<spoke>/research-index.md plus the
# research/<plan-slug>/ dir-symlink farm, re-derived from every plan
# manifest's research_artifacts[] on every run; it also
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
# research_artifacts[] entry (declaration is the selectivity gate — undeclared
# artifacts never earn a row).
#
# row schema: path / type / status (active|finalized|deferred) /
# plan-origin / one-liner, PLUS a Library column populated from the entry's
# library_refs[].
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
# symlink farm: under the spoke binder home, research/<plan-slug>/ is a
# DIRECTORY symlink -> each contributing plan's <plan>/_research/ dir. Generated
# AND pruned each run: a farm symlink whose target plan/_research no longer exists
# (or whose plan no longer belongs to the spoke) is removed. NEVER follows or
# deletes through a symlink target — only the farm link itself is unlinked.
#
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/research-index.md   (atomic temp+os.replace;
#         full-file regenerate — this is a generated roll-up surface, no
#         survivorship region).
#     - {PLANS_ROOT}/_projects/<spoke>/research/<plan-slug>/  dir-symlinks
#         (created/pruned; the link itself only — targets untouched).
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
#     - atomic temp-file + os.replace; the symlink farm is reconciled (create the
#       missing, prune the stale) only after the index renders.
#   Failure mode: BLOCK-AND-LOG. A manifest that cannot be parsed emits a finding
#     and is skipped; no partial/garbage write. Never write-and-hope.
#   Maintainer-provenance: research-index.md + the research/ farm are
#     librarian-maintained artifacts (maintainer=librarian);
#     this capability is their sole originating writer. It NEVER writes
#     decision-log.md, handoff-chronicle.md, plan manifests, or any plan _research/
#     content, and NEVER repairs a one-sided promotion edge (it only detects it).
#
# CLI:
#   plan-research-index.sh                 # regenerate every spoke's binder
#   plan-research-index.sh --spoke <key>   # regenerate one spoke's binder only
#   plan-research-index.sh --dry-run       # findings + would-be writes, NO write
#   plan-research-index.sh --help
#
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24. Read-only manifest
# walk + atomic file write(s) + symlink-farm reconcile.

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
        # /(): keep only real plans. A real plan has a `status` field
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
    ras = man.get("research_artifacts")
    if not isinstance(ras, list):
        continue
    for ra in ras:
        if not isinstance(ra, dict):
            continue
        for lr in (ra.get("library_refs") or []):
            manifest_refs.setdefault(str(lr).strip(), set()).add(slug)


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
    """Row 'type' field. The shipped research_artifacts[] item has no required
    'type', but additionalProperties:true permits one; prefer an explicit type,
    else infer from the path stem, else 'research'."""
    t = ra.get("type")
    if isinstance(t, str) and t.strip():
        return t.strip()
    base = os.path.basename(str(path or "")).lower()
    if base.endswith(".md"):
        base = base[:-3]
    for kw, label in (("brief", "ideation-brief"), ("survey", "survey"),
                      ("decision", "decision"), ("adr", "adr"),
                      ("synthesis", "synthesis"), ("research", "research")):
        if kw in base:
            return label
    return "research"


# --- assemble rows per spoke, grouped by parent_plan lineage ----------------
# spoke -> lineage-group -> [row dicts]
def lineage_of(man, slug):
    pp = str(field(man, "parent_plan") or "").strip()
    return pp if pp else slug   # top-level plan heads its own lineage group


spokes = {}             # spoke -> { lineage -> [rows] }
spoke_plan_dirs = {}    # spoke -> { plan-slug -> plan_dir } (for the symlink farm)

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
    spoke_plan_dirs.setdefault(spoke, {})
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
        row = {
            "plan_slug": slug, "path": path, "type": rtype, "status": status,
            "one_liner": one_liner, "library_refs": lib_refs, "inline": inline,
            "plan_dir": plan_dir,
        }
        grp.append(row)
        # this plan contributes to the symlink farm (it declares artifacts)
        spoke_plan_dirs[spoke][slug] = plan_dir

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
            elif back and back != slug:
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
    # Resolving Path link by DECLARED home. A path under the plan's _research/ home is
    # reachable through the research/<plan-slug>/ dir-symlink farm (which mirrors
    # <plan>/_research/), so it keeps that farm route with the FULL remainder after
    # _research/ — the whole remainder, not just the basename, so a nested subdir path
    # resolves. Any OTHER declared home (decisions/, target-state/ incl. canonical/,
    # deliverables/, a legacy research/ dir, a plan-root file, a depth-2 sub-plan) is
    # not mirrored by the farm, so it links by a binder-home-relative path straight to
    # the plan file. Links derive only from the manifest's DECLARED path, so a later
    # move that repoints the declaration keeps the row resolving with no renderer change.
    if not path or path == "—":
        return "—"
    if path == "_research" or path.startswith("_research/"):
        remainder = path[len("_research/"):] if path.startswith("_research/") else ""
        return md_link(path, "./research/%s/%s" % (plan, remainder))
    if plan_dir:
        target = os.path.normpath(os.path.join(plan_dir, path))
        return md_link(path, os.path.relpath(target, binder_home))
    # defensive: no plan dir known => keep the legacy farm route with the basename.
    return md_link(path, "./research/%s/%s" % (plan, os.path.basename(path)))


def render_row(row, binder_home):
    path = row["path"] or "—"
    plan = row["plan_slug"]
    pcell = resolve_pcell(row["path"], plan, row.get("plan_dir", ""), binder_home)
    one = row["one_liner"] or "—"
    cells = [
        pcell,
        row["type"] or "—",
        row["status"] or "—",
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

spokes_written = 0
links_created = 0
links_pruned = 0

# When a --spoke filter names a spoke with no contributing plans, still render an
# empty binder for it (idempotent empty surface), so the farm prunes correctly.
target_spokes = sorted(spokes.keys())
if spoke_filter and spoke_filter not in spokes:
    target_spokes = [spoke_filter] if not target_spokes else sorted(set(target_spokes) | {spoke_filter})

for spoke in target_spokes:
    lineages = spokes.get(spoke, {})
    binder_home = os.path.join(PROJECTS, spoke)
    research_idx = os.path.join(binder_home, "research-index.md")
    farm_home = os.path.join(binder_home, "research")

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
        "`research_artifacts[]` entry across every `%s`-spoke plan, grouped by "
        "`parent_plan` lineage. Inline `> ` finding bodies appear only for "
        "non-inferable finalized findings; all other rows point at the artifact." % spoke,
        "",
    ]

    total_rows = 0
    for lineage in sorted(lineages.keys()):
        rows = lineages[lineage]
        if not rows:
            continue
        body_lines.append("## Lineage: %s" % lineage)
        body_lines.append("")
        body_lines.append(HDR)
        body_lines.append(SEP)
        # stable row order: by plan-slug then path
        ordered = sorted(rows, key=lambda r: (r["plan_slug"], r["path"], r["one_liner"]))
        inlines = []
        for row in ordered:
            body_lines.append(render_row(row, binder_home))
            total_rows += 1
            if row["inline"] is not None:
                inlines.append(row)
        body_lines.append("")
        # non-inferable finalized findings: a `> ` distilled blockquote per row,
        # keyed to the artifact path, AFTER the lineage table (the table cells stay
        # well-formed; the inline body is the copied finding, not a pointer).
        for row in inlines:
            distilled = re.sub(r"\s+", " ", row["inline"]).strip()
            anchor = row["path"] or row["one_liner"] or "(artifact)"
            body_lines.append("**%s** — finalized finding:" % anchor)
            body_lines.append("> %s" % distilled)
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

    # --- dir-symlink farm: generate + prune --------------------------
    # Targets: each contributing plan's <plan>/_research/ dir. Generate the
    # missing; prune the stale (a farm link whose target plan/_research no longer
    # exists, or whose plan no longer contributes to this spoke). NEVER follow or
    # delete THROUGH a target — only os.unlink the farm symlink itself.
    want = {}   # plan-slug -> absolute target _research dir
    for slug, plan_dir in spoke_plan_dirs.get(spoke, {}).items():
        rdir = os.path.join(plan_dir, "_research")
        want[slug] = rdir

    if not dry_run:
        try:
            os.makedirs(farm_home, exist_ok=True)
        except Exception as exc:
            emit({"finding": "plan-research-index-blocked", "file": farm_home,
                  "reason": "farm-mkdir-failed", "error": str(exc), "detected_at": today})
            want = {}

    # prune: anything in the farm that is a symlink and is not wanted (or whose
    # target no longer resolves to an existing dir) is removed (the LINK only).
    if os.path.isdir(farm_home):
        try:
            existing = os.listdir(farm_home)
        except Exception:
            existing = []
        for name in existing:
            link = os.path.join(farm_home, name)
            if not os.path.islink(link):
                # a real dir/file in the farm is NOT ours — never delete it. It is a
                # stray placed inside the binder symlink farm: detect + report so a
                # sweep can re-home it, but NEVER clobber/remove a non-symlink entry
                # (the never-clobber posture; removal is not the generator's job).
                emit({"finding": "farm-stray-regular-entry", "file": link,
                      "spoke": spoke, "name": name,
                      "reason": "non-symlink entry inside the research/ symlink farm "
                                "(a stray placed in a binder interior); re-home to its "
                                "owning plan — never auto-deleted",
                      "detected_at": today})
                continue
            target = want.get(name)
            stale = (name not in want) or (target is not None and not os.path.isdir(target))
            if stale:
                if dry_run:
                    links_pruned += 1
                else:
                    try:
                        os.unlink(link)   # unlink the LINK; target untouched.
                        links_pruned += 1
                    except Exception as exc:
                        emit({"finding": "plan-research-index-blocked", "file": link,
                              "reason": "farm-prune-failed", "error": str(exc),
                              "detected_at": today})

    # generate: create the wanted links whose target dir exists.
    for slug, target in sorted(want.items()):
        if not os.path.isdir(target):
            # the plan declares artifacts but has no _research/ dir yet; no link.
            continue
        link = os.path.join(farm_home, slug)
        if os.path.islink(link):
            # already present; refresh only if it points elsewhere.
            try:
                cur = os.readlink(link)
            except Exception:
                cur = ""
            if os.path.abspath(os.path.join(farm_home, cur)) == os.path.abspath(target):
                continue
            if not dry_run:
                try:
                    os.unlink(link)
                except Exception:
                    pass
        elif os.path.exists(link):
            # a real path squats the name — never clobber it; report and skip.
            emit({"finding": "plan-research-index-blocked", "file": link,
                  "reason": "farm-name-occupied-by-real-path", "detected_at": today})
            continue
        if dry_run:
            links_created += 1
        else:
            try:
                os.symlink(target, link)
                links_created += 1
            except Exception as exc:
                emit({"finding": "plan-research-index-blocked", "file": link,
                      "reason": "farm-symlink-failed", "error": str(exc),
                      "detected_at": today})

print("plan-research-index: spokes=%d rows-source-manifests=%d links_created=%d "
      "links_pruned=%d dry_run=%s"
      % (spokes_written, len(manifests), links_created, links_pruned, dry_run),
      file=sys.stderr)
PY

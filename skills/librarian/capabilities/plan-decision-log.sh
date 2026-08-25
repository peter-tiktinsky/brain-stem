#!/bin/bash
# plan-decision-log — generate the per-spoke binder decision surface:
# <plans-root>/_projects/<spoke>/decision-log.md — the
# decision_records[] projection across every plan launched from the spoke,
# re-derived from each plan manifest on every run.
# Distinct from the shipped handoff-disposition-check.sh (a close-out chronicle
# checker, NOT a binder generator).
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as a line reference in comments; no Draft202012Validator is constructed, so there is no schema-gate degrade path.
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
# decision_records[] entry — this is a PURE projection (declaration is the only
# gate; no symlink farm, no inline-vs-pointer selectivity — those belong to the
# research-index surface, not the decision log).
#
# row schema: ADR id (ADR-NN) / title / status
# (proposed|accepted|rejected|deprecated|superseded) / path; plus optional
# superseded_by and created columns when present. ADR BODIES, rationale, and
# option-tables STAY at the path — the projection never copies them inline.
#
# Append-immutability (TRANSCRIBED from the binding contract, verbatim clause
# "Superseded records are forward-linked, never deleted"): the append-immutable
# semantic the contract mandates is scoped to the SUPERSEDED lifecycle STATUS — a
# record whose status == superseded is FORWARD-LINKED via its superseded_by ADR
# ordinal and is NEVER filtered/dropped from the projection (it persists in the
# log, pointing forward at the ADR that replaced it). The contract speaks ONLY to
# the superseded status; it does NOT mandate caching records that vanish from a
# source manifest (that crash-window/divergence class is a separate concern, owned
# by the research-index detector, not the decision log). This is a re-derive-from-
# frontmatter projection: every decision_records[] entry present in a contributing
# manifest is projected; a superseded entry is rendered with its forward-link and
# is never suppressed, ordered/rejected/deprecated/proposed/accepted alike. When a
# superseded record's superseded_by target ADR is itself present in the same
# spoke's projection, the forward-link is cross-referenced to that row.
#
# Re-derive from manifests every run; missing/empty decision_records[] = EMPTY
# section, never an error (defensive default; legacy manifests carry no
# field). A malformed manifest emits a finding and is skipped — block-and-log.
#
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/decision-log.md   (atomic temp+os.replace;
#         full-file regenerate — this is a generated roll-up surface, no
#         survivorship region; the append-immutability is a CONTENT property
#         — superseded rows are never dropped — not a partial-append mechanism).
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: null (no JSON Schema governs the generated binder roll-up markdown;
#     decision-log.md is a generated human-readable projection — the row shape is
#     fixed by that contract, the SOURCE field by the SHIPPED decision_records[] at
#     schemas/plan-manifest-schema.json:723, status enum :744-753). Body-structure
#     authority: the decision-log artifact contract (the ratified
#     binder-contract decision).
#   Pre-write validation:
#     - the plans home must resolve to a directory (absent => block-and-log, no
#       write, exit 0 — defensive class, never crash).
#     - each manifest is read defensively; a malformed/missing decision_records[]
#       is treated as empty, never an error; a plan with zero records contributes
#       no rows (and an empty spoke renders a valid empty decision log).
#     - atomic temp-file + os.replace.
#   Failure mode: BLOCK-AND-LOG. A manifest that cannot be parsed emits a finding
#     and is skipped; no partial/garbage write. Never write-and-hope.
#   Maintainer-provenance: decision-log.md is a librarian-maintained
#     artifact (maintainer=librarian); this capability is its sole
#     originating writer. It NEVER writes research-index.md,
#     handoff-chronicle.md, the research/ symlink farm, plan manifests, or any
#     plan _research/ / decisions/ content. It reads decision_records[] and writes
#     ONLY decision-log.md.
#
# CLI:
#   plan-decision-log.sh                 # regenerate every spoke's decision log
#   plan-decision-log.sh --spoke <key>   # regenerate one spoke's log only
#   plan-decision-log.sh --dry-run       # findings + would-be writes, NO write
#   plan-decision-log.sh --help
#
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24. Read-only manifest
# walk + atomic file write(s).

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
    *) echo "plan-decision-log: unknown flag '$1'" >&2; exit 2 ;;
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
    emit({"finding": "plan-decision-log-blocked", "file": plans_root or "(unset)",
          "reason": "plans-home-absent", "detected_at": today})
    print("plan-decision-log: plans home absent (%s); nothing to log"
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
            emit({"finding": "plan-decision-log-blocked", "file": mp,
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


# --- assemble rows per spoke, grouped by parent_plan lineage ----------------
# spoke -> lineage-group -> [row dicts], one row per decision_records[] entry.
def lineage_of(man, slug):
    pp = str(field(man, "parent_plan") or "").strip()
    return pp if pp else slug   # top-level plan heads its own lineage group


# Valid ADR lifecycle tokens per the SHIPPED schema status enum
# (plan-manifest-schema.json:744-753). An out-of-enum status is rendered as-is
# (defensive: never crash) but flagged.
STATUS_ENUM = {"proposed", "accepted", "rejected", "deprecated", "superseded"}

spokes = {}             # spoke -> { lineage -> [rows] }
# ADR ordinals restart PER PLAN, so a forward-link ✓ qualifies against the ADR
# ids of the row's OWN plan only — never a spoke-global union (a cross-plan
# same-numbered ADR must not false-match). spoke -> { plan_slug -> set(adr ids) }.
spoke_adr_ids = {}

for plan_dir, man in manifests:
    spoke = str(field(man, "project") or "").strip()
    if not spoke:
        # missing project: => cannot attribute to a spoke; skip silently
        # (missing-field-empty; this is not an error).
        continue
    if spoke_filter and spoke != spoke_filter:
        continue
    slug = slug_of(plan_dir)
    drs = man.get("decision_records")
    # defensive default: missing/empty/malformed => EMPTY, never error.
    if not isinstance(drs, list) or not drs:
        continue
    lineage = lineage_of(man, slug)
    spokes.setdefault(spoke, {})
    spoke_adr_ids.setdefault(spoke, {})
    grp = spokes[spoke].setdefault(lineage, [])
    for dr in drs:
        if not isinstance(dr, dict):
            continue
        adr_id = str(field(dr, "id") or "").strip()
        title = str(field(dr, "title") or "").strip()
        status = str(field(dr, "status") or "").strip()
        path = str(field(dr, "path") or "").strip()
        # superseded_by is optional (null/absent except when status==superseded).
        sb = field(dr, "superseded_by")
        superseded_by = str(sb).strip() if isinstance(sb, str) and sb.strip() else ""
        created = str(field(dr, "created") or "").strip()
        row = {
            "plan_slug": slug, "id": adr_id, "title": title, "status": status,
            "path": path, "superseded_by": superseded_by, "created": created,
            "plan_dir": plan_dir,
        }
        grp.append(row)
        if adr_id:
            # key by the owning plan_slug: the ✓ qualifies same-plan only.
            spoke_adr_ids[spoke].setdefault(slug, set()).add(adr_id)

        # append-immutability is a CONTENT property of the SUPERSEDED
        # status: never drop a superseded record; it MUST carry a forward-link.
        # A superseded record missing its superseded_by forward-link is a contract
        # gap — flag it (the record still renders; it is never suppressed).
        if status.lower() == "superseded" and not superseded_by:
            emit({"finding": "decision-log-superseded-without-forward-link",
                  "file": path or adr_id or "(unknown)", "plan": slug,
                  "adr": adr_id, "detail": "status=superseded but superseded_by absent",
                  "detected_at": today})
        # an out-of-enum status is rendered defensively but surfaced.
        if status and status.lower() not in STATUS_ENUM:
            emit({"finding": "decision-log-status-out-of-enum",
                  "file": path or adr_id or "(unknown)", "plan": slug,
                  "adr": adr_id, "status": status, "detected_at": today})


# --- render one decision log per spoke --------------------------------------
def md_link(text, target):
    # deterministic relative-path link (binder roll-up class — generated
    # roll-up rows use relative-path markdown links, never wikilinks). The
    # target must already be rebased to resolve FROM the binder file's own
    # directory (_projects/<spoke>/) — the caller owns that arithmetic; a
    # plan-relative path passed through raw is a dead link from the binder home.
    return "[%s](%s)" % (text, target)


def esc(cell):
    return (cell or "").replace("|", "\\|")


def render_row(row, plan_adr_ids):
    adr = row["id"] or "—"
    title = esc(row["title"]) or "—"
    status = row["status"] or "—"
    # the ADR body STAYS at the path; the row links to it, never copies.
    # The declared path is plan-relative (or absolute — join() passes it through),
    # but this log is written to _projects/<spoke>/ — rebase the href against
    # binder_home the way plan-research-index and plan-handoff-index do, keeping
    # the DECLARED path as the visible text.
    path = row["path"]
    if path:
        target = os.path.normpath(os.path.join(row["plan_dir"], path))
        pcell = md_link(path, os.path.relpath(target, binder_home))
    else:
        pcell = "—"
    # forward-link: a superseded record points forward at the ADR that
    # replaced it; cross-reference to the in-projection row when present. The ✓
    # qualifies against the ADR ids of the row's OWN plan only (ADR ordinals
    # restart per plan) — a cross-plan same-numbered ADR is not a match.
    sb = row["superseded_by"]
    own_plan_ids = plan_adr_ids.get(row["plan_slug"], set())
    if sb:
        sbcell = "%s ✓" % sb if sb in own_plan_ids else sb
    else:
        sbcell = "—"
    created = row["created"] or "—"
    plan = row["plan_slug"]
    cells = [adr, title, status, pcell, sbcell, created, plan]
    return "| " + " | ".join(cells) + " |"


def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._decision-log.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)


HDR = "| ADR | Title | Status | Path | Superseded-by | Created | Plan-origin |"
SEP = "|---|---|---|---|---|---|---|"

spokes_written = 0

# When a --spoke filter names a spoke with no contributing plans, still render an
# empty decision log for it (idempotent empty surface).
target_spokes = sorted(spokes.keys())
if spoke_filter and spoke_filter not in spokes:
    target_spokes = [spoke_filter] if not target_spokes else sorted(set(target_spokes) | {spoke_filter})

for spoke in target_spokes:
    lineages = spokes.get(spoke, {})
    # per-plan ADR-id map for this spoke: { plan_slug -> set(adr ids) }.
    plan_adr_ids = spoke_adr_ids.get(spoke, {})
    binder_home = os.path.join(PROJECTS, spoke)
    decision_log = os.path.join(binder_home, "decision-log.md")

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
        "# %s — Decision Log" % spoke,
        "",
        "_Auto-generated by `librarian plan-decision-log`. Do not hand-edit._",
        "",
        "Append-immutable cross-plan ADR roll-up: one row per declared "
        "`decision_records[]` entry across every `%s`-spoke plan, grouped by "
        "`parent_plan` lineage. ADR bodies, rationale, and option-tables stay at "
        "the linked path. Superseded records are forward-linked (Superseded-by), "
        "never deleted from the projection." % spoke,
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
        # stable row order: by plan-slug then ADR id then path.
        ordered = sorted(rows, key=lambda r: (r["plan_slug"], r["id"], r["path"]))
        for row in ordered:
            body_lines.append(render_row(row, plan_adr_ids))
            total_rows += 1
        body_lines.append("")

    if total_rows == 0:
        body_lines.append("_No declared decision records in this spoke yet._")
        body_lines.append("")

    content = "\n".join(body_lines).rstrip() + "\n"

    if not dry_run:
        try:
            os.makedirs(binder_home, exist_ok=True)
        except Exception as exc:
            emit({"finding": "plan-decision-log-blocked", "file": binder_home,
                  "reason": "mkdir-failed", "error": str(exc), "detected_at": today})
            continue
        try:
            write_atomic(binder_home, decision_log, content)
        except Exception as exc:
            emit({"finding": "plan-decision-log-blocked", "file": decision_log,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            continue
    spokes_written += 1

print("plan-decision-log: spokes=%d source-manifests=%d dry_run=%s"
      % (spokes_written, len(manifests), dry_run), file=sys.stderr)
PY

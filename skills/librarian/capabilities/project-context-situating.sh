#!/bin/bash
# project-context-situating — generate the per-spoke GENERATED situating card:
# <plans-root>/_projects/<spoke>/_situating.md — the eager, force-ingested binder
# surface that lets a session self-orient the instant it opens in a spoke. This is
# NOT hub.md: hub.md is template-scaffolded-then-curated and read on-demand; the
# situating card is the GENERATED, machine-derived eager surface. This capability
# NEVER writes hub.md (it preserves C-HUB / R-BIND "no capability generates hub.md").
# The card is DERIVED entirely from each contributing plan's manifest.json (the
# fields declared in schemas/plan-manifest-schema.json). Only plans whose manifest
# `project:` key == the target spoke contribute (per-spoke, the sibling-generator
# grouping rule). The card carries ONLY machine-derivable blocks:
#   - the plan roster (id/slug/title + per-plan status across the spoke),
#   - an AGGREGATE project-level status (there is NO native aggregate field — G1 —
#     so it is aggregated BY RULE; the rule is documented at AGGREGATE_RULE below),
#   - active focus: the in-progress plan + its current task/blocker (from the
#     manifest tasks[] status fields),
#   - the latest handoff headline (most recent handoff.md across the spoke),
#   - pointers to research-index.md / decision-log.md / handoff-chronicle.md
#     (co-located in the binder home) + the deliverables path ~/work/<spoke>/deliverables/.
# EXCLUDE (hard): the card NEVER emits the non-derivable library-refs or the free
# "active SoT" pointer (non-derivable curation that stays in the on-demand hub, curated by the
# user). The card NEVER emits any work-spoke directory-map / "what-lives-where"
# content — that is the work-map generator's domain (D disjoint roles); the card
# is the BINDER surface, the work-map is the WORK surface.
# The plans home resolves robustly the way sibling capabilities resolve it —
# PLANS_ROOT/PLANS_DIR override, else paths.sh, never a hardcoded user-home
# literal. The _projects/ scaffold proper is the install unit's scope; this
# capability mkdir -p's its OWN output home on demand (generation, not install
# scaffolding).
# The card is force-ingested every session (the SessionStart card-load hook reads
# it as additionalContext), so it is bounded < 9728B (the format_output budget —
# hooks/lib/registry.sh:106 MAX=9728) for a realistic roster. The roster/active-
# focus/headline blocks are length-disciplined so the card stays well under budget;
# if a degenerate roster would overflow, the body is trimmed defensively before the
# write (the card never ships over budget).
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT R-GOV-2/R-GOV-3):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/_situating.md   (atomic temp+os.replace;
#         full-file regenerate — this is a GENERATED roll-up surface, no
#         survivorship region; re-run without source change == byte-identical).
#         Frontmatter carries `type: index` (REUSE the existing index file-type per
#         generated sentinel that distinguishes the machine card from a curated
#         index). The body carries the `_Auto-generated … Do not hand-edit._` line.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: null (no JSON Schema governs the generated card markdown; the card is a
#     generated human-readable projection. Its frontmatter conforms to the existing
#     `index` type contract — governance/frontmatter-rules.json#types.index: required
#     type/tags/updated + parent_folder at depth>=2 — plus the generated:true
#     sentinel. SOURCE fields read from the SHIPPED plan-manifest-schema.json:
#     project / title / status / tasks[].{id,status} / parent_plan / the plan slug.)
#   Pre-write validation:
#     - the plans home must resolve to a directory (absent => block-and-log, no
#       write, exit 0 — R-BIND-10a defensive class, never crash).
#     - each manifest is read defensively; a malformed/missing field is treated as
#       empty, never an error; a manifest that cannot be parsed emits a finding and
#       is SKIPPED (defensive skip, never crash — R-BIND-10a). A plan with no usable
#       fields contributes a roster row with empty cells, never a crash.
#     - the rendered card is bounded < 9728B; a degenerate over-budget roster is
#       defensively trimmed before the atomic write.
#     - atomic temp-file + os.replace.
#   Failure mode: BLOCK-AND-LOG. A manifest that cannot be parsed emits a finding
#     and is skipped; the plans home absent blocks the whole run with a finding and
#     exit 0; no partial/garbage write. Never write-and-hope.
#   Maintainer-provenance (R-GOV-3): _situating.md is a librarian-maintained
#     GENERATED artifact; this capability is its sole originating writer. It NEVER
#     writes hub.md, research-index.md, decision-log.md, handoff-chronicle.md, the
#     research/ symlink farm, plan manifests, any plan handoff.md / _research/ /
#     decisions/ content, or anything under ~/work/. It reads plan manifests (+ the
#     newest handoff.md headline) and writes ONLY _situating.md.
# CLI:
#   project-context-situating.sh                 # regenerate every spoke's card
#   project-context-situating.sh --spoke <key>   # regenerate one spoke's card only
#   project-context-situating.sh --dry-run       # findings + would-be writes, NO write
#   project-context-situating.sh --help
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24 (data via argv, never
# piped stdin — feedback_python_heredoc_argv). Read-only manifest walk + atomic
# file write(s).

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
    -h|--help) sed -n '2,90p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "project-context-situating: unknown flag '$1'" >&2; exit 2 ;;
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

# The force-ingest budget: the card MUST stay under this (registry.sh:106 MAX).
MAX_CARD_BYTES = 9728


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log: the plans home must resolve -----------------------------
if not plans_root or not os.path.isdir(plans_root):
    emit({"finding": "project-context-situating-blocked", "file": plans_root or "(unset)",
          "reason": "plans-home-absent", "detected_at": today})
    print("project-context-situating: plans home absent (%s); nothing to situate"
          % (plans_root or "(unset)"), file=sys.stderr)
    sys.exit(0)

PROJECTS = os.path.join(plans_root, "_projects")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None


# --- walk every manifest under the plans tree -------------------------------
# Each manifest carries project: (the owning-spoke machine identity),
# parent_plan: (lineage), title: (display), status: (canonical 8-state),
# tasks[]: (each with id + status). The plan slug is the dir basename.
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
            # defensive skip + finding (R-BIND-10a) — never crash on a bad manifest.
            emit({"finding": "project-context-situating-blocked", "file": mp,
                  "reason": "manifest-parse-failed", "detected_at": today})
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


# --- AGGREGATE_RULE (G1): there is NO native project-level aggregate status in
# the manifest schema, so the project-level status is aggregated BY RULE from the
# per-plan canonical statuses. The rule, in PRECEDENCE order (first match wins):
#   in-progress  if ANY contributing plan is in-progress (active work)
#   paused       elif ANY is paused (work held)
#   planned      elif ANY is planned or researching (work queued)
#   completed    elif ANY is completed or verified (work done, not yet closed)
#   closed       elif ALL are closed/archived/superseded (spoke at rest)
#   unknown      else (no contributing plan carried a status)
# This is a non-native derivation; it is documented here (the only home) so a
# reader knows the aggregate is computed, not stored.
ACTIVE = "in-progress"
def aggregate_status(statuses):
    s = set(x for x in statuses if x)
    if not s:
        return "unknown"
    if "in-progress" in s:
        return "in-progress"
    if "paused" in s:
        return "paused"
    if "planned" in s or "researching" in s:
        return "planned"
    if "completed" in s or "verified" in s:
        return "completed"
    if s <= {"closed", "archived", "superseded"}:
        return "closed"
    return "unknown"


# --- active-focus: the in-progress plan + its current task/blocker -----------
# Current task = the first tasks[] entry whose status is NOT a terminal/done token
# (the active edge of the plan). The schema does not constrain tasks[].status, so
# read it defensively; treat done/closed/complete/verified/skipped as terminal.
TERMINAL_TASK = {"done", "closed", "complete", "completed", "verified",
                 "skipped", "cancelled", "canceled"}
def current_task(man):
    tasks = man.get("tasks")
    if not isinstance(tasks, list):
        return ("", "")
    for t in tasks:
        if not isinstance(t, dict):
            continue
        tstatus = str(t.get("status") or "").strip().lower()
        if tstatus and tstatus in TERMINAL_TASK:
            continue
        tid = str(t.get("id") or "").strip()
        # blocker: an explicit blocker/blocked_reason/note field if present, else
        # the task title (the active edge), else just the id.
        blocker = ""
        for k in ("blocker", "blocked_reason", "current_blocker", "note"):
            v = t.get(k)
            if isinstance(v, str) and v.strip():
                blocker = v.strip()
                break
        if not blocker:
            blocker = str(t.get("title") or "").strip()
        return (tid, blocker)
    return ("", "")


# --- newest handoff headline ------------------------------------------------
# The latest handoff headline is the most-recent session heading across the spoke's
# handoff.md files. Reuse the sibling chronicle's session-heading recognizer (an
# H2/H3 naming a session-with-number OR a date-prefixed heading). We pick the
# handoff.md with the freshest mtime (a cheap, deterministic "latest" proxy) and
# harvest its FIRST session heading (handoffs are append-only newest-first, so the
# first session heading is the newest in that file).
SESSION_HEADING_RE = re.compile(
    r"^(#{2,4})\s+(.*\bsession\b.*?[0-9].*|[0-9]{4}-[0-9]{2}-[0-9]{2}.*)\s*$",
    re.IGNORECASE,
)
def newest_handoff_headline(plan_dirs):
    best = None  # (mtime, plan_slug, headline)
    for slug, pdir in plan_dirs.items():
        hp = os.path.join(pdir, "handoff.md")
        if not os.path.isfile(hp):
            continue
        try:
            mt = os.path.getmtime(hp)
        except Exception:
            continue
        text = read_text(hp)
        if not text:
            continue
        headline = ""
        for line in text.splitlines():
            if SESSION_HEADING_RE.match(line):
                headline = line.lstrip("# ").strip()
                break
        if not headline:
            continue
        if best is None or mt > best[0]:
            best = (mt, slug, headline)
    if best is None:
        return ("", "")
    return (best[1], best[2])


# --- assemble per-spoke state -----------------------------------------------
# spoke -> { plans: [ {slug,title,status} ], statuses: [..], active: [..],
#            plan_dirs: {slug->dir} }
spokes = {}

for plan_dir, man in manifests:
    spoke = str(field(man, "project") or "").strip()
    if not spoke:
        # missing project: => cannot attribute to a spoke; skip silently
        # (R-BIND-10a missing-field-empty; this is not an error).
        continue
    if spoke_filter and spoke != spoke_filter:
        continue
    slug = slug_of(plan_dir)
    title = str(field(man, "title") or "").strip() or slug
    status = str(field(man, "status") or "").strip()
    st = spokes.setdefault(spoke, {"plans": [], "statuses": [], "active": [],
                                   "plan_dirs": {}})
    st["plans"].append({"slug": slug, "title": title, "status": status})
    st["statuses"].append(status.lower())
    st["plan_dirs"][slug] = plan_dir
    if status.lower() == ACTIVE:
        tid, blocker = current_task(man)
        st["active"].append({"slug": slug, "title": title, "task": tid,
                             "blocker": blocker})


def esc(cell):
    return (cell or "").replace("|", "\\|")


def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._situating.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)


def render_card(spoke, st):
    plans = sorted(st["plans"], key=lambda p: p["slug"])
    agg = aggregate_status(st["statuses"])
    active = st["active"]
    a_slug, a_headline = newest_handoff_headline(st["plan_dirs"])

    # tags item-pattern: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$  (R-GOV-4)
    tag_spoke = re.sub(r"[^a-z0-9-]", "-", spoke.lower()).strip("-") or "spoke"

    lines = [
        "---",
        "type: index",
        "generated: true",
        'tags: ["#projects/%s"]' % tag_spoke,
        "updated: %s" % today,
        "parent_folder: _projects",
        "---",
        "",
        "# %s — Situating Card" % spoke,
        "",
        "_Auto-generated by `librarian project-context-situating`. Do not hand-edit._",
        "",
        "Force-ingested binder orientation for the `%s` spoke. Machine-derived from "
        "each contributing plan's manifest. The curated on-demand surface is "
        "`hub.md` (this card never replaces it)." % spoke,
        "",
        "**Project status (aggregate, by rule): `%s`** — derived from the per-plan "
        "statuses below (no native aggregate field; precedence: in-progress > paused "
        "> planned > completed > closed)." % agg,
        "",
    ]

    # --- plan roster ---------------------------------------------------------
    lines.append("## Plan roster")
    lines.append("")
    if plans:
        lines.append("| Plan | Title | Status |")
        lines.append("|---|---|---|")
        for p in plans:
            lines.append("| %s | %s | %s |"
                         % (esc(p["slug"]), esc(p["title"]) or "—",
                            esc(p["status"]) or "—"))
    else:
        lines.append("_No plans attributed to this spoke yet._")
    lines.append("")

    # --- active focus --------------------------------------------------------
    lines.append("## Active focus")
    lines.append("")
    if active:
        for a in active:
            task = ("`%s`" % a["task"]) if a["task"] else "—"
            blocker = esc(a["blocker"]) or "—"
            lines.append("- **%s** (%s) — current task %s: %s"
                         % (esc(a["title"]), esc(a["slug"]), task, blocker))
    else:
        lines.append("_No in-progress plan in this spoke._")
    lines.append("")

    # --- latest handoff headline --------------------------------------------
    lines.append("## Latest handoff")
    lines.append("")
    if a_headline:
        lines.append("- **%s**: %s" % (esc(a_slug), esc(a_headline)))
    else:
        lines.append("_No session handoff recorded in this spoke yet._")
    lines.append("")

    # --- binder + deliverables pointers (DERIVABLE only) --------------------
    # research-index.md / decision-log.md / handoff-chronicle.md are co-located in
    # this same binder home (_projects/<spoke>/), so they are bare relative links.
    # The deliverables path is the spoke-keyed ~/work/<spoke>/deliverables/ (the
    # hub-template convention). NO library-refs, NO "active SoT" free pointer
    # (non-derivable curation — stays in hub.md). NO work directory-map (the
    # work-side directory-map domain).
    lines.append("## Binder surfaces")
    lines.append("")
    lines.append("- Research: [research-index.md](research-index.md)")
    lines.append("- Decisions: [decision-log.md](decision-log.md)")
    lines.append("- Handoffs: [handoff-chronicle.md](handoff-chronicle.md)")
    lines.append("- Curated cover (on-demand): [hub.md](hub.md)")
    lines.append("- Deliverables: `~/work/%s/deliverables/`" % spoke)
    lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def trim_to_budget(spoke, content):
    """Defensive: the card is force-ingested, so it MUST stay < MAX_CARD_BYTES.
    A degenerate roster could overflow; trim the body (preserving the frontmatter +
    title + the aggregate line) before the write, and emit a finding. Idempotent:
    the trim is deterministic on the same input, so a re-run is byte-identical."""
    if len(content.encode("utf-8")) < MAX_CARD_BYTES:
        return content
    emit({"finding": "project-context-situating-card-over-budget", "file": spoke,
          "reason": "roster-exceeds-9728B; trimmed", "detected_at": today})
    note = "\n_Card trimmed to the force-ingest budget; see the full binder surfaces above._\n"
    budget = MAX_CARD_BYTES - len(note.encode("utf-8")) - 1
    enc = content.encode("utf-8")[:budget]
    # decode defensively (drop a split multibyte tail), then re-append the note.
    trimmed = enc.decode("utf-8", "ignore").rstrip()
    return trimmed + note


spokes_written = 0

# When a --spoke filter names a spoke with no contributing plans, still render an
# empty card for it (idempotent empty surface), so the SessionStart hook has a card.
target_spokes = sorted(spokes.keys())
if spoke_filter and spoke_filter not in spokes:
    target_spokes = [spoke_filter] if not target_spokes else sorted(set(target_spokes) | {spoke_filter})

for spoke in target_spokes:
    st = spokes.get(spoke, {"plans": [], "statuses": [], "active": [], "plan_dirs": {}})
    binder_home = os.path.join(PROJECTS, spoke)
    card_path = os.path.join(binder_home, "_situating.md")

    content = trim_to_budget(spoke, render_card(spoke, st))

    if not dry_run:
        try:
            os.makedirs(binder_home, exist_ok=True)
        except Exception as exc:
            emit({"finding": "project-context-situating-blocked", "file": binder_home,
                  "reason": "mkdir-failed", "error": str(exc), "detected_at": today})
            continue
        try:
            write_atomic(binder_home, card_path, content)
        except Exception as exc:
            emit({"finding": "project-context-situating-blocked", "file": card_path,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            continue
    spokes_written += 1

print("project-context-situating: spokes=%d source-manifests=%d dry_run=%s"
      % (spokes_written, len(manifests), dry_run), file=sys.stderr)
PY

#!/bin/bash
# project-context-situating — generate the per-spoke GENERATED situating card:
# <plans-root>/_projects/<spoke>/_situating.md — the eager, force-ingested binder
# surface that lets a session self-orient the instant it opens in a spoke. The
# situating card is the SOLE binder cover — the project binder is 100%
# machine-derived, generated entirely from each contributing plan's manifest, with
# no hand-curated cover surface.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is cited only as the SOURCE-field shape reference; no Draft202012Validator is constructed, so there is no schema-gate degrade path.
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
#
# EXCLUDE (hard): the card NEVER emits the non-derivable library-refs or the free
# "active SoT" pointer (non-derivable curation the card deliberately omits). The
# card NEVER emits any work-spoke directory-map / "what-lives-where"
# content — that is the work-map generator's domain (D disjoint roles); the card
# is the BINDER surface, the work-map is the WORK surface.
#
# The plans home resolves robustly the way sibling capabilities resolve it —
# PLANS_ROOT/PLANS_DIR override, else paths.sh, never a hardcoded user-home
# literal. The _projects/ scaffold proper is the install unit's scope; this
# capability mkdir -p's its OWN output home on demand (generation, not install
# scaffolding).
#
# The card is force-ingested every session (the SessionStart card-load hook reads
# it as additionalContext), so it self-bounds < 9728B — the force-ingest ceiling
# for a SessionStart additionalContext payload. That bound is met STRUCTURALLY: the
# orientation block renders first and is never trimmed, and the roster below is
# non-terminal-filtered, parent-collapsed, and hard-capped. The generator does NOT
# route its output through the format_output_allow() soft-truncate helper; it stays
# under the ceiling by construction. If a pathological roster somehow overflowed,
# the body would be trimmed defensively before the write as a can-never-fire last
# resort (the card never ships over budget).
#
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/_situating.md   (atomic temp+os.replace;
#         full-file regenerate — this is a GENERATED roll-up surface, no
#         survivorship region; re-run without source change == byte-identical).
#         Frontmatter carries `type: index` (REUSE the existing index file-type per
#         — no new file-type, no governance-type lockstep) PLUS `generated: true` (the
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
#       write, exit 0 — defensive class, never crash).
#     - each manifest is read defensively; a malformed/missing field is treated as
#       empty, never an error; a manifest that cannot be parsed emits a finding and
#       is SKIPPED (defensive skip, never crash). A plan with no usable
#       fields contributes a roster row with empty cells, never a crash.
#     - the rendered card is bounded < 9728B; a degenerate over-budget roster is
#       defensively trimmed before the atomic write.
#     - atomic temp-file + os.replace.
#   Failure mode: BLOCK-AND-LOG. A manifest that cannot be parsed emits a finding
#     and is skipped; the plans home absent blocks the whole run with a finding and
#     exit 0; no partial/garbage write. Never write-and-hope.
#   Maintainer-provenance: _situating.md is a librarian-maintained
#     GENERATED artifact; this capability is its sole originating writer. It NEVER
#     writes research-index.md, decision-log.md, handoff-chronicle.md, the
#     research/ symlink farm, plan manifests, any plan handoff.md / _research/ /
#     decisions/ content, or anything under ~/work/. It reads plan manifests (+ the
#     newest handoff.md headline) and writes ONLY _situating.md.
#
# CLI:
#   project-context-situating.sh                 # regenerate every spoke's card
#   project-context-situating.sh --spoke <key>   # regenerate one spoke's card only
#   project-context-situating.sh --dry-run       # findings + would-be writes, NO write
#   project-context-situating.sh --help
#
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24 (data via argv, never
# piped stdin the heredoc would consume). Read-only manifest walk + atomic
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
    -h|--help) sed -n '2,91p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "project-context-situating: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- plans home resolution (robust; the sibling pattern) ---------------------
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

# the work-spoke home, so the deliverables pointer can be
# existence-gated (WORK_HOME override for test isolation; default ~/work).
WORK_HOME_RES="${WORK_HOME:-$HOME/work}"
case "$WORK_HOME_RES" in */) WORK_HOME_RES="${WORK_HOME_RES%/}" ;; esac

python3 - "$PLANS_ROOT" "$DRY_RUN" "$SPOKE_FILTER" "$WORK_HOME_RES" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root, dry_s, spoke_filter, work_home = sys.argv[1:5]
dry_run = (dry_s == "true")
spoke_filter = spoke_filter or None
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

# The force-ingest ceiling: the card self-bounds under this by convention (the
# SessionStart additionalContext limit), met structurally by the render below —
# not by routing through format_output_allow().
MAX_CARD_BYTES = 9728

# Hard-cap on rendered roster rows — a structural bound so a pathological spoke
# roster cannot blow the force-ingest ceiling. Non-terminal filtering + parent
# collapse keep a realistic spoke well under this; the cap only bites a degenerate
# roster, replacing the overflow with a `+N more` line (never a byte-slice).
ROSTER_CAP = 40


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
# parent_plan: (lineage), title: (display), status: (canonical 6-state),
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
            # defensive skip + finding — never crash on a bad manifest.
            emit({"finding": "project-context-situating-blocked", "file": mp,
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


# --- AGGREGATE_RULE (G1): there is NO native project-level aggregate status in
# the manifest schema, so the project-level status is aggregated BY RULE from the
# per-plan canonical statuses. The rule, in PRECEDENCE order (first match wins):
#   in-progress  if ANY contributing plan is in-progress (active work)
#   paused       elif ANY is paused (work held)
#   planned      elif ANY is planned or researching (work queued)
#   completed    elif ANY is completed (work done — the sole terminal done-state)
#   superseded   elif ALL are superseded (spoke fully at rest)
#   unknown      else (no contributing plan carried a status)
# This is a non-native derivation; it is documented here (the only home) so a
# reader knows the aggregate is computed, not stored.
ACTIVE = "in-progress"
# At-rest (terminal) plan statuses — a spoke is fully at rest only when ALL its
# plans are terminal. Reused by the roster's non-terminal filter: at-rest plans
# are summarized by a count line + a chronicle pointer instead of listed row-by-row.
AT_REST = {"completed", "superseded"}
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
    if "completed" in s:
        return "completed"
    if s <= AT_REST:
        return "superseded"
    return "unknown"


# --- active-focus: the in-progress plan + its current task/blocker -----------
# Current task = the first tasks[] entry whose status is NOT a terminal token
# (the active edge of the plan). Keyed to the declared task-status vocabulary
# (schemas/plan-manifest-schema.json declared_vocabulary): the canonical
# terminal split (done/cut) declared at declared_vocabulary.terminal, onto which
# the legacy synonyms were converged by migration 0009; the reader normalizes on
# the declared front-token chain so a narrated status ("done (verified)")
# classifies by its front token.
TERMINAL_TASK = {"done", "cut"}
def current_task(man):
    tasks = man.get("tasks")
    if not isinstance(tasks, list):
        return ("", "")
    for t in tasks:
        if not isinstance(t, dict):
            continue
        tstatus = str(t.get("status") or "").split("(")[0].strip().lower().replace("_", "-")
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
# The latest-handoff headline is the genuinely-newest session heading across ALL
# handoff.md files in the spoke, selected by parsed session_key (session ordinal
# DESC, then date DESC) — NOT the freshest-mtime file's FIRST heading. A handoff
# whose newest block is not its first, or a spoke whose latest work landed in a file
# with an older mtime, would otherwise publish a stale line. The recognizer is a
# hand-copied 3rd copy of the chronicle pair's session-heading recognizer
# (skills/librarian/capabilities/plan-handoff-index.sh + hooks/handoff-chronicle-
# append.sh); the SESSION_HEADING_RE / SESSION_NUM_RE / DATE_RE triple is
# byte-identical to that pair (the recognizer region is parity-gated) and parses the
# same shapes: the heading is anchored to the heading-text start (a narrative
# "...(Session N)" is not a boundary); the ordinal parser rejects a YYYY-MM-DD date
# (the date is the date sort-key) and parses S-prefixed / colon forms.
SESSION_HEADING_RE = re.compile(
    r"^(#{2,4})\s+"
    r"((?:alignment\s+)?session\s*(?::|s?[0-9])"
    r"|s[0-9]+\b"
    r"|[0-9]{4}-[0-9]{2}-[0-9]{2}\b)"
    r".*$",
    re.IGNORECASE,
)
SESSION_NUM_RE = re.compile(r"(?:\bsession\s*:?\s*|^)S?([0-9]+)(?![0-9])(?!-[0-9]{2}-[0-9]{2})", re.IGNORECASE)
DATE_RE = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})")
def newest_handoff_headline(plan_dirs):
    # PER-SLUG maxima: for EACH plan slug, scan every session heading in its own
    # handoff.md, parse the session ordinal + date, and keep THAT slug's maximum
    # (ordinal DESC, then date DESC). Returns {slug: headline} — one newest headline
    # per plan, NOT a single global winner, so the card can render one latest-handoff
    # pointer per in-progress Active-focus bullet (member b). A single mid-scan global
    # `best` would collapse all plans to one line. No mtime, no first-heading shortcut.
    best = {}  # slug -> (session_num, date, headline)
    for slug, pdir in plan_dirs.items():
        hp = os.path.join(pdir, "handoff.md")
        if not os.path.isfile(hp):
            continue
        text = read_text(hp)
        if not text:
            continue
        for line in text.splitlines():
            if not SESSION_HEADING_RE.match(line):
                continue
            headline = line.lstrip("# ").strip()
            nm = SESSION_NUM_RE.search(headline)
            num = int(nm.group(1)) if nm else -1
            dm = DATE_RE.search(headline)
            dt = dm.group(1) if dm else ""
            cur = best.get(slug)
            if cur is None or (num, dt) > (cur[0], cur[1]):
                best[slug] = (num, dt, headline)
    return {slug: v[2] for slug, v in best.items()}


# --- assemble per-spoke state -----------------------------------------------
# spoke -> { plans: [ {slug,title,status} ], statuses: [..], active: [..],
#            plan_dirs: {slug->dir} }
spokes = {}

for plan_dir, man in manifests:
    spoke = str(field(man, "project") or "").strip()
    if not spoke:
        # missing project: => cannot attribute to a spoke; skip silently
        # (missing-field-empty; this is not an error).
        continue
    if spoke_filter and spoke != spoke_filter:
        continue
    slug = slug_of(plan_dir)
    title = str(field(man, "title") or "").strip() or slug
    status = str(field(man, "status") or "").strip()
    parent_plan = str(field(man, "parent_plan") or "").strip()
    st = spokes.setdefault(spoke, {"plans": [], "statuses": [], "active": [],
                                   "plan_dirs": {}})
    st["plans"].append({"slug": slug, "title": title, "status": status,
                        "parent_plan": parent_plan})
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
    agg = aggregate_status(st["statuses"])
    active = st["active"]
    handoffs = newest_handoff_headline(st["plan_dirs"])  # {slug: newest headline}
    binder_home = os.path.join(PROJECTS, spoke)

    # tags item-pattern: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$
    tag_spoke = re.sub(r"[^a-z0-9-]", "-", spoke.lower()).strip("-") or "spoke"

    # ORIENTATION BLOCK — rendered FIRST and NEVER trimmed. On an eager force-
    # ingested surface the orientation (aggregate status + active focus + latest
    # handoff + binder surfaces) is the load-bearing content; it must survive
    # regardless of roster size. The roster renders LAST so any defensive trim
    # (a can-never-fire last resort) sheds roster rows, never orientation.
    lines = [
        "---",
        "type: index",
        "generated: true",
        'tags: ["#project/%s"]' % tag_spoke,
        "updated: %s" % today,
        "parent_folder: _projects",
        "---",
        "",
        "# %s — Situating Card" % spoke,
        "",
        "_Auto-generated by `librarian project-context-situating`. Do not hand-edit._",
        "",
        "Force-ingested binder orientation for the `%s` spoke. Machine-derived from "
        "each contributing plan's manifest — the sole, 100%% machine-derived binder "
        "cover." % spoke,
        "",
        "**Project status (aggregate, by rule): `%s`** — derived from the per-plan "
        "statuses below (no native aggregate field; precedence: in-progress > paused "
        "> planned > completed > superseded)." % agg,
        "",
    ]

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

    # --- latest handoff pointers (one PER in-progress Active-focus bullet) ---
    # PER-PLAN, not a single global line: each in-progress plan (the Active-focus
    # bullets above) renders its OWN newest-handoff pointer, aligned to that bullet;
    # a plan with no handoff.md contributes no row. These rows live in the
    # never-trimmed orientation zone, so they stay compact (<9728B).
    lines.append("## Latest handoff")
    lines.append("")
    handoff_rows = []
    for a in active:
        hl = handoffs.get(a["slug"])
        if hl:
            handoff_rows.append("- **%s**: %s" % (esc(a["slug"]), esc(hl)))
    if handoff_rows:
        lines.extend(handoff_rows)
    elif active:
        lines.append("_No session handoff recorded for an in-progress plan in this spoke yet._")
    else:
        lines.append("_No session handoff recorded in this spoke yet._")
    lines.append("")

    # --- binder + deliverables pointers (DERIVABLE only) --------------------
    # research-index.md / decision-log.md / handoff-chronicle.md are co-located in
    # this same binder home (_projects/<spoke>/); each link is gated on the surface
    # actually existing, so the card never renders a dead link to a not-yet-created
    # binder file. The deliverables path is the spoke-keyed ~/work/<spoke>/
    # deliverables/. NO library-refs, NO "active SoT" free pointer (non-derivable
    # curation the card deliberately omits). NO work directory-map.
    lines.append("## Binder surfaces")
    lines.append("")
    for label, fname in (("Research", "research-index.md"),
                         ("Decisions", "decision-log.md"),
                         ("Handoffs", "handoff-chronicle.md")):
        if os.path.exists(os.path.join(binder_home, fname)):
            lines.append("- %s: [%s](%s)" % (label, fname, fname))
    # existence-gate the deliverables pointer, mirroring the
    # binder-surface gate above. A binder-only spoke with no ~/work/<spoke>/deliverables/
    # otherwise force-ingested a DEAD pointer every session. (The hub.md-pointer half of
    # the deliverables-hub pointer is DISSOLVED (de-hub); the card no longer emits a hub.md pointer.)
    if os.path.isdir(os.path.join(work_home, spoke, "deliverables")):
        lines.append("- Deliverables: `~/work/%s/deliverables/`" % spoke)
    lines.append("")

    # PLAN ROSTER — rendered LAST and STRUCTURALLY BOUNDED. Keyed per-spoke off
    # the manifest `project:` (the true-owner axis). The roster lists only
    # non-terminal plans, collapses child sub-plans under their parent_plan, and
    # is hard-capped with a `+N more` line; at-rest (completed/superseded)
    # plans are summarized by a count line + a handoff-chronicle pointer instead of
    # listed row-by-row. This bounds the card without any byte-slicing.
    lines.append("## Plan roster")
    lines.append("")

    all_plans = st["plans"]
    terminal_count = sum(
        1 for p in all_plans
        if str(p.get("status") or "").strip().lower() in AT_REST)
    nonterminal = [
        p for p in all_plans
        if str(p.get("status") or "").strip().lower() not in AT_REST]

    # collapse: a plan whose parent_plan names another plan is a child; group the
    # children under their parent and render ONE row per parent (with a child count)
    # instead of a row per child.
    children_of = {}
    tops = []
    for p in nonterminal:
        par = str(p.get("parent_plan") or "").strip()
        if par and par != p["slug"]:
            children_of.setdefault(par, []).append(p)
        else:
            tops.append(p)

    rows = []  # (slug, title, status, child_count)
    handled = set()
    for p in tops:
        kids = children_of.get(p["slug"], [])
        rows.append((p["slug"], p["title"], p["status"], len(kids)))
        if kids:
            handled.add(p["slug"])
    # orphan parents: a parent named by children but with no non-terminal top-level
    # row of its own (its own plan is terminal or absent) — synthesize one row.
    for par in sorted(children_of):
        if par in handled:
            continue
        rows.append((par, par, "", len(children_of[par])))

    rows.sort(key=lambda r: r[0])

    if rows:
        lines.append("| Plan | Title | Status |")
        lines.append("|---|---|---|")
        for slug, title, status, kids in rows[:ROSTER_CAP]:
            title_cell = esc(title) or "—"
            if kids:
                title_cell = "%s _(+%d sub-plan%s)_" % (
                    title_cell, kids, "" if kids == 1 else "s")
            lines.append("| %s | %s | %s |"
                         % (esc(slug), title_cell, esc(status) or "—"))
        extra = len(rows) - ROSTER_CAP
        if extra > 0:
            lines.append("| … | _+%d more non-terminal plan%s_ | … |"
                         % (extra, "" if extra == 1 else "s"))
    else:
        lines.append("_No non-terminal plans attributed to this spoke._")
    lines.append("")

    if terminal_count:
        lines.append(
            "_%d terminal plan%s (completed/superseded) not shown — see the "
            "handoff chronicle (linked under Binder surfaces)._"
            % (terminal_count, "" if terminal_count == 1 else "s"))
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

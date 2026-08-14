#!/bin/bash
# new-plan.sh — The ONE collapsed plan scaffolder (research-skip mode entrypoint).
#
# .6: ONE canonical scaffolder, multiple modes. /new-plan is the
# research-skip mode; /backlog-research is the research-backed mode (peer skill).
# flat depth-2 quartet is the DEFAULT emission; --master is OPT-IN (never
# auto-emitted); --add-subplan adds a sub-plan to an existing master.
#
# Modes:
#   (default)        Emit the flat depth-2 quartet at ~/.claude-plans/NN-<slug>/:
#                    spec.md + tasks.md + handoff.md + manifest.json + the
#                    placeholder 00-ideation-brief.md (DEFAULT). type:plan.
#   --master         Emit the master quartet (from templates/master-*.tmpl) +
#                    the first sub-plan quartet (from templates/sub-*.tmpl) at
#                    NN-<slug>/ and NN-<slug>/01-<sub-slug>/. OPT-IN only.
#   --add-subplan    Add a new sub-plan quartet (from templates/sub-*.tmpl) into
#                    an existing master and register it in the master's
#                    sub_plans[] aggregate skeleton. The librarian reconciler does
#                    the pull-based status fill, NOT this scaffolder.
#
# NOT built (charter — NOT minted):
#   - flat->master graduation (DESIGNED-BUT-DEFERRED; see SKILL.md).
#   - --promote-master (— no such flag exists; --add-subplan is the only
#     sub-emit path).
#
# Failure mode is BLOCK-AND-LOG (never write-and-hope): all validation runs before
# any write; a mid-scaffold failure rolls back the created directory.
#
# CLI:
#   new-plan.sh <slug> [--section <backlog-section>] [--title <title>] [--project <spoke-key>] [--force-slug]
#   new-plan.sh --master <slug> --sub <sub-slug> [--sub-title <title>] [--title <title>] [--project <spoke-key>] [--force-slug]
#   new-plan.sh --add-subplan <master-NN-slug> --sub <sub-slug> [--sub-title <title>]
#   new-plan.sh --dry-run ...        # compute + emit; no write
#   new-plan.sh --help
#
# Identity field-triad: the scaffolded manifest stamps `title:` (human
# display name), `project:` (the owning-spoke machine identity, resolved from the
# session cwd through the anchored-spoke registry — NEVER the bare title), and
# `parent_plan:` (lineage, on sub-plans). --project <spoke-key> overrides the
# auto-resolved spoke (must be a registered key; collision-safe by construction).
#
# Env overrides:
#   PLANS_ROOT     Plan-tree root (test isolation). Else PLANS_DIR (paths.sh),
#                  else $HOME/.claude-plans.
#   TEMPLATES_DIR  Quartet template source (default: this skill's templates/).
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24 (data via argv).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null || true
fi

# Spoke-key resolver: prefer the live install, fall back to this
# skill's lib/ copy (dev-repo / test isolation).
for _sr in \
  "${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh" \
  "$SCRIPT_DIR/lib/spoke-resolve.sh"; do
  # shellcheck source=/dev/null
  if [[ -f "$_sr" ]]; then source "$_sr"; break; fi
done

# Resolve the librarian:tasks-render capability (RULING 2 /). tasks-render is the
# SINGLE writer of the tasks.md sentinel region (R-37/): the scaffolder seeds
# manifest.tasks[], ships an EMPTY sentinel pair, and DELEGATES the region-fill to this
# capability at scaffold time — never statically pre-emitting a region the renderer owns.
# Resolve it SIBLING-FIRST (scaffolder + renderer co-ship in the same skill tree, so they are
# always version-matched and the resolution is hermetic in-repo AND in a clean install),
# CLAUDE_HOME as the fallback; never a hardcoded home.
TASKS_RENDER=""
for _tr in \
  "$SCRIPT_DIR/../librarian/capabilities/tasks-render.sh" \
  "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/tasks-render.sh"; do
  if [[ -f "$_tr" ]]; then TASKS_RENDER="$_tr"; break; fi
done

MODE="flat"            # flat | master | add-subplan
SLUG=""                # plan slug (flat/master) OR master NN-slug (add-subplan)
SUB_SLUG=""
TITLE_OVERRIDE=""
SUB_TITLE_OVERRIDE=""
SECTION="Vault & Infrastructure"
PROJECT_OVERRIDE=""
FORCE_SLUG="false"
DRY_RUN="false"

usage() { /usr/bin/sed -n '2,38p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master)       MODE="master"; SLUG="${2:-}"; shift 2 ;;
    --add-subplan)  MODE="add-subplan"; SLUG="${2:-}"; shift 2 ;;
    --sub)          SUB_SLUG="${2:-}"; shift 2 ;;
    --sub-title)    SUB_TITLE_OVERRIDE="${2:-}"; shift 2 ;;
    --title)        TITLE_OVERRIDE="${2:-}"; shift 2 ;;
    --project)      PROJECT_OVERRIDE="${2:-}"; shift 2 ;;
    --section)      SECTION="${2:-}"; shift 2 ;;
    --force-slug)   FORCE_SLUG="true"; shift ;;
    --dry-run)      DRY_RUN="true"; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "new-plan: unknown flag '$1' (see --help)" >&2; exit 2 ;;
    *)              if [[ -z "$SLUG" ]]; then SLUG="$1"; else echo "new-plan: unexpected arg '$1'" >&2; exit 2; fi; shift ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "new-plan: missing <slug> (see --help)" >&2
  exit 2
fi
if [[ "$MODE" != "flat" && -z "$SUB_SLUG" ]]; then
  echo "new-plan: --$MODE requires --sub <sub-slug>" >&2
  exit 2
fi

# Resolve plan-tree root (test override -> paths.sh -> default).
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
# Self-heal the plan-tree root if absent. install.sh creates the default
# ~/.claude-plans at apply-time, but a hand-edited custom plans_root may not exist
# yet; mkdir -p is idempotent and only a genuine create failure is fatal. Skipped
# under --dry-run so a preview writes nothing.
if [[ "${DRY_RUN:-}" != "true" ]]; then
  mkdir -p "$PLANS_ROOT" || { echo "new-plan: cannot create PLANS_ROOT: $PLANS_ROOT" >&2; exit 1; }
fi

# Resolve template dir (test override -> this skill's templates/).
TMPL_DIR="${TEMPLATES_DIR:-$SCRIPT_DIR/templates}"
if [[ ! -d "$TMPL_DIR" ]]; then
  echo "new-plan: templates dir not found: $TMPL_DIR (set TEMPLATES_DIR)" >&2
  exit 1
fi

# Resolve the owning-spoke key. --project overrides the cwd
# auto-resolution; either way the value must be a registered spoke key. A
# collision (two anchors → one key) or an unrecognized override BLOCKS here,
# before any write (block-and-log).
if ! type spoke_resolve_from_cwd >/dev/null 2>&1; then
  echo "new-plan: spoke-resolve.sh not found — cannot resolve owning-spoke key" >&2
  exit 1
fi
if [[ -n "$PROJECT_OVERRIDE" ]]; then
  SPOKE_KEY="$(spoke_validate_override "$PROJECT_OVERRIDE")" || exit 1
else
  SPOKE_KEY="$(spoke_resolve_from_cwd "$PWD")" || exit 1
fi

python3 - "$MODE" "$SLUG" "$SUB_SLUG" "$TITLE_OVERRIDE" "$SUB_TITLE_OVERRIDE" \
  "$FORCE_SLUG" "$DRY_RUN" "$PLANS_ROOT" "$TMPL_DIR" "$SPOKE_KEY" "$TASKS_RENDER" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date

(mode, slug, sub_slug, title_override, sub_title_override,
 force_slug, dry_run, plans_root, tmpl_dir, spoke_key, tasks_render) = sys.argv[1:12]
force_slug = force_slug == "true"
dry_run = dry_run == "true"
today = date.today().isoformat()

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$")
SHAME_RE = re.compile(r"^[a-z]+-[a-z]+ing-[a-z]+$")  # adjective-gerund-noun auto-slug
PLAN_DIR_RE = re.compile(r"^[0-9]{2,}-[a-z][a-z0-9-]+$")


def abort(msg):
    print("new-plan: aborted — %s" % msg, file=sys.stderr)
    sys.exit(1)


def title_case(s):
    return s.replace("-", " ").title()


def check_slug(s, label):
    if not SLUG_RE.match(s):
        abort("invalid %s shape '%s' (lowercase alphanumeric + hyphens, no leading/trailing/double hyphen)" % (label, s))
    if not (3 <= len(s) <= 60):
        abort("%s '%s' length out of range (3..60)" % (label, s))
    if SHAME_RE.match(s) and not force_slug:
        abort("%s '%s' matches the shame-slug pattern (adjective-gerund-noun). "
              "Provide a descriptive slug. Override: --force-slug." % (label, s))


def next_prefix(root):
    max_p, width = 0, 2
    for entry in (os.listdir(root) if os.path.isdir(root) else []):
        m = re.match(r"^([0-9]+)", entry)
        if m:
            n = int(m.group(1))
            if n > max_p:
                max_p = n
            width = max(width, len(m.group(1)))
    return str(max_p + 1).zfill(width)


def base_slug_collision(root, s):
    for entry in (os.listdir(root) if os.path.isdir(root) else []):
        if entry.startswith(".") or entry.startswith("_"):
            continue
        base = re.sub(r"^[0-9]+-", "", entry)
        if base == s:
            return entry
    return None


def tmpl(name):
    p = os.path.join(tmpl_dir, name)
    if not os.path.isfile(p):
        abort("template missing: %s" % p)
    with open(p, encoding="utf-8") as fh:
        return fh.read()


def render(text, **kw):
    for k, v in kw.items():
        text = text.replace("{{%s}}" % k, v)
    return text


def write_atomic(plan_dir, files):
    """Block-and-log batch write with rollback. files = {relpath: content}."""
    created_root = None
    try:
        for rel in files:
            d = os.path.dirname(os.path.join(plan_dir, rel)) or plan_dir
            os.makedirs(d, exist_ok=True)
        if not os.path.isdir(plan_dir):
            os.makedirs(plan_dir)
        created_root = plan_dir
        for rel, content in files.items():
            target = os.path.join(plan_dir, rel)
            d = os.path.dirname(target) or plan_dir
            fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(rel) + ".", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(content)
            os.chmod(tmp, 0o644)
            os.replace(tmp, target)
    except Exception as exc:
        if created_root and os.path.isdir(created_root):
            shutil.rmtree(created_root, ignore_errors=True)
        abort("scaffold write failed (%s); rolled back" % exc)


def delegate_render(target_dir):
    """RULING 2 (): delegate the tasks.md sentinel-region fill to librarian:tasks-render
    (the SINGLE writer of the region, R-37/) after manifest.json is on disk, so a fresh
    scaffold ships one renderer-owned `## Tasks` INSIDE the sentinels rather than a statically
    pre-emitted duplicate. BEST-EFFORT by design: a render hiccup must NOT roll back an
    already-valid, atomically-written scaffold — the tasks.md still carries the EMPTY sentinel
    pair that the next manifest-touch render fills, so the duplicate-`## Tasks` defect stays
    closed regardless. Surface any failure on stderr; never swallow it, never write-and-hope.
    stdout is muted so the capability's NDJSON findings never pollute this scaffolder's own
    JSON result line."""
    if not tasks_render or not os.path.isfile(tasks_render):
        print("new-plan: tasks-render capability not resolved (%s); tasks.md ships the empty "
              "sentinel pair, filled on the next render" % tasks_render, file=sys.stderr)
        return
    try:
        subprocess.run(["bash", tasks_render, target_dir],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    except Exception as exc:
        print("new-plan: tasks-render delegation failed (%s); tasks.md ships the empty "
              "sentinel pair, filled on the next render" % exc, file=sys.stderr)


# FLAT default emission. Inline bodies (the roster authorizes only the 8
# master/sub .tmpl + the brief template; the flat quartet is emitted inline here,
# mirroring the live /new-plan inline-manifest pattern). type:plan, no parent_plan.
def flat_files(title, plan_dir):
    spec = (
        "---\n"
        "title: %s — Spec\n"
        "type: spec\n"
        "created: %s\n"
        "updated: %s\n"
        "---\n\n"
        "# %s — Spec\n\n"
        "**Goal:** {One sentence. When this ships, what is true that wasn't true before?}\n\n"
        "<!-- Head-immutable post Session 1: Goal / Problem Statement / Constraints "
        "(governance/file-type-contracts/spec.md.json). created/parent live in the YAML "
        "frontmatter; the plan's canonical 6-state status lives on manifest.json :: status "
        "(DERIVE single-SoT — the artifact carries no status: frontmatter). Cap ~500 lines. -->\n\n"
        "## Problem Statement\n\n"
        "{2-4 sentences. What's broken, missing, or suboptimal today?}\n\n"
        "## Constraints\n\n"
        "- {Hard constraint}\n"
        "- {Scope constraint — e.g., single-team scope; no cross-org rollout}\n"
        "- {Anti-scope lock — what is explicitly OUT of scope}\n\n"
        "## Solution Approach\n\n"
        "{3-8 sentences. High-level strategy. Post-Session-1 amendment blocks land here.}\n\n"
        "## Files Modified/Created\n\n"
        "| File | Action | Purpose |\n"
        "|------|--------|---------|\n"
        "| `{path}` | New / Modify | {one-line purpose} |\n\n"
        "## Success Metrics\n\n"
        "| Metric | Target | How to Measure |\n"
        "|--------|--------|---------------|\n"
        "| {metric} | {target} | {how} |\n"
    ) % (title, today, today, title)

    # RULING 2: ship frontmatter + preface + an EMPTY tasks:start/tasks:end
    # sentinel pair ONLY. The outside `## Tasks` + `### T-1` block is GONE — the renderer
    # (librarian:tasks-render, the single writer,/R-37) fills the region from
    # manifest.tasks[] via delegate_render() below, so a fresh scaffold never carries a
    # statically pre-emitted duplicate `## Tasks`.
    tasks = (
        "---\n"
        "title: %s — Tasks\n"
        "type: tasks\n"
        "created: %s\n"
        "updated: %s\n"
        "---\n\n"
        "# %s — Tasks\n\n"
        "**Spec:** `%s/spec.md`\n"
        "**Last Updated:** %s\n\n"
        "## Status Key\n\n"
        "`not-started` | `in-progress` | `done` | `blocked` | `cut`\n\n"
        "<!-- ledger-at-top + per-task-at-bottom; the tasks:start/end sentinel pair bounds the "
        "librarian:tasks-render region (the SINGLE writer,/R-37). The scaffolder ships an "
        "EMPTY pair and delegates the fill to tasks-render at scaffold time (RULING 2 /) "
        "— NEVER hand-author inside the sentinels; task-state SoT = manifest.tasks[]. -->\n\n"
        "<!-- tasks:start -->\n\n"
        "<!-- tasks:end -->\n"
    ) % (title, today, today, title, plan_dir, today)

    handoff = (
        "---\n"
        "title: %s — Handoff\n"
        "type: handoff\n"
        "created: %s\n"
        "updated: %s\n"
        "---\n\n"
        "# %s — Handoff\n\n"
        "Append-only session record. Newest entry at top.\n\n"
        "<!-- STRICTLY APPEND-ONLY, NEWEST-FIRST (handoff.md.json). New sessions PREPEND a "
        "`## Session N` block below this line. handoff.md is parent_plan-exempt (R-28). "
        "task-done marker convention lives here. -->\n\n"
        "## Session 0 — scaffold\n\n"
        "**Date:** %s\n"
        "**Next session:** T-1 — Define spec\n\n"
        "### Scope\n{Scaffolded via /new-plan (research-skip). Spec + task stubs in place.}\n\n"
        "### Files modified\n"
        "| File | Change |\n"
        "|------|--------|\n"
        "| `%s/` | created (quartet + placeholder brief) |\n\n"
        "---\n"
    ) % (title, today, today, title, today, plan_dir)

    manifest = {
        "schema_version": 1,
        "title": title,
        "project": spoke_key,
        "spec_path": os.path.join(plan_dir, "spec.md"),
        "architecture_path": None,
        "type": "plan",
        "status": "planned",
        "phase_2_scaffolded_at": today,
        # T-3: seed `updated` at creation so the backlog-index Updated cell is
        # populated from birth (breaking the circularity — backlog-hygiene's staleness
        # math requires `updated`, which nothing maintained). Mechanical seeding at every
        # manifest-creation surface (flat / master / sub / promote-from-inbox).
        "updated": today,
        # Scaffold the EMPTY research_artifacts[] seed the
        # per-spoke research-index renderer (plan-research-index.sh) already reads. Missing
        # field == empty (never an error), but declaring the empty seed makes the affordance
        # explicit on every fresh plan; session-close's plan-research-declare writer (T-2)
        # populates it from the plan's OWN _research/ at close (owning-spoke). Scoped to
        # this JSON manifest dict — DISJOINT from the .md artifact-frontmatter status: stamps
        # (the DERIVE-strip surface; coordination_contract).
        "research_artifacts": [],
        "tasks": [
            {
                "id": "T-1",
                "title": "Define spec",
                "description": ("Flesh out spec.md (Problem / Constraints / Solution Approach); "
                                "replace all template placeholders. The minimum stub for a valid manifest."),
                "acceptance_criteria": [
                    "Complete all spec.md sections",
                    "Replace template placeholder rows",
                ],
                "file_references": [os.path.join(plan_dir, "spec.md")],
                "depends_on": [],
                "max_budget_usd": 2,
            }
        ],
    }

    brief = render(tmpl("00-ideation-brief.md.tmpl"), title=title, date=today,
                   plan_dir=plan_dir, slug=slug)

    return {
        "spec.md": spec,
        "tasks.md": tasks,
        "handoff.md": handoff,
        "manifest.json": json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        "00-ideation-brief.md": brief,
    }


def render_sub_quartet(title, parent_plan, sub_plan_id, plan_dir, scaffold_brief):
    """Render the sub-plan quartet from templates/sub-*.tmpl into plan_dir-relative files."""
    kw = dict(title=title, date=today, plan_dir=plan_dir, spoke_key=spoke_key,
              parent_plan=parent_plan, sub_plan_id=sub_plan_id, slug=sub_slug)
    files = {
        "spec.md": render(tmpl("sub-spec.md.tmpl"), **kw),
        "tasks.md": render(tmpl("sub-tasks.md.tmpl"), **kw),
        "handoff.md": render(tmpl("sub-handoff.md.tmpl"), **kw),
        "manifest.json": render(tmpl("sub-manifest.json.tmpl"), **kw),
    }
    if scaffold_brief:
        files["00-ideation-brief.md"] = render(tmpl("00-ideation-brief.md.tmpl"), **kw)
    # sanity: the rendered sub manifest must be valid JSON
    json.loads(files["manifest.json"])
    return files


if mode == "flat":
    check_slug(slug, "slug")
    coll = base_slug_collision(plans_root, slug)
    if coll:
        abort("slug collision with existing plan: %s" % coll)
    nn = next_prefix(plans_root)
    plan_slug = "%s-%s" % (nn, slug)
    if not PLAN_DIR_RE.match(plan_slug):
        abort("computed plan slug '%s' fails plan dir pattern" % plan_slug)
    plan_dir = os.path.join(plans_root, plan_slug)
    if os.path.exists(plan_dir):
        abort("target plan dir already exists: %s" % plan_dir)
    # /backlog-research mutual-exclusion: refuse if an existing dir owns this slug via a brief
    title = title_override.strip() or title_case(slug)
    files = flat_files(title, plan_dir)
    if dry_run:
        print("new-plan: dry-run flat — would create %s (%d files)" % (plan_dir, len(files)), file=sys.stderr)
        print(json.dumps({"mode": "flat", "plan_slug": plan_slug, "project": spoke_key, "files": sorted(files)}))
        sys.exit(0)
    write_atomic(plan_dir, files)
    delegate_render(plan_dir)  # RULING 2: renderer fills the empty sentinel region from manifest.tasks[]
    print("new-plan: created flat plan %s (%d files)" % (plan_slug, len(files)), file=sys.stderr)
    print(json.dumps({"mode": "flat", "plan_slug": plan_slug, "project": spoke_key, "plan_dir": plan_dir}))

elif mode == "master":
    check_slug(slug, "master slug")
    check_slug(sub_slug, "sub slug")
    coll = base_slug_collision(plans_root, slug)
    if coll:
        abort("slug collision with existing plan: %s" % coll)
    nn = next_prefix(plans_root)
    master_slug = "%s-%s" % (nn, slug)
    if not PLAN_DIR_RE.match(master_slug):
        abort("computed master slug '%s' fails plan dir pattern" % master_slug)
    master_dir = os.path.join(plans_root, master_slug)
    if os.path.exists(master_dir):
        abort("target master dir already exists: %s" % master_dir)
    sub_id = "01"  # first sub-plan, execution order
    sub_plan_dir = os.path.join(master_dir, "%s-%s" % (sub_id, sub_slug))

    m_title = title_override.strip() or title_case(slug)
    s_title = sub_title_override.strip() or title_case(sub_slug)

    m_kw = dict(title=m_title, date=today, plan_dir=master_dir, spoke_key=spoke_key,
                first_sub_slug=sub_slug, slug=slug)
    master_files = {
        "spec.md": render(tmpl("master-spec.md.tmpl"), **m_kw),
        "tasks.md": render(tmpl("master-tasks.md.tmpl"), **m_kw),
        "handoff.md": render(tmpl("master-handoff.md.tmpl"), **m_kw),
        "manifest.json": render(tmpl("master-manifest.json.tmpl"), **m_kw),
    }
    json.loads(master_files["manifest.json"])  # sanity
    sub_files = render_sub_quartet(s_title, master_slug, sub_id, sub_plan_dir, scaffold_brief=False)

    # combine into one atomic batch keyed under the master dir
    files = dict(master_files)
    for rel, content in sub_files.items():
        files[os.path.join("%s-%s" % (sub_id, sub_slug), rel)] = content

    if dry_run:
        print("new-plan: dry-run master — would create %s + sub 01-%s" % (master_dir, sub_slug), file=sys.stderr)
        print(json.dumps({"mode": "master", "master_slug": master_slug,
                          "first_sub": "%s-%s" % (sub_id, sub_slug), "files": sorted(files)}))
        sys.exit(0)
    write_atomic(master_dir, files)
    # RULING 2: render the SUB's tasks.md (the sub carries real tasks). The master's tasks.md is
    # a hand-owned rollup with NO sentinels — tasks-render detect-and-skips a master (184/03), so
    # the master is intentionally NOT delegated here.
    delegate_render(sub_plan_dir)
    print("new-plan: created master %s + first sub 01-%s" % (master_slug, sub_slug), file=sys.stderr)
    print(json.dumps({"mode": "master", "master_slug": master_slug,
                      "first_sub": "%s-%s" % (sub_id, sub_slug), "master_dir": master_dir}))

elif mode == "add-subplan":
    # SLUG is the existing master NN-slug here.
    master_slug = slug
    if not PLAN_DIR_RE.match(master_slug):
        abort("--add-subplan <master> must be an existing NN-slug dir, got '%s'" % master_slug)
    check_slug(sub_slug, "sub slug")
    master_dir = os.path.join(plans_root, master_slug)
    master_manifest_path = os.path.join(master_dir, "manifest.json")
    if not os.path.isdir(master_dir):
        abort("master plan dir not found: %s" % master_dir)
    if not os.path.isfile(master_manifest_path):
        abort("master manifest not found: %s" % master_manifest_path)
    with open(master_manifest_path, encoding="utf-8") as fh:
        master = json.load(fh)
    if master.get("type") != "master":
        abort("target manifest type is '%s', expected 'master' (use --master to create one)" % master.get("type"))

    # The new sub-plan inherits the master's owning-spoke key (same project; the
    # cwd-resolved key is for fresh-tree creation, not for joining an existing
    # lineage). Fall back to the cwd-resolved spoke_key if the master predates
    # the field-triad migration.
    spoke_key = master.get("project") or spoke_key

    existing = master.get("sub_plans", []) or []
    # next sub_plan_id = execution-order ordinal (not creation order; here = max+1)
    used_ids = [int(sp["sub_plan_id"]) for sp in existing if str(sp.get("sub_plan_id", "")).isdigit()]
    # also account for any NN- dirs already on disk
    for entry in os.listdir(master_dir):
        m = re.match(r"^([0-9]{2,})-", entry)
        if m and os.path.isdir(os.path.join(master_dir, entry)):
            used_ids.append(int(m.group(1)))
    sub_id = "%02d" % ((max(used_ids) + 1) if used_ids else 1)

    # collision: same sub-slug already present under the master?
    for entry in os.listdir(master_dir):
        if re.sub(r"^[0-9]{2,}-", "", entry) == sub_slug and os.path.isdir(os.path.join(master_dir, entry)):
            abort("sub-slug collision under master: %s already exists" % entry)

    sub_plan_dir = os.path.join(master_dir, "%s-%s" % (sub_id, sub_slug))
    if os.path.exists(sub_plan_dir):
        abort("target sub-plan dir already exists: %s" % sub_plan_dir)

    s_title = sub_title_override.strip() or title_case(sub_slug)
    sub_files = render_sub_quartet(s_title, master_slug, sub_id, sub_plan_dir, scaffold_brief=False)

    if dry_run:
        print("new-plan: dry-run add-subplan — would create %s and register sub_plans[] entry %s"
              % (sub_plan_dir, sub_id), file=sys.stderr)
        print(json.dumps({"mode": "add-subplan", "master_slug": master_slug,
                          "sub_plan_id": sub_id, "sub_slug": sub_slug, "files": sorted(sub_files)}))
        sys.exit(0)

    # write the sub-plan quartet (rollback-safe within the new sub dir)
    write_atomic(sub_plan_dir, sub_files)
    delegate_render(sub_plan_dir)  # RULING 2: renderer fills the new sub's empty sentinel region

    # register the new sub-plan in the master's sub_plans[] aggregate SKELETON.
    # The librarian reconciler does the pull-based status fill; the
    # scaffolder writes only the skeleton entry (status seed = planned).
    skeleton = {"sub_plan_id": sub_id, "slug": sub_slug, "status": "planned", "graduation_timestamp": None}
    master.setdefault("sub_plans", [])
    master["sub_plans"].append(skeleton)
    tmp = master_manifest_path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(master, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, master_manifest_path)

    print("new-plan: added sub-plan %s-%s to master %s (registered in sub_plans[])"
          % (sub_id, sub_slug, master_slug), file=sys.stderr)
    print(json.dumps({"mode": "add-subplan", "master_slug": master_slug,
                      "sub_plan_id": sub_id, "sub_slug": sub_slug, "sub_plan_dir": sub_plan_dir}))
PY

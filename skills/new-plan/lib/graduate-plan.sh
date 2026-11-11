#!/bin/bash
# graduate-plan.sh — turn a flat plan into a master plan whose first sub-plan is the flat
# plan's own content, in one locked pass.
#
#   graduate-plan.sh <flat-NN-slug> <sub-slug> [--dry-run]
#                                   (reached as: new-plan.sh --graduate <flat-NN-slug> --sub <sub-slug> [--dry-run])
#
# The plan directory keeps its name and its number. Its whole content, every entry and
# dotfile, moves into 01-<sub-slug>/; the directory then holds exactly the master quartet
# (spec.md, tasks.md, handoff.md, manifest.json, rendered from the master templates) and
# 01-<sub-slug>/. The sub-plan manifest and the frontmatter lines of the moved spec.md,
# tasks.md, handoff.md and 00-ideation-brief.md are rewritten; no other byte of any moved
# file changes. Graduation changes structure, never lifecycle state.
#
# Validation (read-only, in this order, stopping at the first refusal; each refusal prints
# `new-plan: aborted — <reason>` and exits 1 with the plans tree untouched): the name shape,
# a stale `.graduate-<NN-slug>` stage, the directory (not a symlink), a parseable manifest,
# a flat plan (type plan, no sub_plans and no parent_plan), a plan that is not terminal, a
# plan that is not armed, the sub slug (the scaffolder's slug rules), no numbered entry
# inside the plan, the four master templates, and both rewritten manifests against
# plan-manifest-schema.json (the master first). --dry-run runs the same checks, takes no
# lock and writes nothing.
#
# Lock and write: a blocking exclusive flock(2) on the plans-root directory fd, the lock the
# flat and master mints take, taken before the first check and held to the exit, so a second
# graduate validates against the restructured tree and a concurrent mint never lists a plans
# root that is missing this plan's number. No lock file. The plan directory is renamed to a
# `.graduate-<NN-slug>` stage (the leading dot makes numbering and the collision check skip
# it), the master directory is made by mkdir with the old directory's mode, the stage is
# renamed under it as 01-<sub-slug>, then every rewritten file is written as a temp file plus
# os.replace: the sub files in the order manifest.json, tasks.md, handoff.md,
# 00-ideation-brief.md, spec.md, then the master files in the order spec.md, tasks.md,
# handoff.md, manifest.json. A failure at any step undoes every completed step in reverse,
# restoring the held original bytes and modes, and exits 1 with `graduate failed at <step>
# (<error>); rolled back, the plan dir is as it was` (step: stage, nest, sub-write or
# master-write).
#
# Derivations: after a restructure that committed, never on a dry run or after a rollback, and
# once the lock is released, lib/after-write.sh plan_after_write runs for the master manifest and
# then for the first sub-plan's manifest, with the plans root exported as PLANS_ROOT and
# PLANS_DIR. A missing hook, or one that exits non-zero, prints a NOTE and never fails the
# command. No other hook runs, and the backlog is never written: the last stderr line is
# `new-plan: next: /librarian backlog-index (re-renders the backlog row for <NN-slug>)`.
#
# Output: stdout one JSON line, stderr the human lines (a NOTE per skipped or failing
# derivation, then the next: line). Exit 0 done or a dry run, 1 aborted, 2 usage (also:
# plan-manifest-schema.json not found, before any write).
#
# Env: PLANS_ROOT, else PLANS_DIR, else $HOME/.claude-plans (the plans root).
#      TEMPLATES_DIR (default: the skill's own templates/). PLAN_MANIFEST_SCHEMA (default:
#      <claude-home>/schemas/plan-manifest-schema.json). CLAUDE_HOME (default $HOME/.claude):
#      the install root of the armed-plan resolver.
#
# Bash 3.2 clean (R-23). Data reaches python3 through argv (R-24), never a piped stdin.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"
SUB="${2:-}"
DRY="false"
if [[ "${3:-}" == "--dry-run" ]]; then DRY="true"; fi
if [[ -z "$ARG" ]]; then
  echo "new-plan: missing <slug> (see --help)" >&2
  exit 2
fi

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
CH="${CLAUDE_HOME:-$HOME/.claude}"
SCHEMA="${PLAN_MANIFEST_SCHEMA:-$CH/schemas/plan-manifest-schema.json}"
if [[ ! -f "$SCHEMA" ]]; then
  echo "new-plan: plan-manifest-schema not found: $SCHEMA" >&2
  exit 2
fi
TMPL_DIR="${TEMPLATES_DIR:-$(cd "$LIB_DIR/.." && pwd)/templates}"

PLAN_COMMON_DIR="$LIB_DIR" PYTHONDONTWRITEBYTECODE=1 \
python3 - "$ARG" "$SUB" "$DRY" "$PLANS_ROOT" "$TMPL_DIR" "$CH/hooks/lib/active-plan-resolve.sh" "$SCHEMA" <<'PY'
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import date

sys.path.insert(0, os.environ["PLAN_COMMON_DIR"])
from plan_common import cohort_base, fm_quote_titles, q, render

arg, sub_slug, dry_run, plans_root, tmpl_dir, resolver, schema_path = sys.argv[1:8]
dry_run = dry_run == "true"
today = date.today().isoformat()

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$")
SHAME_RE = re.compile(r"^[a-z]+-[a-z]+ing-[a-z]+$")  # adjective-gerund-noun auto-slug
PLAN_DIR_RE = re.compile(r"^[0-9]{2,}-[a-z][a-z0-9-]+$")
NUMBERED_RE = re.compile(r"^[0-9]{2,}-")
TERMINAL = {
    "completed",
    "superseded",
}
MASTER_TEMPLATES = ("master-spec.md.tmpl", "master-tasks.md.tmpl", "master-handoff.md.tmpl",
                    "master-manifest.json.tmpl")
SUB_ORDER = ("manifest.json", "tasks.md", "handoff.md", "00-ideation-brief.md", "spec.md")
MASTER_ORDER = ("spec.md", "tasks.md", "handoff.md", "manifest.json")
ID_SUFFIX = {"spec.md": "spec", "tasks.md": "tasks", "handoff.md": "handoff",
             "00-ideation-brief.md": "ideation-brief"}


def abort(msg):
    print("new-plan: aborted — %s" % msg, file=sys.stderr)
    sys.exit(1)


def title_case(s):
    return s.replace("-", " ").title()


# --- the --master renderer helpers: render, cohort_base, q and fm_quote_titles come from plan_common;
# --- tmpl stays here because it closes over this script's template directory and abort
def tmpl(name):
    p = os.path.join(tmpl_dir, name)
    if not os.path.isfile(p):
        abort("template missing: %s" % p)
    with open(p, encoding="utf-8") as fh:
        return fh.read()


# --- lock: the plans-root directory fd, before the first check, held to the exit ---------------
if not dry_run and os.path.isdir(plans_root):
    lock_fd = os.open(plans_root, os.O_RDONLY)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

# --- validation, read-only -----------------------------------------------------------------
if not PLAN_DIR_RE.match(arg):
    abort("invalid plan dir name '%s' (expected NN-slug)" % arg)
stage = os.path.join(plans_root, ".graduate-" + arg)
if os.path.lexists(stage):
    abort("stale graduate stage exists: %s (a previous run was interrupted; "
          "the plan's content is inside it)" % stage)
plan_dir = os.path.join(plans_root, arg)
if os.path.islink(plan_dir):
    abort("plan dir is a symlink: %s" % plan_dir)
if not os.path.isdir(plan_dir):
    abort("plan dir not found: %s" % plan_dir)
manifest_path = os.path.join(plan_dir, "manifest.json")
if not os.path.isfile(manifest_path):
    abort("manifest not found: %s" % manifest_path)
try:
    with open(manifest_path, encoding="utf-8") as fh:
        flat = json.load(fh)
    if not isinstance(flat, dict):
        raise ValueError("not an object")
except Exception:
    abort("manifest unparseable: %s" % manifest_path)
if flat.get("type") != "plan":
    abort("plan type is '%s', expected 'plan' (only a flat plan graduates)" % flat.get("type"))
if "sub_plans" in flat or "parent_plan" in flat:
    abort("plan already carries sub_plans[] or parent_plan; it is not a flat plan")
status = flat.get("status")
if status in TERMINAL:
    abort("plan status is '%s': a terminal plan is a closed record and does not graduate" % status)
project = flat.get("project") or ""
if not os.path.isfile(resolver):
    abort("armed-plan resolver not found: %s" % resolver)
armed = subprocess.run(["bash", "-c", '. "$1"; resolve_active_plan_for_spoke "$2" "$3"', "armed-check",
                        resolver, plans_root, project], stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode("utf-8", "replace").strip()
if armed == arg:
    abort("plan %s is armed for spoke '%s'; disarm it before graduating" % (arg, project))
if not SLUG_RE.match(sub_slug):
    abort("invalid sub slug shape '%s' (lowercase alphanumeric + hyphens, no leading/trailing/double hyphen)" % sub_slug)
if not (3 <= len(sub_slug) <= 60):
    abort("sub slug '%s' length out of range (3..60)" % sub_slug)
if SHAME_RE.match(sub_slug):
    abort("sub slug '%s' matches the shame-slug pattern (adjective-gerund-noun). "
          "Provide a descriptive slug." % sub_slug)
entries = sorted(os.listdir(plan_dir))
for entry in entries:
    if NUMBERED_RE.match(entry) and os.path.isdir(os.path.join(plan_dir, entry)):
        abort("plan dir holds the numbered entry '%s'; a flat plan must hold none" % entry)
for name in MASTER_TEMPLATES:
    if not os.path.isfile(os.path.join(tmpl_dir, name)):
        abort("template missing: %s" % os.path.join(tmpl_dir, name))

# --- build both rewritten manifests and every rewritten file, in memory --------------------------
base_slug = re.sub(r"^[0-9]+-", "", arg)
sub_dir_name = "01-%s" % sub_slug
sub_dir = os.path.join(plan_dir, sub_dir_name)
title = flat.get("title") if isinstance(flat.get("title"), str) and flat.get("title") else title_case(base_slug)

m_kw = dict(title=title, date=today, plan_dir=plan_dir, spoke_key=project, first_sub_slug=sub_slug,
            slug=base_slug, cohort_base=cohort_base(plan_dir))
master_md = {
    "spec.md": render(tmpl("master-spec.md.tmpl"), **m_kw),
    "tasks.md": render(tmpl("master-tasks.md.tmpl"), **m_kw),
    "handoff.md": render(tmpl("master-handoff.md.tmpl"), **m_kw),
}
master_md = dict((rel, fm_quote_titles(text)) for rel, text in master_md.items())
# the template's one rollup row hardcodes the first status; the row carries the flat plan's status
seed_row = "| 01 | `01-%s` | " % sub_slug
master_md["tasks.md"] = "\n".join(
    (seed_row + "%s |" % status) if ln.startswith(seed_row) and ln.endswith(" |") else ln
    for ln in master_md["tasks.md"].split("\n"))
master = json.loads(render(tmpl("master-manifest.json.tmpl"),
                           **dict(m_kw, title=json.dumps(title, ensure_ascii=False)[1:-1])))
master["status"] = status
for key in ("paused_reason", "disposition", "promoted_from", "absorbed_notes", "phase_2_scaffolded_at"):
    if key in flat:
        master[key] = flat[key]
master["sub_plans"] = [{"sub_plan_id": "01", "slug": sub_dir_name, "status": status, "graduation_timestamp": None}]
master["updated"] = today


def repoint(value):
    """A string that is the old plan directory, or starts with it plus '/', moves under the sub
    directory; every other value (outside the directory, a sibling-prefix, a relative path) stays."""
    if isinstance(value, str):
        if value == plan_dir or value.startswith(plan_dir + "/"):
            return plan_dir + "/" + sub_dir_name + value[len(plan_dir):]
        return value
    if isinstance(value, list):
        return [repoint(x) for x in value]
    if isinstance(value, dict):
        return dict((k, repoint(x)) for k, x in value.items())
    return value


sub = {}
for key, value in flat.items():
    if key == "type":
        sub["type"] = "sub-plan"
        sub["parent_plan"] = arg
        sub["sub_plan_id"] = "01"
    else:
        sub[key] = repoint(value)
sub["updated"] = today

schema = None
with open(schema_path, encoding="utf-8") as fh:
    schema = json.load(fh)


def check_schema(label, manifest):
    try:
        import jsonschema  # type: ignore
    except ImportError:
        jsonschema = None
    if jsonschema is not None:
        try:
            jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(manifest)
        except Exception as exc:
            abort("the rewritten %s manifest fails plan-manifest-schema: %s"
                  % (label, (str(exc).splitlines() or ["schema-invalid"])[0]))
        return
    need = list(schema.get("required", []))
    for clause in schema.get("allOf", []):
        const = ((clause.get("if") or {}).get("properties") or {}).get("type", {}).get("const")
        if const is not None and const == manifest.get("type"):
            need += list((clause.get("then") or {}).get("required", []))
    for key in need:
        if key not in manifest:
            abort("the rewritten %s manifest fails plan-manifest-schema: '%s' is a required property"
                  % (label, key))


check_schema("master", master)
check_schema("sub", sub)

old_base = cohort_base(plan_dir)
sub_base = cohort_base(sub_dir)


def rewrite_md(name, text):
    lines = text.split("\n")
    if lines and lines[0] == "---":
        end = None
        for i, line in enumerate(lines[1:], start=1):
            if line == "---":
                end = i
                break
        if end is not None:
            fm = lines[1:end]
            old_id = "id: %s-%s" % (old_base, ID_SUFFIX[name])
            fm = [("id: %s-%s" % (sub_base, ID_SUFFIX[name])) if ln == old_id else ln for ln in fm]
            if name in ("spec.md", "tasks.md") and not any(ln.startswith("parent_plan:") for ln in fm):
                at = len(fm)
                for i, ln in enumerate(fm):
                    if ln.startswith("description:"):
                        at = i + 1
                fm.insert(at, "parent_plan: %s" % arg)
            lines = ["---"] + fm + lines[end:]
    if name == "tasks.md":
        old_ref, new_ref = "`%s/spec.md`" % plan_dir, "`%s/spec.md`" % sub_dir
        lines = [ln.replace(old_ref, new_ref) if ln.startswith("**Spec:**") else ln for ln in lines]
    return "\n".join(lines)


def read_raw(path):
    with open(path, "rb") as fh:
        return fh.read()


held = {}     # name -> (original bytes, original mode) of every file the sub-write step rewrites
sub_new = {"manifest.json": (json.dumps(sub, indent=2, ensure_ascii=False) + "\n").encode("utf-8")}
for name in SUB_ORDER:
    path = os.path.join(plan_dir, name)
    if not os.path.isfile(path):
        continue
    held[name] = (read_raw(path), stat.S_IMODE(os.stat(path).st_mode))
    if name != "manifest.json":
        sub_new[name] = rewrite_md(name, held[name][0].decode("utf-8", "surrogateescape")).encode(
            "utf-8", "surrogateescape")
master_new = dict((rel, text.encode("utf-8")) for rel, text in master_md.items())
master_new["manifest.json"] = (json.dumps(master, indent=2, ensure_ascii=False) + "\n").encode("utf-8")

if dry_run:
    print("new-plan: dry-run graduate — would restructure %s (%d entries move under %s)"
          % (plan_dir, len(entries), sub_dir_name), file=sys.stderr)
    print(json.dumps({"mode": "graduate", "master_slug": arg, "sub_plan_dir": sub_dir, "moved": entries},
                     ensure_ascii=False))
    sys.exit(0)

# --- write: stage, nest, sub-write, master-write; any failure undoes every completed step ---------
done = {"staged": False, "made": False, "nested": False, "sub": [], "master": []}


def write_replace(path, data, mode):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def undo():
    problems = []
    for name in reversed(done["master"]):
        try:
            os.unlink(os.path.join(plan_dir, name))
        except Exception as exc:
            problems.append("remove %s: %s" % (name, exc))
    for name in reversed(done["sub"]):
        data, mode = held[name]
        target = os.path.join(sub_dir, name)
        try:
            write_replace(target, data, mode)
        except Exception:
            try:
                with open(target, "wb") as fh:
                    fh.write(data)
                os.chmod(target, mode)
            except Exception as exc:
                problems.append("restore %s: %s" % (name, exc))
    if done["nested"]:
        try:
            os.rename(sub_dir, stage)
        except Exception as exc:
            problems.append("unnest: %s" % exc)
    if done["made"]:
        try:
            os.rmdir(plan_dir)
        except Exception as exc:
            problems.append("remove the master dir: %s" % exc)
    if done["staged"]:
        try:
            os.rename(stage, plan_dir)
        except Exception as exc:
            problems.append("restore the plan dir: %s" % exc)
    return problems


step = "stage"
try:
    old_mode = stat.S_IMODE(os.stat(plan_dir).st_mode)
    os.rename(plan_dir, stage)
    done["staged"] = True
    step = "nest"
    os.mkdir(plan_dir)
    done["made"] = True
    os.chmod(plan_dir, old_mode)
    os.rename(stage, sub_dir)
    done["nested"] = True
    step = "sub-write"
    for name in SUB_ORDER:
        if name in sub_new:
            write_replace(os.path.join(sub_dir, name), sub_new[name], held[name][1] if name in held else 0o644)
            done["sub"].append(name)
    step = "master-write"
    for name in MASTER_ORDER:
        write_replace(os.path.join(plan_dir, name), master_new[name], 0o644)
        done["master"].append(name)
except Exception as exc:
    problems = undo()
    if problems:
        abort("graduate failed at %s (%s); rollback incomplete (%s): the plan content is under %s or %s"
              % (step, exc, "; ".join(problems), stage, sub_dir))
    abort("graduate failed at %s (%s); rolled back, the plan dir is as it was" % (step, exc))

print("new-plan: graduated %s — now a master with first sub %s" % (arg, sub_dir_name), file=sys.stderr)
print(json.dumps({"mode": "graduate", "master_slug": arg, "sub_plan_id": "01", "sub_slug": sub_slug,
                  "master_dir": plan_dir, "sub_plan_dir": sub_dir}, ensure_ascii=False))
PY

# The python process has exited: the restructure committed (a failure exited above under set -e)
# and the plans-root lock is released. A dry run changed nothing, so nothing derives.
if [[ "$DRY" != "true" ]]; then
  # shellcheck source=after-write.sh
  . "$LIB_DIR/after-write.sh"
  plan_after_write "$PLANS_ROOT/$ARG/manifest.json"
  plan_after_write "$PLANS_ROOT/$ARG/01-$SUB/manifest.json"
  echo "new-plan: next: /librarian backlog-index (re-renders the backlog row for $ARG)" >&2
fi

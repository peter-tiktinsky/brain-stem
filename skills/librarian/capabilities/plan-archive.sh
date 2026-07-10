#!/bin/bash
# plan-archive — Promote closed plans to archived; append to
# <plans-root>/_archive.md. Librarian reader cap with the master-subtree
# archival gate.
# Librarian reader cap (1.1 line 127). Ported from the
# plan-archive.sh with the
# MASTER-SUBTREE ARCHIVAL GATE added: a master plan is archive-eligible only
# when EVERY entry in its sub_plans[] read-replica (READ from the aggregate
# subplan-aggregate.sh / populates) is in a terminal status
# (verified/closed/archived/superseded). A master with any non-terminal sub is
# held back even if its own status is closed.
# Two-axis trigger: eligibility is event-driven (manifest status == closed);
# promotion is gated by a data-driven cooldown (plans-rules.json
# lifecycle.status_transitions.closed_to_archived.cooldown_days; default 3).
# Output Contract
#   Files written: <plans-root>/_archive.md (append quarterly row) + the
#     promoted manifest's status flip (closed -> archived); findings to stdout
#     (NDJSON via hooks/lib/findings.sh shape) or $FINDINGS_OUTPUT.
#   Schema gate: each manifest validates against plan-manifest-schema.json.
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Idempotent (keyed by plan_slug + closed_at).
# Finding categories:
#   archive-eligible-plan (event) | archive-row-malformed | manifest-schema-violation
#   | master-subtree-incomplete (master held back; not all subs terminal)
# CLI:
#   plan-archive.sh                       # sweep all plans
#   plan-archive.sh --plan-slug <slug>    # scope to a single plan
#   plan-archive.sh --dry-run             # compute + emit findings; no write
#   plan-archive.sh --help
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   ARCHIVE_FILE             output file (default: $PLANS_ROOT/_archive.md)
#   PLANS_RULES_PATH         plans-rules.json (default: foundation -> live)
#   PLAN_MANIFEST_SCHEMA     plan-manifest-schema.json (default: foundation -> live)
#   PLAN_ARCHIVE_TODAY       override "today" (YYYY-MM-DD) for deterministic tests
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#   FOUNDATION_TEST_MODE     bypass the non-interactive guard
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

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

DRY_RUN="false"
PLAN_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --plan-slug) PLAN_SLUG="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "plan-archive: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "plan-archive: skipped (non-interactive)" >&2
  exit 0
fi

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "plan-archive: PLANS_ROOT does not exist: $PLANS_ROOT" >&2
  exit 0
fi

ARCHIVE_FILE="${ARCHIVE_FILE:-$PLANS_ROOT/_archive.md}"

RULES_PATH="${PLANS_RULES_PATH:-}"
if [[ -z "$RULES_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/governance/plans-rules.json"; do
    if [[ -f "$candidate" ]]; then RULES_PATH="$candidate"; break; fi
  done
fi
# install.sh Step 8.5 keeps the 7 loose pillars unshipped). A clean adopter ships ONLY the
# two bundles (foundation-master + overlay-master), which governance consumers read as ONE
# merged view via hooks/lib/foundation-overlay-load.sh (the R-52 union-load primitive —
# overlay overlaid on foundation). When the loose pillar is absent, resolve the EFFECTIVE
# `.plans` slot through that merger (--force-override = read posture per pre-write-guard:91
# "every hook-side read passes the flag") so the cap reads the REAL register instead of
# hard-exiting on a clean install.
if [[ -z "$RULES_PATH" || ! -f "$RULES_PATH" ]]; then
  for _loader in \
    "$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh" \
    "$_REPO_LIB/foundation-overlay-load.sh"; do
    [[ -x "$_loader" ]] || continue
    _rt="$(mktemp 2>/dev/null)" || break
    if bash "$_loader" --query '.plans' --force-override > "$_rt" 2>/dev/null \
         && [[ -s "$_rt" ]] && [[ "$(head -c4 "$_rt" 2>/dev/null)" != null ]]; then
      RULES_PATH="$_rt"; trap 'rm -f "$_rt"' EXIT; break
    fi
    rm -f "$_rt"
  done
fi
if [[ -z "$RULES_PATH" || ! -f "$RULES_PATH" ]]; then
  echo "plan-archive: plans-rules.json not found and no foundation-master+overlay bundle (set PLANS_RULES_PATH)" >&2
  exit 1
fi

SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/schemas/plan-manifest-schema.json"; do
    if [[ -f "$candidate" ]]; then SCHEMA_PATH="$candidate"; break; fi
  done
fi

python3 - "$PLANS_ROOT" "$DRY_RUN" "$RULES_PATH" "$SCHEMA_PATH" "$ARCHIVE_FILE" "$PLAN_SLUG" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root = sys.argv[1]
dry_run = sys.argv[2] == "true"
rules_path = sys.argv[3]
schema_path = sys.argv[4]
archive_file = sys.argv[5]
only_slug = sys.argv[6]

today_str = os.environ.get("PLAN_ARCHIVE_TODAY", date.today().isoformat())
try:
    today = date.fromisoformat(today_str)
except ValueError:
    today = date.today()

with open(rules_path, encoding="utf-8") as fh:
    rules = json.load(fh)
cooldown_days = (rules.get("lifecycle", {}).get("status_transitions", {})
                 .get("closed_to_archived", {}).get("cooldown_days", 3))

TERMINAL = {"verified", "closed", "archived", "superseded"}

validator = None
if schema_path and os.path.isfile(schema_path):
    try:
        import jsonschema  # type: ignore
        with open(schema_path, encoding="utf-8") as fh:
            _schema = json.load(fh)
        validator = jsonschema.Draft202012Validator(_schema)
    except Exception:
        validator = None

def manifest_valid(m):
    for req in ("schema_version", "project", "spec_path"):
        if req not in m:
            return False
    if validator is not None:
        try:
            validator.validate(m)
        except Exception:
            return False
    return True

def emit(d):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(d, separators=(", ", ": "), sort_keys=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        print(line)

def cell(value):
    s = "" if value is None else str(value)
    return s.replace("\r", " ").replace("\n", " ").replace("|", "\\|").strip()

def _atomic_json(path, obj):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

def quarter_of(iso_date):
    d = date.fromisoformat(iso_date)
    return "%d-Q%d" % (d.year, (d.month - 1) // 3 + 1)

ARCHIVE_HEADER = "| Plan | Closed | Archived | Outcome | Shipped | Postmortem | Successor |"
ARCHIVE_SEP = "|---|---|---|---|---|---|---|"

def row_already_present(content, slug, closed_at):
    for line in content.split("\n"):
        if not line.strip().startswith("|"):
            continue
        cols = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cols) >= 2 and cols[0] == slug and cols[1] == closed_at:
            return True
    return False

def insert_row(content, quarter, row):
    lines = content.split("\n")
    target = "## " + quarter
    sec_idx = next((i for i, l in enumerate(lines) if l.strip() == target), None)
    if sec_idx is None:
        block = ["", target, "", ARCHIVE_HEADER, ARCHIVE_SEP, row]
        return content.rstrip("\n") + "\n" + "\n".join(block) + "\n"
    end = len(lines)
    for j in range(sec_idx + 1, len(lines)):
        if lines[j].startswith("## "):
            end = j
            break
    last_row = None
    has_header = False
    for j in range(sec_idx + 1, end):
        if lines[j].strip().startswith("|"):
            if lines[j].strip() == ARCHIVE_HEADER:
                has_header = True
            last_row = j
    if last_row is None or not has_header:
        lines[sec_idx + 1:sec_idx + 1] = ["", ARCHIVE_HEADER, ARCHIVE_SEP, row]
    else:
        lines[last_row + 1:last_row + 1] = [row]
    return "\n".join(lines)

def master_subtree_complete(manifest):
    """master-subtree gate: True iff not a master, or every sub_plans[]
    entry is terminal. Returns (eligible_bool, incomplete_subs[])."""
    subs = manifest.get("sub_plans")
    is_master = (manifest.get("type") == "master") or isinstance(subs, list)
    if not is_master or not isinstance(subs, list):
        return True, []
    incomplete = [sp.get("slug") or sp.get("sub_plan_id")
                  for sp in subs if isinstance(sp, dict) and sp.get("status") not in TERMINAL]
    return (len(incomplete) == 0), incomplete

if only_slug:
    candidates = [only_slug] if os.path.isdir(os.path.join(plans_root, only_slug)) else []
else:
    candidates = sorted(e for e in os.listdir(plans_root)
                        if not e.startswith(".") and not e.startswith("_")
                        and os.path.isdir(os.path.join(plans_root, e)) and e != "Logs")

archived_count = 0
for slug in candidates:
    manifest_path = os.path.join(plans_root, slug, "manifest.json")
    if not os.path.isfile(manifest_path):
        continue
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, json.JSONDecodeError):
        emit({"finding": "manifest-schema-violation", "file": slug, "plan_slug": slug,
              "validation_error_or_missing_fields": "unparseable JSON",
              "detected_at": today_str, "first_seen": today_str})
        continue
    if not manifest_valid(manifest):
        emit({"finding": "manifest-schema-violation", "file": slug, "plan_slug": slug,
              "validation_error_or_missing_fields": "fails plan-manifest-schema",
              "detected_at": today_str, "first_seen": today_str})
        continue
    if str(manifest.get("status", "")).strip() != "closed":
        continue

    # master-subtree gate.
    eligible, incomplete = master_subtree_complete(manifest)
    if not eligible:
        emit({"finding": "master-subtree-incomplete", "file": slug, "plan_slug": slug,
              "non_terminal_subs": incomplete, "detected_at": today_str, "first_seen": today_str})
        continue

    closed_at = str(manifest.get("closed_at", "")).strip()
    missing = [f for f in ("closed_at", "outcome_summary", "shipped_artifacts")
               if not manifest.get(f)]
    if missing:
        emit({"finding": "manifest-schema-violation", "file": slug, "plan_slug": slug,
              "validation_error_or_missing_fields": "missing required-on-close: %s" % ",".join(missing),
              "detected_at": today_str, "first_seen": today_str})
        continue
    try:
        eligibility = date.fromisoformat(closed_at)
    except ValueError:
        emit({"finding": "manifest-schema-violation", "file": slug, "plan_slug": slug,
              "validation_error_or_missing_fields": "closed_at not ISO date: %s" % closed_at,
              "detected_at": today_str, "first_seen": today_str})
        continue
    if (today - eligibility).days < cooldown_days:
        continue

    shipped = manifest.get("shipped_artifacts", [])
    shipped_str = "<br>".join(str(s) for s in shipped) if isinstance(shipped, list) else str(shipped)
    outcome = manifest.get("outcome_summary", "")
    superseded_by = manifest.get("superseded_by")
    if superseded_by:
        outcome = "[superseded by %s] %s" % (superseded_by, outcome)
    row = "| %s | %s | %s | %s | %s | %s | %s |" % (
        cell(slug), cell(closed_at), cell(today_str), cell(outcome),
        cell(shipped_str), cell(manifest.get("postmortem_path") or "—"),
        cell(manifest.get("successor") or "—"))
    if len(re.split(r'(?<!\\)\|', row.strip())) - 2 != 7:
        emit({"finding": "archive-row-malformed", "file": slug, "plan_slug": slug,
              "malformed_field": "column-count", "manifest_value": row,
              "detected_at": today_str, "first_seen": today_str})
        continue

    quarter = quarter_of(closed_at)
    if os.path.isfile(archive_file):
        with open(archive_file, encoding="utf-8") as fh:
            archive = fh.read()
    else:
        archive = "# Plan Archive\n\nQuarterly retrospective of archived plans (librarian:plan-archive owns this file).\n"
    if row_already_present(archive, slug, closed_at):
        if not dry_run and str(manifest.get("status")) == "closed":
            manifest["status"] = "archived"
            _atomic_json(manifest_path, manifest)
        continue

    new_archive = insert_row(archive, quarter, row)
    if not new_archive.endswith("\n"):
        new_archive += "\n"

    if not dry_run:
        d = os.path.dirname(archive_file) or "."
        fd, tmp = tempfile.mkstemp(dir=d, prefix="._archive.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(new_archive)
            os.replace(tmp, archive_file)
        except Exception:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        with open(manifest_path, encoding="utf-8") as fh:
            fresh = json.load(fh)
        fresh["status"] = "archived"
        if manifest_valid(fresh):
            _atomic_json(manifest_path, fresh)
        else:
            print("plan-archive: post-flip manifest invalid; skipping flip: %s" % slug, file=sys.stderr)

    archived_count += 1
    emit({"finding": "archive-eligible-plan", "file": slug, "plan_slug": slug,
          "closed_at": closed_at, "archived_at": today_str,
          "archive_row_quarter": quarter, "dry_run": dry_run, "detected_at": today_str})

if dry_run:
    print("plan-archive: dry-run (root=%s) archived=%d" % (plans_root, archived_count), file=sys.stderr)
PY

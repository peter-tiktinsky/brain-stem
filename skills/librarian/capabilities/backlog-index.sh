#!/bin/bash
# backlog-index — Regenerate <plans-root>/_backlog.md from plan manifests as a
# manifest-derived read-replica. Librarian reader cap with the master-row
# policy + satellite-pointer retarget.
# Librarian reader cap (1.1 line 126). Ported from the
# backlog-index.sh with two
# additions:
#   (1) MASTER-ROW POLICY: when a master plan with sub_plans[] is in the
#       backlog, render only the MASTER row (its rollup READ from the
#       sub_plans[] aggregate that subplan-aggregate.sh / populates);
#       sub-plan dirs do not get their own backlog rows.
#   (2) SATELLITE-POINTER RETARGET: the per-row session-history
#       pointer is the plan dir / master handoff.md — NOT the retired
#       /<slug>.md satellite.
#       The Notes cell is carried forward verbatim (the row sentinel pattern).
# Output Contract
#   Files written: <plans-root>/_backlog.md (sentinel-bounded table region;
#     operator narrative + per-row Notes preserved); findings to stdout (NDJSON
#     via hooks/lib/findings.sh shape) or $FINDINGS_OUTPUT.
#   Schema gate: each manifest validates against plan-manifest-schema.json
#     (jsonschema when available; structural fallback).
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Idempotent.
# Finding categories:
#   backlog-row-missing-disposition | manifest-status-orphan | slug-violation
#   | backlog-regenerated (event)
# CLI:
#   backlog-index.sh                 # regenerate _backlog.md + emit findings
#   backlog-index.sh --dry-run       # compute + emit findings + summary; no write
#   backlog-index.sh --help
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   BACKLOG_FILE             output file (default: $PLANS_ROOT/_backlog.md)
#   PLANS_RULES_PATH         plans-rules.json (default: foundation -> live)
#   PLAN_MANIFEST_SCHEMA     plan-manifest-schema.json (default: foundation -> live)
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "backlog-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "backlog-index: skipped (non-interactive)" >&2
  exit 0
fi

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "backlog-index: PLANS_ROOT does not exist: $PLANS_ROOT" >&2
  exit 0
fi

BACKLOG_FILE="${BACKLOG_FILE:-$PLANS_ROOT/_backlog.md}"

RULES_PATH="${PLANS_RULES_PATH:-}"
if [[ -z "$RULES_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/governance/plans-rules.json"; do
    if [[ -f "$candidate" ]]; then RULES_PATH="$candidate"; break; fi
  done
fi
# master-fallback (R4 / H-6): plans-rules.json is repo-only (
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
  echo "backlog-index: plans-rules.json not found and no foundation-master+overlay bundle (set PLANS_RULES_PATH)" >&2
  exit 1
fi

SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/schemas/plan-manifest-schema.json"; do
    if [[ -f "$candidate" ]]; then SCHEMA_PATH="$candidate"; break; fi
  done
fi

python3 - "$PLANS_ROOT" "$DRY_RUN" "$RULES_PATH" "$SCHEMA_PATH" "$BACKLOG_FILE" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root = sys.argv[1]
dry_run = sys.argv[2] == "true"
rules_path = sys.argv[3]
schema_path = sys.argv[4]
backlog_file = sys.argv[5]
today = date.today().isoformat()

SENTINEL_START = "<!-- backlog:start -->"
SENTINEL_END = "<!-- backlog:end -->"

with open(rules_path, encoding="utf-8") as fh:
    rules = json.load(fh)
backlog_row = rules.get("backlog_row", {})
disposition_enum = backlog_row.get("disposition_enum",
                                   ["FIX NOW", "ABSORB", "STANDALONE", "DEFERRED"])
slug_pattern = rules.get("slug_rules", {}).get("pattern", r"^[0-9]{2,}-[a-z][a-z0-9-]+$")
slug_re = re.compile(slug_pattern)
# single-SoT: the plan-status validation vocabulary is derived from the
# CANONICAL SoT — schemas/plan-manifest-schema.json :: properties.status.enum
# (9-state, INCLUDES `superseded`). governance/plans-rules.json ::
# lifecycle.status_enum is an 8-state SUBSET (it factors `superseded` out into
# the sibling terminal_from_any_non_archived key) and is NO LONGER read as the
# validation authority here — reading it false-flagged a correctly-`superseded`
# plan as manifest-status-orphan. The hardcoded 9-state list below is a
# schema-absent LAST-RESORT fallback ONLY (defensive), never a second authority.
_STATUS_ENUM_FALLBACK = [
    "researching", "planned", "in-progress", "paused", "completed", "verified",
    "closed", "archived", "superseded"]
lifecycle_enum = None
if schema_path and os.path.isfile(schema_path):
    try:
        with open(schema_path, encoding="utf-8") as fh:
            _status_schema = json.load(fh)
        _status_enum = _status_schema.get("properties", {}).get("status", {}).get("enum")
        if isinstance(_status_enum, list) and _status_enum:
            lifecycle_enum = _status_enum
    except Exception:
        lifecycle_enum = None
if lifecycle_enum is None:
    lifecycle_enum = _STATUS_ENUM_FALLBACK
IN_BACKLOG = ("researching", "planned")

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

# A1 inbox-walk: minimal line-oriented frontmatter parser for the
# _inbox/<slug>.md idea notes (ported adapted from the backlog-index.sh).
_FM_KEY_RE = re.compile(r'^([A-Za-z0-9_-]+):\s*"?(.*?)"?\s*$')

def parse_frontmatter(file_path):
    """Return dict of YAML-ish frontmatter (line-oriented), or None if absent."""
    try:
        with open(file_path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return None
    if not content.startswith("---\n"):
        return None
    end = content.find("\n---\n", 4)
    if end < 0:
        return None
    fm = {}
    for line in content[4:end].split("\n"):
        m = _FM_KEY_RE.match(line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm

# preserve operator narrative + per-row notes.
preface, footer = "", ""
prior_notes = {}
sentinel_existed = False
if os.path.isfile(backlog_file):
    with open(backlog_file, encoding="utf-8") as fh:
        existing = fh.read()
    s_idx = existing.find(SENTINEL_START)
    e_idx = existing.find(SENTINEL_END)
    if s_idx >= 0 and e_idx > s_idx:
        sentinel_existed = True
        preface = existing[:s_idx]
        footer = existing[e_idx + len(SENTINEL_END):]
        region = existing[s_idx + len(SENTINEL_START):e_idx]
        for line in region.split("\n"):
            if not line.strip().startswith("|"):
                continue
            cols = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cols) < 6:
                continue
            m = re.search(r"\[\[([^\]]+)\]\]", cols[1])
            if m:
                prior_notes[m.group(1)] = cols[5]
    else:
        preface = existing
        if preface and not preface.endswith("\n"):
            preface += "\n"
if not sentinel_existed and not preface:
    preface = "# Backlog\n\nManifest-derived read-replica (librarian:backlog-index owns this file).\n\n"

rows = []
rendered = 0
skipped = 0

for entry in sorted(os.listdir(plans_root)):
    if entry.startswith(".") or entry.startswith("_"):
        continue
    plan_dir = os.path.join(plans_root, entry)
    if not os.path.isdir(plan_dir) or entry == "Logs":
        continue
    manifest_path = os.path.join(plan_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        continue
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, json.JSONDecodeError):
        skipped += 1
        print("backlog-index: skipped unparseable manifest: %s" % manifest_path, file=sys.stderr)
        continue
    if not manifest_valid(manifest):
        skipped += 1
        print("backlog-index: skipped schema-invalid manifest: %s" % manifest_path, file=sys.stderr)
        continue

    status = str(manifest.get("status", "")).strip()
    if status and status not in lifecycle_enum:
        emit({"finding": "manifest-status-orphan", "file": entry, "plan_slug": entry,
              "declared_status": status, "valid_statuses": lifecycle_enum,
              "detected_at": today, "first_seen": today})
        skipped += 1
        continue
    if status not in IN_BACKLOG:
        skipped += 1
        continue
    if not slug_re.match(entry):
        emit({"finding": "slug-violation", "file": entry, "plan_slug": entry,
              "pattern_violation_reason": "does not match %s" % slug_pattern,
              "detected_at": today, "first_seen": today})

    title = manifest.get("title") or manifest.get("project") or entry
    updated = manifest.get("updated") or ""
    disposition = str(manifest.get("disposition", "")).strip()
    if disposition not in disposition_enum:
        emit({"finding": "backlog-row-missing-disposition", "file": entry, "plan_slug": entry,
              "current_disposition": disposition or None, "stale_for_days": 0,
              "detected_at": today, "first_seen": today})
        disposition = "MISSING"

    # MASTER-ROW POLICY: a master with sub_plans[] renders one row whose
    # status display is the master's own status; the per-sub rows are NOT
    # rendered (the master carries the rollup). Plain plans render normally.
    is_master = (manifest.get("type") == "master") or isinstance(manifest.get("sub_plans"), list)
    initiative = "[[%s]] %s" % (entry, title)
    if is_master and isinstance(manifest.get("sub_plans"), list):
        initiative += " (master · %d subs)" % len(manifest["sub_plans"])

    # SATELLITE-POINTER RETARGET: the session-history pointer is the plan dir /
    # master handoff.md, NOT/<slug>.md.
    project_dir = entry + "/handoff.md"

    notes = prior_notes.get(entry, "")
    row = "| %s | %s | %s | %s | %s | %s |" % (
        cell(project_dir), cell(initiative), cell(status),
        cell(disposition), cell(updated), cell(notes))
    rows.append((cell(project_dir).lower(), updated, row))
    rendered += 1

# inbox-walk: pre-plan idea notes at
# $PLANS_ROOT/_inbox/<slug>.md render as backlog rows alongside the
# {researching, planned} plan manifests — the unified pickup-able funnel view the
# triage->research skills depend on. Without this block the funnel renders
# nothing for captured ideas (the LOAD-BEARING gap). The row
# pointer is the note itself (_inbox/<slug>.md), NEVER a
# satellite. Slug carries NO NN- prefix (assigned at graduation).
inbox_cfg = rules.get("inbox", {})
inbox_funnel = inbox_cfg.get("funnel_status_enum", ["new", "triaged", "briefed"])
inbox_type = inbox_cfg.get("note_frontmatter", {}).get("type_value", "idea")
inbox_dir = os.path.join(plans_root, "_inbox")
if os.path.isdir(inbox_dir):
    for entry in sorted(os.listdir(inbox_dir)):
        if not entry.endswith(".md"):
            continue
        full = os.path.join(inbox_dir, entry)
        if not os.path.isfile(full):
            continue
        fm = parse_frontmatter(full)
        if fm is None or fm.get("type", "").strip() != inbox_type:
            skipped += 1
            continue
        slug = entry[:-3]
        wikilink = "_inbox/%s" % slug
        status = fm.get("status", "").strip() or "new"
        if status not in inbox_funnel:
            skipped += 1
            print("backlog-index: inbox note '%s' non-funnel status '%s'; skipped"
                  % (entry, status), file=sys.stderr)
            continue
        title = fm.get("title", "") or slug
        updated = fm.get("updated", "") or fm.get("created", "")
        disposition = fm.get("disposition", "").strip() or "MISSING"
        project_dir = "_inbox/%s" % entry
        notes = prior_notes.get(wikilink, "")
        row = "| %s | %s | %s | %s | %s | %s |" % (
            cell(project_dir), cell("[[%s]] %s" % (wikilink, title)),
            cell(status), cell(disposition), cell(updated), cell(notes))
        rows.append((cell(project_dir).lower(), updated, row))
        rendered += 1

rows.sort(key=lambda r: r[1], reverse=True)
rows.sort(key=lambda r: r[0])

table_lines = ["| Project Dir | Initiative | Status | Disposition | Updated | Notes |",
               "|---|---|---|---|---|---|"]
table_lines.extend(r[2] for r in rows)
table_block = SENTINEL_START + "\n" + "\n".join(table_lines) + "\n" + SENTINEL_END

if preface and not preface.endswith("\n"):
    preface += "\n"
if footer and not footer.startswith("\n"):
    footer = "\n" + footer
new_content = preface + table_block + footer
if not new_content.endswith("\n"):
    new_content += "\n"

if not dry_run:
    if SENTINEL_START not in new_content or SENTINEL_END not in new_content:
        print("backlog-index: refusing to write — sentinel markers missing", file=sys.stderr)
        sys.exit(1)
    d = os.path.dirname(backlog_file) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix="._backlog.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new_content)
        os.replace(tmp, backlog_file)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

emit({"finding": "backlog-regenerated", "file": os.path.basename(backlog_file),
      "plans_rendered_count": rendered, "plans_skipped_count": skipped,
      "sentinel_recreated_bool": (not sentinel_existed), "dry_run": dry_run,
      "detected_at": today})

if dry_run:
    print("backlog-index: dry-run (root=%s) rendered=%d skipped=%d"
          % (plans_root, rendered, skipped), file=sys.stderr)
PY

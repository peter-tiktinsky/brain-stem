#!/bin/bash
# backlog-index — Regenerate <plans-root>/_backlog.md from plan manifests as a
# manifest-derived read-replica. Librarian reader cap with the master-row
# policy + satellite-pointer retarget.
#
# plan-manifest-schema degrade-contract: ADVISORY validator — a schema-invalid manifest is counted defect_skipped + emits a backlog-manifest-schema-invalid finding; indexing CONTINUES over the other plans (not refuse-and-freeze).
# Librarian reader cap (1.1 line 126). Ported from the
# backlog-index.sh with two
# additions:
#   (1) MASTER-ROW POLICY: when a master plan with sub_plans[] is in the
#       backlog, render only the MASTER row (its rollup READ from the
#       sub_plans[] aggregate that subplan-aggregate.sh / populates);
#       sub-plan dirs do not get their own backlog rows.
#   (2) PROJECT-DIR OWNERSHIP CELL: the per-row Project Dir cell carries the
#       registry-resolved project-home directory (anchored-spoke-registry
#       cwd_anchors, resolved from the manifest/note project: key); the
#       Initiative [[wikilink]] is the plan pointer. (The retired
#       /<slug>.md satellite stays retired.)
#       The Notes cell is carried forward verbatim (the row sentinel pattern).
#
# Output Contract
#   Files written:
#     <plans-root>/_backlog.md — TWO sentinel-bounded regions: the ACTIVE table
#       (backlog:start/end — 7 cols: Project Dir | Initiative | Status | Disposition |
#       Target | Updated | Notes) and the SETTLED ledger (backlog-settled:start/end —
#       Item | Resolution | Landed In | Project Dir | Settled). Operator narrative
#       outside both regions + per-row Notes carry-forward preserved byte-for-byte.
#     <plans-root>/_inbox/_index.md — machine-written (generated: true) inbox roster
#       (active + settled) + a remediation-highlights block derived from this run's own
#       findings. Excluded from the note walk (the _-prefix skip below).
#     <plans-root>/_inbox/<slug>.md — the closure loop restamps a terminal resolution:
#       write-IF-CHANGED (a settled note is byte-untouched on re-run) on notes whose
#       promoted_to/absorbed_into target plan has reached lifecycle.terminal_status.
#   Project Dir cell (standard): the Claude project-home directory resolved
#     from the row's project: key via anchored-spoke-registry.json (graceful empty on
#     absent/unresolvable/home) — NOT a plans-folder link.
#   Schema gate: each manifest validates against plan-manifest-schema.json
#     (jsonschema when available; structural fallback).
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Idempotent. --dry-run computes + emits findings without writing any file.
#
# Finding categories:
#   backlog-row-missing-disposition | manifest-status-orphan | slug-violation
#   | backlog-manifest-schema-invalid | backlog-regenerated (event)
#   | inbox-note-settled (event) | inbox-target-unresolvable | inbox-absorb-target-missing
#
# CLI:
#   backlog-index.sh                 # regenerate _backlog.md + _inbox/_index.md + emit findings
#   backlog-index.sh --dry-run       # compute + emit findings + summary; no write
#   backlog-index.sh --help
#
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   BACKLOG_FILE             output file (default: $PLANS_ROOT/_backlog.md)
#   PLANS_RULES_PATH         plans-rules.json (default: foundation -> live)
#   PLAN_MANIFEST_SCHEMA     plan-manifest-schema.json (default: foundation -> live)
#   SPOKE_REGISTRY_PATH      anchored-spoke-registry.json (default: the
#                            $CLAUDE_HOME install first, the repo governance/
#                            copy only as a fallback — hooks/lib/anchored-spoke-registry.sh)
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#
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
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/anchored-spoke-registry.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/anchored-spoke-registry.sh"; } \
  || { [ -r "$_REPO_LIB/anchored-spoke-registry.sh" ] && source "$_REPO_LIB/anchored-spoke-registry.sh"; } || true

DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "backlog-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

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

# Anchored-spoke registry (Project Dir cell): resolves each row's project:
# spoke key to its project-home directory (cwd_anchors[0]). The ONE shared resolver
# (hooks/lib/anchored-spoke-registry.sh) owns the order — test override -> the
# $CLAUDE_HOME install -> the repo governance/ copy as a fallback. A missing/unreadable
# registry renders every Project Dir cell as the graceful empty (never a crash).
if ! command -v spoke_registry_resolve >/dev/null 2>&1; then
  echo "backlog-index: hooks/lib/anchored-spoke-registry.sh not found (looked under $CLAUDE_HOME_RES/hooks/lib and $_REPO_LIB)" >&2
  exit 1
fi
_REPO_GOV="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/governance"
SPOKE_REG="$(spoke_registry_resolve "$_REPO_GOV")"

# WRITE-TARGET COHERENCE. This capability resolves its write target from $HOME and
# its registry from $CLAUDE_HOME; a run that pairs the live plan corpus with another
# tree's registry would render a table whose every unknown row is silently blank.
# Refuse it here, before the render, in this capability's block-and-log posture (the
# --dry-run path refuses too: the incoherent input, not the write, is what is wrong).
spoke_registry_assert_coherent "$SPOKE_REG" "$BACKLOG_FILE" "backlog-index" || exit 1

python3 - "$PLANS_ROOT" "$DRY_RUN" "$RULES_PATH" "$SCHEMA_PATH" "$BACKLOG_FILE" "$SPOKE_REG" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root = sys.argv[1]
dry_run = sys.argv[2] == "true"
rules_path = sys.argv[3]
schema_path = sys.argv[4]
backlog_file = sys.argv[5]
spoke_reg = sys.argv[6] if len(sys.argv) > 6 else ""
today = date.today().isoformat()

# Active-region sentinels (the pickup-able funnel table) + the SETTLED-ledger region
# (graduated + in-place-resolved items). Two distinct sentinel pairs so the
# active-region parser is untouched by the settled render.
SENTINEL_START = "<!-- backlog:start -->"
SENTINEL_END = "<!-- backlog:end -->"
SETTLED_START = "<!-- backlog-settled:start -->"
SETTLED_END = "<!-- backlog-settled:end -->"

with open(rules_path, encoding="utf-8") as fh:
    rules = json.load(fh)
backlog_row = rules.get("backlog_row", {})
disposition_enum = backlog_row.get("disposition_enum",
                                   ["FIX NOW", "ABSORB", "STANDALONE", "DEFERRED"])
slug_pattern = rules.get("slug_rules", {}).get("pattern", r"^[0-9]{2,}-[a-z][a-z0-9-]+$")
slug_re = re.compile(slug_pattern)

# Inbox contract (fallback defaults EQUAL the T-9 pillar contract — correct both before
# and after the operator-serialized pillar lands).
inbox_cfg = rules.get("inbox", {})
inbox_funnel = inbox_cfg.get("funnel_status_enum", ["new", "triaged", "briefed"])
inbox_type = inbox_cfg.get("note_frontmatter", {}).get("type_value", "idea")
resolution_enum = inbox_cfg.get("resolution_enum",
                                ["promoted", "absorbed", "resolved", "dropped"])
# Terminal plan-status set for the closure loop (single-SoT: read the pillar,
# fall back to the post-[completed, superseded] 2-state terminal set).
terminal_status = rules.get("lifecycle", {}).get("terminal_status",
                                                 ["completed", "superseded"])
# single-SoT: the plan-status validation vocabulary is derived from the
# CANONICAL SoT — schemas/plan-manifest-schema.json :: properties.status.enum
# (6-state, INCLUDES `superseded`) — NOT governance/plans-rules.json ::
# lifecycle.status_enum, so a schema shrink auto-tightens this orphan check for
# free with no hardcode to chase. The hardcoded 6-state list below is a
# schema-absent LAST-RESORT fallback ONLY (defensive), never a second authority.
_STATUS_ENUM_FALLBACK = [
    "researching", "planned", "in-progress", "paused", "completed",
    "superseded"]
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
        validator = jsonschema.Draft202012Validator(_schema, format_checker=jsonschema.FormatChecker())
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

# --- Project Dir resolution (T-3) ----------------------------------
# Map each registry spoke_key -> its project-home dir (cwd_anchors[0]); mirror of
# plan-index.sh::_load_spoke_dir_map. The anchorless `home` spoke declares no
# cwd_anchors, so it is absent from the map (renders the graceful empty).
def _load_spoke_dir_map(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return {}
    m = {}
    for sp in doc.get("spokes", []) or []:
        if not isinstance(sp, dict):
            continue
        key = sp.get("spoke_key", "")
        anchors = sp.get("cwd_anchors", []) or []
        if key and isinstance(anchors, list) and anchors:
            m[key] = anchors[0]
    return m

SPOKE_DIR_MAP = _load_spoke_dir_map(spoke_reg)

def resolve_project_dir(proj):
    """The Claude project-home dir for a row's project: spoke key (standard).
    Graceful empty on absent project:, the anchorless `home` spoke, an unresolvable key,
    or a missing/unreadable registry — never a crash, mirroring plan-index.sh."""
    if not proj or not isinstance(proj, str):
        return ""
    return SPOKE_DIR_MAP.get(proj, "")

# --- target-key resolution against the plan roster (T-4) --------------------
_TASK_SUFFIX_RE = re.compile(r"\s*::\s*")

def target_plan_key(target):
    """Strip the optional ` :: T-N` task suffix, returning the bare plan-dir key
    (NN-<slug> or NN-<slug>/SS-<subslug>)."""
    if not target:
        return ""
    return _TASK_SUFFIX_RE.split(target.strip(), 1)[0].strip()

def resolve_plan_dir(target):
    """Resolve a promoted_to/absorbed_into target to an EXISTING plan dir (or sub-plan
    dir). Returns (abs_plan_dir_or_None, plan_key). An artifact pointer, a traversal, or
    a name that matches no dir yields (None, key)."""
    key = target_plan_key(target)
    if not key or key.startswith("/") or ".." in key.split("/"):
        return None, key
    d = os.path.join(plans_root, key)
    if os.path.isdir(d) and os.path.isfile(os.path.join(d, "manifest.json")):
        return d, key
    return None, key

def dir_status(plan_dir):
    """The manifest status of a resolved (sub-)plan dir, or '' on any read failure."""
    try:
        with open(os.path.join(plan_dir, "manifest.json"), encoding="utf-8") as fh:
            return str(json.load(fh).get("status", "")).strip()
    except (OSError, json.JSONDecodeError):
        return ""

# --- write-if-changed frontmatter restamp (T-4 closure loop) ----------------
_FM_LINE_KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):")

def apply_fm_updates(content, pairs):
    """Return `content` with the given frontmatter key/value pairs set — replacing an
    existing key's value in place, or appending a new key before the closing `---`. The
    note BODY is byte-untouched. Returns content unchanged if there is no frontmatter."""
    if not content.startswith("---\n"):
        return content
    end = content.find("\n---\n", 4)
    if end < 0:
        return content
    fm_block = content[4:end]
    rest = content[end:]  # begins with "\n---\n" — the closing fence + body
    updates = dict(pairs)
    seen = set()
    out_lines = []
    for line in fm_block.split("\n"):
        m = _FM_LINE_KEY_RE.match(line)
        if m and m.group(1) in updates:
            out_lines.append("%s: %s" % (m.group(1), updates[m.group(1)]))
            seen.add(m.group(1))
        else:
            out_lines.append(line)
    for k, v in pairs:
        if k not in seen:
            out_lines.append("%s: %s" % (k, v))
    return "---\n" + "\n".join(out_lines) + rest

def atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

# preserve operator narrative (outside both regions) + per-row Notes carry-forward.
preface, middle, footer = "", None, ""
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
        after_active = existing[e_idx + len(SENTINEL_END):]
        # The settled region may be absent on the one-time 6->7-col migration run.
        ss = after_active.find(SETTLED_START)
        se = after_active.find(SETTLED_END)
        if ss >= 0 and se > ss:
            middle = after_active[:ss]
            footer = after_active[se + len(SETTLED_END):]
        else:
            middle = after_active  # migration: preserve post-active prose as `middle`
            footer = ""
        # Header-aware Notes carry-forward over the ACTIVE region: locate the header row
        # (it names the columns) to find the Initiative + Notes indices, so the parse
        # survives BOTH the old 6-col and the new 7-col layout (one-time format migration).
        region = existing[s_idx + len(SENTINEL_START):e_idx]
        idx_init, idx_notes, header_seen = 1, 5, False
        for line in region.split("\n"):
            st = line.strip()
            if not st.startswith("|"):
                continue
            cols = [c.strip() for c in st.strip("|").split("|")]
            if not header_seen and "Initiative" in cols and "Notes" in cols:
                idx_init = cols.index("Initiative")
                idx_notes = cols.index("Notes")
                header_seen = True
                continue
            if len(cols) <= idx_init or len(cols) <= idx_notes:
                continue
            m = re.search(r"\[\[([^\]]+)\]\]", cols[idx_init])
            if m:
                prior_notes[m.group(1)] = cols[idx_notes]
    else:
        preface = existing
        if preface and not preface.endswith("\n"):
            preface += "\n"
if not sentinel_existed and not preface:
    preface = "# Backlog\n\nManifest-derived read-replica (librarian:backlog-index owns this file).\n\n"

rows = []
settled_rows = []          # (settled_date, sort_key, [5 cells]) for the settled ledger
active_note_roster = []    # {slug,title,status,disposition,project,target} for _inbox/_index.md
highlights = {             # remediation categories for _inbox/_index.md (this run's own walk)
    "malformed_frontmatter": [], "missing_project": [], "non_enum_status": [],
    "absorb_no_target": [], "unresolvable_target": []}
settled_note_count = 0
rendered = 0
# telemetry split: by-design skips (out-of-funnel status / non-idea inbox files) are
# counted separately from defect skips (unparseable / schema-invalid / status-orphan).
# plans_skipped_count is reported as their SUM (the former single counter), preserving
# the backlog-regenerated finding's backward compatibility.
out_of_funnel = 0
defect_skipped = 0

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
        defect_skipped += 1
        print("backlog-index: skipped unparseable manifest: %s" % manifest_path, file=sys.stderr)
        continue
    if not manifest_valid(manifest):
        # visibility: a schema-invalid funnel manifest is invisible today (silent
        # counted skip). Emit an NDJSON finding so the dirty corpus surfaces for repair
        # instead of disappearing from the read-replica.
        emit({"finding": "backlog-manifest-schema-invalid", "file": entry, "plan_slug": entry,
              "manifest_path": manifest_path, "detected_at": today, "first_seen": today})
        defect_skipped += 1
        print("backlog-index: skipped schema-invalid manifest: %s" % manifest_path, file=sys.stderr)
        continue

    status = str(manifest.get("status", "")).strip()
    if status and status not in lifecycle_enum:
        emit({"finding": "manifest-status-orphan", "file": entry, "plan_slug": entry,
              "declared_status": status, "valid_statuses": lifecycle_enum,
              "detected_at": today, "first_seen": today})
        defect_skipped += 1
        continue

    # Settled ledger: any manifest carrying `promoted_from` is a GRADUATED
    # inbox item — the idea left the funnel, which IS settlement from the inbox's
    # perspective — regardless of the landing plan's CURRENT status. The row is sourced
    # from the manifest alone; no inbox-side record is required (the note was tombstoned).
    pf = str(manifest.get("promoted_from", "")).strip()
    if pf:
        g_slug = re.sub(r"\.md$", "", re.sub(r"^_inbox/", "", pf))
        g_projdir = resolve_project_dir(manifest.get("project"))
        g_settled = str(manifest.get("completed_at") or manifest.get("updated")
                        or manifest.get("phase_2_scaffolded_at") or "")
        g_landed = "[[%s]] (%s)" % (entry, status or "?")
        settled_rows.append((g_settled, "1graduated:" + g_slug,
                             [cell(g_slug), cell("promoted"), cell(g_landed),
                              cell(g_projdir), cell(g_settled)]))

    if status not in IN_BACKLOG:
        out_of_funnel += 1
        continue
    if not slug_re.match(entry):
        emit({"finding": "slug-violation", "file": entry, "plan_slug": entry,
              "pattern_violation_reason": "does not match %s" % slug_pattern,
              "detected_at": today, "first_seen": today})

    title = manifest.get("title") or manifest.get("project") or entry
    # render-time fallback: when `updated` is absent, fall back to the scaffold date so
    # the Updated cell is never empty for a manifest that carries phase_2_scaffolded_at.
    updated = manifest.get("updated") or manifest.get("phase_2_scaffolded_at") or ""
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

    # Project Dir cell: the Claude project-home directory resolved
    # from the manifest `project:` spoke key — NOT the old <plan>/handoff.md plans-folder
    # link (the Initiative [[wikilink]] already reaches the plan dir). The table now
    # groups by owning project. Target is empty for plan rows (promoted_to/absorbed_into
    # are inbox-note disposition targets, not plan-manifest fields).
    project_dir = resolve_project_dir(manifest.get("project"))
    target = ""

    notes = prior_notes.get(entry, "")
    row = "| %s | %s | %s | %s | %s | %s | %s |" % (
        cell(project_dir), cell(initiative), cell(status), cell(disposition),
        cell(target), cell(updated), cell(notes))
    rows.append((cell(project_dir).lower(), updated, row))
    rendered += 1

# INBOX PASS — the T-4 closure loop (write-if-changed terminal-resolution reconcile)
# fused with the T-3/T-5 active/settled classification and the T-6 remediation walk.
# A PRE-RENDER reconcile: settle notes on disk (UNCONDITIONAL on the note's current
# status: — the legacy `status: promoted` carriers are the primary settle population,
# invisible to a funnel-status gate) BEFORE the render reads them, so a settled note
# leaves the active table and enters the settled ledger in the same run. `_`-prefixed
# files (e.g. the generated _index.md) are NEVER walked as notes. Row pointer is the
# note itself (_inbox/<slug>.md); slug carries NO NN- prefix (assigned at graduation).
inbox_dir = os.path.join(plans_root, "_inbox")
if os.path.isdir(inbox_dir):
    for entry in sorted(os.listdir(inbox_dir)):
        if not entry.endswith(".md") or entry.startswith("_"):
            continue  # T-3: skip _-prefixed inbox files (incl. the generated _index.md)
        full = os.path.join(inbox_dir, entry)
        if not os.path.isfile(full):
            continue
        slug = entry[:-3]
        wikilink = "_inbox/%s" % slug
        try:
            with open(full, encoding="utf-8") as fh:
                content = fh.read()
        except OSError:
            continue
        fm = parse_frontmatter(full)
        if fm is None or fm.get("type", "").strip() != inbox_type:
            highlights["malformed_frontmatter"].append(slug)
            out_of_funnel += 1
            continue

        promoted_to = fm.get("promoted_to", "").strip()
        absorbed_into = fm.get("absorbed_into", "").strip()
        disposition = fm.get("disposition", "").strip()
        resolution = fm.get("resolution", "").strip()
        project = fm.get("project", "").strip()
        if not project:
            highlights["missing_project"].append(slug)

        # --- closure loop: ABSORB-without-target backstop (mechanical mirror of T-2) ---
        if disposition == "ABSORB" and not absorbed_into:
            emit({"finding": "inbox-absorb-target-missing", "file": entry, "inbox_slug": slug,
                  "disposition": disposition, "detected_at": today, "first_seen": today})
            highlights["absorb_no_target"].append(slug)

        # --- closure loop: terminal-resolution reconcile over the disposition target ---
        target = absorbed_into or promoted_to
        res_kind = "absorbed" if absorbed_into else ("promoted" if promoted_to else "")
        if target:
            plan_dir_res, plan_key = resolve_plan_dir(target)
            if plan_dir_res is None:
                emit({"finding": "inbox-target-unresolvable", "file": entry, "inbox_slug": slug,
                      "target": target, "target_key": plan_key,
                      "detected_at": today, "first_seen": today})
                highlights["unresolvable_target"].append(slug)
            elif dir_status(plan_dir_res) in terminal_status:
                # WRITE-IF-CHANGED: a note already carrying this terminal resolution is
                # byte-UNTOUCHED (the f5 graduation-timestamp lesson applied at birth).
                already = (resolution == res_kind and fm.get("resolved_at", "").strip())
                if not already:
                    new_note = apply_fm_updates(content, [
                        ("resolution", res_kind), ("resolved_at", today), ("updated", today)])
                    if new_note != content:
                        emit({"finding": "inbox-note-settled", "file": entry, "inbox_slug": slug,
                              "resolution": res_kind, "target": target, "target_key": plan_key,
                              "resolved_at": today, "detected_at": today})
                        if not dry_run:
                            atomic_write(full, new_note)
                        content = new_note
                        resolution = res_kind  # reflect post-stamp for classification

        # --- classify: settled note -> settled ledger; else active table / residue ----
        if resolution in resolution_enum:
            settled_note_count += 1
            _pdir, _pk = resolve_plan_dir(target) if target else (None, "")
            landed = "[[%s]]" % _pk if (_pdir is not None) else (target or "—")
            s_date = fm.get("resolved_at", "").strip() or fm.get("updated", "").strip() or today
            settled_rows.append((s_date, "0note:" + slug,
                                 [cell("[[%s]]" % wikilink), cell(resolution), cell(landed),
                                  cell(resolve_project_dir(project)), cell(s_date)]))
            continue

        status = fm.get("status", "").strip() or "new"
        if status not in inbox_funnel:
            out_of_funnel += 1
            highlights["non_enum_status"].append(slug)
            print("backlog-index: inbox note '%s' non-funnel status '%s'; skipped"
                  % (entry, status), file=sys.stderr)
            continue

        title = fm.get("title", "") or slug
        updated = fm.get("updated", "") or fm.get("created", "")
        disp_cell = disposition or "MISSING"
        project_dir = resolve_project_dir(project)
        notes = prior_notes.get(wikilink, "")
        row = "| %s | %s | %s | %s | %s | %s | %s |" % (
            cell(project_dir), cell("[[%s]] %s" % (wikilink, title)),
            cell(status), cell(disp_cell), cell(target), cell(updated), cell(notes))
        rows.append((cell(project_dir).lower(), updated, row))
        rendered += 1
        active_note_roster.append({
            "slug": slug, "title": title, "status": status,
            "disposition": disp_cell, "project": project, "target": target})

rows.sort(key=lambda r: r[1], reverse=True)
rows.sort(key=lambda r: r[0])

active_lines = ["| Project Dir | Initiative | Status | Disposition | Target | Updated | Notes |",
                "|---|---|---|---|---|---|---|"]
active_lines.extend(r[2] for r in rows)
active_block = SENTINEL_START + "\n\n" + "\n".join(active_lines) + "\n\n" + SENTINEL_END

# Settled ledger: graduated rows (manifest promoted_from) + in-place resolved
# notes. Newest-settled first, then a stable secondary key so the render is deterministic.
settled_rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
settled_lines = ["| Item | Resolution | Landed In | Project Dir | Settled |",
                 "|---|---|---|---|---|"]
settled_lines.extend("| %s |" % " | ".join(c) for _, _, c in settled_rows)
settled_block = SETTLED_START + "\n\n" + "\n".join(settled_lines) + "\n\n" + SETTLED_END

# Assemble the two sentinel regions. Prose OUTSIDE both regions is preserved
# byte-for-byte across regens; `middle` (operator narrative BETWEEN the regions) is
# preserved; the one-time 6->7-col migration folds any post-active prose into `middle`.
if preface and not preface.endswith("\n"):
    preface += "\n"
if middle is None:
    middle = "\n\n"  # fresh render: a blank-line separator between the two regions
elif middle and not middle.endswith("\n"):
    middle += "\n"   # keep the settled sentinel on its own line (one-time migration only)
new_content = preface + active_block + middle + settled_block + footer
if not new_content.endswith("\n"):
    new_content += "\n"

if not dry_run:
    for _s in (SENTINEL_START, SENTINEL_END, SETTLED_START, SETTLED_END):
        if _s not in new_content:
            print("backlog-index: refusing to write — sentinel markers missing", file=sys.stderr)
            sys.exit(1)
    atomic_write(backlog_file, new_content)

# T-6 — render _inbox/_index.md (machine-written; generated: true). Active + settled
# rosters consistent with the _backlog.md regions from THIS run, plus a remediation-
# highlights block derived from this run's own walk (no second scan, no hand-kept
# content). The file is never walked as a note (the _-prefix skip above). A clean corpus
# renders an explicit all-clear line, not an empty block.
if os.path.isdir(inbox_dir):
    idx = ["---", "title: Inbox Index", "type: index", "generated: true",
           "updated: %s" % today, "---", "",
           "# Inbox Index", "",
           "_Machine-generated by `librarian:backlog-index`. Do not hand-edit._", "",
           "## Active notes (%d)" % len(active_note_roster), "",
           "| Slug | Title | Status | Disposition | Project | Target |",
           "|---|---|---|---|---|---|"]
    for n in sorted(active_note_roster, key=lambda x: x["slug"]):
        idx.append("| %s | %s | %s | %s | %s | %s |" % (
            cell(n["slug"]), cell(n["title"]), cell(n["status"]),
            cell(n["disposition"]), cell(n["project"]), cell(n["target"])))
    idx += ["", "## Settled (%d)" % len(settled_rows), "",
            "| Item | Resolution | Landed In | Project Dir | Settled |",
            "|---|---|---|---|---|"]
    for _, _, c in settled_rows:
        idx.append("| %s |" % " | ".join(c))
    idx += ["", "## Remediation highlights", ""]
    _cats = [("malformed_frontmatter", "Missing / malformed frontmatter"),
             ("missing_project", "Missing project:"),
             ("non_enum_status", "Non-enum status (outside the funnel vocabulary)"),
             ("absorb_no_target", "ABSORB without a resolvable target"),
             ("unresolvable_target", "Unresolvable disposition target")]
    _cap = 50
    _any = False
    for key, label in _cats:
        names = highlights[key]
        if not names:
            continue
        _any = True
        shown = ", ".join(sorted(set(names))[:_cap])
        more = "" if len(set(names)) <= _cap else " (+%d more)" % (len(set(names)) - _cap)
        idx.append("- **%s** (%d): %s%s" % (label, len(set(names)), shown, more))
    if not _any:
        idx.append("_All clear — every inbox note is well-formed, attributed, and its "
                   "disposition target resolves._")
    index_content = "\n".join(idx).rstrip("\n") + "\n"
    if not dry_run:
        atomic_write(os.path.join(inbox_dir, "_index.md"), index_content)

skipped = out_of_funnel + defect_skipped
emit({"finding": "backlog-regenerated", "file": os.path.basename(backlog_file),
      "plans_rendered_count": rendered, "plans_skipped_count": skipped,
      "out_of_funnel": out_of_funnel, "defect_skipped": defect_skipped,
      "settled_notes": settled_note_count, "settled_rows": len(settled_rows),
      "sentinel_recreated_bool": (not sentinel_existed), "dry_run": dry_run,
      "detected_at": today})

if dry_run:
    print("backlog-index: dry-run (root=%s) rendered=%d skipped=%d (out_of_funnel=%d defect_skipped=%d settled=%d)"
          % (plans_root, rendered, skipped, out_of_funnel, defect_skipped, len(settled_rows)), file=sys.stderr)
PY

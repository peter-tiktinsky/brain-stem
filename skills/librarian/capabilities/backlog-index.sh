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
#       Initiative markdown dir-link is the plan pointer. (The retired
#       /<slug>.md satellite stays retired.)
#       The Notes cell is carried forward verbatim (the row sentinel pattern).
#
# Output Contract
#   Files written:
#     <plans-root>/_backlog.md — TWO sentinel-bounded regions: the ACTIVE table
#       (backlog:start/end — 7 cols: Project Dir | Initiative | Status | Disposition |
#       Target | Updated | Notes) and the SETTLED ledger (backlog-settled:start/end —
#       Item | Resolution | Landed In | Project Dir | Settled; THREE sources: manifest
#       promoted_from graduations, manifest absorbed_notes[] N:1 absorption joins, and
#       terminally-resolved inbox notes — note-side wins over a join for the same slug).
#       Operator narrative outside both regions + per-row Notes carry-forward preserved
#       byte-for-byte.
#     <plans-root>/_inbox/_index.md — machine-written (generated: true) inbox roster
#       (active + settled) + a remediation-highlights block derived from this run's own
#       findings. Excluded from the note walk (the _-prefix skip below).
#     <plans-root>/_inbox/<slug>.md — the closure loop restamps a terminal resolution:
#       write-IF-CHANGED (a settled note is byte-untouched on re-run) on notes whose
#       promoted_to/absorbed_into target plan has reached lifecycle.terminal_status.
#     <plans-root>/_inbox/_settled/<slug>.md — the stamp EVENT relocates the note to
#       the settled home in the same run (forward-only: already-settled flat notes are
#       never moved; the _settled/ walk is render-only + misfile advisory).
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
#   | inbox-resolution-out-of-enum | inbox-settled-misfiled | inbox-settled-move-conflict
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
from urllib.parse import quote as _urlquote, unquote as _urlunquote

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
                                ["promoted", "absorbed", "resolved", "dropped",
                                 "superseded", "discharged"])
# Settled home (plans-root-relative). A settlement EVENT (the closure-loop stamp,
# or the inbox-settle capability) relocates the note here; already-settled notes
# sitting flat are NEVER moved by this renderer (forward-only separation).
settled_rel = inbox_cfg.get("settled_dir", "_inbox/_settled/").strip("/")
# index-relative link prefix: the inbox index lives IN _inbox/, so a settled
# sibling links as _settled/<slug>.md from there
settled_idx_prefix = settled_rel.split("/", 1)[1] if "/" in settled_rel else settled_rel
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

# --- ruled link grammar (relative markdown links, never wikilinks) ----------
# _backlog.md lives at the plans root and _inbox/_index.md lives inside _inbox/,
# so the SAME logical reference needs a DIFFERENT relative target per writing
# surface (a wikilink was location-independent; a markdown link is not). Cells
# that carry links are therefore rendered per-surface at append time — never
# shared verbatim between the two files.

def _mdq(target):
    # %-quote the path portion (spaces etc.); keep / as the separator
    return _urlquote(target, safe="/")

def md_plan_link(key, rel=""):
    # plan-DIR link (trailing slash), plans-root-relative; `rel` is the
    # traversal prefix from the writing file's own directory ('' from the
    # plans root, '../' from inside _inbox/)
    return "[%s](%s%s/)" % (key, rel, _mdq(key))

def md_note_link(label, target):
    # inbox-note FILE link; label and target are chosen per writing surface
    # (same-directory-first: the inbox index links its own siblings bare)
    return "[%s](%s.md)" % (label, _mdq(target))

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
            # BOTH-grammar read-back: rows regenerated before the markdown-link
            # conversion carry [[entry]]; converted rows carry [entry](entry/).
            # Parsing both means a wikilink-era row's Notes survive the regen
            # that converges the row onto the ruled grammar.
            m = re.search(r"\[\[([^\]]+)\]\]", cols[idx_init])
            if m:
                prior_notes[m.group(1)] = cols[idx_notes]
            else:
                m = re.search(r"\[[^\]]*\]\(([^)]+)\)", cols[idx_init])
                if m:
                    key = _urlunquote(m.group(1))
                    # plan rows target the dir (entry/); note rows target the
                    # file (_inbox/<slug>.md) — the notes key is the bare ref
                    key = key[:-1] if key.endswith("/") else \
                        (key[:-3] if key.endswith(".md") else key)
                    prior_notes[key] = cols[idx_notes]
    else:
        preface = existing
        if preface and not preface.endswith("\n"):
            preface += "\n"
if not sentinel_existed and not preface:
    preface = "# Backlog\n\nManifest-derived read-replica (librarian:backlog-index owns this file).\n\n"

rows = []
settled_rows = []          # (settled_date, sort_key, [5 cells for _backlog.md],
                           #  [5 cells for _inbox/_index.md]) — link cells are rendered
                           # per-surface because relative targets differ by writing home
active_note_roster = []    # {slug,title,status,disposition,project,target} for _inbox/_index.md
highlights = {             # remediation categories for _inbox/_index.md (this run's own walk)
    "malformed_frontmatter": [], "missing_project": [], "non_enum_status": [],
    "absorb_no_target": [], "unresolvable_target": [], "resolution_out_of_enum": [],
    "settled_misfiled": []}
settled_note_count = 0
moved_this_run = set()  # filenames the closure loop relocated THIS run (settled-walk dedup)
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
        g_landed_b = "%s (%s)" % (md_plan_link(entry), status or "?")
        g_landed_i = "%s (%s)" % (md_plan_link(entry, rel="../"), status or "?")
        settled_rows.append((g_settled, "1graduated:" + g_slug,
                             [cell(g_slug), cell("promoted"), cell(g_landed_b),
                              cell(g_projdir), cell(g_settled)],
                             [cell(g_slug), cell("promoted"), cell(g_landed_i),
                              cell(g_projdir), cell(g_settled)]))

    # Settled ledger: manifest-side ABSORPTION joins — absorbed_notes[] is the plan-side
    # record of an N:1 absorption (several notes into one plan), which no single note-side
    # absorbed_into: can express from the plan's perspective. One row PER listed note,
    # sourced from the manifest alone (the note may be tombstoned, settled, or still
    # sitting flat); a note-side settled row for the same slug takes precedence (deduped
    # after the walks — the note-side row is richer: linked and dated by resolved_at).
    an = manifest.get("absorbed_notes")
    if isinstance(an, list):
        for _ref in an:
            _ref = str(_ref).strip()
            if not _ref:
                continue
            a_slug = re.sub(r"\.md$", "", re.sub(r"^_inbox/", "", _ref))
            a_projdir = resolve_project_dir(manifest.get("project"))
            a_settled = str(manifest.get("completed_at") or manifest.get("updated")
                            or manifest.get("phase_2_scaffolded_at") or "")
            a_landed_b = "%s (%s)" % (md_plan_link(entry), status or "?")
            a_landed_i = "%s (%s)" % (md_plan_link(entry, rel="../"), status or "?")
            settled_rows.append((a_settled, "2absorbed:" + a_slug,
                                 [cell(a_slug), cell("absorbed"), cell(a_landed_b),
                                  cell(a_projdir), cell(a_settled)],
                                 [cell(a_slug), cell("absorbed"), cell(a_landed_i),
                                  cell(a_projdir), cell(a_settled)]))

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
    initiative = "%s %s" % (md_plan_link(entry), title)
    if is_master and isinstance(manifest.get("sub_plans"), list):
        initiative += " (master · %d subs)" % len(manifest["sub_plans"])

    # Project Dir cell: the Claude project-home directory resolved
    # from the manifest `project:` spoke key — NOT the old <plan>/handoff.md plans-folder
    # link (the Initiative markdown dir-link already reaches the plan dir). The table now
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
        note_ref = "_inbox/%s" % slug
        idx_target = slug  # same-directory sibling from _inbox/_index.md (rebased on move)
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
                        # Settle-time move (forward-only): the stamp EVENT relocates the
                        # note to the settled home in the same run. Never clobbers — a
                        # destination collision leaves the note flat with an advisory.
                        dest_dir = os.path.join(plans_root, *settled_rel.split("/"))
                        dest = os.path.join(dest_dir, entry)
                        move_ok = not os.path.exists(dest)
                        emit({"finding": "inbox-note-settled", "file": entry, "inbox_slug": slug,
                              "resolution": res_kind, "target": target, "target_key": plan_key,
                              "resolved_at": today, "detected_at": today,
                              "settled_path": ("%s/%s" % (settled_rel, entry)) if move_ok
                                              else ("_inbox/%s" % entry)})
                        if not dry_run:
                            atomic_write(full, new_note)
                            if move_ok:
                                os.makedirs(dest_dir, exist_ok=True)
                                os.replace(full, dest)
                                moved_this_run.add(entry)
                                full = dest
                                note_ref = "%s/%s" % (settled_rel, slug)
                                idx_target = "%s/%s" % (settled_idx_prefix, slug)
                            else:
                                emit({"finding": "inbox-settled-move-conflict", "file": entry,
                                      "inbox_slug": slug, "dest": "%s/%s" % (settled_rel, entry),
                                      "detected_at": today, "first_seen": today})
                        content = new_note
                        resolution = res_kind  # reflect post-stamp for classification

        # --- classify: settled note -> settled ledger; else active table / residue ----
        # Precedence: terminal-resolution EVIDENCE wins over funnel status. A note
        # settles when `resolution` is in the canonical enum, OR when a non-empty
        # out-of-enum `resolution` is corroborated by `resolved_at` or `superseded_by`
        # (operator-judgment settlement — an enum cannot enumerate free judgment; the
        # evidence gate keeps a bare typo from silently settling a note). The evidence
        # path emits an advisory so vocabulary drift stays visible, instead of
        # ACTIVE-rendering the note (in-funnel status) or dropping it from both tables
        # (non-funnel status).
        resolution_evidence = bool(fm.get("resolved_at", "").strip()
                                   or fm.get("superseded_by", "").strip())
        if resolution in resolution_enum or (resolution and resolution_evidence):
            if resolution not in resolution_enum:
                emit({"finding": "inbox-resolution-out-of-enum", "file": entry,
                      "inbox_slug": slug, "resolution": resolution,
                      "superseded_by": fm.get("superseded_by", "").strip(),
                      "detected_at": today, "first_seen": today})
                highlights["resolution_out_of_enum"].append(slug)
            settled_note_count += 1
            _pdir, _pk = resolve_plan_dir(target) if target else (None, "")
            landed_b = md_plan_link(_pk) if (_pdir is not None) else (target or "—")
            landed_i = md_plan_link(_pk, rel="../") if (_pdir is not None) else (target or "—")
            s_date = fm.get("resolved_at", "").strip() or fm.get("updated", "").strip() or today
            # Item cell: from the plans root the note is _inbox/<slug>.md; from
            # inside _inbox/ it is a same-directory sibling (<slug>.md)
            settled_rows.append((s_date, "0note:" + slug,
                                 [cell(md_note_link(note_ref, note_ref)), cell(resolution),
                                  cell(landed_b), cell(resolve_project_dir(project)),
                                  cell(s_date)],
                                 [cell(md_note_link(note_ref, idx_target)), cell(resolution),
                                  cell(landed_i), cell(resolve_project_dir(project)),
                                  cell(s_date)]))
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
        notes = prior_notes.get(note_ref, "")
        row = "| %s | %s | %s | %s | %s | %s | %s |" % (
            cell(project_dir), cell("%s %s" % (md_note_link(note_ref, note_ref), title)),
            cell(status), cell(disp_cell), cell(target), cell(updated), cell(notes))
        rows.append((cell(project_dir).lower(), updated, row))
        rendered += 1
        active_note_roster.append({
            "slug": slug, "title": title, "status": status,
            "disposition": disp_cell, "project": project, "target": target})

# --- settled-home walk (RENDER-ONLY): notes in the settled subfolder always render
# in the settled ledger — folder placement is operator intent. No stamping and no
# moving happens here; a resident lacking settlement evidence (not in the enum AND
# not evidence-corroborated) emits the inbox-settled-misfiled advisory so it gets
# remediated by hand instead of silently normalizing.
settled_abs = os.path.join(plans_root, *settled_rel.split("/"))
if os.path.isdir(settled_abs):
    for entry in sorted(os.listdir(settled_abs)):
        if not entry.endswith(".md") or entry.startswith("_"):
            continue
        if entry in moved_this_run:
            continue  # the flat loop already rendered the note it just relocated
        full = os.path.join(settled_abs, entry)
        if not os.path.isfile(full):
            continue
        slug = entry[:-3]
        note_ref = "%s/%s" % (settled_rel, slug)
        idx_target = "%s/%s" % (settled_idx_prefix, slug)
        fm = parse_frontmatter(full)
        if fm is None or fm.get("type", "").strip() != inbox_type:
            highlights["malformed_frontmatter"].append(note_ref)
            continue
        resolution = fm.get("resolution", "").strip()
        _evidence = bool(fm.get("resolved_at", "").strip()
                         or fm.get("superseded_by", "").strip())
        if not (resolution in resolution_enum or (resolution and _evidence)):
            emit({"finding": "inbox-settled-misfiled", "file": note_ref + ".md",
                  "inbox_slug": slug, "resolution": resolution,
                  "detected_at": today, "first_seen": today})
            highlights["settled_misfiled"].append(slug)
        target = fm.get("absorbed_into", "").strip() or fm.get("promoted_to", "").strip()
        project = fm.get("project", "").strip()
        settled_note_count += 1
        _pdir, _pk = resolve_plan_dir(target) if target else (None, "")
        landed_b = md_plan_link(_pk) if (_pdir is not None) else (target or "—")
        landed_i = md_plan_link(_pk, rel="../") if (_pdir is not None) else (target or "—")
        s_date = fm.get("resolved_at", "").strip() or fm.get("updated", "").strip() or today
        settled_rows.append((s_date, "0note:" + slug,
                             [cell(md_note_link(note_ref, note_ref)), cell(resolution or "—"),
                              cell(landed_b), cell(resolve_project_dir(project)),
                              cell(s_date)],
                             [cell(md_note_link(note_ref, idx_target)), cell(resolution or "—"),
                              cell(landed_i), cell(resolve_project_dir(project)),
                              cell(s_date)]))

rows.sort(key=lambda r: r[1], reverse=True)
rows.sort(key=lambda r: r[0])

active_lines = ["| Project Dir | Initiative | Status | Disposition | Target | Updated | Notes |",
                "|---|---|---|---|---|---|---|"]
active_lines.extend(r[2] for r in rows)
active_block = SENTINEL_START + "\n\n" + "\n".join(active_lines) + "\n\n" + SENTINEL_END

# Settled ledger: graduated rows (manifest promoted_from) + absorption-join rows
# (manifest absorbed_notes[]) + resolved notes (flat or settled-home). A note-side
# row wins over a manifest-side absorption join for the same slug — the note-side
# row is linked and dated by resolved_at; the join row is the fallback record for a
# note that no longer renders note-side (tombstoned or never stamped).
_note_slugs = {r[1][len("0note:"):] for r in settled_rows if r[1].startswith("0note:")}
settled_rows = [r for r in settled_rows
                if not (r[1].startswith("2absorbed:")
                        and r[1][len("2absorbed:"):] in _note_slugs)]
# Newest-settled first, then a stable secondary key so the render is deterministic.
settled_rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
settled_lines = ["| Item | Resolution | Landed In | Project Dir | Settled |",
                 "|---|---|---|---|---|"]
settled_lines.extend("| %s |" % " | ".join(r[2]) for r in settled_rows)
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
    # Slug cell is a same-directory file-link (<slug>.md) — the index lives IN _inbox/,
    # so the note is a sibling; mirrors the _backlog.md active-row md_note_link shape.
    for n in sorted(active_note_roster, key=lambda x: x["slug"]):
        idx.append("| %s | %s | %s | %s | %s | %s |" % (
            cell(md_note_link(n["slug"], n["slug"])), cell(n["title"]), cell(n["status"]),
            cell(n["disposition"]), cell(n["project"]), cell(n["target"])))
    idx += ["", "## Settled (%d)" % len(settled_rows), "",
            "| Item | Resolution | Landed In | Project Dir | Settled |",
            "|---|---|---|---|---|"]
    for r in settled_rows:
        idx.append("| %s |" % " | ".join(r[3]))
    idx += ["", "## Remediation highlights", ""]
    _cats = [("malformed_frontmatter", "Missing / malformed frontmatter"),
             ("missing_project", "Missing project:"),
             ("non_enum_status", "Non-enum status (outside the funnel vocabulary)"),
             ("absorb_no_target", "ABSORB without a resolvable target"),
             ("unresolvable_target", "Unresolvable disposition target"),
             ("resolution_out_of_enum",
              "Out-of-enum resolution settled on evidence (normalize the vocabulary)"),
             ("settled_misfiled",
              "Settled-home resident without settlement evidence (misfiled; move back or stamp)")]
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

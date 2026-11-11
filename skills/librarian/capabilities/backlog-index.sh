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
#       terminally-resolved inbox notes — the note's own row, active or settled, wins
#       over a join for the same slug; an active row wins only while the listing plan is
#       non-terminal, so a terminal plan's join stays beside a note it could not settle).
#       Operator narrative outside both regions + per-row Notes carry-forward preserved
#       byte-for-byte.
#     <plans-root>/_inbox/_index.md — machine-written (generated: true) inbox roster
#       (active + settled) + a remediation-highlights block derived from this run's own
#       findings. Excluded from the note walk (the _-prefix skip below).
#     <plans-root>/_inbox/<slug>.md — the closure loop restamps a terminal resolution:
#       write-IF-CHANGED (a settled note is byte-untouched on re-run) on notes whose
#       promoted_to/absorbed_into target plan has reached lifecycle.terminal_status.
#       The manifest-side arm settles a flat note that has no target of its own, no
#       resolution and an empty or ABSORB disposition when EXACTLY ONE terminal plan
#       lists it in absorbed_notes[]: it stamps disposition: ABSORB + absorbed_into:
#       <plan key> through the same path, and the settle event carries source
#       manifest-absorbed_notes (a note-side settle carries source note). The note's
#       created date must fall on or before the plan's completed_at (fallback updated).
#       Every refused case writes nothing and emits inbox-absorb-manifest-ambiguous
#       with a reason: multi-claim | created-after-plan | created-unknown |
#       plan-date-unknown | disposition-conflict. A non-terminal listing plan leaves
#       the note untouched. An absorbed_notes[] ref joins on the bare slug in either
#       the flat (_inbox/<slug>.md) or the settled-home (_inbox/_settled/<slug>.md) form.
#     <plans-root>/_inbox/_settled/<slug>.md — the stamp EVENT relocates the note to
#       the settled home in the same run (forward-only: already-settled flat notes are
#       never moved; the _settled/ walk is render-only + misfile advisory).
#       NO-BUILD is a decided "no" watched by a gate: a flat note with disposition
#       NO-BUILD and a registered reopen_gate (inbox.reopen_gates in the plans pillar)
#       is stamped resolution: parked + resolved_at and moved to the settled home, the
#       event carrying source no-build. Each settled NO-BUILD note's gate is evaluated
#       through hooks/lib/reopen-gate.sh on every run (a manual gate is never
#       evaluated): when it is met the note moves back flat with the disposition,
#       resolution and resolved_at cleared and reopened_at + reopened_from_gate
#       stamped. A flat NO-BUILD note whose reopen_gate equals its reopened_from_gate
#       is not settled again (a fresh decision is required). This is the one carve-out
#       to forward-only settlement.
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
#   | inbox-absorb-manifest-ambiguous | inbox-disposition-missing | inbox-disposition-out-of-enum
#   (inbox-absorb-target-missing matches ABSORB and the free-text `ABSORB <target>` prefix
#   form alike. inbox-disposition-missing fires for an active flat note with a blank
#   disposition once its age, from updated or else created, reaches
#   backlog_row.stale_advisory_days[0]: tier advisory, escalation at [1], age-unknown when
#   neither date parses. inbox-disposition-out-of-enum names a value outside
#   backlog_row.disposition_enum. Settled notes are never checked, and neither finding
#   changes a byte.)
#   | inbox-reopened (event) | inbox-reopen-gate-unknown | inbox-reopen-gate-repeat
#   (inbox-reopened: a settled NO-BUILD note's gate was met and the note moved back flat.
#   inbox-reopen-gate-unknown: a NO-BUILD note, flat or settled, names a blank or
#   unregistered reopen_gate; it stays where it is. inbox-reopen-gate-repeat: a flat
#   NO-BUILD note names the gate it was last re-opened from; it stays flat. A re-open
#   whose flat destination already exists emits inbox-settled-move-conflict with
#   direction reopen and the note stays settled.)
#   | inbox-near-duplicate-pair (advisory; one per unlinked pair of open flat notes the
#   near-duplicate scorer, hooks/lib/inbox-near-dup.sh, flags, on every run; a pair linked by
#   either note's distinct_from is omitted; changes no byte)
#   | inbox-frontmatter-invalid (advisory; a flat note's frontmatter block fails
#   yaml.safe_load or parses to a non-mapping — error carries the exception class and
#   its first message line; the note's bytes are untouched and its row still renders;
#   settled notes are never checked; when PyYAML is not importable the check is
#   skipped and one stderr notice prints once at least one flat note was walked)
#   | inbox-capture-freeze-open | inbox-capture-freeze-unevaluable
#   (A spoke holding a freeze record at inbox.capture_freeze_record
#   (_projects/<spoke>/.capture-freeze, one line start_sha=<40-hex>, the plans-repo commit
#   that recorded the opening ruling) has a freeze in force. inbox-capture-freeze-open: an
#   open flat note of that spoke, added to _inbox/ after that commit (committed, staged or
#   untracked), carries no target; a target is disposition ABSORB with an absorbed_into key
#   (optional ' :: T-N' stripped) that resolves to a manifest.json under the plans root, or
#   disposition STANDALONE with release_class post-release (aimed at the next patch release).
#   inbox-capture-freeze-unevaluable: the record is not exactly that one line, names a sha
#   the plans repo does not know, or the plans root is not a git repository. No record, nothing
#   reported; neither finding changes a byte.)
#
# CLI:
#   backlog-index.sh                 # regenerate _backlog.md + _inbox/_index.md + emit findings
#   backlog-index.sh --dry-run       # compute + emit findings + summary; no write
#   backlog-index.sh --freeze-check [--spoke <key>]
#       # read-only: print one JSON object per spoke holding a freeze record (or for the named
#       # spoke) {"spoke","freeze","start_sha","open":[{"inbox_slug",...}]}; no spoke with a
#       # record prints freeze false. Exit 0 when open is empty, 1 when not, 2 when a record
#       # cannot be evaluated (the object then carries an "error" key).
#       # A note is open unless it is targeted: an ABSORB into a resolving key, or a STANDALONE
#       # note of class post-release.
#       # The record is opened by hooks/lib/field-set.sh capture-freeze open <spoke> (it writes
#       # start_sha= of the plans repository's HEAD) and lifted by capture-freeze lift <spoke>.
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
FREEZE_CHECK="false"
FREEZE_SPOKE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --freeze-check) FREEZE_CHECK="true"; shift ;;
    --spoke)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "backlog-index: --spoke needs a spoke key" >&2; exit 2; fi
      FREEZE_SPOKE="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "backlog-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [[ -n "$FREEZE_SPOKE" && "$FREEZE_CHECK" != "true" ]]; then
  echo "backlog-index: --spoke applies with --freeze-check" >&2
  exit 2
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

# The re-open gate reader, installed copy first (the same order as the libs above). Empty when
# neither exists: a command gate is then never evaluated and the note stays where it is.
REOPEN_GATE_SCRIPT=""
for _rg in "$CLAUDE_HOME_RES/hooks/lib/reopen-gate.sh" "$_REPO_LIB/reopen-gate.sh"; do
  if [[ -f "$_rg" ]]; then REOPEN_GATE_SCRIPT="$_rg"; break; fi
done

# The near-duplicate scorer (installed copy first, like the reader above). Empty when neither
# exists: the near-duplicate sweep is then skipped.
NEAR_DUP_SCRIPT=""
for _nd in "$CLAUDE_HOME_RES/hooks/lib/inbox-near-dup.sh" "$_REPO_LIB/inbox-near-dup.sh"; do
  if [[ -f "$_nd" ]]; then NEAR_DUP_SCRIPT="$_nd"; break; fi
done

python3 - "$PLANS_ROOT" "$DRY_RUN" "$RULES_PATH" "$SCHEMA_PATH" "$BACKLOG_FILE" "$SPOKE_REG" "$REOPEN_GATE_SCRIPT" "$NEAR_DUP_SCRIPT" "$FREEZE_CHECK" "$FREEZE_SPOKE" <<'PY'
import json, os, re, subprocess, sys, tempfile
from datetime import date
from urllib.parse import quote as _urlquote, unquote as _urlunquote

try:
    import yaml
except ImportError:
    yaml = None

plans_root = sys.argv[1]
dry_run = sys.argv[2] == "true"
rules_path = sys.argv[3]
schema_path = sys.argv[4]
backlog_file = sys.argv[5]
spoke_reg = sys.argv[6] if len(sys.argv) > 6 else ""
reopen_gate_script = sys.argv[7] if len(sys.argv) > 7 else ""
near_dup_script = sys.argv[8] if len(sys.argv) > 8 else ""
freeze_check = len(sys.argv) > 9 and sys.argv[9] == "true"
freeze_spoke = sys.argv[10] if len(sys.argv) > 10 else ""
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
                                   ["FIX NOW", "ABSORB", "STANDALONE", "NO-BUILD"])
# [advisory, escalation] age thresholds in days for a missing disposition.
stale_days = backlog_row.get("stale_advisory_days", [14, 21])
slug_pattern = rules.get("slug_rules", {}).get("pattern", r"^[0-9]{2,}-[a-z][a-z0-9-]+$")
slug_re = re.compile(slug_pattern)

# Inbox contract (fallback defaults EQUAL the T-9 pillar contract — correct both before
# and after the operator-serialized pillar lands).
inbox_cfg = rules.get("inbox", {})
inbox_funnel = inbox_cfg.get("funnel_status_enum", ["new", "triaged", "briefed"])
inbox_type = inbox_cfg.get("note_frontmatter", {}).get("type_value", "idea")
resolution_enum = inbox_cfg.get("resolution_enum",
                                ["promoted", "absorbed", "resolved", "dropped",
                                 "superseded", "discharged", "parked"])
# Closed registry of NO-BUILD re-open gates: id -> {kind: manual | command, ...}. Only the
# registry is read here; a command gate is evaluated through hooks/lib/reopen-gate.sh.
reopen_gates = inbox_cfg.get("reopen_gates", {})
if not isinstance(reopen_gates, dict):
    reopen_gates = {}
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

# A column separator is a pipe NOT preceded by a backslash. cell() escapes only `|` and every
# row pads each cell with one space, so a separator never follows a backslash; a pipe inside a
# cell always carries the backslash its escape added.
_CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")

def split_cells(line):
    # Split a rendered row on UNESCAPED pipes only and decode each cell's `\|` back to `|`
    # once, so the carried Notes re-escaped by cell() round-trips exactly. A bare split on
    # every pipe let a pipe-bearing title shift the columns and carry another column into Notes.
    return [c.strip().replace("\\|", "|") for c in _CELL_SPLIT_RE.split(line.strip().strip("|"))]

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
_FM_KEY_RE = re.compile(r'^([A-Za-z0-9_-]+):\s*(.*)$')

def fm_value(raw):
    """A frontmatter value as read back: a double-quoted value is JSON-decoded, or loses its
    outer quotes when JSON rejects it (a YAML-only escape stays as written); a single-quoted
    value loses its outer quotes with '' folded to '; a plain value passes through unchanged."""
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        try:
            v = json.loads(raw)
            if isinstance(v, str):
                return v
        except ValueError:
            pass
        return raw[1:-1]
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        return raw[1:-1].replace("''", "'")
    return raw

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
            fm[m.group(1)] = fm_value(m.group(2).strip())
    return fm

def fm_yaml_error(file_path):
    """A frontmatter block's YAML problem ('<exception class>: <first message line>'), or
    None when the block is absent, parses and maps — the advisory check's payload."""
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
    try:
        doc = yaml.safe_load(content[4:end])
    except yaml.YAMLError as e:
        return "%s: %s" % (e.__class__.__name__, str(e).split("\n")[0])
    if not isinstance(doc, dict):
        return "%s: the frontmatter block is not a mapping" % type(doc).__name__
    return None

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

def absorbed_ref_slug(ref):
    """The bare note slug of an absorbed_notes[] ref, whether it names the flat note
    (_inbox/<slug>.md) or its settled home (_inbox/_settled/<slug>.md)."""
    s = re.sub(r"\.md$", "", str(ref).strip())
    for prefix in (settled_rel + "/", "_inbox/"):
        if s.startswith(prefix):
            return s[len(prefix):]
    return s

def iso_date(value):
    """The calendar date of an ISO date or datetime value (its first 10 chars), or None
    when the value is missing or unparseable."""
    try:
        return date.fromisoformat(str(value).strip()[:10])
    except (TypeError, ValueError):
        return None

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

def reopen_note_text(content, gate_id):
    """`content` re-opened from a parked NO-BUILD settlement: the disposition cleared, the
    resolution and resolved_at keys dropped, updated and reopened_at set to today and
    reopened_from_gate set to the gate that was met. The note body is byte-untouched."""
    end = content.find("\n---\n", 4)
    out, seen = [], set()
    updates = {"updated": today, "reopened_at": today, "reopened_from_gate": gate_id}
    for line in content[4:end].split("\n"):
        m = _FM_LINE_KEY_RE.match(line)
        name = m.group(1) if m else None
        if name in ("resolution", "resolved_at"):
            continue
        if name == "disposition":
            out.append("disposition:")
            continue
        if name in updates:
            out.append("%s: %s" % (name, updates[name]))
            seen.add(name)
            continue
        out.append(line)
    for k in ("updated", "reopened_at", "reopened_from_gate"):
        if k not in seen:
            out.append("%s: %s" % (k, updates[k]))
    return "---\n" + "\n".join(out) + content[end:]

def eval_command_gate(gate_id, timeout_s):
    """Evaluate one registered command gate through the reader; its exit code, or None when no
    reader is installed. The reader is handed the same rules file this run resolved."""
    if not reopen_gate_script:
        return None
    try:
        wait = float(timeout_s) + 15
    except (TypeError, ValueError):
        wait = 45
    try:
        proc = subprocess.run(["bash", reopen_gate_script, "--eval", gate_id], shell=False,
                              timeout=wait, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              env=dict(os.environ, PLANS_RULES_PATH=rules_path))
    except (subprocess.TimeoutExpired, OSError):
        return 5
    return proc.returncode

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

# --- Capture freeze (read-only) ----------------------------------------------
# A spoke holding a freeze record (inbox.capture_freeze_record, with <spoke> standing for the
# spoke key) has opened a freeze: the record is exactly one line `start_sha=<40-hex>`, the plans
# repo commit that recorded the opening ruling. Every open flat note of that spoke added to
# _inbox/ after that commit (committed, staged or untracked) must name a target: ABSORB into a
# key that resolves to a plan or sub-plan manifest, or a STANDALONE note of class post-release
# (the next patch release). Any other class stays open. No record means no freeze. A record that
# cannot be read as a sha of this plans repo cannot be evaluated, and says so.
_FREEZE_LINE_RE = re.compile(r"^start_sha=([0-9a-f]{40})$")
freeze_pattern = inbox_cfg.get("capture_freeze_record", "")

def _git(*args):
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    return subprocess.run(["git", "-C", plans_root] + list(args), stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60)

def _git_lines(*args):
    p = _git(*args)
    if p.returncode != 0:
        return None
    return [ln for ln in p.stdout.decode("utf-8", "replace").split("\n") if ln]

def freeze_spokes():
    """Spoke keys whose freeze record exists, in sorted order."""
    if "<spoke>" not in freeze_pattern:
        return []
    head, tail = freeze_pattern.split("<spoke>", 1)
    base = os.path.join(plans_root, head)
    out = []
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for n in names:
        if os.path.isfile(os.path.join(base, n + tail)):
            out.append(n)
    return out

def freeze_eval(spoke):
    """One spoke's freeze state: {spoke, freeze, start_sha, open[, error]}."""
    res = {"spoke": spoke, "freeze": False, "start_sha": None, "open": []}
    if "<spoke>" not in freeze_pattern:
        return res
    rec = os.path.join(plans_root, freeze_pattern.replace("<spoke>", spoke))
    if not os.path.isfile(rec):
        return res
    res["freeze"] = True
    try:
        with open(rec, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        res["error"] = "the freeze record cannot be read (%s)" % exc
        return res
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    m = _FREEZE_LINE_RE.match(lines[0]) if len(lines) == 1 else None
    if not m:
        res["error"] = "the freeze record is not exactly one line start_sha=<40-hex>"
        return res
    sha = m.group(1)
    res["start_sha"] = sha
    try:
        top = _git("rev-parse", "--show-toplevel")
        if (top.returncode != 0 or os.path.realpath(top.stdout.decode("utf-8", "replace").strip())
                != os.path.realpath(plans_root)):
            res["error"] = "the plans root is not a git repository"
            return res
        if _git("cat-file", "-e", sha + "^{commit}").returncode != 0:
            res["error"] = "start_sha is not a commit of the plans repository"
            return res
        added = _git_lines("log", "--no-renames", "--diff-filter=A", "--name-only", "--format=",
                           sha + "..HEAD", "--", "_inbox/")
        staged = _git_lines("diff", "--cached", "--name-only", "--diff-filter=A", "--", "_inbox/")
        untracked = _git_lines("ls-files", "--others", "--exclude-standard", "--", "_inbox/")
    except (OSError, subprocess.SubprocessError) as exc:
        res["error"] = "git could not be run (%s)" % exc
        return res
    if added is None or staged is None or untracked is None:
        res["error"] = "git could not list the notes added after start_sha"
        return res
    seen = set()
    for rel in added + staged + untracked:
        parts = rel.split("/")
        if len(parts) != 2 or parts[0] != "_inbox" or not parts[1].endswith(".md") \
                or parts[1].startswith("_"):
            continue
        slug = parts[1][:-3]
        if slug in seen:
            continue
        seen.add(slug)
        fm = parse_frontmatter(os.path.join(plans_root, rel))
        if fm is None or fm.get("type", "").strip("\"'") != inbox_type:
            continue
        if fm.get("project", "").strip("\"'") != spoke or fm.get("resolution", "").strip("\"'"):
            continue
        disp = fm.get("disposition", "").strip("\"'")
        target = fm.get("absorbed_into", "").strip("\"'")
        if disp == "ABSORB" and resolve_plan_dir(target)[0]:
            continue
        if disp == "STANDALONE" and fm.get("release_class", "").strip("\"'") == "post-release":
            continue
        res["open"].append({"inbox_slug": slug, "disposition": disp, "absorbed_into": target})
    res["open"].sort(key=lambda o: o["inbox_slug"])
    return res

if freeze_check:
    spokes = [freeze_spoke] if freeze_spoke else freeze_spokes()
    code = 0
    if not spokes:
        print(json.dumps({"spoke": None, "freeze": False, "start_sha": None, "open": []}))
    for sp in spokes:
        r = freeze_eval(sp)
        print(json.dumps(r, ensure_ascii=False))
        if "error" in r:
            if os.environ.get("FINDINGS_OUTPUT", ""):  # stdout stays the one JSON object
                emit({"finding": "inbox-capture-freeze-unevaluable", "spoke": sp,
                      "reason": r["error"], "detected_at": today})
            code = 2
        elif r["open"] and code == 0:
            code = 1
    sys.exit(code)

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
            cols = split_cells(st)
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
absorb_map = {}         # note slug -> {plan key: (plan status, plan date)} from absorbed_notes[]
nonterminal_joins = set()  # settled_rows indexes of join rows whose listing plan is non-terminal
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
    # after the walks — the note-side row is richer: linked and dated by resolved_at), and
    # so does an active note row while this plan is non-terminal (nonterminal_joins).
    # The same listing also feeds absorb_map, which the inbox pass's manifest-side
    # settle arm reads (plan date: completed_at, fallback updated).
    an = manifest.get("absorbed_notes")
    if isinstance(an, list):
        _plan_date = iso_date(manifest.get("completed_at")) or iso_date(manifest.get("updated"))
        for _ref in an:
            _ref = str(_ref).strip()
            if not _ref:
                continue
            a_slug = absorbed_ref_slug(_ref)
            absorb_map.setdefault(a_slug, {})[entry] = (status, _plan_date)
            a_projdir = resolve_project_dir(manifest.get("project"))
            a_settled = str(manifest.get("completed_at") or manifest.get("updated")
                            or manifest.get("phase_2_scaffolded_at") or "")
            a_landed_b = "%s (%s)" % (md_plan_link(entry), status or "?")
            a_landed_i = "%s (%s)" % (md_plan_link(entry, rel="../"), status or "?")
            if status not in terminal_status:
                nonterminal_joins.add(len(settled_rows))
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

# --- NO-BUILD watcher: re-open a parked note whose registered gate is met ------------------
# Runs before the flat walk so a note it moves back renders as an active row in this same run.
# A manual gate is never evaluated; a blank or unregistered id leaves the note settled with an
# advisory; a command gate is run by the reader (exit 0 = met). The one carve-out to forward-only
# settlement: the note moves back flat only when no flat note already owns the slug.
_parked_abs = os.path.join(plans_root, *settled_rel.split("/"))
if os.path.isdir(_parked_abs):
    for entry in sorted(os.listdir(_parked_abs)):
        if not entry.endswith(".md") or entry.startswith("_"):
            continue
        full = os.path.join(_parked_abs, entry)
        if not os.path.isfile(full):
            continue
        fm = parse_frontmatter(full)
        if fm is None or fm.get("type", "").strip() != inbox_type:
            continue
        if fm.get("disposition", "").strip() != "NO-BUILD":
            continue
        slug = entry[:-3]
        gate_id = fm.get("reopen_gate", "").strip()
        gate = reopen_gates.get(gate_id) if gate_id else None
        if not isinstance(gate, dict) or gate_id.startswith("_"):
            emit({"finding": "inbox-reopen-gate-unknown", "file": "%s/%s" % (settled_rel, entry),
                  "inbox_slug": slug, "reopen_gate": gate_id,
                  "detected_at": today, "first_seen": today})
            continue
        if gate.get("kind") != "command":
            continue  # a manual gate: an operator re-opens the note
        rc = eval_command_gate(gate_id, gate.get("timeout_s"))
        if rc is None:
            print("backlog-index: no re-open gate reader installed; gate '%s' of '%s' not evaluated"
                  % (gate_id, slug), file=sys.stderr)
            continue
        if rc != 0:
            if rc != 1:
                print("backlog-index: re-open gate '%s' of '%s' errored (exit %d); note left settled"
                      % (gate_id, slug, rc), file=sys.stderr)
            continue
        dest = os.path.join(inbox_dir, entry)
        if os.path.exists(dest):
            emit({"finding": "inbox-settled-move-conflict", "file": "%s/%s" % (settled_rel, entry),
                  "inbox_slug": slug, "dest": "_inbox/%s" % entry, "direction": "reopen",
                  "detected_at": today, "first_seen": today})
            continue
        emit({"finding": "inbox-reopened", "file": entry, "inbox_slug": slug,
              "reopen_gate": gate_id, "reopened_at": today,
              "settled_path": "%s/%s" % (settled_rel, entry), "detected_at": today})
        if not dry_run:
            with open(full, encoding="utf-8") as fh:
                _parked_text = fh.read()
            atomic_write(full, reopen_note_text(_parked_text, gate_id))
            os.makedirs(inbox_dir, exist_ok=True)
            os.replace(full, dest)

if os.path.isdir(inbox_dir):
    yaml_absent_notice = False
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

        # YAML validity advisory (flat notes only — settled notes are never checked):
        # the block a YAML reader parses must safe_load to a mapping. Advisory-only —
        # no byte changes, the row still renders below, the exit is unchanged. When
        # PyYAML is not importable the check is skipped and one stderr notice prints
        # (once, at the first flat note walked).
        if yaml is None:
            if not yaml_absent_notice:
                sys.stderr.write("backlog-index: inbox frontmatter not YAML-checked"
                                 " (PyYAML not importable)\n")
                yaml_absent_notice = True
        else:
            _yerr = fm_yaml_error(full)
            if _yerr:
                emit({"finding": "inbox-frontmatter-invalid", "file": entry,
                      "inbox_slug": slug, "error": _yerr,
                      "detected_at": today, "first_seen": today})

        promoted_to = fm.get("promoted_to", "").strip()
        absorbed_into = fm.get("absorbed_into", "").strip()
        disposition = fm.get("disposition", "").strip()
        resolution = fm.get("resolution", "").strip()
        project = fm.get("project", "").strip()
        if not project:
            highlights["missing_project"].append(slug)

        # --- closure loop: manifest-side settle over absorbed_notes[] ---
        # A flat note with no target, no resolution and an empty or ABSORB disposition
        # takes its target from the ONE terminal plan that lists it, so the plan-side
        # record alone settles it. The signal is indirect, so it never overrides a
        # deliberate triage and never settles a note captured after the plan's date
        # (a reused slug); each refusal writes nothing and emits one advisory. Runs
        # before the ABSORB-without-target backstop, which a note it settles no longer
        # trips.
        manifest_settle = False
        _claims = absorb_map.get(slug, {})
        if not absorbed_into and not promoted_to and not resolution and _claims:
            _term = sorted(k for k, (st, _d) in _claims.items() if st in terminal_status)
            if _term:
                reason = ""
                if disposition and disposition != "ABSORB":
                    reason = "disposition-conflict"
                elif len(_term) > 1:
                    reason = "multi-claim"
                else:
                    _created = iso_date(fm.get("created"))
                    _pdate = _claims[_term[0]][1]
                    if _created is None:
                        reason = "created-unknown"
                    elif _pdate is None:
                        reason = "plan-date-unknown"
                    elif _created > _pdate:
                        reason = "created-after-plan"
                if reason:
                    _row = {"finding": "inbox-absorb-manifest-ambiguous", "file": entry,
                            "inbox_slug": slug, "reason": reason, "plans": _term}
                    if reason == "disposition-conflict":
                        _row["disposition"] = disposition
                    _row.update({"detected_at": today, "first_seen": today})
                    emit(_row)
                else:
                    absorbed_into = _term[0]
                    disposition = "ABSORB"
                    manifest_settle = True

        # --- closure loop: ABSORB-without-target backstop (mechanical mirror of T-2) ---
        # The free-text prefix form (`ABSORB <target>`) names no machine-readable target
        # either, so it matches too.
        if (disposition == "ABSORB" or disposition.startswith("ABSORB ")) and not absorbed_into:
            emit({"finding": "inbox-absorb-target-missing", "file": entry, "inbox_slug": slug,
                  "disposition": disposition, "detected_at": today, "first_seen": today})
            highlights["absorb_no_target"].append(slug)

        # --- closure loop: NO-BUILD settles under its registered re-open gate ---
        # A decided "no" leaves the active table: a flat note with disposition NO-BUILD and a
        # registered reopen_gate is stamped resolution: parked and moved to the settled home
        # through the same settle-time move. A blank or unregistered id is an advisory and the
        # note stays flat; a note whose gate equals the gate it was last re-opened from stays
        # flat too (a fresh decision is required, so a gate cannot flap the note).
        if disposition == "NO-BUILD" and not resolution:
            _gate = fm.get("reopen_gate", "").strip()
            _from = fm.get("reopened_from_gate", "").strip()
            if (not _gate or _gate.startswith("_")
                    or not isinstance(reopen_gates.get(_gate), dict)):
                emit({"finding": "inbox-reopen-gate-unknown", "file": entry, "inbox_slug": slug,
                      "reopen_gate": _gate, "detected_at": today, "first_seen": today})
            elif _gate == _from:
                emit({"finding": "inbox-reopen-gate-repeat", "file": entry, "inbox_slug": slug,
                      "reopen_gate": _gate, "detected_at": today, "first_seen": today})
            else:
                stamp = [("resolution", "parked"), ("resolved_at", today), ("updated", today)]
                new_note = apply_fm_updates(content, stamp)
                dest_dir = os.path.join(plans_root, *settled_rel.split("/"))
                dest = os.path.join(dest_dir, entry)
                move_ok = not os.path.exists(dest)
                if not move_ok and not os.path.exists(full):
                    continue  # a concurrent run already moved this note; render it once, there
                emit({"finding": "inbox-note-settled", "file": entry, "inbox_slug": slug,
                      "resolution": "parked", "target": "", "target_key": "",
                      "resolved_at": today, "detected_at": today,
                      "settled_path": ("%s/%s" % (settled_rel, entry)) if move_ok
                                      else ("_inbox/%s" % entry),
                      "source": "no-build"})
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
                fm.update(stamp)
                resolution = "parked"

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
                    stamp = [("resolution", res_kind), ("resolved_at", today), ("updated", today)]
                    if manifest_settle:
                        stamp = [("disposition", "ABSORB"), ("absorbed_into", plan_key)] + stamp
                    new_note = apply_fm_updates(content, stamp)
                    if new_note != content:
                        # Settle-time move (forward-only): the stamp EVENT relocates the
                        # note to the settled home in the same run. Never clobbers — a
                        # destination collision leaves the note flat with an advisory.
                        dest_dir = os.path.join(plans_root, *settled_rel.split("/"))
                        dest = os.path.join(dest_dir, entry)
                        move_ok = not os.path.exists(dest)
                        if not move_ok and not os.path.exists(full):
                            # A concurrent run already stamped and moved this note: write
                            # nothing (a write here would re-create a flat duplicate) and let
                            # the settled-home walk render it once. The window left between
                            # this existence check and the write below is microseconds; no
                            # lock covers it.
                            continue
                        emit({"finding": "inbox-note-settled", "file": entry, "inbox_slug": slug,
                              "resolution": res_kind, "target": target, "target_key": plan_key,
                              "resolved_at": today, "detected_at": today,
                              "settled_path": ("%s/%s" % (settled_rel, entry)) if move_ok
                                              else ("_inbox/%s" % entry),
                              "source": "manifest-absorbed_notes" if manifest_settle
                                        else "note"})
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
                        fm.update(stamp)  # render this run from the stamped values
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
        # Disposition advisories (findings only): an active note owed a triage past the
        # advisory age, or carrying a value outside the enum.
        if not disposition:
            _since = iso_date(fm.get("updated")) or iso_date(fm.get("created"))
            _age = (date.today() - _since).days if _since else None
            if _age is None or _age >= stale_days[0]:
                emit({"finding": "inbox-disposition-missing", "file": entry, "inbox_slug": slug,
                      "stale_for_days": _age,
                      "tier": ("age-unknown" if _age is None else
                               "escalation" if _age >= stale_days[1] else "advisory"),
                      "detected_at": today, "first_seen": today})
        elif disposition not in disposition_enum:
            emit({"finding": "inbox-disposition-out-of-enum", "file": entry, "inbox_slug": slug,
                  "disposition": disposition, "valid_dispositions": disposition_enum,
                  "detected_at": today, "first_seen": today})
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
# (manifest absorbed_notes[]) + resolved notes (flat or settled-home). The note's own
# row, active or settled, wins over a manifest-side absorption join for the same slug:
# a settled note-side row always (it is linked and dated by resolved_at), an active
# row while the join's listing plan is non-terminal (the note is still owed its
# outcome, so it renders once, as active). A terminal plan's join stays beside an
# active note, because that note is one the manifest-side arm held back with an
# advisory. The join row stays the fallback record for a note that renders no row of
# its own (tombstoned, malformed, or outside the funnel vocabulary).
_note_slugs = {r[1][len("0note:"):] for r in settled_rows if r[1].startswith("0note:")}
_active_slugs = {n["slug"] for n in active_note_roster}
settled_rows = [r for i, r in enumerate(settled_rows)
                if not (r[1].startswith("2absorbed:")
                        and (r[1][len("2absorbed:"):] in _note_slugs
                             or (i in nonterminal_joins
                                 and r[1][len("2absorbed:"):] in _active_slugs)))]
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

# Near-duplicate sweep: one inbox-near-duplicate-pair finding per unlinked pair of OPEN flat
# notes (a pair linked by either note's distinct_from is omitted), on every run. The scorer
# is read-only; a run that cannot score says so on stderr and indexes on.
if near_dup_script and os.path.isdir(inbox_dir):
    try:
        nd = subprocess.run(["bash", near_dup_script, "--pairs", "--inbox", inbox_dir],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=120, env=dict(os.environ, PLANS_RULES_PATH=rules_path))
        if nd.returncode != 0:
            print("backlog-index: near-duplicate scan skipped (scorer exited %d: %s)"
                  % (nd.returncode, nd.stderr.decode("utf-8", "replace").strip()), file=sys.stderr)
        else:
            for ln in nd.stdout.decode("utf-8", "replace").split("\n"):
                parts = ln.split("\t")
                if len(parts) == 3:
                    emit({"finding": "inbox-near-duplicate-pair", "tier": "advisory",
                          "inbox_slugs": [parts[0], parts[1]], "signals": parts[2],
                          "detected_at": today})
    except (OSError, subprocess.SubprocessError) as exc:
        print("backlog-index: near-duplicate scan skipped (%s)" % exc, file=sys.stderr)

# Capture freeze: per spoke holding a record, one inbox-capture-freeze-open per open flat note
# added after the recorded sha that names no target, or one inbox-capture-freeze-unevaluable when
# the record cannot be evaluated. No record, nothing reported.
for _sp in freeze_spokes():
    _fz = freeze_eval(_sp)
    if "error" in _fz:
        emit({"finding": "inbox-capture-freeze-unevaluable", "spoke": _sp,
              "reason": _fz["error"], "detected_at": today})
        continue
    for _o in _fz["open"]:
        emit({"finding": "inbox-capture-freeze-open", "tier": "advisory", "spoke": _sp,
              "inbox_slug": _o["inbox_slug"], "start_sha": _fz["start_sha"],
              "disposition": _o["disposition"], "detected_at": today})

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

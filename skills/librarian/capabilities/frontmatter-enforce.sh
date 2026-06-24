#!/bin/bash
# frontmatter-enforce — Validate and optionally fix frontmatter on vault files.
# Sources `hooks/lib/findings.sh` + `hooks/lib/manifest.sh`.
# Two phases per invocation:
#   1. Per-file validation — walks scope, checks required fields per 26-row type
#      table, empty optionals, tag taxonomy. Emits `frontmatter-*` findings via
#      emit_finding (stdout / FINDINGS_OUTPUT).
#   2. Drift audits (vault-wide, unless --scope):
#        (a) provides-canonicality-drift    — DC-NNN
#        (b) size-warning-{soft,strong} + size-guard-violation — SM-NNN
#        (c) Hub-spoke recommendation engine — attached to (b) severity >= warning
#        (d) schema-type-hook-coverage-gap  — ST-NNN
#      Persistent IDs: matched by (type, capability) for DC, (type, file) for SM,
#      (type, schema_key) for ST. Matched rows retain first_seen; new rows get
#      the next sequence number; resolved rows drop out on the observing run.
#      Written atomically via manifest_set to `drift_findings.*` arrays.
# CLI:
#   frontmatter-enforce.sh                     # --recent by default
#   frontmatter-enforce.sh --full              # full vault walk
#   frontmatter-enforce.sh --scope <path>      # narrow scope (skips drift audits)
#   frontmatter-enforce.sh --fix               # auto-apply auto-fix class
#   frontmatter-enforce.sh --dry-run           # summary counts only
# Scope exemptions:
#   $VAULT_ROOT/.claude/, .obsidian/, .git/, .claude/projects/, _test*
#   <projects_root>/*/CLAUDE.md (no frontmatter required; projects_root
#       parameterized via FM_PROJECTS_ROOT_DIRNAME env / vault.projects_root_dirname
#       manifest field; defaults to "Engagements" for backward compatibility)
#   Logs/ideation-brief-*.md (load-bearing symlink-or-retrofit)
# Engagement-subfolder taxonomy parameterization:
#   The four canonical sub-directories under each engagement (People, Projects,
#   Strategic, Planning) are parameterized via env / user-manifest fields:
#     - FM_PEOPLE_DIRNAME       / vault.people_dirname       (default: "People")
#     - FM_PROJECTS_SUBDIRNAME  / vault.projects_subdirname  (default: "Projects")
#     - FM_STRATEGIC_DIRNAME    / vault.strategic_dirname    (default: "Strategic")
#     - FM_PLANNING_DIRNAME     / vault.planning_dirname     (default: "Planning")
#   Defaults preserve install-convention for users who never declared
#   the fields. Path-pattern detection in detect_type() consumes the escaped
#   env values; no hardcoded substrings remain.
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"
if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || source "$_REPO_LIB/manifest.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || source "$_REPO_LIB/user-manifest-read.sh"

SCOPE=""
MODE="check"         # check | fix
WALK="recent"        # recent | full | scope
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)     SCOPE="$2"; WALK="scope"; shift 2 ;;
    --recent)    WALK="recent"; shift ;;
    --full)      WALK="full"; shift ;;
    --check)     MODE="check"; shift ;;
    --fix)       MODE="fix"; shift ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    -h|--help)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "frontmatter-enforce: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- Pre-load existing drift_findings for persistent ID reconciliation ---
EXISTING_DRIFT="$(manifest_get '.drift_findings' '{}')"
# Env-var overrides for testing (waiver-audit precedent).
DRIFT_ALLOWLIST_FILE="${FM_DRIFT_ALLOWLIST_FILE_OVERRIDE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/drift-allowlist.json}"
FOUNDATION_MASTER="${FM_FOUNDATION_MASTER:-${FOUNDATION_MASTER:-${GOVERNANCE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/governance}/foundation-master.json}}"
# --- R-52 union-load redirect (FULL-UNION) ---
# Read governance through the foundation+overlay merger so adopter Layer-3
# overlay amendments are honored (overlay wins per R-52), instead of consuming
# foundation-master RAW. Materialize the merged union ONCE to a temp file and
# point FOUNDATION_MASTER (hence the exported FM_FOUNDATION_MASTER read by the
# python _load_tag_prefixes/_load_seed_taxonomy_exempt_paths blocks) at it.
# Degrade to the raw foundation file when the merger is unavailable (loud-safe).
# Cleanup is composed into the existing EXIT trap (see _FM_UNION below).
_FM_UNION=""
_OVL="${FOUNDATION_OVERLAY_LOAD:-${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -f "$FOUNDATION_MASTER" ]; then
  _FM_UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$_FM_UNION" ] && bash "$_OVL" --foundation-path "$FOUNDATION_MASTER" \
        --overlay-path "$(dirname "$FOUNDATION_MASTER")/overlay-master.json" --force-override > "$_FM_UNION" 2>/dev/null \
        && [ -s "$_FM_UNION" ]; then
    FOUNDATION_MASTER="$_FM_UNION"
  elif [ -n "$_FM_UNION" ]; then rm -f "$_FM_UNION"; _FM_UNION=""; fi
fi
PRE_WRITE_GUARD="${FM_PRE_WRITE_GUARD_OVERRIDE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/pre-write-guard.sh}"
POST_WRITE_VERIFY="${FM_POST_WRITE_VERIFY_OVERRIDE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/post-write-verify.sh}"

VAULT_SCOPE="${SCOPE:-$VAULT_ROOT}"

export FM_EXISTING_DRIFT="$EXISTING_DRIFT"
export FM_DRIFT_ALLOWLIST_FILE="$DRIFT_ALLOWLIST_FILE"
export FM_FOUNDATION_MASTER="$FOUNDATION_MASTER"
export FM_PRE_WRITE_GUARD="$PRE_WRITE_GUARD"
export FM_POST_WRITE_VERIFY="$POST_WRITE_VERIFY"
export FM_ENGAGEMENT_ALIASES_JSON="$(umr_get_object '.vault.engagement_aliases')"
# Default "Engagements" preserves the install-convention default for
# users who never declared the field.
FM_PROJECTS_ROOT_DIRNAME_RAW="$(umr_get_string '.vault.projects_root_dirname' 2>/dev/null || true)"
export FM_PROJECTS_ROOT_DIRNAME="${FM_PROJECTS_ROOT_DIRNAME_RAW:-Engagements}"
# Parameterize engagement-subfolder taxonomy.
# Defaults preserve install-convention for users who never declared
# the fields. Each is an independent env / manifest field so non-
# vault structures (academic, generalist, etc.) can rebrand any subset.
FM_PEOPLE_DIRNAME_RAW="$(umr_get_string '.vault.people_dirname' 2>/dev/null || true)"
export FM_PEOPLE_DIRNAME="${FM_PEOPLE_DIRNAME_RAW:-People}"
FM_PROJECTS_SUBDIRNAME_RAW="$(umr_get_string '.vault.projects_subdirname' 2>/dev/null || true)"
export FM_PROJECTS_SUBDIRNAME="${FM_PROJECTS_SUBDIRNAME_RAW:-Projects}"
FM_STRATEGIC_DIRNAME_RAW="$(umr_get_string '.vault.strategic_dirname' 2>/dev/null || true)"
export FM_STRATEGIC_DIRNAME="${FM_STRATEGIC_DIRNAME_RAW:-Strategic}"
FM_PLANNING_DIRNAME_RAW="$(umr_get_string '.vault.planning_dirname' 2>/dev/null || true)"
export FM_PLANNING_DIRNAME="${FM_PLANNING_DIRNAME_RAW:-Planning}"
export FM_VAULT_ROOT="$VAULT_ROOT"

# --- Missing-vault guard ---
# paths.sh leaves VAULT_ROOT empty on a fresh manifest-less adopter (paths.sh:17-19
# documented contract — no install-convention default; missing-vault is
# graceful-degrade, every hook exits 0 on missing manifest). Honor that contract
# here before spawning the python block: an empty/absent VAULT_ROOT would reach
# os.listdir('') in canonical_scope_files() and raise FileNotFoundError under
# set -euo pipefail, aborting session-close. Exit 0 = capability records ok/skipped,
# never error.
# producer (paths.sh) rather than re-derive `[ -z … ] || [ ! -d … ]` inline. The
# `:-0` fallback keeps the guard safe under set -u if paths.sh sourcing was
# skipped (line 55 source is conditional) — fail closed (skip) on no vault.
if [ "${VAULT_CONFIGURED:-0}" != "1" ]; then
  echo "frontmatter-enforce: no vault configured (VAULT_ROOT empty) — skipping" >&2
  exit 0
fi

# Tmp file for merged drift_findings JSON emitted by the python block below.
DRIFT_OUT="$(mktemp -t fm-enforce-drift.XXXXXX)"
trap 'rm -f "$DRIFT_OUT" ${_FM_UNION:+"$_FM_UNION"}' EXIT

python3 - "$VAULT_SCOPE" "$WALK" "$MODE" "$DRY_RUN" "$DRIFT_OUT" <<'PY'
import json, os, re, sys, time, fnmatch
from datetime import datetime, timezone

vault_scope, walk, mode, dry_run_s, drift_out_path = sys.argv[1:6]
dry_run = (dry_run_s == "true")
fix_mode = (mode == "fix")

# Read from FM_PROJECTS_ROOT_DIRNAME env (set from .vault.projects_root_dirname
# via umr_get_string above). Fall back to "Engagements" if empty/unset for
# backward compatibility with users who never declared the field.
PROJ_DIR = (os.environ.get("FM_PROJECTS_ROOT_DIRNAME") or "").strip() or "Engagements"
PD = re.escape(PROJ_DIR)
# Parameterize engagement-subfolder taxonomy.
# Each subfolder name is independently overridable via env / user-manifest;
# fallbacks preserve the canonical install convention.
PEOPLE_DIR = (os.environ.get("FM_PEOPLE_DIRNAME") or "").strip() or "People"
PROJECTS_SUBDIR = (os.environ.get("FM_PROJECTS_SUBDIRNAME") or "").strip() or "Projects"
STRATEGIC_DIR = (os.environ.get("FM_STRATEGIC_DIRNAME") or "").strip() or "Strategic"
PLANNING_DIR = (os.environ.get("FM_PLANNING_DIRNAME") or "").strip() or "Planning"
PD_PEOPLE = re.escape(PEOPLE_DIR)
PD_PROJECTS = re.escape(PROJECTS_SUBDIR)
PD_STRATEGIC = re.escape(STRATEGIC_DIR)
PD_PLANNING = re.escape(PLANNING_DIR)
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
vault_root = os.environ["FM_VAULT_ROOT"]
now = time.time()
today_iso = datetime.now(timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%S")
today_date = datetime.now(timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%d")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# ---------- frontmatter parsing ----------
FM_START = re.compile(r"^---\s*$")
def parse_frontmatter(path):
    """Return (fm_dict, body, fm_end_offset). fm_end_offset is -1 if no fm."""
    try:
        with open(path, "r") as f:
            text = f.read()
    except Exception:
        return {}, "", -1
    lines = text.split("\n")
    if not lines or not FM_START.match(lines[0] or ""):
        return {}, text, -1
    fm_end_line = -1
    for i in range(1, len(lines)):
        if FM_START.match(lines[i] or ""):
            fm_end_line = i
            break
    if fm_end_line == -1:
        return {}, text, -1
    fm_text = "\n".join(lines[1:fm_end_line])
    body = "\n".join(lines[fm_end_line + 1:])
    fm = {}
    list_key = None
    for raw in fm_text.split("\n"):
        if not raw.strip():
            continue
        if list_key is not None and raw.lstrip().startswith("- "):
            item = raw.lstrip()[2:].strip()
            # Unquote: YAML `- "foo"` or `- 'foo'`
            if (len(item) >= 2
                and ((item[0] == '"' and item[-1] == '"')
                     or (item[0] == "'" and item[-1] == "'"))):
                item = item[1:-1]
            fm[list_key].append(item)
            continue
        list_key = None
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$", raw)
        if not m:
            continue
        key, val = m.group(1), m.group(2).rstrip()
        if val == "" or val is None:
            # possibly a YAML list begins on next line
            list_key = key
            fm[key] = []
        elif val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            if not inner:
                fm[key] = []
            else:
                fm[key] = [x.strip().strip('"').strip("'") for x in inner.split(",")]
        else:
            stripped = val.strip()
            # Unquote: `""` or `''` => empty string
            if stripped in ('""', "''"):
                fm[key] = ""
            elif (len(stripped) >= 2
                  and ((stripped[0] == '"' and stripped[-1] == '"')
                       or (stripped[0] == "'" and stripped[-1] == "'"))):
                fm[key] = stripped[1:-1]
            elif stripped.lower() == "null":
                fm[key] = ""
            else:
                fm[key] = stripped
    return fm, body, fm_end_line

# ---------- type detection (path patterns) ----------
def detect_type(rel, fm):
    # Frontmatter `type:` takes precedence if explicitly set
    t = fm.get("type") if isinstance(fm.get("type"), str) else None
    if t:
        return t
    # Path pattern inference
    if re.match(rf"^{PD}/[^/]+/{PD_PEOPLE}/[^/]+\.md$", rel):
        return "people"
    if re.match(rf"^{PD}/[^/]+/{PD_PROJECTS}/[^/]+/.+ - PRD\.md$", rel):
        return "prd"
    if re.match(rf"^{PD}/[^/]+/{PD_PROJECTS}/[^/]+/.+ - Updates\.md$", rel):
        return "updates"
    if re.match(rf"^{PD}/[^/]+/{PD_PROJECTS}/[^/]+/.+ - Context\.md$", rel):
        return "context"
    if re.match(rf"^{PD}/[^/]+/{PD_PROJECTS}/[^/]+/[^/]+\.md$", rel):
        return "project"
    if re.match(rf"^{PD}/[^/]+/.+ - Overview\.md$", rel):
        return "overview"
    if re.match(rf"^{PD}/[^/]+/.+ - Updates\.md$", rel):
        return "updates"
    if re.match(rf"^{PD}/[^/]+/.+ - Reference\.md$", rel):
        return "reference"
    if re.match(rf"^{PD}/[^/]+/CLAUDE\.md$", rel):
        return "navigation"
    if re.match(rf"^{PD}/[^/]+/{PD_STRATEGIC}/.+\.md$", rel):
        return "strategic"
    if re.match(rf"^{PD}/[^/]+/{PD_PLANNING}/.+\.md$", rel):
        return "planning"
    if rel.startswith("Daily/") and rel.endswith(" - Briefing.md"):
        return "briefing"
    if rel.startswith("Daily/") and rel.endswith(".md"):
        return "daily-note"
    if rel.startswith("Inbox/"):
        return "reference"  # inbox files are consumed by dashboard — loose schema
    if rel.startswith("Archive/Inbox/"):
        return "inbox-archive"
    if rel.startswith("Logs/"):
        return "log"
    if rel.startswith("Skills/"):
        return "skill-spec"
    if rel.startswith("Reference/"):
        return "reference"
    return None

# ---------- required-field matrix (alias collapse applied) ----------
# REQUIRED is READ from the composed governance bundle
# (foundation-master.json#frontmatter.types[<type>].required), NOT hand-mirrored.
# The hand-mirror previously drifted from the composed bundle — notably the
# `reference` type was missing entirely, silently skipping its required-field
# enforcement. This read mirrors the drift-sweep.sh precedent
# (drift-sweep.sh:152-181): same composed-bundle source (FM_FOUNDATION_MASTER,
# already union-redirected through the overlay merger), same .frontmatter.types
# path, same `_`-prefixed-key skip so the `_description` sentinel is never
# enumerated as a real type. Adopter extensions resolve via overlay-master at
# bundle composition time; reading the composed view honors them for free.
ALIAS = {"file-index": "index"}

def _load_required_matrix():
    bundle_path = os.environ.get("FM_FOUNDATION_MASTER", "")
    try:
        with open(bundle_path) as fh:
            bundle = json.load(fh)
    except Exception:
        return {}
    types = (bundle.get("frontmatter", {}) or {}).get("types", {}) or {}
    if not isinstance(types, dict):
        return {}
    matrix = {}
    for key, spec in types.items():
        if key.startswith("_"):
            continue
        req = (spec or {}).get("required", [])
        if isinstance(req, list):
            matrix[key] = [f for f in req if isinstance(f, str)]
    return matrix

REQUIRED = _load_required_matrix()

# Deliverables live under the Work/ surface (a symlink to the external work home).
# os.walk(followlinks=False) above does NOT descend into that symlink during a
# whole-vault audit, so deliverable enforcement is reached by a SCOPED invocation
# (`frontmatter-enforce.sh --scope <vault>/Work`) — the same dedicated-scan pattern
# library-index uses for the _library physical root. This REQUIRED row makes the
# field check real once the scan reaches a deliverable.

# Tag prefix allowlist sourced from foundation-master#tagging.taxonomy.dimension_prefixes.
# Foundation ships system-utility dimensions (status, log); user-facing dimensions
# pending overlay-master union-resolve (T-7+T-8). Empty → tag taxonomy
# validation skips silently (graceful degradation until union-resolve lands).
def _load_tag_prefixes():
    bundle_path = os.environ.get("FM_FOUNDATION_MASTER", "")
    try:
        with open(bundle_path) as fh:
            bundle = json.load(fh)
    except Exception:
        return ()
    raw = bundle.get("tagging", {}).get("taxonomy", {}).get("dimension_prefixes", None)
    if not isinstance(raw, list):
        return ()
    return tuple((p if p.endswith("/") else p + "/") for p in raw if isinstance(p, str))

TAG_PREFIXES = _load_tag_prefixes()

# from foundation-master.json#seed_taxonomy_exempt_paths_composed (composed from
# tagging-rules.json#_rules[id=R-47].seed_taxonomy_exempt_paths via
# tools/build-foundation-master.sh). SEPARATE from the R-47 tag-PRESENCE exempt
# list (r47_exempt_paths) — this gates ONLY the tag-not-in-taxonomy membership
# arm so the foundation-shipped vault-init seed surface (Vault Writers/_index.md)
# does not flag day-one violations, while seeds stay byte-unchanged and still
# obey the tag-presence rule. NOT pre-loaded by is_exempt(); read here.
def _load_seed_taxonomy_exempt_paths():
    bundle_path = os.environ.get("FM_FOUNDATION_MASTER", "")
    try:
        with open(bundle_path) as fh:
            bundle = json.load(fh)
    except Exception:
        return ()
    raw = bundle.get("seed_taxonomy_exempt_paths_composed", None)
    if not isinstance(raw, list):
        return ()
    return tuple(p for p in raw if isinstance(p, str))

SEED_TAXONOMY_EXEMPT_PATHS = _load_seed_taxonomy_exempt_paths()

def is_seed_taxonomy_exempt(rel):
    return any(fnmatch.fnmatch(rel, g) for g in SEED_TAXONOMY_EXEMPT_PATHS)

# ---------- walk exemptions ----------
EXEMPT_DIRS = ("/.git/", "/.obsidian/", "/.claude/", "/.claude/projects/", "/_test")
def is_exempt(full_path, rel):
    if any(ex in "/" + full_path + "/" for ex in EXEMPT_DIRS):
        return True
    # Logs/ideation-brief-*.md are load-bearing — skip per CLAUDE.md convention
    if rel.startswith("Logs/ideation-brief-"):
        return True
    return False

def days_since_mtime(full):
    try:
        return (now - os.path.getmtime(full)) / 86400.0
    except Exception:
        return 0

# ---------- path-based tag inference (for --fix mode) ----------
# Engagement aliases sourced from manifest.vault.engagement_aliases{} via the
# shell-level lib/user-manifest-read.sh helper (FM_ENGAGEMENT_ALIASES_JSON env
# var carries the materialized JSON object). Each entry maps a directory name
# (case-insensitive) to a tag slug. When no alias matches, the directory name
# is slugified directly. Foundation ships an empty map; users populate as
# their engagement taxonomy stabilizes.
def _load_engagement_aliases():
    raw = os.environ.get("FM_ENGAGEMENT_ALIASES_JSON", "{}")
    try:
        aliases = json.loads(raw)
    except Exception:
        return {}
    if not isinstance(aliases, dict):
        return {}
    return {str(k).lower(): str(v) for k, v in aliases.items() if isinstance(v, str)}

ENGAGEMENT_ALIASES = _load_engagement_aliases()

def infer_tags(rel):
    inferred = []
    m = re.match(rf"^{PD}/([^/]+)/", rel)
    if m:
        eng_dir = m.group(1)
        eng_lc = eng_dir.lower()
        eng_slug = ENGAGEMENT_ALIASES.get(eng_lc)
        if not eng_slug:
            # Fall back to slugifying the directory name.
            eng_slug = re.sub(r"[^a-z0-9]+", "-", eng_lc).strip("-")
        if eng_slug:
            inferred.append(f"#engagement/{eng_slug}")
    return inferred

# ---------- scope assembly ----------
def build_scope():
    files = []
    root = vault_scope if walk != "scope" else vault_scope
    # (no crash), but guard explicitly so a non-vault/empty root degrades to no-op.
    if not root or not os.path.isdir(root):
        return files
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in ("node_modules", "_test")]
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, vault_root)
            if is_exempt(full, rel):
                continue
            if walk == "recent" and days_since_mtime(full) > 7:
                continue
            files.append((full, rel))
    return files

# ---------- per-file validation ----------
def empty_str_optional(fm, required_set):
    bad = []
    for k, v in fm.items():
        if k in required_set:
            continue
        if isinstance(v, str) and v.strip() == "":
            bad.append(k)
    return bad

def tag_violations(fm, rel=None):
    tags = fm.get("tags")
    if tags is None:
        return []
    if isinstance(tags, str):
        return [("tags-not-list", tags)]
    if not TAG_PREFIXES:
        # No allowlist configured (foundation default) — skip taxonomy check.
        return []
    # foundation-shipped vault-init seed surface — those seeds legitimately carry
    # adopter-tier dimensions the foundation taxonomy ships empty (by design).
    # Gates ONLY this membership arm; tags-not-list above still applies.
    if rel is not None and is_seed_taxonomy_exempt(rel):
        return []
    bad = []
    for t in tags:
        norm = t.lstrip("#")
        if not any(norm.startswith(p) for p in TAG_PREFIXES):
            bad.append(("tag-not-in-taxonomy", t))
    return bad

def run_per_file(files):
    per_file_findings = 0
    auto_fixed = 0
    manual = 0
    fixed_files = []
    for full, rel in files:
        fm, body, fm_end_line = parse_frontmatter(full)
        file_type = detect_type(rel, fm)

        # navigation (engagement CLAUDE.md) is exempt per SKILL.md
        if file_type == "navigation" and rel.endswith("/CLAUDE.md"):
            # still require type, engagement, updated minimally if frontmatter exists
            if not fm:
                continue

        if file_type is None:
            if fm and fm.get("type"):
                # unrecognized type — escalate to drift-sweep, not per-file
                continue
            # No type inference available, no frontmatter → skip silently
            continue

        canonical = ALIAS.get(file_type, file_type)
        required = REQUIRED.get(canonical, [])

        # --- missing required
        missing = [k for k in required if k not in fm or (isinstance(fm[k], str) and fm[k].strip() == "")]
        # --- empty optional
        empties = empty_str_optional(fm, set(required))
        # --- tag taxonomy (T-3: pass rel for seed-taxonomy exemption)
        tag_issues = tag_violations(fm, rel)

        if not (missing or empties or tag_issues):
            continue

        # --fix: auto-apply safe additions
        if fix_mode:
            changed = False
            new_fm = dict(fm)
            # updated
            if "updated" in missing and ("updated" in required):
                new_fm["updated"] = today_date
                changed = True
                missing = [k for k in missing if k != "updated"]
            # tags inference
            if ("tags" in missing or not fm.get("tags")) and "tags" in required:
                inferred = infer_tags(rel)
                if inferred:
                    new_fm["tags"] = inferred
                    changed = True
                    missing = [k for k in missing if k != "tags"]
                    tag_issues = []
            # empty optional removal
            for k in empties:
                if k in new_fm:
                    del new_fm[k]
                    changed = True
            if changed:
                _rewrite_frontmatter(full, new_fm, body, fm_end_line)
                fixed_files.append(rel)
                auto_fixed += 1

        # --- emit remaining issues
        for k in missing:
            classification = "auto-fix" if k in ("updated", "tags") else "manual"
            if classification == "manual":
                manual += 1
            emit({"finding": "frontmatter-missing-required",
                  "file": rel, "field": k,
                  "file_type": canonical, "classification": classification})
            per_file_findings += 1
        for k in empties:
            emit({"finding": "frontmatter-empty-optional",
                  "file": rel, "field": k, "classification": "auto-fix"})
            per_file_findings += 1
        for reason, val in tag_issues:
            emit({"finding": "frontmatter-tag-violation",
                  "file": rel, "reason": reason, "value": val, "classification": "manual"})
            per_file_findings += 1
            manual += 1
    return per_file_findings, auto_fixed, manual, fixed_files

def _rewrite_frontmatter(path, fm, body, fm_end_line):
    """Survivorship: preserve all existing key order, only modify the keys we changed.
    Defensive: re-read the file and edit in place line-by-line to preserve formatting
    we don't understand (quoted strings, multi-line, comments)."""
    with open(path, "r") as f:
        lines = f.read().split("\n")
    if not lines or not FM_START.match(lines[0] or ""):
        return
    end = -1
    for i in range(1, len(lines)):
        if FM_START.match(lines[i] or ""):
            end = i
            break
    if end == -1:
        return
    # Rebuild frontmatter lines preserving order of keys in the old block, then
    # append any newly-added keys at the end of the fm block.
    old_keys_in_order = []
    for raw in lines[1:end]:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:", raw)
        if m:
            old_keys_in_order.append(m.group(1))
    new_fm_lines = []
    seen = set()
    for k in old_keys_in_order:
        if k not in fm:
            continue  # removed (e.g., empty optional)
        seen.add(k)
        new_fm_lines.extend(_render_key(k, fm[k]))
    for k, v in fm.items():
        if k in seen:
            continue
        new_fm_lines.extend(_render_key(k, v))
    out_lines = [lines[0]] + new_fm_lines + [lines[end]] + lines[end + 1:]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(out_lines))
    os.replace(tmp, path)

def _render_key(k, v):
    if isinstance(v, list):
        if not v:
            return [f"{k}: []"]
        out = [f"{k}:"]
        for item in v:
            out.append(f"  - {item}")
        return out
    return [f"{k}: {v}"]

# ---------- drift audits (only run on vault-wide / non-scoped) ----------

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def load_drift_allowlist():
    doc = load_json(os.environ["FM_DRIFT_ALLOWLIST_FILE"])
    if not isinstance(doc, dict):
        return []
    return [e.get("capability") for e in (doc.get("provides_overlap") or [])
            if isinstance(e, dict) and e.get("capability")]

def canonical_scope_files():
    """Vault root depth-1 + Skills/**"""
    out = []
    # FileNotFoundError on an empty vault_root, aborting session-close under
    # set -euo pipefail. Guard before the walk so a missing vault degrades to [].
    if not vault_root or not os.path.isdir(vault_root):
        return out
    # vault root depth-1
    for fn in os.listdir(vault_root):
        full = os.path.join(vault_root, fn)
        if os.path.isfile(full) and fn.endswith(".md"):
            out.append((full, fn))
    for sub in ("Skills",):
        base = os.path.join(vault_root, sub)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for fn in filenames:
                if fn.endswith(".md"):
                    full = os.path.join(dirpath, fn)
                    out.append((full, os.path.relpath(full, vault_root)))
    return out

def drift_provides_canonicality(allowlist):
    owners = {}  # capability -> set(rel)
    for full, rel in canonical_scope_files():
        fm, _, _ = parse_frontmatter(full)
        prov = fm.get("provides")
        if not prov:
            continue
        if isinstance(prov, str):
            prov = [prov]
        for cap in prov:
            owners.setdefault(cap, set()).add(rel)
    findings = []
    for cap, files in sorted(owners.items()):
        if len(files) < 2:
            continue
        if cap in allowlist:
            continue
        file_list = sorted(files)
        sev = "warning"
        for f in file_list:
            if "/" not in f:
                sev = "blocking"
                break
        findings.append({
            "type": "provides-canonicality-drift",
            "severity": sev,
            "capability": cap,
            "owners": file_list,
            "remediation": f"Designate one canonical owner for '{cap}'; remove it from every other provides: array.",
        })
    return findings

# ---------- size monitoring + hub-spoke ----------
STRUCTURAL = {"frontmatter", "version history", "summary", "behavioral rules"}

def parse_h2_h3(full):
    """Return list of (title, line_count_of_section)."""
    try:
        with open(full) as f:
            lines = f.read().split("\n")
    except Exception:
        return []
    sections = []
    i = 0
    cur_title = None
    cur_start = 0
    while i < len(lines):
        m = re.match(r"^(#{2,3})\s+(.+)$", lines[i])
        if m:
            if cur_title is not None:
                sections.append((cur_title, i - cur_start))
            cur_title = m.group(2).strip()
            cur_start = i
        i += 1
    if cur_title is not None:
        sections.append((cur_title, len(lines) - cur_start))
    return sections

def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def hub_spoke_recommendation(full, rel):
    sections = parse_h2_h3(full)
    candidates = [s for s in sections if s[0].lower() not in STRUCTURAL]
    if not candidates:
        return None
    largest = max(candidates, key=lambda s: s[1])
    if largest[1] < 30:
        return "Manual review needed — no single section is large enough to extract cleanly."
    basename = os.path.splitext(os.path.basename(rel))[0]
    parent = os.path.dirname(rel)
    spoke_dir = (f"{parent}/{basename}" if parent else basename)
    slug = slugify(largest[0])
    proposed = f"{spoke_dir}/{basename} - {slug}.md"
    full_spoke_dir = os.path.join(vault_root, spoke_dir)
    has_spokes = os.path.isdir(full_spoke_dir)
    if not has_spokes:
        siblings = [n for n in (os.listdir(os.path.join(vault_root, parent) if parent else vault_root) or [])
                    if n.startswith(f"{basename} - ") and n.endswith(".md")]
        has_spokes = bool(siblings)
    if not has_spokes:
        return (f"Convert to hub-spoke: create folder '{spoke_dir}/', extract H2 "
                f"'{largest[0]}' (~{largest[1]} lines) to '{proposed}', leave a stub redirect in the hub.")
    return (f"Add new spoke alongside existing: extract H2 '{largest[0]}' "
            f"(~{largest[1]} lines) to '{proposed}'.")

def drift_size_monitoring():
    findings = []
    # Walk every .md file except exempt dirs
    for dirpath, dirnames, filenames in os.walk(vault_root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in ("Archive", "Logs")]
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, vault_root)
            if is_exempt(full, rel):
                continue
            fm, _, _ = parse_frontmatter(full)
            declared_max = fm.get("max_lines")
            declared_source = "frontmatter"
            if declared_max is None:
                is_root = (os.path.dirname(rel) == "")
                if not is_root:
                    continue
                declared_max = 400
                declared_source = "default_root"
            try:
                declared_max = int(declared_max)
            except Exception:
                continue
            try:
                with open(full) as f:
                    actual = sum(1 for _ in f)
            except Exception:
                continue
            pct = (actual / declared_max) * 100.0 if declared_max else 0
            finding_type = None
            severity = None
            if pct < 70:
                continue
            elif pct < 85:
                finding_type, severity = "size-warning-soft", "info"
            elif pct < 100:
                finding_type, severity = "size-warning-strong", "warning"
            else:
                finding_type, severity = "size-guard-violation", "blocking"
            canonical = (os.path.dirname(rel) == "" or rel.startswith("Skills/"))
            recommendation = None
            if canonical and severity in ("warning", "blocking"):
                recommendation = hub_spoke_recommendation(full, rel)
            findings.append({
                "type": finding_type,
                "severity": severity,
                "file": rel,
                "declared_max": declared_max,
                "declared_source": declared_source,
                "actual_lines": actual,
                "pct_of_max": round(pct, 1),
                "delta": actual - declared_max,
                "recommendation": recommendation,
            })
    return findings

# ---------- schema-type-hook-coverage-gap ----------
def drift_schema_type_coverage():
    # post-dissolution SoT — foundation-master.json#frontmatter.types (vault-schema
    # dissolved in T-4; frontmatter-rules.json:7 absorbed_from_vault_schema).
    # `or {}` is LOAD-BEARING: load_json returns None (not {}) on failure, so without
    # it bundle.get("frontmatter") would raise AttributeError on the graceful-degrade
    # path — re-introducing's exact crash before the isinstance guard below.
    bundle = load_json(os.environ.get("FM_FOUNDATION_MASTER", "")) or {}
    schema = (bundle.get("frontmatter") or {}).get("types") or {}
    if not isinstance(schema, dict):
        return []
    schema_keys = [k for k in schema.keys() if not k.startswith("_")]
    try:
        with open(os.environ["FM_PRE_WRITE_GUARD"]) as f:
            pg = f.read()
    except Exception:
        pg = ""
    try:
        with open(os.environ["FM_POST_WRITE_VERIFY"]) as f:
            pv = f.read()
    except Exception:
        pv = ""
    pg_types = set(m.group(1) for m in re.finditer(r"^\s+([a-z][a-z-]*)\)\s+SCHEMA_KEY=", pg, re.MULTILINE))
    pv_types = set(m.group(1) for m in re.finditer(r"^\s+'([a-z][a-z-]*)'\s*:\s*'", pv, re.MULTILINE))
    # static type arms (the regexes above match zero lines), so the coverage audit
    # is inapplicable — return empty rather than flood 6 false-positive
    # "missing in both hooks" findings (one per frontmatter.types key).
    if not pg_types and not pv_types:
        return []
    findings = []
    for k in sorted(schema_keys):
        missing_in = []
        if k not in pg_types:
            missing_in.append("pre-write-guard.sh")
        if k not in pv_types:
            missing_in.append("post-write-verify.sh")
        if not missing_in:
            continue
        findings.append({
            "type": "schema-type-hook-coverage-gap",
            "severity": "warning",
            "schema_key": k,
            "missing_in": missing_in,
            "remediation": "Add the type to both hooks' explicit case/type_map and to CLAUDE.md File Content Standards.",
        })
    return findings

# ---------- persistent-ID reconciliation ----------
def reconcile(section, existing_list, new_findings, match_keys, id_prefix):
    """Given the prior `drift_findings.<section>` list and the fresh findings,
    return the merged list: matched rows retain first_seen + id; new rows get
    next sequence; resolved rows (in existing but not in new) are dropped."""
    existing_by_key = {}
    max_n = 0
    for row in existing_list or []:
        if not isinstance(row, dict):
            continue
        key = tuple(row.get(k) or "" for k in match_keys)
        existing_by_key[key] = row
        rid = row.get("id") or ""
        m = re.match(rf"^{id_prefix}-(\d+)$", rid)
        if m:
            n = int(m.group(1))
            if n > max_n:
                max_n = n
    merged = []
    seen_keys = set()
    for f in new_findings:
        key = tuple(f.get(k) or "" for k in match_keys)
        seen_keys.add(key)
        if key in existing_by_key:
            prior = existing_by_key[key]
            f_out = dict(f)
            f_out["id"] = prior.get("id") or f"{id_prefix}-{max_n+1:03d}"
            f_out["first_seen"] = prior.get("first_seen") or today_iso
            f_out["last_seen"] = today_iso
            if not prior.get("id"):
                max_n += 1
        else:
            max_n += 1
            f_out = dict(f)
            f_out["id"] = f"{id_prefix}-{max_n:03d}"
            f_out["first_seen"] = today_iso
            f_out["last_seen"] = today_iso
        merged.append(f_out)
    # Resolved rows dropped (rows in existing_by_key but not in seen_keys).
    return merged

# ---------- orchestrate ----------
existing_drift = {}
try:
    existing_drift = json.loads(os.environ.get("FM_EXISTING_DRIFT") or "{}")
except Exception:
    existing_drift = {}

files = build_scope()
pf_count, fixed_count, manual_count, fixed_files = run_per_file(files)

# Drift audits only run when walk != "scope" (i.e., full or recent, vault-wide)
drift_sections = {}
if walk != "scope":
    allowlist = load_drift_allowlist()
    dc_new = drift_provides_canonicality(allowlist)
    sm_new = drift_size_monitoring()
    st_new = drift_schema_type_coverage()

    prior_dc = (existing_drift.get("provides_canonicality") or [])
    prior_sm = (existing_drift.get("size_monitoring") or [])
    prior_st = (existing_drift.get("schema_type_coverage") or [])

    dc_merged = reconcile("provides_canonicality", prior_dc, dc_new, ("capability",), "DC")
    sm_merged = reconcile("size_monitoring", prior_sm, sm_new, ("file",), "SM")
    st_merged = reconcile("schema_type_coverage", prior_st, st_new, ("schema_key",), "ST")

    drift_sections = {
        "schema_version": 1,
        "last_scan": today_iso,
        "provides_canonicality": dc_merged,
        "size_monitoring": sm_merged,
        "schema_type_coverage": st_merged,
    }

with open(drift_out_path, "w") as f:
    json.dump(drift_sections or {"skip_drift": True}, f)

if dry_run:
    print(f"frontmatter-enforce: scanned={len(files)} findings={pf_count} "
          f"auto-fixed={fixed_count} manual={manual_count} "
          f"drift_DC={len(drift_sections.get('provides_canonicality') or [])} "
          f"drift_SM={len(drift_sections.get('size_monitoring') or [])} "
          f"drift_ST={len(drift_sections.get('schema_type_coverage') or [])}")
PY

# --- If drift payload was produced, persist it via manifest_set ---
if [[ -s "$DRIFT_OUT" ]]; then
  SKIP="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("1" if d.get("skip_drift") else "0")' "$DRIFT_OUT" 2>/dev/null || echo 0)"
  if [[ "$SKIP" != "1" ]]; then
    manifest_set '.drift_findings' "$(cat "$DRIFT_OUT")"
  fi
fi

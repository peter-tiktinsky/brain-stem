#!/bin/bash
# memory-hygiene — Lifecycle maintenance for the Claude memory system.
#
# Tier 3 hybrid pattern exemplar. Shell prefilter handles the deterministic
# drift classes as direct findings and emits NDJSON candidates for the
# judgment classes that Claude synthesizes at /librarian runtime.
#
# Deterministic classes (emit `emit_finding`):
#   #4 Orphan            — file on disk not referenced in MEMORY.md
#   #5 Index             — MEMORY.md entry pointing at missing target
#   #7 Temporal hygiene  — empty updated: field or malformed ISO date
#   #8 Budget            — MEMORY.md line count vs 200-line cap (green/yellow/red)
#
# Judgment classes (emit NDJSON candidates on stdout):
#   #2 Status verification — project_* with status: complete + stale last_verified
#   #3 Overlap             — slug/frontmatter similarity between two files
#   #6 Conflict            — same-subject frontmatter-name duplicates
#
# NDJSON schema per `tests/prefilter-contract.md`.
#
# Tier: judgment. Output Contract: block-and-log + requires_confirmation.
# Cron block: weekly. Exits 0 with a "skipped (non-interactive)"
# log line when invoked outside a TTY session with neither CLAUDECODE nor
# FOUNDATION_TEST_MODE set (a Claude Code tool-context session runs).
#
# CLI:
#   memory-hygiene.sh                    # emit to $FINDINGS_OUTPUT or stdout
#   memory-hygiene.sh --scope <path>     # override MEMORY_DIR
#   memory-hygiene.sh --all-projects     # sweep EVERY ~/.claude/projects/*/memory dir
#   memory-hygiene.sh --dry-run          # summary counts only
#   memory-hygiene.sh --help             # usage
#
# Env overrides:
#   MEMORY_DIR              Override session memory dir (else resolved via
#                           lib/paths.sh::resolve_memory_dir — cwd-slug-derived
#                           $CLAUDE_HOME/projects/<slug>/memory).
#   MEMORY_PROJECTS_ROOT    (--all-projects) projects root to enumerate
#                           (default: $CLAUDE_HOME/projects).
#   MEMORY_INDEX_PATH       (default: $MEMORY_DIR/MEMORY.md)
#   FINDINGS_OUTPUT         (default: stdout)
#   STALENESS_THRESHOLD_DAYS (default: 30)
#   FOUNDATION_TEST_MODE    Bypass non-interactive guard (test/CI runners).
#
# Manifest seam: system.memory_hygiene_exemptions[] (user-manifest) lists
# exact file names the inventory walk skips; absent field = no exemptions.
# Dot-led .md files are always skipped (a memory slug cannot begin with a dot).
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

# Gate paths.sh sourcing on the FUNCTION this capability consumes
# (resolve_memory_dir), not an exported-var proxy: a child dispatched from a
# parent that already sourced paths.sh inherits the exported vars WITHOUT the
# shell functions, so a var-presence guard would skip sourcing and lose
# resolve_memory_dir — a silent wrong-scope no-op.
if ! command -v resolve_memory_dir >/dev/null 2>&1; then
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
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/dates.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/dates.sh"; } \
  || source "$_REPO_LIB/dates.sh"
# the review-queue producer API — so the deterministic hygiene
# classes reach the review-drain/banner surface (enqueue_item), not just the findings stream.
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/review-queue.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/review-queue.sh"; } \
  || { [ -r "$_REPO_LIB/review-queue.sh" ] && source "$_REPO_LIB/review-queue.sh"; } || true
# user-manifest read API — powers the operator-exemption seam
# (system.memory_hygiene_exemptions[]); an absent lib or field degrades to no
# exemptions, so unconfigured installs behave exactly as before.
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || { [ -r "$_REPO_LIB/user-manifest-read.sh" ] && source "$_REPO_LIB/user-manifest-read.sh"; } || true

SCOPE=""
DRY_RUN="false"
ALL_PROJECTS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --all-projects) ALL_PROJECTS="true"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "memory-hygiene: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Judgment-tier non-interactive guard. Bypassed by FOUNDATION_TEST_MODE so
# synthetic harnesses can fire the capability without a controlling TTY.
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${CLAUDECODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "memory-hygiene: skipped (non-interactive)" >&2
  exit 0
fi

# CROSS-PROJECT sweep. resolve_memory_dir is cwd/git-slug-keyed,
# so a bare invocation audits ONLY the current project's memory while N project memory dirs
# exist (only memory-globalize swept projects/*/memory). --all-projects enumerates EVERY
# $CLAUDE_HOME/projects/*/memory dir and re-runs the per-project scan (deterministic +
# judgment classes) against each by re-invoking this capability with --scope. The single-
# project path (below) is unchanged. MEMORY_PROJECTS_ROOT overrides the root for tests.
if [[ "$ALL_PROJECTS" == "true" ]]; then
  _mh_root="${MEMORY_PROJECTS_ROOT:-$CLAUDE_HOME_RES/projects}"
  _mh_rc=0
  if [[ -d "$_mh_root" ]]; then
    for _mh_p in "$_mh_root"/*/memory; do
      [[ -d "$_mh_p" ]] || continue
      if [[ "$DRY_RUN" == "true" ]]; then
        env -u MEMORY_DIR -u MEMORY_INDEX_PATH bash "$0" --scope "$_mh_p" --dry-run || _mh_rc=$?
      else
        env -u MEMORY_DIR -u MEMORY_INDEX_PATH bash "$0" --scope "$_mh_p" || _mh_rc=$?
      fi
    done
  else
    echo "memory-hygiene --all-projects: projects root absent: $_mh_root" >&2
  fi
  exit "$_mh_rc"
fi

if [[ -n "${MEMORY_DIR:-}" ]]; then
  : # caller-set override wins
elif command -v resolve_memory_dir >/dev/null 2>&1; then
  MEMORY_DIR="$(resolve_memory_dir)"
else
  MEMORY_DIR=""
fi
if [[ -n "$SCOPE" ]]; then
  MEMORY_DIR="$SCOPE"
fi
# Loud-skip when the memory dir never resolved (paths.sh unreadable via BOTH the
# CLAUDE_HOME and repo-lib fallbacks): exit 0 with a message rather than let the
# empty value normalize to '/' below and silently scan filesystem root.
if [[ -z "$MEMORY_DIR" ]]; then
  echo "memory-hygiene: memory dir unresolved (paths.sh not loaded?)" >&2
  exit 0
fi
case "$MEMORY_DIR" in
  */) : ;;
  *) MEMORY_DIR="$MEMORY_DIR/" ;;
esac

MEMORY_INDEX_PATH="${MEMORY_INDEX_PATH:-${MEMORY_DIR}MEMORY.md}"
STALENESS_THRESHOLD_DAYS="${STALENESS_THRESHOLD_DAYS:-30}"

# the memory-schema source for the frontmatter conformance arm.
MEMORY_SCHEMA_PATH="${MEMORY_SCHEMA_PATH:-$CLAUDE_HOME_RES/schemas/memory-schema.json}"
[ -f "$MEMORY_SCHEMA_PATH" ] || MEMORY_SCHEMA_PATH="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/schemas/memory-schema.json"
export MEMORY_SCHEMA_PATH

if [[ ! -d "$MEMORY_DIR" ]]; then
  echo "memory-hygiene: MEMORY_DIR does not exist: $MEMORY_DIR" >&2
  exit 0
fi

# python writes review-queue items for the deterministic classes to
# this sink; the bash layer enqueues each after the run (mirrors stale-detect's subtree-out).
MEMORY_ENQUEUE_OUT="$(mktemp -t mh-enqueue-XXXXXX)"
export MEMORY_ENQUEUE_OUT

# Operator-exempted memory-file names (system.memory_hygiene_exemptions[] in
# the user manifest, mirroring the vault.tag_audit_exemptions seam): exact-name
# skips for the inventory walk, newline-separated for the python layer.
MH_EXEMPT_NAMES=""
command -v umr_get_array >/dev/null 2>&1 \
  && MH_EXEMPT_NAMES="$(umr_get_array '.system.memory_hygiene_exemptions')"
export MH_EXEMPT_NAMES

python3 - "$MEMORY_DIR" "$MEMORY_INDEX_PATH" "$STALENESS_THRESHOLD_DAYS" "$DRY_RUN" <<'PY'
import hashlib, json, os, re, sys, time
from datetime import date

memory_dir = sys.argv[1]
index_path = sys.argv[2]
try:
    stale_threshold = int(sys.argv[3])
except ValueError:
    stale_threshold = 30
dry_run = (sys.argv[4] == "true")

findings_out = os.environ.get("FINDINGS_OUTPUT", "")
exempt_names = set(filter(None, os.environ.get("MH_EXEMPT_NAMES", "").splitlines()))
now = time.time()
today = date.today()

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# enqueue a DETERMINISTIC-class finding into the review queue so it
# reaches the review-drain/banner surface (hygiene-review count non-zero). Python writes the
# validated item shape (id/class/severity/state/defer_count/dismiss_count — the enqueue_item
# inline contract) to $MEMORY_ENQUEUE_OUT; the bash layer calls enqueue_item per line. The
# judgment classes (#2/#3/#6) stay NDJSON-candidate emit (NOT enqueued). Never in dry-run.
enqueue_out = os.environ.get("MEMORY_ENQUEUE_OUT", "")
def enqueue_review(cls, subject, summary, severity="warn"):
    if not enqueue_out or dry_run:
        return
    item = {
        "id": candidate_id("memory-hygiene", cls, subject),
        "class": "memory-hygiene:" + cls,
        "severity": severity,
        "state": "open",
        "defer_count": 0,
        "dismiss_count": 0,
        "subject": subject,
        "summary": summary,
    }
    try:
        with open(enqueue_out, "a") as f:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
    except Exception:
        pass

def candidate_id(capability, check, subject):
    h = hashlib.sha256(("%s|%s|%s" % (capability, check, subject)).encode("utf-8")).hexdigest()
    return h[:16]

def parse_fm(path):
    try:
        t = open(path).read()
    except Exception:
        return {}, ""
    if not t.startswith("---"):
        return {}, t
    end = t.find("\n---", 3)
    if end == -1:
        return {}, t
    fm_raw = t[3:end].strip()
    body = t[end+4:]
    fm = {}
    for line in fm_raw.split("\n"):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$', line)
        if m:
            val = m.group(2).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                val = val[1:-1]
            fm[m.group(1)] = val
    return fm, body

def days_since_iso(iso):
    try:
        y, mo, d = iso.strip()[:10].split("-")
        return (today - date(int(y), int(mo), int(d))).days
    except Exception:
        return -1

def days_since_mtime(p):
    try:
        return int((now - os.path.getmtime(p)) / 86400)
    except Exception:
        return -1

# ---------- Inventory ----------
disk_files = []
for fn in sorted(os.listdir(memory_dir)):
    if not fn.endswith(".md"):
        continue
    if fn == "MEMORY.md":
        continue
    # dot-led files are never memories: the memory-schema naming contract
    # makes a file's name its slug, and a slug cannot begin with a dot — a
    # dot-led .md in a memory dir is an operational/runtime artifact (own or
    # third-party), so it is never orphan-eligible.
    if fn.startswith("."):
        continue
    # operator-exempted exact names (the user-manifest seam above).
    if fn in exempt_names:
        continue
    # exclude episodic-chronicle*.md from the hygiene inventory. It is
    # a runtime-generated append-only chronicle (type:episodic never decays), NOT a curated
    # pointer/topic carrier; passing the gate produced a false #4 orphan + a false
    # body-relative-date temporal (T-8 retired the flat-30d #1 half). Mirrors
    # pointer-currency-scan.sh's episodic-chronicle exclusion.
    if fn.startswith("episodic-chronicle"):
        continue
    full = os.path.join(memory_dir, fn)
    if os.path.isfile(full):
        disk_files.append((fn, full))

indexed = {}
index_line_count = 0
if os.path.isfile(index_path):
    with open(index_path) as f:
        idx_text = f.read()
    index_line_count = len(idx_text.splitlines())
    for m in re.finditer(r'\[([^\]]+\.md)\]\([^)]*\)', idx_text):
        indexed[m.group(1)] = True
else:
    idx_text = ""

counts = {
    "orphan": 0, "index": 0, "temporal": 0, "budget": 0,
    "status_candidates": 0, "overlap_candidates": 0, "conflict_candidates": 0,
    "schema_conformance": 0,
}

# ---------- #8 Budget ----------
if index_line_count > 0:
    pct = int((index_line_count / 200.0) * 100)
    if pct >= 90:
        status = "red"
    elif pct >= 75:
        status = "yellow"
    else:
        status = "green"
    if status != "green":
        emit({
            "finding": "budget",
            "file": "MEMORY.md",
            "category": "budget",
            "status": status,
            "line_count": index_line_count,
            "cap": 200,
            "percentage": pct,
            "reason": "MEMORY.md index size %d/200 lines (%d%%) — %s threshold" % (index_line_count, pct, status),
        })
        counts["budget"] += 1
        enqueue_review("budget", "MEMORY.md",
                       "MEMORY.md index %d/200 lines (%d%%) — %s" % (index_line_count, pct, status),
                       severity=("error" if status == "red" else "warn"))

# ---------- Per-file walks ----------
file_meta = {}
for fn, full in disk_files:
    fm, body = parse_fm(full)
    file_meta[fn] = (fm, body, full)

    # #4 Orphan
    if fn not in indexed:
        emit({
            "finding": "orphan",
            "file": fn,
            "category": "orphan",
            "reason": "File present in memory/ but missing from MEMORY.md index",
        })
        counts["orphan"] += 1
        enqueue_review("orphan", fn, "memory file %s present on disk but missing from MEMORY.md index" % fn)

    # #1 Staleness — RETIRED (T-8, tier3-memo #11, operator-ratified
    # 2026-07-07). The flat-30-day staleness rule (both the last_verified-present
    # branch and the mtime-only fallback) is superseded by the per-type
    # memory-staleness.sh (T-6). last_verified still feeds the #2 status
    # verification judgment class below; per-type staleness is memory-staleness.sh's.

    # #7 Temporal hygiene
    for fld in ("updated", "last_verified", "created"):
        if fld not in fm:
            continue
        val = fm[fld]
        if val == "":
            emit({
                "finding": "temporal",
                "file": fn,
                "category": "temporal",
                "field": fld,
                "reason": "%s: field is empty string" % fld,
            })
            counts["temporal"] += 1
            enqueue_review("temporal", "%s:%s" % (fn, fld), "%s: empty date field in %s" % (fld, fn))
        elif not re.match(r'^\d{4}-\d{2}-\d{2}', val):
            emit({
                "finding": "temporal",
                "file": fn,
                "category": "temporal",
                "field": fld,
                "value": val,
                "reason": "%s: malformed date '%s' (expected YYYY-MM-DD)" % (fld, val),
            })
            counts["temporal"] += 1
            enqueue_review("temporal", "%s:%s" % (fn, fld), "%s: malformed date '%s' in %s" % (fld, val, fn))

# ---------- #7 Temporal hygiene (body scan — relative-date markers) ----------
# Patterns flagged as body-relative-date: bare "yesterday|today|tomorrow",
# week markers ("last|this|next week|month"), bare day-name standalone
# ("on Thursday" / "Thursday we "), and N-units-ago ("3 days ago").
RELDATE_RE = re.compile(
    r'\b('
    r'yesterday|today|tomorrow|'
    r'(?:last|this|next)\s+(?:week|month|quarter|year)|'
    r'(?:\d+|a|few|couple|several)\s+(?:days?|weeks?|months?|years?)\s+ago|'
    r'recently|soon'
    r')\b',
    re.IGNORECASE,
)
DAYNAME_RE = re.compile(
    r'\b(?:on\s+|last\s+|next\s+|this\s+)(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b',
    re.IGNORECASE,
)
for fn, (fm, body, full) in file_meta.items():
    if not body:
        continue
    hits = []
    for m in RELDATE_RE.finditer(body):
        hits.append(("relative", m.group(1), m.start()))
    for m in DAYNAME_RE.finditer(body):
        hits.append(("dayname", m.group(0), m.start()))
    if not hits:
        continue
    # Report first 3 distinct patterns per file; deduplicate by matched substring.
    seen = set()
    uniq = []
    for kind, match_text, pos in hits:
        key = match_text.lower()
        if key in seen:
            continue
        seen.add(key)
        uniq.append((kind, match_text, pos))
        if len(uniq) >= 3:
            break
    # Emit one temporal finding per file with consolidated pattern list.
    patterns = [m[1] for m in uniq]
    emit({
        "finding": "temporal",
        "file": fn,
        "category": "body-relative-date",
        "patterns": patterns,
        "hit_count": len(hits),
        "reason": "body contains relative-date markers (%d total, showing first %d): %s — consider absolute-date backfill" % (len(hits), len(uniq), ", ".join(patterns)),
    })
    counts["temporal"] += 1
    enqueue_review("temporal", "%s:body" % fn, "body relative-date markers in %s: %s" % (fn, ", ".join(patterns)))

# ---------- #5 Index accuracy ----------
for indexed_fn in indexed.keys():
    full = os.path.join(memory_dir, indexed_fn)
    if not os.path.isfile(full):
        emit({
            "finding": "index",
            "file": "MEMORY.md",
            "category": "index",
            "missing_target": indexed_fn,
            "reason": "MEMORY.md references %s but file does not exist" % indexed_fn,
        })
        counts["index"] += 1
        enqueue_review("index", indexed_fn, "MEMORY.md references %s but the file does not exist" % indexed_fn)

# ---------- memory frontmatter schema conformance ----------
# No cap validated memory frontmatter vs schemas/memory-schema.json; frontmatter-enforce
# excludes .claude/projects/. This is the conformance owner. The required set + type enum +
# episodic conditional are SCHEMA-GROUNDED (read from memory-schema.json). A jsonschema+yaml
# faithful path runs when BOTH modules import (YAML-typed frontmatter); else a structural
# fallback (key-presence + enum + episodic->source_session_id). episodic-chronicle*.md is
# already excluded from file_meta, so it is never checked here.
mem_schema_path = os.environ.get("MEMORY_SCHEMA_PATH", "")
MEM_REQUIRED = ["name", "description", "type", "tags", "created", "updated", "last_validated"]
MEM_TYPE_ENUM = ["semantic", "episodic", "procedural"]
_mem_schema_obj = None
if mem_schema_path and os.path.isfile(mem_schema_path):
    try:
        with open(mem_schema_path) as _sfh:
            _mem_schema_obj = json.load(_sfh)
        _req = _mem_schema_obj.get("required")
        if isinstance(_req, list) and _req:
            MEM_REQUIRED = _req
        _en = ((_mem_schema_obj.get("properties") or {}).get("type") or {}).get("enum")
        if isinstance(_en, list) and _en:
            MEM_TYPE_ENUM = _en
    except Exception:
        _mem_schema_obj = None

try:
    import jsonschema as _jsonschema
    _have_js = True
except Exception:
    _have_js = False
try:
    import yaml as _yaml
    _have_yaml = True
except Exception:
    _have_yaml = False

def _fm_block_text(full):
    try:
        t = open(full).read()
    except Exception:
        return ""
    if not t.startswith("---"):
        return ""
    e = t.find("\n---", 3)
    return t[3:e] if e != -1 else ""

def _normalize_yaml(v):
    # YAML implicit-types a bare ISO date (2026-07-09) to a datetime.date object, which trips
    # the schema's `type: string` for created/updated/last_validated. Coerce any date/datetime
    # back to its ISO string so the faithful jsonschema path validates the AUTHORED shape.
    if hasattr(v, "isoformat"):
        try:
            return v.isoformat()
        except Exception:
            return str(v)
    if isinstance(v, dict):
        return {k: _normalize_yaml(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_normalize_yaml(x) for x in v]
    return v

def memory_fm_problems(full, fm):
    # jsonschema faithful path (YAML-typed frontmatter) when both modules import.
    if _have_js and _have_yaml and _mem_schema_obj is not None:
        try:
            data = _normalize_yaml(_yaml.safe_load(_fm_block_text(full)) or {})
            if isinstance(data, dict):
                errs = list(_jsonschema.Draft7Validator(_mem_schema_obj).iter_errors(data))
                return [e.message for e in errs[:5]]
        except Exception:
            pass  # degrade to structural
    # structural fallback (schema-grounded): key-presence + enum + episodic conditional.
    probs = []
    for k in MEM_REQUIRED:
        if k not in fm:
            probs.append("missing:%s" % k)
    tv = (fm.get("type") or "").strip()
    if tv and MEM_TYPE_ENUM and tv not in MEM_TYPE_ENUM:
        probs.append("type-not-in-enum:%s" % tv)
    if tv == "episodic" and "source_session_id" not in fm:
        probs.append("episodic-missing:source_session_id")
    return probs

for fn, (fm, body, full) in file_meta.items():
    _probs = memory_fm_problems(full, fm)
    if _probs:
        emit({
            "finding": "memory-frontmatter-nonconformant",
            "file": fn,
            "category": "schema-conformance",
            "problems": _probs,
            "reason": "memory frontmatter non-conformant to memory-schema.json: %s" % ", ".join(_probs),
        })
        counts["schema_conformance"] += 1

# ---------- #2 Status verification candidates (JUDGMENT) ----------
for fn, (fm, body, full) in file_meta.items():
    if not fn.startswith("project_"):
        continue
    status = fm.get("status", "").lower()
    if status not in ("complete", "completed", "superseded", "closed", "done"):
        continue
    lv = fm.get("last_verified", "")
    sd = days_since_iso(lv) if lv else days_since_mtime(full)
    excerpt = body.strip().replace("\n", " ")[:500]
    subject = fn
    cid = candidate_id("memory-hygiene", "status-verification", subject)
    score = 0.7 if sd > stale_threshold else 0.4
    emit({
        "capability": "memory-hygiene",
        "check": "status-verification",
        "candidate_id": cid,
        "subject": subject,
        "evidence": {
            "file_path": fn,
            "frontmatter": {"type": fm.get("type", ""), "status": status, "last_verified": lv},
            "content_excerpt": excerpt,
            "related_files": [],
            "drift_class": "#2",
        },
        "score": score,
        "notes": "project memory with status '%s' and last_verified %dd old — confirm plan/engagement actually closed" % (status, sd),
    })
    counts["status_candidates"] += 1

# ---------- #3 Overlap candidates (JUDGMENT) ----------
def slug_tokens(fn):
    base = fn[:-3] if fn.endswith(".md") else fn
    for p in ("user_", "feedback_", "project_", "reference_"):
        if base.startswith(p):
            base = base[len(p):]
            break
    return set(t for t in base.split("_") if len(t) >= 3)

file_list = list(file_meta.items())
seen_pairs = set()
for i, (fn_a, (fm_a, body_a, full_a)) in enumerate(file_list):
    toks_a = slug_tokens(fn_a)
    if not toks_a:
        continue
    type_a = fm_a.get("type", "")
    name_a = fm_a.get("name", "")
    desc_a = fm_a.get("description", "")
    for j in range(i+1, len(file_list)):
        fn_b, (fm_b, body_b, full_b) = file_list[j]
        type_b = fm_b.get("type", "")
        if type_a and type_b and type_a != type_b:
            continue
        toks_b = slug_tokens(fn_b)
        if not toks_b:
            continue
        shared = toks_a & toks_b
        union = toks_a | toks_b
        if not union:
            continue
        jaccard = len(shared) / float(len(union))
        name_b = fm_b.get("name", "")
        desc_b = fm_b.get("description", "")
        name_overlap = False
        if name_a and name_b:
            na = set(w.lower() for w in re.findall(r'\w+', name_a) if len(w) >= 3)
            nb = set(w.lower() for w in re.findall(r'\w+', name_b) if len(w) >= 3)
            if na and nb:
                nj = len(na & nb) / float(len(na | nb))
                if nj >= 0.5:
                    name_overlap = True
        if jaccard >= 0.5 or name_overlap:
            pair_key = tuple(sorted([fn_a, fn_b]))
            if pair_key in seen_pairs:
                continue
            seen_pairs.add(pair_key)
            subject = "%s|%s" % pair_key
            cid = candidate_id("memory-hygiene", "overlap", subject)
            score = max(jaccard, 0.5 if name_overlap else 0.0)
            notes_val = "candidate overlap: shared slug tokens %s" % sorted(list(shared)) if shared else "name-description overlap"
            emit({
                "capability": "memory-hygiene",
                "check": "overlap",
                "candidate_id": cid,
                "subject": subject,
                "evidence": {
                    "file_a": {"path": fn_a, "name": name_a, "description": desc_a, "excerpt": body_a.strip().replace("\n", " ")[:300]},
                    "file_b": {"path": fn_b, "name": name_b, "description": desc_b, "excerpt": body_b.strip().replace("\n", " ")[:300]},
                    "slug_jaccard": round(jaccard, 2),
                    "name_overlap": name_overlap,
                    "drift_class": "#3",
                },
                "score": round(score, 2),
                "notes": notes_val,
            })
            counts["overlap_candidates"] += 1

# ---------- #6 Conflict candidates (JUDGMENT) ----------
name_index = {}
for fn, (fm, body, full) in file_meta.items():
    name = fm.get("name", "").strip().lower()
    if not name:
        continue
    name_index.setdefault(name, []).append((fn, fm, body))

for name, entries in name_index.items():
    if len(entries) < 2:
        continue
    for i in range(len(entries)):
        for j in range(i+1, len(entries)):
            fn_a, fm_a, body_a = entries[i]
            fn_b, fm_b, body_b = entries[j]
            subject = "%s|%s" % tuple(sorted([fn_a, fn_b]))
            cid = candidate_id("memory-hygiene", "conflict", subject)
            emit({
                "capability": "memory-hygiene",
                "check": "conflict",
                "candidate_id": cid,
                "subject": subject,
                "evidence": {
                    "shared_name": name,
                    "file_a": {"path": fn_a, "description": fm_a.get("description", ""), "excerpt": body_a.strip().replace("\n", " ")[:300]},
                    "file_b": {"path": fn_b, "description": fm_b.get("description", ""), "excerpt": body_b.strip().replace("\n", " ")[:300]},
                    "drift_class": "#6",
                },
                "score": 0.6,
                "notes": "two memories share frontmatter name '%s' — adjudicate content for contradiction" % name,
            })
            counts["conflict_candidates"] += 1

if dry_run:
    total = sum(counts.values())
    print("memory-hygiene: scanned=%d index_lines=%d total=%d counts=%s" % (len(disk_files), index_line_count, total, dict(counts)))

PY

# enqueue the deterministic-class findings into the review queue so
# they reach the review-drain/banner surface (hygiene-review count non-zero). python wrote the
# validated item shapes to $MEMORY_ENQUEUE_OUT; enqueue_item validates + appends each
# (block-and-log; idempotent by id). Absent enqueue_item (review-queue lib unreachable) or jq
# degrades gracefully. Never in --dry-run (python did not write items).
if command -v enqueue_item >/dev/null 2>&1 \
   && [[ -n "${MEMORY_ENQUEUE_OUT:-}" && -s "$MEMORY_ENQUEUE_OUT" ]]; then
  while IFS= read -r _mh_item; do
    [ -z "$_mh_item" ] && continue
    enqueue_item "$_mh_item" >/dev/null 2>&1 || true
  done < "$MEMORY_ENQUEUE_OUT"
fi
[ -n "${MEMORY_ENQUEUE_OUT:-}" ] && rm -f "$MEMORY_ENQUEUE_OUT" 2>/dev/null || true

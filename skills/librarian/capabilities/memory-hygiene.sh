#!/bin/bash
# memory-hygiene — Lifecycle maintenance for the Claude memory system.
#
# Tier 3 hybrid pattern exemplar. Shell prefilter handles 5 deterministic
# drift classes as direct findings and emits NDJSON candidates for 3
# judgment classes that Claude synthesizes at /librarian runtime.
#
# Deterministic classes (emit `emit_finding`):
#   #1 Staleness         — frontmatter last_verified (or mtime fallback) > threshold
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
# Cron block: skip-non-interactive. Exits 0 with a "skipped (non-interactive)"
# log line when invoked outside a TTY session and FOUNDATION_TEST_MODE unset.
#
# CLI:
#   memory-hygiene.sh                    # emit to $FINDINGS_OUTPUT or stdout
#   memory-hygiene.sh --scope <path>     # override MEMORY_DIR
#   memory-hygiene.sh --dry-run          # summary counts only
#   memory-hygiene.sh --help             # usage
#
# Env overrides:
#   MEMORY_DIR              Override session memory dir (else resolved via
#                           lib/paths.sh::resolve_memory_dir — cwd-slug-derived
#                           $CLAUDE_HOME/projects/<slug>/memory).
#   MEMORY_INDEX_PATH       (default: $MEMORY_DIR/MEMORY.md)
#   FINDINGS_OUTPUT         (default: stdout)
#   STALENESS_THRESHOLD_DAYS (default: 30)
#   FOUNDATION_TEST_MODE    Bypass non-interactive guard (test/CI runners).
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24.

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
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/dates.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/dates.sh"; } \
  || source "$_REPO_LIB/dates.sh"

SCOPE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "memory-hygiene: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Judgment-tier non-interactive guard. Bypassed by FOUNDATION_TEST_MODE so
# synthetic harnesses can fire the capability without a controlling TTY.
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "memory-hygiene: skipped (non-interactive)" >&2
  exit 0
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
case "$MEMORY_DIR" in
  */) : ;;
  *) MEMORY_DIR="$MEMORY_DIR/" ;;
esac

MEMORY_INDEX_PATH="${MEMORY_INDEX_PATH:-${MEMORY_DIR}MEMORY.md}"
STALENESS_THRESHOLD_DAYS="${STALENESS_THRESHOLD_DAYS:-30}"

if [[ ! -d "$MEMORY_DIR" ]]; then
  echo "memory-hygiene: MEMORY_DIR does not exist: $MEMORY_DIR" >&2
  exit 0
fi

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
now = time.time()
today = date.today()

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

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
    "staleness": 0, "orphan": 0, "index": 0, "temporal": 0, "budget": 0,
    "status_candidates": 0, "overlap_candidates": 0, "conflict_candidates": 0,
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

    # #1 Staleness
    lv = fm.get("last_verified", "")
    stale_days = -1
    if lv:
        stale_days = days_since_iso(lv)
    if lv and stale_days > stale_threshold:
        emit({
            "finding": "staleness",
            "file": fn,
            "category": "staleness",
            "last_verified": lv,
            "days": stale_days,
            "threshold": stale_threshold,
            "reason": "last_verified %s is %dd old (threshold %dd)" % (lv, stale_days, stale_threshold),
        })
        counts["staleness"] += 1
    elif not lv:
        mtime_days = days_since_mtime(full)
        if mtime_days > stale_threshold:
            emit({
                "finding": "staleness",
                "file": fn,
                "category": "staleness",
                "last_verified": "",
                "days": mtime_days,
                "threshold": stale_threshold,
                "reason": "no last_verified; mtime %dd old (threshold %dd)" % (mtime_days, stale_threshold),
            })
            counts["staleness"] += 1

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

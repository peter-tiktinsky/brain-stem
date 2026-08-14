#!/bin/bash
# memory-staleness — Single-180d non-episodic re-validation flagging for memory
# files.
#
# Collapses the dropped 4-type half-life model
# {semantic:180, procedural:90, reflective:365, episodic:None} to a SINGLE
# 180-day non-episodic interval, keyed on last_validated. Reads
# schemas/memory-schema.json :: revalidation_interval_days.non_episodic (the
# 2.0.0 key) — NOT the removed _design_notes.per_type_half_life_days (a key the
# 2.0.0 schema no longer carries, which silently fell through to stale defaults
# applying procedural=90d — demonstrably wrong for the dominant feedback_
# class). Episodic NEVER decays. The `reflective` type is DROPPED (the 2.0.0
# MAJOR bump removed it; reflection rides the feedback_ provenance prefix).
# Same R-25/R-37 lockstep as the R-45 fix — the staleness
# consumer + the R-45 validator agree on the 2.0.0 triad + last_validated.
# Propose-only — no --fix mode, no auto-write.
#
# Distinct from memory-hygiene#1 Staleness:
#   - memory-hygiene#1 uses a flat 30d threshold against legacy last_verified
#     (mtime fallback). Single-policy, type-agnostic, legacy-field only.
#   - memory-staleness (this capability) uses the single 180d non-episodic
#     interval against the canonical last_validated with last_verified legacy
#     alias fallback (per schemas/memory-schema.json
#     _design_notes.legacy_field_aliases).
#
# memory-hygiene#1 retirement is tracked as separate cleanup follow-up;
# both capabilities co-exist at MVP.
#
# NDJSON schema (emit_finding):
#   { "finding": "memory-staleness", "file": "<basename>",
#     "category": "memory-staleness", "type": "<schema-type>",
#     "last_validated": "<YYYY-MM-DD>", "days_since": <int>,
#     "interval_days": <int>, "reason": "..." }
#
# Tier: mechanical (propose-only). Output Contract: propose-only + adopter
# reviews via /librarian invocation. Cron block: weekly.
#
# CLI:
#   memory-staleness.sh                    # emit to $FINDINGS_OUTPUT or stdout
#   memory-staleness.sh --scope <path>     # override MEMORY_DIR
#   memory-staleness.sh --all-projects     # sweep EVERY ~/.claude/projects/*/memory dir
#   memory-staleness.sh --dry-run          # summary counts only
#   memory-staleness.sh --help             # usage
#
# Env overrides:
#   MEMORY_DIR              Override session memory dir (else resolved via
#                           lib/paths.sh::resolve_memory_dir).
#   MEMORY_PROJECTS_ROOT    (--all-projects) projects root to enumerate
#                           (default: $CLAUDE_HOME/projects).
#   FINDINGS_OUTPUT         (default: stdout)
#   MEMORY_SCHEMA_PATH      (default: $FOUNDATION_REPO/schemas/memory-schema.json
#                           — overrides per-type half-life table)
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24
# (data via argv, never a piped stdin).

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

SCOPE=""
DRY_RUN="false"
ALL_PROJECTS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --all-projects) ALL_PROJECTS="true"; shift ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "memory-staleness: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# CROSS-PROJECT sweep. resolve_memory_dir is cwd/git-slug-keyed, so a bare invocation
# audits ONLY the current project's memory while N project memory dirs exist.
# --all-projects enumerates EVERY $CLAUDE_HOME/projects/*/memory dir and re-runs the
# per-project scan against each by re-invoking this capability with --scope. The single-
# project path (below) is unchanged. MEMORY_PROJECTS_ROOT overrides the root for tests.
if [[ "$ALL_PROJECTS" == "true" ]]; then
  _ms_root="${MEMORY_PROJECTS_ROOT:-$CLAUDE_HOME_RES/projects}"
  _ms_rc=0
  if [[ -d "$_ms_root" ]]; then
    for _ms_p in "$_ms_root"/*/memory; do
      [[ -d "$_ms_p" ]] || continue
      if [[ "$DRY_RUN" == "true" ]]; then
        env -u MEMORY_DIR -u MEMORY_INDEX_PATH bash "$0" --scope "$_ms_p" --dry-run || _ms_rc=$?
      else
        env -u MEMORY_DIR -u MEMORY_INDEX_PATH bash "$0" --scope "$_ms_p" || _ms_rc=$?
      fi
    done
  else
    echo "memory-staleness --all-projects: projects root absent: $_ms_root" >&2
  fi
  exit "$_ms_rc"
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
  echo "memory-staleness: memory dir unresolved (paths.sh not loaded?)" >&2
  exit 0
fi
case "$MEMORY_DIR" in
  */) : ;;
  *) MEMORY_DIR="$MEMORY_DIR/" ;;
esac

if [[ ! -d "$MEMORY_DIR" ]]; then
  echo "memory-staleness: MEMORY_DIR does not exist: $MEMORY_DIR" >&2
  exit 0
fi

# Resolve schema path (test override → foundation-repo default → live install).
SCHEMA_PATH="${MEMORY_SCHEMA_PATH:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "${CLAUDE_HOME:-$HOME/.claude}/schemas/memory-schema.json"; do
    if [[ -f "$candidate" ]]; then
      SCHEMA_PATH="$candidate"
      break
    fi
  done
fi

python3 - "$MEMORY_DIR" "$DRY_RUN" "$SCHEMA_PATH" <<'PY'
import json
import os
import re
import sys
from datetime import date

memory_dir = sys.argv[1]
dry_run = sys.argv[2] == "true"
schema_path = sys.argv[3]

# Single 180-day non-episodic re-validation interval. Read from
# schemas/memory-schema.json ::
# revalidation_interval_days.non_episodic (the 2.0.0 key); episodic NEVER decays
# (revalidation_interval_days.episodic = null). The dropped 4-type
# per_type_half_life_days model + the `reflective` type are GONE. Schema-driven
# when reachable + parseable; else fall back to the documented 180d default.
NON_EPISODIC_INTERVAL = 180  # default

if schema_path and os.path.isfile(schema_path):
    try:
        with open(schema_path) as fh:
            schema = json.load(fh)
        rid = schema.get("revalidation_interval_days", {})
        ne = rid.get("non_episodic")
        if isinstance(ne, int):
            NON_EPISODIC_INTERVAL = ne
    except (OSError, json.JSONDecodeError):
        pass  # fall back to the documented default

# Per-type interval resolution: episodic never decays (None); every other type
# in the 2.0.0 triad (semantic, procedural) gets the single non-episodic
# interval. Any non-episodic schema-type — including a feedback_ file typed
# semantic/procedural — decays on the single 180d clock.
def interval_for(mem_type):
    if mem_type == "episodic":
        return None
    return NON_EPISODIC_INTERVAL

# the valid memory-type set, GROUNDED on schemas/memory-schema.json's
# type enum (95 — semantic|episodic|procedural). An out-of-enum type is emitted as a finding
# (not silently skipped). Fall back to the 2.0.0 triad when the schema is unreachable.
VALID_TYPES = ("semantic", "procedural", "episodic")
if schema_path and os.path.isfile(schema_path):
    try:
        with open(schema_path) as fh:
            _sc = json.load(fh)
        _en = ((_sc.get("properties") or {}).get("type") or {}).get("enum")
        if isinstance(_en, list) and _en:
            VALID_TYPES = tuple(_en)
    except (OSError, json.JSONDecodeError):
        pass

today = date.today()

# Frontmatter parser — line-oriented, tolerant of comments/blank lines.
FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')

def parse_frontmatter(file_path):
    """Return dict of frontmatter, or None on malformed/absent."""
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
        m = FM_KEY_RE.match(line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm or None

def days_since_iso(iso_date):
    """Parse YYYY-MM-DD; return days since, or -1 on parse failure."""
    try:
        d = date.fromisoformat(iso_date)
    except (TypeError, ValueError):
        return -1
    return (today - d).days

def emit(finding_dict):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(finding_dict, separators=(", ", ": "), sort_keys=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        print(line)

counts = {
    "stale": 0,
    "ok": 0,
    "skipped_episodic": 0,
    "skipped_no_validation": 0,
    "skipped_unknown_type": 0,
    "skipped_no_frontmatter": 0,
}

scanned = 0

if not os.path.isdir(memory_dir):
    sys.exit(0)

for entry in sorted(os.listdir(memory_dir)):
    if not entry.endswith(".md"):
        continue
    if entry == "MEMORY.md":
        continue  # index file out of scope
    full = os.path.join(memory_dir, entry)
    if not os.path.isfile(full):
        continue
    scanned += 1

    fm = parse_frontmatter(full)
    if fm is None:
        counts["skipped_no_frontmatter"] += 1
        continue

    mem_type = fm.get("type", "").strip()
    # 2.0.0 retrieval-type triad: semantic | procedural | episodic.
    # `reflective` was dropped at the 2.0.0 MAJOR bump.
    if mem_type not in VALID_TYPES:
        # emit a finding for an out-of-enum type instead of a silent
        # skipped_unknown_type continue. A mistyped/legacy `reflective` otherwise escaped BOTH
        # the staleness clock AND type validation (type-table-ceiling).
        counts["skipped_unknown_type"] += 1
        if not dry_run:
            emit({
                "finding": "memory-type-invalid",
                "file": entry,
                "category": "memory-type-invalid",
                "type": mem_type or "(empty)",
                "valid_types": list(VALID_TYPES),
                "reason": "memory type '%s' not in the schema type enum (%s) — it escapes the "
                          "staleness clock AND type validation"
                          % (mem_type or "(empty)", "|".join(VALID_TYPES)),
            })
        continue

    threshold = interval_for(mem_type)
    if threshold is None:
        # Episodic NEVER decays.
        counts["skipped_episodic"] += 1
        continue

    # Canonical last_validated; legacy alias last_verified per
    # schema._design_notes.legacy_field_aliases (additive accept; canonical
    # name authoritative; no rewrite).
    lv = fm.get("last_validated", "").strip() or fm.get("last_verified", "").strip()
    if not lv:
        counts["skipped_no_validation"] += 1
        continue

    days = days_since_iso(lv)
    if days < 0:
        counts["skipped_no_validation"] += 1
        continue

    if days > threshold:
        if not dry_run:
            emit({
                "finding": "memory-staleness",
                "file": entry,
                "category": "memory-staleness",
                "type": mem_type,
                "last_validated": lv,
                "days_since": days,
                "interval_days": threshold,
                "reason": "type=%s last_validated=%s is %dd old (re-validation interval %dd)" % (
                    mem_type, lv, days, threshold,
                ),
            })
        counts["stale"] += 1
    else:
        counts["ok"] += 1

if dry_run:
    print("memory-staleness: dry-run summary (scope=%s)" % memory_dir, file=sys.stderr)
    print("  scanned=%d  stale=%d  ok=%d" % (scanned, counts["stale"], counts["ok"]), file=sys.stderr)
    print("  skipped: episodic=%d  no_validation=%d  unknown_type=%d  no_frontmatter=%d" % (
        counts["skipped_episodic"],
        counts["skipped_no_validation"],
        counts["skipped_unknown_type"],
        counts["skipped_no_frontmatter"],
    ), file=sys.stderr)
PY

exit 0

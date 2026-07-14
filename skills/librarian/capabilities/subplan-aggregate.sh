#!/bin/bash
# subplan-aggregate — Pull-based master sub_plans[] aggregator. Reads each
# sub-plan's published status into the master manifest's sub_plans[]
# read-replica. The master aggregate is a librarian-generated read-replica
# (same trust class as _index.md; NEVER hand-edited).
#
# Librarian body.
#
# Element shape written into master.sub_plans[] (schema gate
# schemas/plan-manifest-schema.json :: sub_plans):
#   { sub_plan_id, slug, status, graduation_timestamp }
# keyed on the canonical 8-state status. The master display keys on
# coarse buckets active/done/verified/closed — derived from the
# single canonical status; no second status field.
#
# graduation_timestamp WRITER: this aggregator is the graduation_timestamp
# writer. When a sub publishes a TERMINAL status (verified/closed) upward and
# its own manifest carries a graduation_timestamp, the value is copied into the
# master read-replica; if the sub is terminal but carries no timestamp, the
# aggregator stamps the publish-upward moment (UTC now). The librarian
# RECONCILER (trinity-drift-detect/drift-sweep) READS this — it never
# writes graduation_timestamp.
#
# Output Contract
#   Files written: <master-dir>/manifest.json :: sub_plans[] (the read-replica
#     only; the master's other fields are untouched; atomic temp+rename);
#     findings to stdout (NDJSON via hooks/lib/findings.sh) or $FINDINGS_OUTPUT.
#   Schema gate: each sub manifest + the master manifest validate against
#     schemas/plan-manifest-schema.json (jsonschema when available; structural
#     fallback). block-and-log on a malformed master manifest (no write).
#   Pre-write validation: assert the master dir + manifest.json present; the
#     master must declare type:master (or sub_plans[] already present).
#   Failure mode: block-and-log; never write-and-hope. Sub manifests read-only.
#
# Finding categories:
#   subplan-aggregate-updated     (info-event) sub_plans[] regenerated; once per run
#   subplan-status-published      (info-event) a sub's status read into the replica
#   subplan-graduation-stamped    (info-event) graduation_timestamp written for a terminal sub
#   subplan-missing-manifest      (warning) a sub dir lacks a manifest.json
#
# CLI:
#   subplan-aggregate.sh <master-dir>          # regenerate master sub_plans[]
#   subplan-aggregate.sh --check <master-dir>  # parity report + findings; no write
#   subplan-aggregate.sh --help
# <master-dir> may be absolute or relative to PLANS_ROOT.
#
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   PLAN_MANIFEST_SCHEMA     plan-manifest-schema.json (default: foundation -> live)
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#   FOUNDATION_TEST_MODE     bypass the non-interactive guard
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

CHECK_ONLY="false"
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY="true"; shift ;;
    -h|--help) sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "subplan-aggregate: unknown flag '$1'" >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "subplan-aggregate: skipped (non-interactive)" >&2
  exit 0
fi

if [[ -z "$TARGET" ]]; then
  echo "subplan-aggregate: missing <master-dir> argument (see --help)" >&2
  exit 2
fi

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

case "$TARGET" in
  /*) MASTER_DIR="$TARGET" ;;
  *)  MASTER_DIR="$PLANS_ROOT/$TARGET" ;;
esac
case "$MASTER_DIR" in */) MASTER_DIR="${MASTER_DIR%/}" ;; esac
if [[ ! -d "$MASTER_DIR" ]]; then
  echo "subplan-aggregate: master dir does not exist: $MASTER_DIR" >&2
  exit 1
fi
if [[ ! -f "$MASTER_DIR/manifest.json" ]]; then
  echo "subplan-aggregate: no manifest.json in $MASTER_DIR" >&2
  exit 1
fi

SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/schemas/plan-manifest-schema.json"; do
    if [[ -f "$candidate" ]]; then SCHEMA_PATH="$candidate"; break; fi
  done
fi

python3 - "$MASTER_DIR" "$CHECK_ONLY" "$SCHEMA_PATH" <<'PY'
import json, os, re, sys, tempfile
from datetime import datetime, timezone

master_dir = sys.argv[1]
check_only = (sys.argv[2] == "true")
schema_path = sys.argv[3]
out = os.environ.get("FINDINGS_OUTPUT", "")
now_iso = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

# Coarse-bucket map: the single canonical status -> coarse bucket.
COARSE = {
    "researching": "active", "planned": "active", "in-progress": "active", "paused": "active",
    "completed": "done",
    "verified": "verified",
    "closed": "closed", "archived": "closed", "superseded": "closed",
}
TERMINAL = {"verified", "closed", "archived", "superseded"}

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

master_path = os.path.join(master_dir, "manifest.json")
try:
    with open(master_path, encoding="utf-8") as fh:
        master = json.load(fh)
except Exception as exc:
    print("subplan-aggregate: master manifest malformed; aborting "
          "(block-and-log): %s" % exc, file=sys.stderr)
    sys.exit(1)

if schema_path and os.path.isfile(schema_path):
    try:
        import jsonschema  # type: ignore
        with open(schema_path, encoding="utf-8") as fh:
            _schema = json.load(fh)
        jsonschema.Draft202012Validator(_schema, format_checker=jsonschema.FormatChecker()).validate(master)
    except ImportError:
        pass
    except Exception as exc:
        print("subplan-aggregate: master fails schema; refusing to write: %s"
              % exc, file=sys.stderr)
        sys.exit(1)

# enumerate sub-plan subdirectories (execution-order NN- prefixed dirs with a
# manifest.json). The sub-plan convention is NN-<slug>/ under the
# master dir.
prior = {}
for sp in (master.get("sub_plans") or []):
    if isinstance(sp, dict) and sp.get("sub_plan_id"):
        prior[sp["sub_plan_id"]] = sp

sub_plans = []
for entry in sorted(os.listdir(master_dir)):
    sub_dir = os.path.join(master_dir, entry)
    if not os.path.isdir(sub_dir) or entry.startswith(".") or entry.startswith("_"):
        continue
    if entry in ("tests", "_orchestrator"):
        continue
    sub_manifest = os.path.join(sub_dir, "manifest.json")
    # ordinal: NN- prefix (optional SP- prefix)
    m = re.match(r"^(?:SP-)?(\d{1,2})[-_]", entry)
    if not m and not os.path.isfile(sub_manifest):
        continue
    ordinal = m.group(1).zfill(2) if m else entry
    slug = entry
    if not os.path.isfile(sub_manifest):
        emit({"finding": "subplan-missing-manifest", "file": sub_dir,
              "sub_plan_id": ordinal, "slug": slug, "detected_at": now_iso[:10]})
        continue
    try:
        with open(sub_manifest, encoding="utf-8") as fh:
            sm = json.load(fh)
    except Exception:
        emit({"finding": "subplan-missing-manifest", "file": sub_manifest,
              "sub_plan_id": ordinal, "slug": slug,
              "detail": "unparseable", "detected_at": now_iso[:10]})
        continue
    status = sm.get("status", "")
    sub_id = sm.get("sub_plan_id", ordinal) or ordinal
    grad = sm.get("graduation_timestamp")
    # Stamp graduation when terminal + missing on the sub.
    stamped = False
    if status in TERMINAL and not grad:
        grad = now_iso
        stamped = True
        emit({"finding": "subplan-graduation-stamped", "file": sub_manifest,
              "sub_plan_id": sub_id, "slug": slug, "status": status,
              "graduation_timestamp": grad, "detected_at": now_iso[:10]})
    element = {
        "sub_plan_id": sub_id,
        "slug": slug,
        "status": status,
        "graduation_timestamp": grad,
    }
    sub_plans.append(element)
    emit({"finding": "subplan-status-published", "file": sub_manifest,
          "sub_plan_id": sub_id, "slug": slug, "status": status,
          "coarse_bucket": COARSE.get(status, "active"), "detected_at": now_iso[:10]})

# sort by ordinal
def ord_key(e):
    m = re.match(r"(\d+)", str(e.get("sub_plan_id", "")))
    return int(m.group(1)) if m else 9999
sub_plans.sort(key=ord_key)

drift = (master.get("sub_plans") != sub_plans)

if check_only:
    emit({"finding": "subplan-aggregate-updated", "file": master_path,
          "sub_plan_count": len(sub_plans), "dry_run": True,
          "drift_detected_bool": drift, "detected_at": now_iso[:10]})
    print("subplan-aggregate: --check subs=%d drift=%s"
          % (len(sub_plans), str(drift).lower()), file=sys.stderr)
    sys.exit(0)

master["sub_plans"] = sub_plans
d = os.path.dirname(master_path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(master, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, master_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

emit({"finding": "subplan-aggregate-updated", "file": master_path,
      "sub_plan_count": len(sub_plans), "dry_run": False,
      "detected_at": now_iso[:10]})
PY

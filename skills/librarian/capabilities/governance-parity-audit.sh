#!/bin/bash
# governance-parity-audit — Audit-time self-consistency backstop for the
# governance pillar JSON surfaces. Walks the pillar JSON registries and emits
# drift findings categorized by pillar.
# NET-NEW librarian body (1.1 line 135). Authored from the
# only —(a): no governance/librarian-capabilities/ doc in brain-stem).
# Two-layer composition: the write-time R-37 atomic lockstep prevents
# partial-surface commits at the gate; this capability is the audit-time
# backstop detecting drift that lands DESPITE the gate (manual filesystem
# edits, bypass scenarios, foundation-upgrade lag). Read-only — emits findings,
# never writes governance or vault content.
# Output Contract
#   Files written: findings to stdout (NDJSON via hooks/lib/findings.sh) or
#     $FINDINGS_OUTPUT. No governance writes; no vault writes.
#   Finding shape: hooks/lib/findings.sh emit_finding (#2 — the phantom
#     librarian-finding-schema.json is reconciled to findings.sh; not created).
#   Pre-run validation: each pillar JSON must parse (jq); _index.json must
#     parse. block-and-log on a malformed pillar JSON (pillar-schema-malformed
#     finding + the pillar is skipped, never silently passed).
#   Failure mode: block-and-log; never write-and-hope.
# Finding categories:
#   source-divergence      (info)    rules[].source: path does not resolve
#   foundation-upgrade-touches-shadowed-entry (warning) upgrade touched a shadowed overlay entry (--upgrade)
#   pillar-schema-malformed(warning) a pillar JSON failed parse at audit-time
# CLI:
#   governance-parity-audit.sh             # audit (default)
#   governance-parity-audit.sh --upgrade   # also run the shadowed-entry walk
#   governance-parity-audit.sh --dry-run   # summary counts, no findings
#   governance-parity-audit.sh --help
# Env overrides (testing):
#   GOVERNANCE_DIR    governance root (default: foundation-repo -> live install)
#   FINDINGS_OUTPUT   NDJSON sink (default: stdout)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"

MODE="audit"
UPGRADE="false"
DIFF_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade) UPGRADE="true"; shift ;;
    --diff) DIFF_ARG="${2:-}"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "governance-parity-audit: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Resolve the governance dir (foundation-repo -> live install).
GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "${FOUNDATION_REPO:-$HOME/Code/brain-stem}/governance" \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi
if [ -z "$GOV_DIR" ] || [ ! -d "$GOV_DIR" ]; then
  echo "governance-parity-audit: governance dir not found" >&2
  exit 1
fi

# read the SHIPPED foundation-master (adopter surface reach). On an
# adopter install ONLY the composed master (+ overlay) ships — the loose pillar JSONs are
# repo-only, so PILLARS resolves them all "absent" and the R-37 audit backstop is a TOTAL
# no-op. Resolve the master in the governance dir being audited + merge the overlay via
# foundation-overlay-load.sh (mirroring library-index / index-maintain): the
# merged union carries every pillar's composed slot. The python body reads pillar rules from
# the master's slots when the master is available, and FALLS BACK to the loose pillar JSONs
# when it is not (dev-repo / no bundle — loud-safe, never broken).
GP_MASTER=""
for _cand in "$GOV_DIR/foundation-master.json" "$CLAUDE_HOME_RES/governance/foundation-master.json"; do
  [ -f "$_cand" ] && { GP_MASTER="$_cand"; break; }
done
_OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -n "$GP_MASTER" ] && [ -f "$GP_MASTER" ]; then
  GP_UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$GP_UNION" ] && bash "$_OVL" --foundation-path "$GP_MASTER" \
        --overlay-path "$(dirname "$GP_MASTER")/overlay-master.json" --force-override > "$GP_UNION" 2>/dev/null \
        && [ -s "$GP_UNION" ]; then
    GP_MASTER="$GP_UNION"; trap 'rm -f "$GP_UNION"' EXIT
  elif [ -n "$GP_UNION" ]; then rm -f "$GP_UNION"; fi
fi

# the file-type-contract schema (parse/drift validation) +
# the --upgrade shadow-guard diff-context + raw overlay-master (shadow-set source).
FTC_SCHEMA="${FILE_TYPE_CONTRACT_SCHEMA:-}"
if [ -z "$FTC_SCHEMA" ]; then
  for _c in "$CLAUDE_HOME_RES/schemas/file-type-contract-schema.json" \
            "$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/schemas/file-type-contract-schema.json"; do
    [ -f "$_c" ] && { FTC_SCHEMA="$_c"; break; }
  done
fi
OVERLAY_PATH="${OVERLAY_MASTER_PATH:-$GOV_DIR/overlay-master.json}"
DIFF_PATH="${GOVERNANCE_DIFF_CONTEXT:-$DIFF_ARG}"

python3 - "$GOV_DIR" "$MODE" "$UPGRADE" "$GP_MASTER" "$FTC_SCHEMA" "$DIFF_PATH" "$OVERLAY_PATH" <<'PY'
import json, os, re, sys

gov_dir, mode, upgrade = sys.argv[1], sys.argv[2], sys.argv[3]
master_path = sys.argv[4] if len(sys.argv) > 4 else ""
ftc_schema_path = sys.argv[5] if len(sys.argv) > 5 else ""
diff_path = sys.argv[6] if len(sys.argv) > 6 else ""
overlay_path = sys.argv[7] if len(sys.argv) > 7 else ""
dry_run = (mode == "dry-run")
out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(d):
    if dry_run:
        return
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# The governance pillar JSON registries walked for self-consistency. Each row is
# (pillar-name, loose-pillar-filename, composed-master-slot-key) — the master slot is
# read on an adopter surface, the loose file in the dev-repo fallback.
PILLARS = [
    ("frontmatter",     "frontmatter-rules.json",    "frontmatter"),
    ("tagging",         "tagging-rules.json",         "tagging"),
    ("naming",          "naming-rules.json",          "naming"),
    ("mandatory-files", "mandatory-files-rules.json", "mandatory_files"),
    ("doc-dependencies","doc-dependencies.json",      "doc_dependencies"),
    ("vault-writers",   "vault-writers-rules.json",   "vault_writers"),
]

counts = {
    "source-divergence": 0, "foundation-upgrade-touches-shadowed-entry": 0,
    "pillar-schema-malformed": 0, "contract-schema-malformed": 0, "contract-drift": 0,
}

def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), None
    except FileNotFoundError:
        return None, "absent"
    except Exception as exc:
        return None, str(exc)

def pillar_rules(doc):
    """Return list of rule dicts from a pillar JSON (_rules[] or rules[])."""
    if not isinstance(doc, dict):
        return []
    for key in ("_rules", "rules"):
        if isinstance(doc.get(key), list):
            return [r for r in doc[key] if isinstance(r, dict)]
    return []

# read the SHIPPED master (merged union) once. When present, each pillar's rules
# come from its composed master slot (adopter surface reach); the loose pillar JSONs
# are the FALLBACK when the master is unavailable (dev-repo / no bundle — loud-safe).
master = None
if master_path and os.path.isfile(master_path):
    _md, _merr = load_json(master_path)
    if _merr is None and isinstance(_md, dict):
        master = _md

for pillar, fname, slot in PILLARS:
    if master is not None:
        # Adopter surface — read the pillar's rules from the composed master slot.
        slot_doc = master.get(slot)
        if not isinstance(slot_doc, dict):
            # slot absent/empty in the master -> not this audit's drift class; skip.
            continue
        doc = slot_doc
    else:
        # Dev-repo / no-master fallback: resolve the loose pillar JSON (prior behavior).
        fpath = os.path.join(gov_dir, fname)
        doc, err = load_json(fpath)
        if err == "absent":
            # An absent pillar JSON is not this audit's drift class (mandatory-files
            # coverage is owned elsewhere); skip silently.
            continue
        if err:
            emit({"finding": "pillar-schema-malformed", "file": fname,
                  "pillar": pillar, "schema_validation_error": err})
            counts["pillar-schema-malformed"] += 1
            continue

    rules = pillar_rules(doc)

    # source-divergence — rules[].source: path does not resolve.
    for r in rules:
        rid = r.get("id", "")
        src = r.get("source", "")
        if not isinstance(src, str) or not src:
            continue
        # Extract a candidate filesystem path token (before " :: " or " (").
        token = re.split(r"\s+::\s+|\s+\(", src, 1)[0].strip()
        if "/" in token and not token.startswith("governance/"):
            # only resolve repo-relative path-shaped tokens
            cand = os.path.join(os.path.dirname(gov_dir), token)
            if not os.path.exists(cand):
                emit({"finding": "source-divergence", "file": fname, "pillar": pillar,
                      "rule_id": rid, "json_source_pointer": token,
                      "resolution": "unresolved"})
                counts["source-divergence"] += 1

# _index.json self-consistency — a malformed cross-cutting index is a pillar
#    schema defect (the spoke-coverage compare arm is retired with the spokes).
idx_doc, idx_err = load_json(os.path.join(gov_dir, "_index.json"))
if idx_err and idx_err != "absent":
    emit({"finding": "pillar-schema-malformed", "file": "_index.json",
          "pillar": "_index", "schema_validation_error": idx_err})
    counts["pillar-schema-malformed"] += 1

# file-type-contract parity arm. governance/file-type-contracts/ (13
# contract JSONs) was walked by NO cap — only ship-gate sub-gate 9 validated _rationale at BUILD
# time (no audit-time/runtime parity owner). Walk each contract: parse + (when the schema is
# present) validate against file-type-contract-schema.json (the SAME _rationale content-class
# schema sub-gate 9 runs). Emit contract-schema-malformed on a parse failure, contract-drift on a
# schema violation. Additive after the PILLARS loop; disjoint from the pillar-read region.
ftc_dir = os.path.join(gov_dir, "file-type-contracts")
_ftc_validator = None
if ftc_schema_path and os.path.isfile(ftc_schema_path):
    try:
        import jsonschema as _js
        with open(ftc_schema_path, encoding="utf-8") as _sfh:
            _ftc_schema = json.load(_sfh)
        _ftc_validator = _js.Draft7Validator(_ftc_schema)
    except Exception:
        _ftc_validator = None
if os.path.isdir(ftc_dir):
    for _cf in sorted(os.listdir(ftc_dir)):
        if not _cf.endswith(".json"):
            continue
        _cdoc, _cerr = load_json(os.path.join(ftc_dir, _cf))
        if _cerr and _cerr != "absent":
            emit({"finding": "contract-schema-malformed", "file": "file-type-contracts/" + _cf,
                  "pillar": "file-type-contracts", "schema_validation_error": _cerr})
            counts["contract-schema-malformed"] += 1
            continue
        if _ftc_validator is not None and isinstance(_cdoc, dict):
            _errs = list(_ftc_validator.iter_errors(_cdoc))
            if _errs:
                emit({"finding": "contract-drift", "file": "file-type-contracts/" + _cf,
                      "pillar": "file-type-contracts",
                      "drift": [e.message for e in _errs[:3]]})
                counts["contract-drift"] += 1

# foundation-vs-overlay shadow guard (--upgrade). A foundation upgrade
# that touches an entry SHADOWED by a POPULATED overlay-master slot is MASKED from the adopter's
# effective governance (the overlay overrides). Diff context: a newline list of touched
# governance keys from --diff / GOVERNANCE_DIFF_CONTEXT (the upgrade/install path supplies it).
# The shadow set = the raw overlay-master's populated top-level slots. Without diff context the
# walk degrades to a documented advisory-noop (NOT a crash) — WAS: an unconditional `pass` stub.
if upgrade == "true":
    touched = []
    if diff_path and os.path.isfile(diff_path):
        try:
            with open(diff_path, encoding="utf-8") as _dfh:
                touched = [ln.strip() for ln in _dfh if ln.strip()]
        except Exception:
            touched = []
    if touched:
        shadow_set = set()
        if overlay_path and os.path.isfile(overlay_path):
            _odoc, _oerr = load_json(overlay_path)
            if _oerr is None and isinstance(_odoc, dict):
                for _k, _v in _odoc.items():
                    if (isinstance(_v, dict) and _v) or (isinstance(_v, list) and _v):
                        shadow_set.add(_k)
        for _entry in touched:
            if _entry in shadow_set:
                emit({"finding": "foundation-upgrade-touches-shadowed-entry",
                      "file": "overlay-master.json", "pillar": "overlay",
                      "shadowed_entry": _entry,
                      "reason": "the upgrade touches foundation entry '%s' which is shadowed by a "
                                "populated overlay-master slot; the change is masked from the "
                                "adopter's effective (merged) governance" % _entry})
                counts["foundation-upgrade-touches-shadowed-entry"] += 1
    # else: no diff context -> advisory-noop (graceful; documented).

if dry_run:
    print("governance-parity-audit: dry-run counts=%s" % json.dumps(counts))
PY

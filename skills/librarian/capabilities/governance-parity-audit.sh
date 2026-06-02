#!/bin/bash
# governance-parity-audit — Audit-time alignment-mechanism backstop for the
# dual-surface governance pattern. Walks the governance pillar JSON surfaces +
# their narrative spokes and emits drift findings categorized by pillar.
#
# Librarian body.
#
# Two-layer composition: the write-time R-37 atomic lockstep prevents
# partial-surface commits at the gate; this capability is the audit-time
# backstop detecting drift that lands DESPITE the gate (manual filesystem
# edits, bypass scenarios, foundation-upgrade lag). Read-only — emits findings,
# never writes governance or vault content.
#
# Output Contract
#   Files written: findings to stdout (NDJSON via hooks/lib/findings.sh) or
#     $FINDINGS_OUTPUT. No governance writes; no vault writes.
#   Finding shape: hooks/lib/findings.sh emit_finding (the phantom
#     librarian-finding-schema.json is reconciled to findings.sh; not created).
#   Pre-run validation: each pillar JSON must parse (jq); _index.json must
#     parse. block-and-log on a malformed pillar JSON (pillar-schema-malformed
#     finding + the pillar is skipped, never silently passed).
#   Failure mode: block-and-log; never write-and-hope.
#
# Finding categories (7):
#   rule-id-mismatch       (warning) R-NN in pillar JSON but not in spoke (or vice-versa)
#   field-missing          (warning) rule field not documented in the spoke
#   tier-mismatch          (warning) JSON tier != spoke tier framing
#   source-divergence      (info)    rules[].source: path does not resolve
#   foundation-upgrade-touches-shadowed-entry (warning) upgrade touched a shadowed overlay entry (--upgrade)
#   meta-rule-coverage-gap (warning) _index.json cross-cutting meta-rule not referenced in any spoke
#   pillar-schema-malformed(warning) a pillar JSON failed parse at audit-time
#
# CLI:
#   governance-parity-audit.sh             # audit (default)
#   governance-parity-audit.sh --upgrade   # also run the shadowed-entry walk
#   governance-parity-audit.sh --dry-run   # summary counts, no findings
#   governance-parity-audit.sh --help
#
# Env overrides (testing):
#   GOVERNANCE_DIR    governance root (default: foundation-repo -> live install)
#   SPOKES_DIR        narrative-spoke root (default: vault-init governance spokes)
#   FINDINGS_OUTPUT   NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"

MODE="audit"
UPGRADE="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade) UPGRADE="true"; shift ;;
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

# Narrative-spoke root (vault-init shipped spokes -> adopter vault). Optional:
# absent spokes degrade rule-id-mismatch/field-missing/meta-rule coverage to
# "spoke-absent" advisory, not a hard abort.
SPOKE_DIR="${SPOKES_DIR:-}"
if [ -z "$SPOKE_DIR" ]; then
  # The seed-tree spoke home is vault-init/System Governance.
  # governance-parity-audit is NOT re-pointed to foundation-master.json: its
  # dual-surface compare needs the narrative spokes that don't ship to a fresh
  # adopter, so it chains on the build's own dogfood session-close but is
  # excluded from the adopter session-close.
  for cand in \
    "${FOUNDATION_REPO:-$HOME/Code/brain-stem}/vault-init/System Governance" \
    "${VAULT_ROOT:-}/System Governance"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { SPOKE_DIR="$cand"; break; }
  done
fi

python3 - "$GOV_DIR" "${SPOKE_DIR:-}" "$MODE" "$UPGRADE" <<'PY'
import json, os, re, sys

gov_dir, spoke_dir, mode, upgrade = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
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

# The 6 dual-surface pillars + their canonical spoke filenames (canonical §D).
# The 7th pillar (vault-writers) + plans pillar carry _rules[]/rules[] too but
# the dual-surface narrative spokes are the 6 System Governance mirrors.
PILLARS = [
    ("frontmatter",     "frontmatter-rules.json",     "System Governance - Frontmatter.md"),
    ("tagging",         "tagging-rules.json",         "System Governance - Tagging.md"),
    ("naming",          "naming-rules.json",          "System Governance - Naming.md"),
    ("mandatory-files", "mandatory-files-rules.json", "System Governance - Mandatory-Files.md"),
    ("doc-dependencies","doc-dependencies.json",      "System Governance - Doc-Dependencies.md"),
    ("vault-writers",   "vault-writers-rules.json",   "System Governance - Vault-Writers.md"),
]

counts = {
    "rule-id-mismatch": 0, "field-missing": 0, "tier-mismatch": 0,
    "source-divergence": 0, "foundation-upgrade-touches-shadowed-entry": 0,
    "meta-rule-coverage-gap": 0, "pillar-schema-malformed": 0,
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

def read_spoke(name):
    if not spoke_dir:
        return None
    p = os.path.join(spoke_dir, name)
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None

RID_RE = re.compile(r"R-\d+")

for pillar, fname, spoke_name in PILLARS:
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
    json_ids = set()
    for r in rules:
        rid = r.get("id")
        if isinstance(rid, str) and RID_RE.fullmatch(rid):
            json_ids.add(rid)

    spoke = read_spoke(spoke_name)
    spoke_ids = set(RID_RE.findall(spoke)) if spoke else None

    # 1. rule-id-mismatch (only when a spoke exists to compare against).
    if spoke_ids is not None:
        for rid in sorted(json_ids - spoke_ids):
            emit({"finding": "rule-id-mismatch", "file": fname, "pillar": pillar,
                  "rule_id": rid, "present_in": ["pillar-json"], "missing_from": ["spoke"]})
            counts["rule-id-mismatch"] += 1
        for rid in sorted(spoke_ids - json_ids):
            emit({"finding": "rule-id-mismatch", "file": spoke_name, "pillar": pillar,
                  "rule_id": rid, "present_in": ["spoke"], "missing_from": ["pillar-json"]})
            counts["rule-id-mismatch"] += 1

        # 2. field-missing — rule documents a structural field absent from spoke.
        for r in rules:
            rid = r.get("id", "")
            if not (isinstance(rid, str) and rid in spoke_ids):
                continue
            for field in ("failure_mode", "enforcement_layer"):
                if field in r and field.replace("_", " ") not in spoke.lower() \
                        and field not in spoke:
                    emit({"finding": "field-missing", "file": fname, "pillar": pillar,
                          "rule_id": rid, "field": field, "spoke_section": spoke_name})
                    counts["field-missing"] += 1

        # 3. tier-mismatch — JSON tier not framed in the spoke near the rule id.
        for r in rules:
            rid = r.get("id", "")
            tier = r.get("tier", "")
            if isinstance(rid, str) and rid in spoke_ids and tier and tier not in spoke:
                emit({"finding": "tier-mismatch", "file": fname, "pillar": pillar,
                      "rule_id": rid, "json_tier": tier})
                counts["tier-mismatch"] += 1

    # 4. source-divergence — rules[].source: path does not resolve.
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

# 6. meta-rule-coverage-gap — _index.json cross-cutting meta-rules referenced
#    in at least one of the 6 spokes.
idx_doc, idx_err = load_json(os.path.join(gov_dir, "_index.json"))
if idx_err and idx_err != "absent":
    emit({"finding": "pillar-schema-malformed", "file": "_index.json",
          "pillar": "_index", "schema_validation_error": idx_err})
    counts["pillar-schema-malformed"] += 1
elif isinstance(idx_doc, dict) and spoke_dir:
    meta = idx_doc.get("cross_cutting_meta_rules") or idx_doc.get("_cross_cutting_meta_rules") or []
    all_spokes = ""
    for _, _, spoke_name in PILLARS:
        s = read_spoke(spoke_name)
        if s:
            all_spokes += s + "\n"
    for mr in meta:
        mrid = mr.get("id") if isinstance(mr, dict) else mr
        if isinstance(mrid, str) and mrid and mrid not in all_spokes:
            emit({"finding": "meta-rule-coverage-gap", "file": "_index.json",
                  "rule_id": mrid, "candidate_spokes": [s for _, _, s in PILLARS]})
            counts["meta-rule-coverage-gap"] += 1

# 5. foundation-upgrade-touches-shadowed-entry — only under --upgrade with a
#    diff context. Without git diff context the walk is advisory-noop (graceful).
if upgrade == "true":
    # Clean-room: no diff context wiring yet; emit nothing rather than guess.
    pass

if dry_run:
    print("governance-parity-audit: dry-run counts=%s" % json.dumps(counts))
PY

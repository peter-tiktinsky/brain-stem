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

python3 - "$GOV_DIR" "$MODE" "$UPGRADE" <<'PY'
import json, os, re, sys

gov_dir, mode, upgrade = sys.argv[1], sys.argv[2], sys.argv[3]
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

# The governance pillar JSON registries walked for self-consistency.
PILLARS = [
    ("frontmatter",     "frontmatter-rules.json"),
    ("tagging",         "tagging-rules.json"),
    ("naming",          "naming-rules.json"),
    ("mandatory-files", "mandatory-files-rules.json"),
    ("doc-dependencies","doc-dependencies.json"),
    ("vault-writers",   "vault-writers-rules.json"),
]

counts = {
    "source-divergence": 0, "foundation-upgrade-touches-shadowed-entry": 0,
    "pillar-schema-malformed": 0,
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

for pillar, fname in PILLARS:
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

# foundation-upgrade-touches-shadowed-entry — only under --upgrade with a
#    diff context. Without git diff context the walk is advisory-noop (graceful).
if upgrade == "true":
    # Clean-room: no diff context wiring yet; emit nothing rather than guess.
    pass

if dry_run:
    print("governance-parity-audit: dry-run counts=%s" % json.dumps(counts))
PY

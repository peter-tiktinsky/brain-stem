#!/bin/bash
# log-subtype-canonical — Audit-time (Layer 2) detector of unregistered #log/*
# and #status/* subtypes drifting into the vault + near-match drift WITHIN the
# registry itself.
#
# Librarian body.
#
# SCOPE GUARD: tag-subtype canonicality has
# BOTH a Layer-1 write-time hook (pre-write-guard.sh tag-validation branch) AND
# this Layer-2 librarian capability. The Layer-1 hook lives in
# pre-write-guard.sh; this body is the Layer-2 audit-time detector.
#
# Output Contract
#   Files written: findings to stdout (NDJSON via hooks/lib/findings.sh) or
#     $FINDINGS_OUTPUT. No vault writes; no registry writes.
#   Pre-run validation: governance/log-subtype-registry.json must parse;
#     block-and-log + abort on registry-schema-malformed (never emit findings
#     against a malformed registry).
#   Failure mode: block-and-log; never write-and-hope. Read-only.
#
# Finding categories (3):
#   log-subtype-unregistered     (warning) vault tag with no exact registry match
#   log-subtype-near-match-drift (warning) two registry subtypes within Levenshtein 2
#   log-subtype-owner-orphan     (info)    registered subtype, no owner, unwritten >90d
#
# CLI:
#   log-subtype-canonical.sh             # audit (default)
#   log-subtype-canonical.sh --dry-run   # summary counts, no findings
#   log-subtype-canonical.sh --help
#
# Env overrides (testing):
#   VAULT_ROOT             vault root to walk
#   GOVERNANCE_DIR         governance root (default: foundation-repo -> live)
#   LOG_SUBTYPE_OVERLAY    adopter overlay path (default: $CLAUDE_HOME/governance/log_subtype_registry_overlay.json)
#   FINDINGS_OUTPUT        NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"

MODE="audit"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "log-subtype-canonical: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi
if [ -z "$GOV_DIR" ] || [ ! -f "$GOV_DIR/log-subtype-registry.json" ]; then
  echo "log-subtype-canonical: log-subtype-registry.json not found" >&2
  exit 1
fi

OVERLAY="${LOG_SUBTYPE_OVERLAY:-$CLAUDE_HOME_RES/governance/log_subtype_registry_overlay.json}"

python3 - "$GOV_DIR/log-subtype-registry.json" "$OVERLAY" "${VAULT_ROOT:-}" "$MODE" <<'PY'
import json, os, re, sys
from datetime import date

reg_path, overlay_path, vroot, mode = sys.argv[1:5]
dry_run = (mode == "dry-run")
today = date.today().isoformat()
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

# block-and-log on registry-schema-malformed.
try:
    with open(reg_path, encoding="utf-8") as fh:
        reg = json.load(fh)
except Exception as exc:
    print("log-subtype-canonical: registry malformed; aborting (block-and-log): %s"
          % exc, file=sys.stderr)
    sys.exit(1)

def registry_entries(doc):
    """Yield (dimension, subtype, entry) over a registry doc. Tolerant of a
    couple of shipped shapes: a flat list of {dimension,subtype,...} OR a
    {subtypes:{<dim>:[{value,owner_skill,owner_cron,last_seen}]}} map."""
    if not isinstance(doc, dict):
        return
    subs = doc.get("subtypes") or doc.get("_subtypes")
    if isinstance(subs, dict):
        for dim, items in subs.items():
            if isinstance(items, list):
                for it in items:
                    if isinstance(it, dict):
                        yield dim, it.get("value") or it.get("subtype") or "", it
    elif isinstance(subs, list):
        for it in subs:
            if isinstance(it, dict):
                yield it.get("dimension", ""), it.get("value") or it.get("subtype") or "", it
    # also tolerate top-level list under _rules-style is out of scope here.

entries = list(registry_entries(reg))
if os.path.isfile(overlay_path):
    try:
        with open(overlay_path, encoding="utf-8") as fh:
            ov = json.load(fh)
        entries += list(registry_entries(ov))
    except Exception:
        pass  # overlay malformed is advisory, not audit-fatal here

# union canonical set keyed (dimension, subtype)
canon = {}
for dim, sub, ent in entries:
    if sub:
        canon[(dim, sub)] = ent

def lev(a, b):
    if a == b:
        return 0
    la, lb = len(a), len(b)
    if abs(la - lb) > 2:
        return 99
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        for j in range(1, lb + 1):
            cost = 0 if a[i-1] == b[j-1] else 1
            cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
        prev = cur
    return prev[lb]

# 2. log-subtype-near-match-drift — two registered subtypes within Levenshtein 2
by_dim = {}
for (dim, sub) in canon:
    by_dim.setdefault(dim, []).append(sub)
reported_pairs = set()
for dim, subs in by_dim.items():
    for i in range(len(subs)):
        for j in range(i + 1, len(subs)):
            a, b = subs[i], subs[j]
            if 0 < lev(a, b) <= 2 or a in b or b in a:
                key = (dim, tuple(sorted((a, b))))
                if key in reported_pairs:
                    continue
                reported_pairs.add(key)
                emit({"finding": "log-subtype-near-match-drift", "file": reg_path,
                      "dimension": dim, "conflicting_subtypes": sorted((a, b)),
                      "detected_at": today, "first_seen": today})

# 3. log-subtype-owner-orphan — registered, no owner, (last_seen >90d if known)
for (dim, sub), ent in canon.items():
    has_owner = bool(ent.get("owner_skill") or ent.get("owner_cron"))
    if not has_owner:
        emit({"finding": "log-subtype-owner-orphan", "file": reg_path,
              "dimension": dim, "subtype": sub,
              "last_seen": ent.get("last_seen", ""),
              "detected_at": today, "first_seen": today})

# 1. log-subtype-unregistered — vault tags with no exact registry match.
TAG_RE = re.compile(r"#(log|status)/([A-Za-z0-9][A-Za-z0-9_-]*)")
if vroot and os.path.isdir(vroot):
    seen_tags = {}
    for dirpath, dirnames, filenames in os.walk(vroot):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, encoding="utf-8") as fh:
                    txt = fh.read()
            except Exception:
                continue
            for m in TAG_RE.finditer(txt):
                dim, val = m.group(1), m.group(2)
                if (dim, val) not in canon:
                    seen_tags.setdefault((dim, val), fp)
    for (dim, val), fp in seen_tags.items():
        # nearest canonical for suggestion
        suggestion = ""
        best = 99
        for c in by_dim.get(dim, []):
            d = lev(val, c)
            if d < best:
                best, suggestion = d, c
        emit({"finding": "log-subtype-unregistered", "file": fp,
              "dimension": dim, "tag_value": val,
              "suggested_canonical": suggestion if best <= 2 else "",
              "detected_at": today, "first_seen": today})

if dry_run:
    print("log-subtype-canonical: dry-run registered=%d near-match-pairs=%d"
          % (len(canon), len(reported_pairs)), file=sys.stderr)
PY

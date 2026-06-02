#!/bin/bash
# rules-index — Regenerate the governance-rules-index: a librarian-derived
# read-replica of the rule register, assembled from the per-pillar _rules[] SoT
# + the _index.json meta block. Grouped by category with a retired-tombstone
# section. NEVER hand-edited; ships UNVALIDATED (no rules-index-schema.json —
# a validated index would re-introduce a second authoring SoT).
#
# Librarian body. NAME-DISAMBIGUATION:
# this is `rules-index` (the governance-rules-index
# regenerator, mirrors the *-index family) — DISTINCT from the
# `rules-hygiene` body (the .claude/rules/*.md auditor). Both bodies coexist.
#
# Derivation: every R-NN resolves to EXACTLY ONE of 4 buckets:
#   (1) pillar         — a rule declared in one of the 7 pillar _rules[]
#   (2) meta           — a cross-cutting meta-rule in _index.json :: cross_cutting_meta_rules[]
#   (3) skill          — enforcement_layer carries a `skill:` declaration
#   (4) librarian      — enforcement_layer is librarian / reconciler / advisory tier
#   buckets (3)/(4) are sub-classifications applied to pillar rules by their
#   enforcement posture; a meta-rule that is ALSO a pillar rule resolves to
#   pillar (the SoT wins) — surfaced as `rule-bucket-collision` if it appears in
#   two independent registers.
#
# Output Contract
#   Files written: the rules-index read-replica (default
#     governance/_generated/rules-index.md, override RULES_INDEX_PATH); findings
#     to stdout (NDJSON via hooks/lib/findings.sh) or $FINDINGS_OUTPUT.
#   Schema gate: NONE for the index itself (ships UNVALIDATED).
#     Source pillars must parse; block-and-log on a malformed pillar.
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Regenerated, never hand-edited.
#
# Finding categories (the derived-index integrity flags):
#   rule-ghost                   (warning) an R-NN referenced in a spoke/enforcement string but in no register
#   rule-bucket-collision        (warning) an R-NN resolves to >1 independent bucket
#   rule-category-mislabel       (warning) a rule's category does not match its home pillar's category convention
#   rule-enforced-without-declaration (warning) enforcement_layer present but rule_text/status absent
#   rule-retired                 (info)    status:retired/superseded -> tombstone section
#
# CLI:
#   rules-index.sh             # regenerate the rules-index
#   rules-index.sh --check     # parity report + findings; no write
#   rules-index.sh --help
#
# Env overrides (testing):
#   GOVERNANCE_DIR     governance root (default: foundation-repo -> live)
#   RULES_INDEX_PATH   output path (default: $GOVERNANCE_DIR/_generated/rules-index.md)
#   FINDINGS_OUTPUT    NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"

CHECK="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK="true"; shift ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "rules-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi
if [ -z "$GOV_DIR" ] || [ ! -d "$GOV_DIR" ]; then
  echo "rules-index: governance dir not found" >&2
  exit 1
fi

# Bundle-first: the per-pillar *-rules.json + _index.json are
# repo-only — they DO NOT ship to a fresh adopter, where only the
# composed governance/foundation-master.json bundle lands.
# Resolve the SHIPPED bundle via ${CLAUDE_HOME:-$HOME/.claude} FIRST so the cap
# reads a REAL register on the adopter instead of degrading to a no-op; fall back
# to the repo pillars only when the bundle is absent (dev-repo authoring). The
# Python body reads the bundle's composed pillar slots when BUNDLE is non-empty,
# else walks the loose pillar files under GOV_DIR.
BUNDLE=""
for cand in \
  "$CLAUDE_HOME_RES/governance/foundation-master.json" \
  "$GOV_DIR/foundation-master.json"; do
  [ -f "$cand" ] && { BUNDLE="$cand"; break; }
done

OUT_PATH="${RULES_INDEX_PATH:-$GOV_DIR/_generated/rules-index.md}"

python3 - "$GOV_DIR" "$OUT_PATH" "$CHECK" "$BUNDLE" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

gov_dir, out_path, check_s = sys.argv[1:4]
bundle_path = sys.argv[4] if len(sys.argv) > 4 else ""
check_only = (check_s == "true")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

# Bundle-first: when the shipped foundation-master.json bundle is
# present, read the composed pillar slots from it (the adopter ships the bundle,
# NOT the loose pillars). Slot key map: bundle slot name -> pillar id.
BUNDLE = None
BUNDLE_SLOT = {
    "frontmatter":      "frontmatter",
    "tagging":          "tagging",
    "naming":           "naming",
    "mandatory_files":  "mandatory-files",
    "doc_dependencies": "doc-dependencies",
    "vault_writers":    "vault-writers",
    "plans":            "plans",
}
if bundle_path and os.path.isfile(bundle_path):
    try:
        with open(bundle_path, encoding="utf-8") as fh:
            BUNDLE = json.load(fh)
    except Exception as exc:
        print("rules-index: bundle malformed; falling back to loose pillars: %s"
              % exc, file=sys.stderr)
        BUNDLE = None

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

PILLARS = [
    ("frontmatter",      "frontmatter-rules.json",     "C1"),
    ("tagging",          "tagging-rules.json",         "C1"),
    ("naming",           "naming-rules.json",          "C1"),
    ("mandatory-files",  "mandatory-files-rules.json", "C1"),
    ("doc-dependencies", "doc-dependencies.json",      "C1"),
    ("vault-writers",    "vault-writers-rules.json",   "C1"),
    ("plans",            "plans-rules.json",           "C3"),
]

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), None
    except FileNotFoundError:
        return None, "absent"
    except Exception as exc:
        return None, str(exc)

def load_pillar(home, fname):
    # Bundle-first: the composed pillar slot carries _rules[].
    if BUNDLE is not None:
        for slot, pid in BUNDLE_SLOT.items():
            if pid == home and slot in BUNDLE:
                return BUNDLE[slot], None
        return None, "absent"
    return load(os.path.join(gov_dir, fname))

def load_index():
    # Bundle-first: the composed bundle carries the _index slot (pillars[] +
    # cross_cutting_meta_rules[]); the loose repo carries _index.json.
    if BUNDLE is not None:
        return (BUNDLE.get("_index"), None) if "_index" in BUNDLE else (None, "absent")
    return load(os.path.join(gov_dir, "_index.json"))

# Bucket (1) pillar rules + sub-buckets (3) skill / (4) librarian.
rules = {}          # R-NN -> entry dict {bucket, category, home, tier, status, ...}
appearances = {}    # R-NN -> set(register names) for collision detection

def classify_sub(rule):
    el = rule.get("enforcement_layer") or []
    if isinstance(el, str):
        el = [el]
    tier = str(rule.get("tier", ""))
    joined = " ".join(el).lower()
    if "skill:" in joined or joined.startswith("skill"):
        return "skill"
    if "librarian" in joined or tier in ("reconciler", "advisory", "librarian"):
        return "librarian"
    return "pillar"

for home, fname, conv_cat in PILLARS:
    doc, err = load_pillar(home, fname)
    if err == "absent":
        continue
    if err:
        emit({"finding": "rule-category-mislabel", "file": fname,
              "detail": "pillar JSON malformed; skipped (block-and-log)",
              "error": err})
        print("rules-index: %s malformed; aborting (block-and-log): %s"
              % (fname, err), file=sys.stderr)
        sys.exit(1)
    rs = doc.get("_rules") or doc.get("rules") or []
    for r in rs:
        if not isinstance(r, dict):
            continue
        rid = r.get("id", "")
        if not rid:
            continue
        appearances.setdefault(rid, set()).add(home)
        sub = classify_sub(r)
        cat = r.get("category", "")
        # rule-category-mislabel — category does not match the home convention
        if cat and cat != conv_cat:
            emit({"finding": "rule-category-mislabel", "file": fname,
                  "rule_id": rid, "declared_category": cat,
                  "home_convention": conv_cat, "detected_at": today})
        # rule-enforced-without-declaration
        if (r.get("enforcement_layer")) and not (r.get("rule_text") and r.get("status")):
            emit({"finding": "rule-enforced-without-declaration", "file": fname,
                  "rule_id": rid, "detected_at": today})
        rules[rid] = {
            "bucket": sub, "category": cat or conv_cat, "home": home,
            "tier": str(r.get("tier", "")), "status": r.get("status", "active"),
            "text": (r.get("rule_text") or "")[:120],
        }

# Bucket (2) meta — _index cross_cutting_meta_rules[].
idx_doc, idx_err = load_index()
meta_ids = set()
if isinstance(idx_doc, dict):
    for mr in (idx_doc.get("cross_cutting_meta_rules") or []):
        mrid = mr.get("id") if isinstance(mr, dict) else mr
        if not isinstance(mrid, str) or not mrid:
            continue
        meta_ids.add(mrid)
        appearances.setdefault(mrid, set()).add("_index.meta")
        if mrid in rules:
            # appears in BOTH a pillar register and the meta register -> collision
            emit({"finding": "rule-bucket-collision", "file": "_index.json",
                  "rule_id": mrid, "registers": sorted(appearances[mrid]),
                  "resolution": "pillar-SoT-wins", "detected_at": today})
        else:
            rules[mrid] = {
                "bucket": "meta", "category": (mr.get("category", "") if isinstance(mr, dict) else ""),
                "home": "_index", "tier": "meta",
                "status": (mr.get("status", "active") if isinstance(mr, dict) else "active"),
                "text": (mr.get("rule_text", "") if isinstance(mr, dict) else "")[:120],
            }

# rule-ghost — R-NN referenced in any pillar/enforcement string but not registered.
referenced = set()
if BUNDLE is not None:
    for slot in BUNDLE_SLOT:
        if slot in BUNDLE:
            for m in re.finditer(r"R-\d+", json.dumps(BUNDLE[slot], ensure_ascii=False)):
                referenced.add(m.group(0))
else:
    for home, fname, _ in PILLARS:
        p = os.path.join(gov_dir, fname)
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as fh:
                for m in re.finditer(r"R-\d+", fh.read()):
                    referenced.add(m.group(0))
for rid in sorted(referenced - set(rules.keys())):
    emit({"finding": "rule-ghost", "file": "governance/", "rule_id": rid,
          "detail": "referenced but not registered in any bucket", "detected_at": today})

# rule_id_range ghost detection. The _index.json
# pillar registry carries a rule_id_range[] per pillar; a clean register has
# every range member resolving to a declared _rules[]/meta object. An R-NN
# listed in a rule_id_range but absent from ALL registers is a range-ghost. This
# makes the rules-index actually CATCH future drift, not just render the clean state.
known = set(rules.keys()) | meta_ids
if isinstance(idx_doc, dict):
    for pillar in (idx_doc.get("pillars") or []):
        if not isinstance(pillar, dict):
            continue
        pid = pillar.get("id", "")
        for rid in (pillar.get("rule_id_range") or []):
            if isinstance(rid, str) and rid and rid not in known:
                emit({"finding": "rule-ghost", "file": "_index.json",
                      "rule_id": rid, "pillar": pid,
                      "detail": "listed in pillar rule_id_range but not declared in any _rules[]/meta register (range-ghost)",
                      "detected_at": today})

# --- render the read-replica grouped by category + retired tombstone --------
by_cat = {}
retired = []
for rid, e in rules.items():
    if e["status"] in ("retired", "superseded", "tombstoned"):
        retired.append((rid, e))
        emit({"finding": "rule-retired", "file": "rules-index", "rule_id": rid,
              "status": e["status"], "detected_at": today})
        continue
    by_cat.setdefault(e["category"] or "uncategorized", []).append((rid, e))

def rid_key(item):
    m = re.match(r"R-(\d+)", item[0])
    return int(m.group(1)) if m else 9999

lines = ["# Governance Rules Index", "",
         "_Librarian-derived read-replica. Regenerated by `librarian rules-index`. "
         "NEVER hand-edit — the per-pillar `_rules[]` + `_index.json` meta block are the SoT._", "",
         "**Generated:** %s" % today,
         "**Rules indexed:** %d (%d retired)" % (len(rules), len(retired)), ""]
for cat in sorted(by_cat):
    items = sorted(by_cat[cat], key=rid_key)
    lines.append("## %s (%d)" % (cat, len(items)))
    lines.append("")
    lines.append("| Rule | Home | Bucket | Tier | Status | Text |")
    lines.append("|------|------|--------|------|--------|------|")
    for rid, e in items:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            rid, e["home"], e["bucket"], e["tier"] or "—", e["status"],
            (e["text"] or "").replace("|", "\\|")))
    lines.append("")
if retired:
    lines.append("## Retired (tombstone) (%d)" % len(retired))
    lines.append("")
    lines.append("| Rule | Home | Status |")
    lines.append("|------|------|--------|")
    for rid, e in sorted(retired, key=rid_key):
        lines.append("| %s | %s | %s |" % (rid, e["home"], e["status"]))
    lines.append("")

content = "\n".join(lines).rstrip() + "\n"

existing = None
if os.path.isfile(out_path):
    with open(out_path, encoding="utf-8") as fh:
        existing = fh.read()
drift = (existing != content)

if check_only:
    if drift:
        emit({"finding": "rule-retired", "file": out_path,
              "detail": "rules-index would change on regeneration",
              "drift_detected_bool": True, "detected_at": today}) if False else None
    print("rules-index: --check rules=%d retired=%d drift=%s"
          % (len(rules), len(retired), str(drift).lower()), file=sys.stderr)
    sys.exit(0)

d = os.path.dirname(out_path)
if d and not os.path.isdir(d):
    os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=(d or "."), prefix=".rules-index.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, out_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

print("rules-index: wrote %s (rules=%d retired=%d)"
      % (out_path, len(rules), len(retired)), file=sys.stderr)
PY

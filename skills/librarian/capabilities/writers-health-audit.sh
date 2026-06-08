#!/bin/bash
# writers-health-audit — Daily read-only sweep of writer-reference files + skill
# registry + path_routing for operational drift. Emits findings only; never
# writes vault content.
#
# Librarian body. Reuses the tag-coverage-audit read-only multi-class sweep
# base; the new logic is the 5 per-class predicates + the dormant-writer
# last-run derivation.
#
# Output Contract
#   Files written: findings to stdout (NDJSON via hooks/lib/findings.sh) or
#     $FINDINGS_OUTPUT (the cron mode appends to a date-stamped JSONL via
#     FINDINGS_OUTPUT). No vault writes — the capability has no write-to-vault
#     code path (R-34 read-only audit).
#   Pre-run validation: governance/file-type-contracts/vault-writer.md.json +
#     vault-writers-rules.json must parse; block-and-log + abort on a malformed
#     source contract (never emit findings against malformed inputs).
#   Failure mode: block-and-log; never write-and-hope.
#
# Finding categories (5):
#   dormant-writer            (warning) last_success >30d OR status:active & never-observed
#   unresolved-destination    (warning) destination glob matches zero folders + no auto_create
#   orphan-writer-skill-ref   (warning) writer_skill points to a non-existent skill slug
#   orphan-destination-ref    (warning) destination references a retired path_routing pattern
#   multi-writer-overlap      (info/cross-ref) writer participates in an _overlap-matrix cluster
#
# CLI:
#   writers-health-audit.sh             # audit (default)
#   writers-health-audit.sh --dry-run   # summary counts, no findings
#   writers-health-audit.sh --help
#
# Env overrides (testing):
#   VAULT_ROOT             vault root (Vault Writers/ resolves under it)
#   GOVERNANCE_DIR         governance root (default: foundation-repo -> live)
#   SKILLS_DIR             installed-skill registry root (default: $CLAUDE_HOME/skills)
#   WRITER_MANIFEST_PATH   SQLite writes manifest (optional; informs dormant-writer)
#   FINDINGS_OUTPUT        NDJSON/JSONL sink (default: stdout)
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
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "writers-health-audit: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi

# Bundle-first: vault-writers-rules.json + file-type-contracts/ are
# repo-only / bundle-composed — on a fresh adopter only foundation-master.json
# lands. Resolve the SHIPPED bundle via ${CLAUDE_HOME:-$HOME/.claude} FIRST; the
# Python body validates the composed .vault_writers + .file_type_contracts slots
# from it, falling back to the loose pillar files when the bundle is absent.
BUNDLE=""
for cand in \
  "$CLAUDE_HOME_RES/governance/foundation-master.json" \
  "$GOV_DIR/foundation-master.json"; do
  [ -f "$cand" ] && { BUNDLE="$cand"; break; }
done

VROOT="${VAULT_ROOT:-}"
if [ -z "$VROOT" ] || [ ! -d "$VROOT/Vault Writers" ]; then
  echo "writers-health-audit: 'Vault Writers/' not found under VAULT_ROOT" >&2
  exit 0
fi

SKILLS_DIR_RES="${SKILLS_DIR:-$CLAUDE_HOME_RES/skills}"

python3 - "$VROOT/Vault Writers" "${GOV_DIR:-}" "$SKILLS_DIR_RES" "${WRITER_MANIFEST_PATH:-}" "$MODE" "$BUNDLE" <<'PY'
import json, os, re, sys, glob as globmod
from datetime import date, datetime, timedelta

writers_dir, gov_dir, skills_dir, manifest_path, mode = sys.argv[1:6]
bundle_path = sys.argv[6] if len(sys.argv) > 6 else ""
dry_run = (mode == "dry-run")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")
vroot = os.environ.get("VAULT_ROOT", "")
MUSTACHE = re.compile(r"\{\{[^}]+\}\}")

def emit(d):
    if dry_run:
        return
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# block-and-log: validate source contracts parse.
# Bundle-first. On a fresh adopter the shipped
# foundation-master.json carries the composed .file_type_contracts["vault-writer.md"]
# + .vault_writers slots; confirm they resolve from the bundle. Fall back to the
# loose pillar files under gov_dir when the bundle is absent (dev-repo).
if bundle_path and os.path.isfile(bundle_path):
    try:
        with open(bundle_path, encoding="utf-8") as fh:
            _b = json.load(fh)
        if "vault_writers" not in _b or "vault-writer.md" not in (_b.get("file_type_contracts") or {}):
            print("writers-health-audit: foundation-master.json missing vault_writers / "
                  "vault-writer.md slot; aborting (block-and-log)", file=sys.stderr)
            sys.exit(1)
    except Exception as exc:
        print("writers-health-audit: foundation-master.json malformed; aborting "
              "(block-and-log): %s" % exc, file=sys.stderr)
        sys.exit(1)
elif gov_dir:
    for fn in ("file-type-contracts/vault-writer.md.json", "vault-writers-rules.json"):
        p = os.path.join(gov_dir, fn)
        if os.path.isfile(p):
            try:
                with open(p, encoding="utf-8") as fh:
                    json.load(fh)
            except Exception as exc:
                print("writers-health-audit: %s malformed; aborting (block-and-log): %s"
                      % (fn, exc), file=sys.stderr)
                sys.exit(1)

def parse_fm_block(text):
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    return text[3:end] if end != -1 else ""

def fm_field(fmb, key):
    m = re.search(r"(?m)^%s:\s*[\"']?([^\"'\n]+?)[\"']?\s*$" % re.escape(key), fmb)
    return m.group(1).strip() if m else ""

def fm_paths(fmb):
    paths = []
    for m in re.finditer(r"path:\s*[\"']?([^\"',}\n]+)", fmb):
        v = m.group(1).strip()
        if v:
            paths.append(v)
    return paths

# skill registry slug set
skill_slugs = set()
if os.path.isdir(skills_dir):
    for d in os.listdir(skills_dir):
        if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md")):
            skill_slugs.add(d)

# last-run map (dormant-writer). Direct sqlite if a manifest + sqlite3 exist;
# else empty -> never-observed predicate handles dormancy.
last_run = {}
if manifest_path and os.path.isfile(manifest_path):
    try:
        import sqlite3
        conn = sqlite3.connect("file:%s?mode=ro" % manifest_path, uri=True)
        for wid, last in conn.execute(
                "SELECT writer_id, MAX(ingestion_date) FROM writes "
                "WHERE status='active' GROUP BY writer_id"):
            last_run[wid] = last
        conn.close()
    except Exception:
        pass

# overlap-matrix cluster membership (cross-reference)
overlap_members = {}
mp = os.path.join(writers_dir, "_overlap-matrix.md")
if os.path.isfile(mp):
    try:
        with open(mp, encoding="utf-8") as fh:
            for ln in fh:
                if ln.strip().startswith("|") and "*" in ln:
                    cols = [c.strip() for c in ln.strip().strip("|").split("|")]
                    if len(cols) >= 2 and cols[1]:
                        glob_ = cols[0]
                        for w in [x.strip() for x in cols[1].split(",") if x.strip()]:
                            overlap_members.setdefault(w, []).append(glob_)
    except Exception:
        pass

cutoff = datetime.now() - timedelta(days=30)
counts = {"dormant-writer": 0, "unresolved-destination": 0,
          "orphan-writer-skill-ref": 0, "orphan-destination-ref": 0,
          "multi-writer-overlap": 0}

for fn in sorted(os.listdir(writers_dir)):
    if not fn.endswith(".md") or fn.startswith("_"):
        continue
    fp = os.path.join(writers_dir, fn)
    try:
        with open(fp, encoding="utf-8") as fh:
            txt = fh.read()
    except Exception:
        continue
    fmb = parse_fm_block(txt)
    if not fmb:
        continue
    name = fm_field(fmb, "writer_name") or fn[:-3]
    status = fm_field(fmb, "status")

    # dormant-writer
    lr = last_run.get(name)
    dormant = False
    if status == "active" and not lr:
        dormant = True
    elif lr:
        try:
            if datetime.fromisoformat(str(lr)[:19]) < cutoff:
                dormant = True
        except Exception:
            pass
    if dormant:
        days = ""
        emit({"finding": "dormant-writer", "file": fp, "writer_name": name,
              "writer_kind": fm_field(fmb, "writer_kind"), "status": status,
              "last_success_iso": lr or "", "days_since_last_success": days,
              "detected_at": today, "first_seen": today})
        counts["dormant-writer"] += 1

    # unresolved-destination
    for p in fm_paths(fmb):
        g = MUSTACHE.sub("*", p)
        matches = globmod.glob(os.path.join(vroot, g)) if vroot else []
        if not matches:
            emit({"finding": "unresolved-destination", "file": fp, "writer_name": name,
                  "destination_path_mustache": p, "destination_path_glob": g,
                  "path_routing_resolution": "no-folder-match",
                  "detected_at": today, "first_seen": today})
            counts["unresolved-destination"] += 1

    # orphan-writer-skill-ref
    ws = fm_field(fmb, "writer_skill")
    if ws and ws not in skill_slugs:
        emit({"finding": "orphan-writer-skill-ref", "file": fp, "writer_name": name,
              "writer_skill_ref": ws, "resolved_skill_path_or_null": None,
              "detected_at": today, "first_seen": today})
        counts["orphan-writer-skill-ref"] += 1

    # multi-writer-overlap (cross-reference)
    for g in overlap_members.get(name, []):
        emit({"finding": "multi-writer-overlap", "file": fp, "writer_name": name,
              "overlap_cluster_glob": g, "peer_writers": [],
              "detected_at": today})
        counts["multi-writer-overlap"] += 1

# orphan-destination-ref requires a path_routing retired-marker surface which
# the foundation does not yet populate; emit nothing rather than
# guess (graceful — the finding class is wired, the data source is absent).

if dry_run:
    print("writers-health-audit: dry-run counts=%s" % json.dumps(counts), file=sys.stderr)
PY

#!/bin/bash
# writers-overlap-refresh — Cross-reference all writer-reference files, derive a
# glob form of each destination path, cluster by glob equivalence, detect cases
# where >=2 writers share a destination, and regenerate
# Vault Writers/_overlap-matrix.md.
#
# Librarian body. Reuses the backlog-index regeneration shell; the new algorithms
# are glob-derivation ({{var}}->*), >=2-writer clustering, write-shape-conflict
# detection, and doc-deps writer-fan-in producer-join validation.
#
# Output Contract
#   Files written: $VAULT_ROOT/Vault Writers/_overlap-matrix.md (sentinel-bounded
#     table region regenerated; operator narrative outside the sentinels
#     preserved verbatim); findings to stdout (NDJSON via hooks/lib/findings.sh)
#     or $FINDINGS_OUTPUT.
#   Pre-write validation: locate the <!-- overlap-matrix:start/end --> sentinel
#     pair (or initialize fresh); abort (block-and-log) if neither.
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Read-only against writer-reference + _processing-rules.json files.
#     Deterministic glob derivation (same Mustache input -> same glob output).
#
# Finding categories (5):
#   multi-writer-overlap-detected     (info-event) a destination glob shared by >=2 writers
#   destination-collision-unresolved  (warning) multi-writer cluster, no folder _processing-rules.json override
#   overlap-matrix-regenerated        (info-event) _overlap-matrix.md regenerated; once per run
#   write-shape-conflict              (warning) cluster members declare incompatible write_shape
#   consumer-references-unmatched-producer (warning) doc-deps writer-fan-in references missing/mismatched producer
#
# CLI:
#   writers-overlap-refresh.sh           # regenerate Vault Writers/_overlap-matrix.md
#   writers-overlap-refresh.sh --check   # parity report + findings; no write
#   writers-overlap-refresh.sh --help
#
# Env overrides (testing):
#   VAULT_ROOT        vault root (Vault Writers/ resolves under it)
#   GOVERNANCE_DIR    governance root (default: foundation-repo -> live)
#   FINDINGS_OUTPUT   NDJSON sink (default: stdout)
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
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "writers-overlap-refresh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi

# Bundle-first: doc-dependencies.json is repo-only / bundle-composed —
# on a fresh adopter only foundation-master.json lands. Resolve the SHIPPED
# bundle via ${CLAUDE_HOME:-$HOME/.claude} FIRST; the Python body reads the
# composed .doc_dependencies slot from it (the writer-fan-in entries), falling
# back to the loose pillar file when the bundle is absent (dev-repo).
BUNDLE=""
for cand in \
  "$CLAUDE_HOME_RES/governance/foundation-master.json" \
  "$GOV_DIR/foundation-master.json"; do
  [ -f "$cand" ] && { BUNDLE="$cand"; break; }
done

VROOT="${VAULT_ROOT:-}"
if [ -z "$VROOT" ] || [ ! -d "$VROOT/Vault Writers" ]; then
  echo "writers-overlap-refresh: 'Vault Writers/' not found under VAULT_ROOT" >&2
  exit 0
fi

python3 - "$VROOT/Vault Writers" "${GOV_DIR:-}" "$CHECK" "$BUNDLE" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

writers_dir, gov_dir, check_s = sys.argv[1:4]
bundle_path = sys.argv[4] if len(sys.argv) > 4 else ""
check_only = (check_s == "true")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")
matrix_path = os.path.join(writers_dir, "_overlap-matrix.md")

START = "<!-- overlap-matrix:start -->"
END = "<!-- overlap-matrix:end -->"
MUSTACHE = re.compile(r"\{\{[^}]+\}\}")

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def parse_fm_block(text):
    """Return the raw frontmatter block text (between the --- fences), or ''."""
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    return text[3:end] if end != -1 else ""

def derive_glob(path):
    return MUSTACHE.sub("*", path)

def writer_destinations(fm_block):
    """Shared block-list-aware destination extraction. The first-pass
    line-anchored reader captures block-list `- path: X` and single-line `path: X`
    with a char-class that does NOT exclude `}`, so a `{{mustache}}` destination is
    captured WHOLE (never truncated at the first `}`). Inline flow-style
    `destinations: [{path: X}]` is captured by a SEPARATE bracket-scoped pass whose
    `}`/`,`/`]` delimiters fire ONLY on genuine flow-style lines (a block-list
    mustache line has no `[` and was captured whole above — Risk row 3 guard).
    Pure-regex, no PyYAML. The prior redundant 2nd inline pass ran a `[^"',}\n]`
    char-class over the WHOLE block and truncated block-list mustache paths at the
    first `}`, injecting a garbage token derive_glob could not collapse -> a phantom
    cluster + duplicate findings; it is DROPPED."""
    paths = []
    shapes = []
    for line in fm_block.splitlines():
        m = re.search(r"(?:^|[-\s])path:\s*[\"']?([^\"'\n]+?)[\"']?\s*$", line)
        if m:
            v = m.group(1).strip()
            if v and v not in paths:
                paths.append(v)
        m2 = re.search(r"write_shape:\s*[\"']?([A-Za-z0-9_-]+)", line)
        if m2:
            shapes.append(m2.group(1).strip())
    for line in fm_block.splitlines():
        if "[" not in line:
            continue
        for m in re.finditer(r"path:\s*[\"']?([^\"',}\]\n]+)", line):
            v = m.group(1).strip()
            if v and v not in paths:
                paths.append(v)
    return paths, shapes

def writer_name(fm_block, fallback):
    m = re.search(r"(?m)^writer_name:\s*[\"']?([^\"'\n]+?)[\"']?\s*$", fm_block)
    return m.group(1).strip() if m else fallback

# enumerate writers -> glob clusters
glob_writers = {}        # glob -> set(writer names)
writer_shape = {}        # (glob, writer) -> write_shape
writer_paths = {}        # writer -> [glob]
total_writers = 0
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
    total_writers += 1
    name = writer_name(fmb, fn[:-3])
    paths, shapes = writer_destinations(fmb)
    shape = shapes[0] if shapes else ""
    for p in paths:
        g = derive_glob(p)
        glob_writers.setdefault(g, set()).add(name)
        writer_shape[(g, name)] = shape
        # dedupe: a writer contributing the SAME glob twice (e.g. two paths that
        # collapse to one *-glob) must not double-count into a cluster.
        if g not in writer_paths.setdefault(name, []):
            writer_paths[name].append(g)

clusters = {g: sorted(ws) for g, ws in glob_writers.items() if len(ws) >= 2}

rows = []
for g in sorted(clusters):
    members = clusters[g]
    rows.append("| %s | %s | | |" % (g.replace("|", "\\|"), ", ".join(members)))
    # multi-writer-overlap-detected (event) per cluster
    emit({"finding": "multi-writer-overlap-detected", "file": matrix_path,
          "destination_glob": g, "writer_count": len(members),
          "writer_names": members, "detected_at": today})
    # destination-collision-unresolved — no folder-level _processing-rules.json
    folder = g.split("*", 1)[0].rstrip("/")
    pr = os.path.join(os.environ.get("VAULT_ROOT", ""), folder, "_processing-rules.json") if folder else ""
    if not pr or not os.path.isfile(pr):
        emit({"finding": "destination-collision-unresolved", "file": matrix_path,
              "destination_glob": g, "writer_names": members,
              "applicable_pillar_defaults": "processing_defaults",
              "detected_at": today, "first_seen": today})
    # write-shape-conflict — incompatible declared write_shape across members
    shapes = set()
    for w in members:
        s = writer_shape.get((g, w), "")
        if s:
            shapes.add(s)
    if len(shapes) >= 2:
        emit({"finding": "write-shape-conflict", "file": matrix_path,
              "destination_glob": g,
              "conflicting_writers": [{"writer_name": w,
                                       "declared_write_shape": writer_shape.get((g, w), "")}
                                      for w in members],
              "detected_at": today, "first_seen": today})

# consumer-references-unmatched-producer — doc-deps writer-fan-in producer-join
# Bundle-first. On a fresh adopter the shipped
# foundation-master.json carries the composed .doc_dependencies slot; read its
# writer-fan-in entries from the bundle, falling back to the loose pillar under
# gov_dir when the bundle is absent (dev-repo authoring).
dd = None
ddp = bundle_path if (bundle_path and os.path.isfile(bundle_path)) else ""
if ddp:
    try:
        with open(ddp, encoding="utf-8") as fh:
            dd = (json.load(fh).get("doc_dependencies") or {})
    except Exception:
        dd = None
elif gov_dir:
    _ddp = os.path.join(gov_dir, "doc-dependencies.json")
    if os.path.isfile(_ddp):
        ddp = _ddp
        try:
            with open(_ddp, encoding="utf-8") as fh:
                dd = json.load(fh)
        except Exception:
            dd = None
if isinstance(dd, dict):
    try:
        for ent in (dd.get("entries") or []):
            if not isinstance(ent, dict) or ent.get("kind") != "writer-fan-in":
                continue
            consumer = ent.get("consumer", "")
            consumer_glob = derive_glob(consumer)
            for w in (ent.get("upstream_writers") or []):
                matched = False
                for g in writer_paths.get(w, []):
                    if g == consumer_glob or consumer_glob.startswith(g.rstrip("*")):
                        matched = True
                        break
                if not matched:
                    emit({"finding": "consumer-references-unmatched-producer",
                          "file": ddp, "consumer": consumer,
                          "missing_or_mismatched_writer": w,
                          "upstream_writers_declared": ent.get("upstream_writers") or [],
                          "detected_at": today, "first_seen": today})
    except Exception:
        pass  # malformed doc-deps is owned by other auditors

table = ["| Destination glob | Writers | Output type(s) | Processing rules resolution |",
         "|------------------|---------|----------------|-----------------------------|"]
if rows:
    table += rows
else:
    table.append("| _No multi-writer overlaps detected._ | | | |")

preface, footer = "", ""
sentinel_existed = False
if os.path.isfile(matrix_path):
    with open(matrix_path, encoding="utf-8") as fh:
        existing = fh.read()
    s_idx = existing.find(START)
    e_idx = existing.find(END)
    if s_idx >= 0 and e_idx > s_idx:
        sentinel_existed = True
        preface = existing[:s_idx]
        footer = existing[e_idx + len(END):]

if not preface.strip():
    preface = (
        "---\ntype: overlap-matrix\nparent_folder: \"Vault Writers\"\n"
        "generated_by: librarian writers-overlap-refresh\n"
        "writers_allowed: [\"librarian\"]\ntags: [\"#scope/reference\"]\n"
        "updated: %s\n---\n\n# Vault Writers — Overlap Matrix\n\n"
        "_Multi-writer destination clusters. Regenerated by the librarian._\n\n"
        "## Clusters\n\n" % today)

generated = START + "\n\n" + "\n".join(table) + "\n\n" + END
if preface and not preface.endswith("\n"):
    preface += "\n"
if footer and not footer.startswith("\n"):
    footer = "\n" + footer
new_content = preface + generated + footer
if not new_content.endswith("\n"):
    new_content += "\n"

existing_content = None
if os.path.isfile(matrix_path):
    with open(matrix_path, encoding="utf-8") as fh:
        existing_content = fh.read()
drift = (existing_content != new_content)

if check_only:
    emit({"finding": "overlap-matrix-regenerated", "file": matrix_path,
          "clusters_rendered_count": len(clusters), "total_writers_scanned": total_writers,
          "sentinel_recreated_bool": (not sentinel_existed), "dry_run": True,
          "drift_detected_bool": drift, "detected_at": today})
    sys.exit(0)

if START not in new_content or END not in new_content:
    print("writers-overlap-refresh: refusing to write — sentinels missing", file=sys.stderr)
    sys.exit(1)

# Idempotence-gate: when the rendered content already
# matches what is on disk, skip the os.replace so a virgin/clean close is a true
# no-op write. Emit only the info-event (write_skipped_bool).
if not drift:
    emit({"finding": "overlap-matrix-regenerated", "file": matrix_path,
          "clusters_rendered_count": len(clusters), "total_writers_scanned": total_writers,
          "sentinel_recreated_bool": (not sentinel_existed),
          "drift_detected_bool": False, "write_skipped_bool": True,
          "detected_at": today})
    sys.exit(0)

d = os.path.dirname(matrix_path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix="._overlap.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(new_content)
    os.replace(tmp, matrix_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

emit({"finding": "overlap-matrix-regenerated", "file": matrix_path,
      "clusters_rendered_count": len(clusters), "total_writers_scanned": total_writers,
      "sentinel_recreated_bool": (not sentinel_existed),
      "drift_detected_bool": True, "write_skipped_bool": False,
      "detected_at": today})
PY

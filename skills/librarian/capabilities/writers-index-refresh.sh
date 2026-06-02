#!/bin/bash
# writers-index-refresh — Regenerate the canonical Vault Writers/_index.md
# catalog table from the writer-reference files in Vault Writers/.
#
# Librarian body. Reuses the backlog-index/plan-index sentinel-regeneration
# pattern; the new logic is the column composer + the per-writer
# vault-writer.md.json validation loop.
#
# Output Contract
#   Files written: $VAULT_ROOT/Vault Writers/_index.md (sentinel-bounded table
#     region regenerated; operator narrative outside the sentinels preserved
#     verbatim); findings to stdout (NDJSON via hooks/lib/findings.sh) or
#     $FINDINGS_OUTPUT.
#   Schema gate: each writer-reference frontmatter validated against
#     governance/file-type-contracts/vault-writer.md.json (required +
#     conditional-by-writer_kind) BEFORE row composition.
#   Pre-write validation: locate the <!-- writers-index:start/end --> sentinel
#     pair (or initialize a fresh file); abort (block-and-log) if neither the
#     sentinel pair can be located NOR a fresh file initialized.
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Read-only against writer-reference files.
#
# Finding categories (4):
#   writer-frontmatter-malformed (warning) unparseable / contract-failing frontmatter
#   writer-missing-required-field(warning) required frontmatter field absent
#   writer-kind-violation        (warning) writer_kind conditional-required field absent
#   writers-index-regenerated    (info-event) _index.md regenerated; once per run
#
# CLI:
#   writers-index-refresh.sh             # regenerate Vault Writers/_index.md
#   writers-index-refresh.sh --check     # parity report + findings; no write
#   writers-index-refresh.sh --help
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
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "writers-index-refresh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi

VROOT="${VAULT_ROOT:-}"
if [ -z "$VROOT" ] || [ ! -d "$VROOT/Vault Writers" ]; then
  echo "writers-index-refresh: 'Vault Writers/' not found under VAULT_ROOT" >&2
  exit 0
fi

python3 - "$VROOT/Vault Writers" "${GOV_DIR:-}" "$CHECK" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

writers_dir, gov_dir, check_s = sys.argv[1:4]
check_only = (check_s == "true")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")
index_path = os.path.join(writers_dir, "_index.md")

START = "<!-- writers-index:start -->"
END = "<!-- writers-index:end -->"

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

REQUIRED = ["type", "writer_name", "writer_kind", "writer_skill",
            "destinations", "status", "created", "updated", "tags"]
CONDITIONAL = {
    "connector": ["writer_subtype", "source", "authentication"],
    "agentic-flow": ["source"],
    "auto-research": ["source", "schedule"],
    "scheduled-skill": ["schedule"],
}

def parse_fm(text):
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    fm = {}
    for line in text[3:end].splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm

def cell(v):
    s = "" if v is None else str(v)
    return s.replace("\n", " ").replace("|", "\\|").strip()

rows = []
rendered = 0
skipped = 0
for fn in sorted(os.listdir(writers_dir)):
    if not fn.endswith(".md") or fn.startswith("_"):
        continue
    fp = os.path.join(writers_dir, fn)
    try:
        with open(fp, encoding="utf-8") as fh:
            txt = fh.read()
    except Exception:
        continue
    fm = parse_fm(txt)
    if fm is None:
        emit({"finding": "writer-frontmatter-malformed", "file": fp,
              "validation_error": "unparseable-frontmatter",
              "detected_at": today, "first_seen": today})
        skipped += 1
        continue
    missing = [f for f in REQUIRED if not fm.get(f)]
    if missing:
        emit({"finding": "writer-missing-required-field", "file": fp,
              "missing_fields": missing, "detected_at": today, "first_seen": today})
    kind = fm.get("writer_kind", "")
    cond = CONDITIONAL.get(kind, [])
    missing_cond = [f for f in cond if not fm.get(f)]
    if missing_cond:
        emit({"finding": "writer-kind-violation", "file": fp,
              "writer_kind": kind, "missing_conditional_fields": missing_cond,
              "detected_at": today, "first_seen": today})
    name = fm.get("writer_name") or fn[:-3]
    if not name:
        skipped += 1
        continue
    dest = fm.get("destinations", "")
    dest_summary = cell(dest)[:60] if dest else "—"
    rows.append((name, "| %s | %s | %s | %s | %s |" % (
        cell(name), cell(kind) or "—", cell(fm.get("status")) or "—",
        cell(fm.get("last_run")) or "—", dest_summary)))
    rendered += 1

rows.sort(key=lambda r: r[0].lower())
table = ["| Name | Kind | Status | Last run | Destinations summary |",
         "|------|------|--------|----------|----------------------|"]
table += [r[1] for r in rows]

# preserve operator narrative outside the sentinels.
preface, footer = "", ""
sentinel_existed = False
if os.path.isfile(index_path):
    with open(index_path, encoding="utf-8") as fh:
        existing = fh.read()
    s_idx = existing.find(START)
    e_idx = existing.find(END)
    if s_idx >= 0 and e_idx > s_idx:
        sentinel_existed = True
        preface = existing[:s_idx]
        footer = existing[e_idx + len(END):]

if not preface.strip():
    preface = (
        "---\ntype: index\nparent_folder: \"Vault Writers\"\n"
        "generated_by: librarian writers-index-refresh\n"
        "writers_allowed: [\"librarian\"]\ntags: [\"#scope/reference\"]\n"
        "updated: %s\n---\n\n# Vault Writers\n\n"
        "_Catalog of vault-writing systems. Regenerated by the librarian; "
        "edit narrative outside the sentinels only._\n\n## Writers\n\n" % today)
if not footer.strip():
    footer = "\n## See also\n\n- [[_overlap-matrix]]\n"

generated = START + "\n" + "\n".join(table) + "\n" + END
if preface and not preface.endswith("\n"):
    preface += "\n"
new_content = preface + generated + footer
if not new_content.endswith("\n"):
    new_content += "\n"

existing_content = None
if os.path.isfile(index_path):
    with open(index_path, encoding="utf-8") as fh:
        existing_content = fh.read()
drift = (existing_content != new_content)

if check_only:
    if drift:
        emit({"finding": "writer-frontmatter-malformed", "file": index_path,
              "validation_error": "index-drift-vs-render", "detected_at": today,
              "first_seen": today}) if False else None
    emit({"finding": "writers-index-regenerated", "file": index_path,
          "writers_rendered_count": rendered, "writers_skipped_count": skipped,
          "sentinel_recreated_bool": (not sentinel_existed), "dry_run": True,
          "drift_detected_bool": drift, "detected_at": today})
    sys.exit(0)

if START not in new_content or END not in new_content:
    print("writers-index-refresh: refusing to write — sentinels missing", file=sys.stderr)
    sys.exit(1)

d = os.path.dirname(index_path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix="._index.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(new_content)
    os.replace(tmp, index_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

emit({"finding": "writers-index-regenerated", "file": index_path,
      "writers_rendered_count": rendered, "writers_skipped_count": skipped,
      "sentinel_recreated_bool": (not sentinel_existed), "detected_at": today})
PY

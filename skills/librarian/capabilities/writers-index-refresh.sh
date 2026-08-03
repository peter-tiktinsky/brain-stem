#!/bin/bash
# writers-index-refresh — Regenerate the canonical Vault Writers/_index.md
# catalog table from the writer-reference files in Vault Writers/.
# NET-NEW librarian body (1.1 line 139). Authored from the
# the net-new logic is the column composer + the per-writer
# vault-writer.md.json validation loop.
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
# Finding categories (4 — §Finding categories):
#   writer-frontmatter-malformed (warning) unparseable / contract-failing frontmatter
#   writer-missing-required-field(warning) required frontmatter field absent
#   writer-kind-violation        (warning) writer_kind conditional-required field absent
#   writers-index-regenerated    (info-event) _index.md regenerated; once per run
# CLI:
#   writers-index-refresh.sh             # regenerate Vault Writers/_index.md
#   writers-index-refresh.sh --check     # parity report + findings; no write
#   writers-index-refresh.sh --help
# Env overrides (testing):
#   VAULT_ROOT        vault root (Vault Writers/ resolves under it)
#   GOVERNANCE_DIR    governance root (default: foundation-repo -> live)
#   FINDINGS_OUTPUT   NDJSON sink (default: stdout)
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
# repo fallback so a dev run without a live install still resolves
# the DECLARED dep governance/file-type-contracts/vault-writer.md.json (ships standalone).
if [ -z "$GOV_DIR" ] || [ ! -d "$GOV_DIR" ]; then
  GOV_DIR="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/governance"
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

# derive REQUIRED + CONDITIONAL from the DECLARED contract
# governance/file-type-contracts/vault-writer.md.json instead of the prior hardcoded
# constants — so contract drift (e.g. the connector `schedule` the contract requires at
# frontmatter_conditional_by_writer_kind.connector.required) is no longer invisible.
# READ-ONLY consume (the contract is not edited) -> NO master rebuild. Block-and-log if
# the contract is absent/malformed (never silently fall back to a stale hardcode).
_contract = None
if gov_dir:
    _cpath = os.path.join(gov_dir, "file-type-contracts", "vault-writer.md.json")
    if os.path.isfile(_cpath):
        try:
            with open(_cpath, encoding="utf-8") as fh:
                _contract = json.load(fh)
        except Exception:
            _contract = "MALFORMED"
if isinstance(_contract, dict):
    REQUIRED = [f for f in (_contract.get("frontmatter_required") or []) if isinstance(f, str)]
    CONDITIONAL = {}
    for _kind, _spec in (_contract.get("frontmatter_conditional_by_writer_kind") or {}).items():
        if isinstance(_spec, dict):
            CONDITIONAL[_kind] = [f for f in (_spec.get("required") or []) if isinstance(f, str)]
else:
    # Contract absent/malformed: emit a LOUD finding and DEGRADE writer validation to a
    # no-op (REQUIRED=[]/CONDITIONAL={}) — never silently fall back to a stale hardcode.
    # The _index.md RENDER (a SEPARATE function from validation) still proceeds so the
    # catalog stays current; the finding surfaces that per-writer conformance was NOT
    # checked this run (the contract ships standalone, so this is an off-nominal path).
    emit({"finding": "writer-contract-unavailable",
          "file": os.path.join(gov_dir or "", "file-type-contracts", "vault-writer.md.json"),
          "reason": "vault-writer.md.json absent-or-malformed",
          "detail": "REQUIRED/CONDITIONAL cannot be contract-sourced; writer validation degraded to no-op (no stale hardcode); render proceeds",
          "detected_at": today, "first_seen": today})
    REQUIRED = []
    CONDITIONAL = {}

def _dest_paths(lines):
    """Shared block-list-aware destination-path extraction (mirrors the overlap
    first-pass reader writers-overlap-refresh.sh:124-130). Handles a block-list
    `- path: X` (a `{{mustache}}` path is captured WHOLE — the char-class does NOT
    exclude `}`), an inline flow-style `destinations: [{path: X}]` (bracket-scoped
    so the `}`/`,`/`]` delimiters fire ONLY on genuine flow-style, never on a
    block-list mustache line), and an inline-scalar `destinations: X`. Pure-regex,
    NO PyYAML (the close-wired cap gains no runtime prereq)."""
    paths = []
    for line in lines:
        m = re.search(r"(?:^|[-\s])path:\s*[\"']?([^\"'\n]+?)[\"']?\s*$", line)
        if m:
            v = m.group(1).strip()
            if v and v not in paths:
                paths.append(v)
    for line in lines:
        if "[" not in line:
            continue
        for m in re.finditer(r"path:\s*[\"']?([^\"',}\]\n]+)", line):
            v = m.group(1).strip()
            if v and v not in paths:
                paths.append(v)
    for line in lines:
        m = re.match(r"^destinations:\s*(.+?)\s*$", line)
        if m:
            raw = m.group(1).strip()
            if raw and not raw.startswith("[") and not raw.startswith("{"):
                v = raw.strip("\"'")
                if v and v not in paths:
                    paths.append(v)
    return paths

def parse_fm(text):
    # Block-list-aware frontmatter reader. A required key is recognized as
    # PRESENT even when its value is a block-list (`- ...`) or a nested map (indented
    # `key:` children) on the lines below it — the flat scalar parse read those as
    # empty "" and false-flagged the wizard's yaml.safe_dump block-list destinations
    # tags and nested authentication/source. Scalar + inline flow-style values on
    # the same line are still read directly, so inline-scalar / legacy shapes stay
    # PRESENT (backward-compat). Destination `- path:` tokens are summarized into
    # `__dest_paths__` for the catalog Destinations column.
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    lines = text[3:end].splitlines()
    n = len(lines)
    fm = {}
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if not m:
            continue
        key, inline = m.group(1), m.group(2)
        if inline != "":
            fm[key] = inline
            continue
        # empty inline value: PRESENT iff a block-list `- ...` or an indented
        # nested-map child follows on the next non-blank line (else genuinely empty).
        present = ""
        for j in range(i + 1, n):
            nxt = lines[j]
            if nxt.strip() == "":
                continue
            if re.match(r"^\s*-\s", nxt) or re.match(r"^\s+\S", nxt):
                present = "__block__"
            break
        fm[key] = present
    fm["__dest_paths__"] = _dest_paths(lines)
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
    project = fm.get("project") or ""
    proj_cell = cell(project) if project else "—"
    # Destinations column: summarize the real block-list `- path:` tokens (was
    # fm.get("destinations") which read the empty block-list scalar -> `—`). Fall
    # back to a parsed inline-scalar `destinations:` value for a legacy writer.
    dpaths = fm.get("__dest_paths__") or []
    if not dpaths:
        _d0 = fm.get("destinations", "")
        if _d0 and _d0 != "__block__" and not str(_d0).startswith("["):
            dpaths = [str(_d0).strip("\"'")]
    dest_summary = cell(", ".join(dpaths))[:60] if dpaths else "—"
    rows.append((project, name, "| %s | %s | %s | %s | %s | %s |" % (
        proj_cell, cell(name), cell(kind) or "—", cell(fm.get("status")) or "—",
        cell(fm.get("last_run")) or "—", dest_summary)))
    rendered += 1

# Composite (project, name) sort over a SINGLE global table: project-scoped rows
# precede unscoped ones (an empty project sorts AFTER any named one), then name.
rows.sort(key=lambda r: (r[0] == "", r[0].lower(), r[1].lower()))
table = ["| Project | Name | Kind | Status | Last run | Destinations summary |",
         "|---------|------|------|--------|----------|----------------------|"]
table += [r[2] for r in rows]

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

generated = START + "\n\n" + "\n".join(table) + "\n\n" + END
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

# Idempotence-gate (-session-close-2): when the rendered content already
# matches what is on disk, skip the os.replace so a virgin/clean close is a true
# no-op write. Emit only the info-event (write_skipped_bool).
if not drift:
    emit({"finding": "writers-index-regenerated", "file": index_path,
          "writers_rendered_count": rendered, "writers_skipped_count": skipped,
          "sentinel_recreated_bool": (not sentinel_existed),
          "drift_detected_bool": False, "write_skipped_bool": True,
          "detected_at": today})
    sys.exit(0)

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
      "sentinel_recreated_bool": (not sentinel_existed),
      "drift_detected_bool": True, "write_skipped_bool": False,
      "detected_at": today})
PY

#!/bin/bash
# work-index-maintain — a WORK-SCOPED index pass that walks $WORK_HOME and
# mints/refreshes a C-IDX-conformant `_index.md` inside each `deliverables/` and
# `reference/` directory under each work spoke. This is the universal-foundation
# counterpart to index-maintain (which is VAULT_ROOT-scoped): a work spoke lives at
# an EXTERNAL root ($WORK_HOME/<spoke>/, not under the vault root), so index-maintain's
# vault walk never reaches it. This pass targets $WORK_HOME DIRECTLY (a NEW pass — it
# does NOT modify index-maintain's VAULT_ROOT scoping, and it is NOT a per-spoke
# overlay-glob registration).
# The `_index.md` it mints conforms to the SAME C-IDX contract index-maintain enforces:
# frontmatter `type: index` + `tags` + `updated` + `parent_folder` (depth>=2) and a
# `<!-- contents-enum:start -->` … `<!-- contents-enum:end -->` block enumerating the
# directory's contents in the `| Name | Lines | Type | Description |` row shape. A file
# minted here passes index-maintain's index contract + frontmatter-enforce's index type.
# Scope (per spoke — all spokes by default, or `--spoke <key>`):
#   FLAT spoke   — $WORK_HOME/<spoke>/deliverables/ + .../reference/ are the TOP level.
#   MASTER spoke — the master holds NO top-level deliverables/+reference/; each
#                  sub-project is a DIRECT child of the master ($WORK_HOME/<spoke>/<sub>/)
#                  and owns its OWN deliverables/+reference/. There is NO literal
#                  `sub-projects/` dir in the shipped scaffold layout — the AC's
#                  "(master) sub-projects/_index.md" resolves to the per-sub-project
#                  $WORK_HOME/<spoke>/<sub>/{deliverables,reference}/_index.md. The
#                  master's TOP-LEVEL sub-project navigation is the work-map's domain
#                  (work-map-generate, the work CLAUDE.md directory map) — NOT this pass.
# For every such directory: mint a full `_index.md` if absent, else refresh ONLY the
# contents-enum block (everything outside the markers preserved byte-for-byte).
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT R-GOV-2/R-GOV-3):
#   Files written:
#     - $WORK_HOME/<spoke>/.../{deliverables,reference}/_index.md (atomic
#       temp+os.replace). MINT the full C-IDX-conformant `_index.md` when absent;
#       when present WITH the contents-enum markers, refresh ONLY the text strictly
#       between the markers (markers + everything outside preserved byte-for-byte);
#       when present WITHOUT the markers (a legacy / hand-authored _index.md), leave it
#       untouched with a finding (never impose the shape). Idempotent: a re-run without
#       a disk change is byte-identical.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: null (no JSON Schema governs the generated markdown; the contents-enum block
#     is a deterministic projection of the directory's file listing, and the frontmatter
#     conforms to governance/frontmatter-rules.json#types.index by construction).
#   Pre-write validation:
#     - the work home must resolve to a directory (absent => block-and-log, no write,
#       exit 0 — never crash).
#     - the spoke dir must exist (absent => defensive skip + finding, no write).
#     - a target {deliverables,reference}/ subfolder must exist + be readable (absent /
#       unreadable => defensive skip + finding; never minted out of thin air).
#     - atomic temp-file + os.replace.
#   Failure mode: BLOCK-AND-LOG. An absent work home / absent spoke / absent-or-unreadable
#     target subfolder / unreadable _index.md / marker-less _index.md emits a finding and
#     is SKIPPED; no partial/garbage write; exit 0 always. Never write-and-hope.
#   Maintainer-provenance (R-GOV-3): the `_index.md` files under
#     $WORK_HOME/<spoke>/.../{deliverables,reference}/ are librarian-maintained; this
#     capability is their sole originating writer. It writes ONLY `_index.md` files in
#     those directories. It NEVER writes README.md, updates.md, CLAUDE.md,
#     deliverable/reference bodies, or anything under the plans root (PLANS_ROOT).
# CLI:
#   work-index-maintain.sh                  # mint/refresh every spoke's index files
#   work-index-maintain.sh --spoke <key>    # one spoke only
#   work-index-maintain.sh --dry-run        # findings + would-be writes, NO write
#   work-index-maintain.sh --help
# Env overrides (testing):
#   WORK_HOME / BRAIN_STEM_WORK_HOME   work spokes root (test isolation; resolved the
#                                      way scaffold.sh / work-map-generate resolve it —
#                                      WORK_HOME wins, then BRAIN_STEM_WORK_HOME, then
#                                      $HOME/work)
#   PLANS_DIR / PLANS_ROOT             plan-tree root (resolved via paths.sh; this pass
#                                      writes to $WORK_HOME, NOT PLANS_ROOT, but paths.sh
#                                      is sourced for sibling parity)
#   FINDINGS_OUTPUT                    NDJSON sink (default: stdout)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24 (data via argv, never
# piped stdin — feedback_python_heredoc_argv). Read-only spoke walk + atomic _index.md
# write under the work home.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

DRY_RUN="false"
SPOKE_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spoke)   SPOKE_FILTER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "work-index-maintain: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- work-home resolution (the scaffold.sh / work-map-generate order: WORK_HOME ->
#     BRAIN_STEM_WORK_HOME -> $HOME/work). Honored for test isolation. -------------
WORK_HOME="${WORK_HOME:-${BRAIN_STEM_WORK_HOME:-$HOME/work}}"
case "$WORK_HOME" in */) WORK_HOME="${WORK_HOME%/}" ;; esac

# --- shape-detection helper (single SoT for sub-project classification) --------
# Source work-spoke-layout.sh so the per-spoke child descent walks ONLY true
# sub-projects (dirs owning deliverables/ or reference/) — the same shared
# predicate the other work walkers use. The sub list crosses into the python3
# heredoc via a small manifest tempfile (path passed by argv).
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/work-spoke-layout.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/work-spoke-layout.sh"; } \
  || { [ -r "$_REPO_LIB/work-spoke-layout.sh" ] && source "$_REPO_LIB/work-spoke-layout.sh"; } \
  || { echo "work-index-maintain: shape helper work-spoke-layout.sh not found" >&2; exit 3; }

CLASSIFY_MANIFEST="$(mktemp)" || { echo "work-index-maintain: mktemp failed" >&2; exit 3; }
DEEXEMPT_UNION=""
trap 'rm -f "$CLASSIFY_MANIFEST" "${DEEXEMPT_UNION:-}"' EXIT

# --- de-exemption SoT: the Work-subtree _index.md mandate TARGETS beyond
#     {deliverables,reference} are DERIVED from the overlay path_routing.rules[]
#     (mandatory-files-rules.json:40 — a Work/** folder registered via the adopter's
#     overlay is RE-INCLUDED in the _index.md mandate). Resolve the SHIPPED foundation-
#     master bundle + merge the overlay via foundation-overlay-load.sh (same posture as
#     index-maintain / library-index): the merged union's frontmatter.path_routing.rules
#     carry every de-exemption glob. FALL BACK to reading $GOV_DIR/overlay-master.json
#     DIRECTLY (the de-exemption SoT) when no bundle/merger (dev-repo / test). The SHIPPED
#     overlay is EMPTY ({}) so this yields ZERO new targets by default (no engagement
#     vocab; preserves the _g4_park empty-skeleton invariant). GOVERNANCE_DIR overrides.
GOV_DIR_RES="${GOVERNANCE_DIR:-$CLAUDE_HOME_RES/governance}"
DEEXEMPT_BUNDLE=""
for _cand in "$CLAUDE_HOME_RES/governance/foundation-master.json" "$GOV_DIR_RES/foundation-master.json"; do
  [ -f "$_cand" ] && { DEEXEMPT_BUNDLE="$_cand"; break; }
done
_OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$_REPO_ROOT/hooks/lib/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -n "$DEEXEMPT_BUNDLE" ] && [ -f "$DEEXEMPT_BUNDLE" ]; then
  DEEXEMPT_UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$DEEXEMPT_UNION" ] && bash "$_OVL" --foundation-path "$DEEXEMPT_BUNDLE" \
        --overlay-path "$(dirname "$DEEXEMPT_BUNDLE")/overlay-master.json" --force-override > "$DEEXEMPT_UNION" 2>/dev/null \
        && [ -s "$DEEXEMPT_UNION" ]; then
    DEEXEMPT_BUNDLE="$DEEXEMPT_UNION"
  elif [ -n "$DEEXEMPT_UNION" ]; then rm -f "$DEEXEMPT_UNION"; DEEXEMPT_UNION=""; fi
fi
OVERLAY_DIRECT="$GOV_DIR_RES/overlay-master.json"

# Emit one target spoke's shape-qualified sub list + the plain OTHER folders (via the
# helper) into the manifest. The OTHER dirs (WSL_OTHER_DIRS — e.g. People/, Meetings/)
# are the de-exemption candidates the python body matches against the overlay globs.
_wim_emit_classification() {
  local sp="$1" dir="$2" nm
  classify_top_level "$dir"
  {
    printf 'SPOKE\t%s\n' "$sp"
    while IFS= read -r nm || [ -n "$nm" ]; do
      [ -n "$nm" ] && printf 'SUB\t%s\n' "$nm"
    done <<EOF
$WSL_SUBPROJECTS
EOF
    while IFS= read -r nm || [ -n "$nm" ]; do
      [ -n "$nm" ] && printf 'OTHER\t%s\n' "$nm"
    done <<EOF
$WSL_OTHER_DIRS
EOF
    printf 'END\n'
  } >> "$CLASSIFY_MANIFEST"
}

if [ -n "$SPOKE_FILTER" ]; then
  _wim_emit_classification "$SPOKE_FILTER" "$WORK_HOME/$SPOKE_FILTER"
elif [ -d "$WORK_HOME" ]; then
  for _sp_path in "$WORK_HOME"/*; do
    [ -d "$_sp_path" ] || continue
    _sp_name=$(basename "$_sp_path")
    case "$_sp_name" in .*) continue ;; esac
    _wim_emit_classification "$_sp_name" "$_sp_path"
  done
fi

python3 - "$WORK_HOME" "$DRY_RUN" "$SPOKE_FILTER" "$CLASSIFY_MANIFEST" "$DEEXEMPT_BUNDLE" "$OVERLAY_DIRECT" <<'PY'
import fnmatch, json, os, re, sys, tempfile
from datetime import date

work_home, dry_s, spoke_filter, manifest_path = sys.argv[1:5]
deexempt_bundle = sys.argv[5] if len(sys.argv) > 5 else ""
overlay_direct = sys.argv[6] if len(sys.argv) > 6 else ""
dry_run = (dry_s == "true")
spoke_filter = spoke_filter or None
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

# Shape-qualified sub list + plain OTHER folders per spoke, built bash-side via
# work-spoke-layout.sh (the single shape-detection SoT). READ here — the child descent
# walks only these true sub-projects, never re-deriving the classification with an
# inlined name test; OTHERS are the de-exemption candidates (People/, Meetings/, ...).
SUBS = {}
OTHERS = {}
try:
    with open(manifest_path, encoding="utf-8") as _mf:
        _cur = None
        _cur_other = None
        for _line in _mf:
            _line = _line.rstrip("\n")
            if not _line:
                continue
            if "\t" in _line:
                _tag, _val = _line.split("\t", 1)
            else:
                _tag, _val = _line, ""
            if _tag == "SPOKE":
                _cur = []
                _cur_other = []
                SUBS[_val] = _cur
                OTHERS[_val] = _cur_other
            elif _cur is None:
                continue
            elif _tag == "SUB":
                _cur.append(_val)
            elif _tag == "OTHER" and _cur_other is not None:
                _cur_other.append(_val)
except Exception:
    SUBS = {}
    OTHERS = {}

# --- de-exemption globs: the overlay path_routing.rules[] patterns. Bundle-
# first (the overlay-merged union honors an adopter's amendments), then the direct
# overlay fallback (dev-repo/test). The SHIPPED overlay is empty -> [] -> zero new
# targets by default (no engagement vocab; _g4_park empty-skeleton invariant preserved).
def _rules_from(obj):
    globs = []
    rules = (((obj.get("frontmatter") or {}).get("path_routing") or {}).get("rules") or [])
    if isinstance(rules, list):
        for r in rules:
            if isinstance(r, dict):
                pat = r.get("pattern")
                if isinstance(pat, str) and pat:
                    globs.append(pat)
    return globs

registered_globs = []
if deexempt_bundle and os.path.isfile(deexempt_bundle):
    try:
        with open(deexempt_bundle, encoding="utf-8") as _bf:
            registered_globs = _rules_from(json.load(_bf))
    except Exception:
        registered_globs = []
if not registered_globs and overlay_direct and os.path.isfile(overlay_direct):
    try:
        with open(overlay_direct, encoding="utf-8") as _of:
            registered_globs = _rules_from(json.load(_of))
    except Exception:
        registered_globs = []

def _deexempt_match(rel):
    # fnmatch + `/**`-matches-own-base (index-maintain _glob_match parity, :233-242);
    # the overlay folder-de-exemption patterns are brace-free `*`-globs (per the
    # frontmatter-rules.json path_routing _rule_shape_contract), so no brace expansion.
    for g in registered_globs:
        if fnmatch.fnmatch(rel, g):
            return True
        if g.endswith("/**") and fnmatch.fnmatch(rel, g[:-3]):
            return True
    return False

START = "<!-- contents-enum:start -->"
END = "<!-- contents-enum:end -->"
TABLE_HEADER = ("| Name | Lines | Type | Description |\n"
                "|------|-------|------|-------------|")


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log: the work home must resolve ------------------------------
if not work_home or not os.path.isdir(work_home):
    emit({"finding": "work-index-maintain-blocked", "file": work_home or "(unset)",
          "reason": "work-home-absent", "detected_at": today})
    print("work-index-maintain: work home absent (%s); nothing to index"
          % (work_home or "(unset)"), file=sys.stderr)
    sys.exit(0)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None


def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._index.workidx.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)


def parse_fm(text):
    # Minimal frontmatter parse — mirrors index-maintain's parse_fm. Returns the
    # field map (used only to detect a type: value when reading a child for the row).
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    fm = {}
    for line in text[3:end].splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm


def file_type(path):
    try:
        with open(path, encoding="utf-8") as fh:
            head = fh.read(2048)
    except Exception:
        return ""
    return parse_fm(head).get("type", "")


def line_count(path):
    try:
        with open(path, "rb") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0


def tag_spoke(spoke):
    # tags item-pattern: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$ (R-GOV-4) — mirror the
    # situating card's sanitization so the index tag passes the same grammar.
    t = re.sub(r"[^a-z0-9-]", "-", spoke.lower()).strip("-")
    return t or "spoke"


# reserved control/scaffold filenames the work surface owns,
# excluded from CONTENT rows — CLAUDE.md/File-Index.md are index/control files; README.md/
# updates.md are work-map-owned. A genuine deliverable would not use these reserved names,
# so the exclusion cannot mask a legitimately-placed content file (the ac fixture proves a
# real .md/.pptx deliverable is still listed alongside an excluded CLAUDE.md).
CONTROL_FILES = ("_index.md", "CLAUDE.md", "File-Index.md", "README.md", "updates.md")


def enum_rows(dirpath):
    # Deterministic projection of the directory's contents as contents-enum rows.
    # RECURSE nested subfolders + enumerate NON-.md deliverables (.pptx/.pdf/.xlsx)
    # (was: flat, .md-only). Exclude the reserved CONTROL_FILES from content rows.
    # name = dir-relative path (a nested file surfaces as subdir/name); .md strips the
    # extension for the wikilink (unchanged for root .md), non-.md keeps its extension.
    # Description left blank (curation-owned). Sorted for determinism + idempotent re-runs.
    if not os.path.isdir(dirpath):
        return None
    entries = []
    try:
        for dp, dns, fns in os.walk(dirpath):
            dns[:] = sorted(d for d in dns if not d.startswith("."))
            for f in fns:
                if f.startswith(".") or f in CONTROL_FILES:
                    continue
                full = os.path.join(dp, f)
                entries.append((os.path.relpath(full, dirpath), full))
    except Exception:
        return None
    rows = []
    for rel, full in sorted(entries):
        disp = rel[:-3] if rel.endswith(".md") else rel
        rows.append("| [[%s]] | %d | %s | |" % (disp, line_count(full), file_type(full) or "—"))
    return rows


def render_enum_region(rows):
    # The text BETWEEN the markers (the markers themselves are emitted by mint/splice).
    # A blank line after the start-sentinel + a symmetric blank before the end-sentinel
    # mint/splice place the markers adjacent to this region, so the region
    # owns the surrounding blank lines that keep the GFM table render valid in the
    # consuming viewer (Obsidian-class parsers refuse a table adjacent to an HTML block).
    body = "\n\n" + TABLE_HEADER + "\n"
    if rows:
        body += "\n".join(rows) + "\n"
    body += "\n"
    return body


def mint_index(dirpath, spoke, parent_folder, rows):
    folder = os.path.basename(dirpath)
    fm = ["---", "type: index",
          'tags: ["#project/%s"]' % tag_spoke(spoke),
          "updated: %s" % today,
          "parent_folder: %s" % parent_folder,
          "---", ""]
    body = "\n".join(fm)
    body += "# %s\n\n" % folder
    body += ("_Folder index for `%s/` (auto-maintained by `librarian work-index-maintain` "
             "— do not hand-edit the contents-enum block)._\n\n" % folder)
    body += "## Contents\n\n" + START + render_enum_region(rows) + END + "\n"
    return body


def splice_enum(text, rows):
    """Replace the text BETWEEN the contents-enum markers with the fresh enum region,
    preserving the markers and everything outside them byte-for-byte. Also bump a
    leading `updated:` frontmatter line when the body changes. Returns (new_text, ok)."""
    si = text.find(START)
    ei = text.find(END)
    if si == -1 or ei == -1 or ei < si:
        return (None, False)
    head = text[:si + len(START)]
    tail = text[ei:]
    new_text = head + render_enum_region(rows) + tail
    return (new_text, True)


# --- enumerate target spokes ------------------------------------------------
if spoke_filter:
    target_spokes = [spoke_filter]
else:
    target_spokes = []
    try:
        for name in sorted(os.listdir(work_home)):
            if name.startswith("."):
                continue
            if os.path.isdir(os.path.join(work_home, name)):
                target_spokes.append(name)
    except Exception:
        target_spokes = []

written = 0
skipped = 0


def process_dir(dirpath, spoke, parent_folder):
    """Mint or refresh the _index.md in a single deliverables/ or reference/ dir."""
    global written, skipped
    # the target subfolder must exist + be readable.
    if not os.path.isdir(dirpath):
        emit({"finding": "work-index-maintain-skipped", "file": dirpath,
              "reason": "target-subfolder-absent", "detected_at": today})
        skipped += 1
        return
    rows = enum_rows(dirpath)
    if rows is None:
        emit({"finding": "work-index-maintain-blocked", "file": dirpath,
              "reason": "target-subfolder-unreadable", "detected_at": today})
        skipped += 1
        return
    idx_path = os.path.join(dirpath, "_index.md")
    if not os.path.isfile(idx_path):
        # MINT the full C-IDX-conformant _index.md.
        new_text = mint_index(dirpath, spoke, parent_folder, rows)
        if not dry_run:
            try:
                write_atomic(dirpath, idx_path, new_text)
            except Exception as exc:
                emit({"finding": "work-index-maintain-blocked", "file": idx_path,
                      "reason": "write-failed", "error": str(exc), "detected_at": today})
                skipped += 1
                return
        written += 1
        emit({"finding": "work-index-mint", "file": idx_path,
              "detected_at": today})
        return
    # existing _index.md — refresh ONLY the contents-enum block.
    text = read_text(idx_path)
    if text is None:
        emit({"finding": "work-index-maintain-blocked", "file": idx_path,
              "reason": "index-unreadable", "detected_at": today})
        skipped += 1
        return
    if START not in text or END not in text:
        # leave-orphan: a marker-less _index.md is legacy / hand-authored — never
        # impose the shape. Skip with a finding.
        emit({"finding": "work-index-maintain-skipped", "file": idx_path,
              "reason": "no-contents-enum-markers", "detected_at": today})
        skipped += 1
        return
    new_text, ok = splice_enum(text, rows)
    if not ok:
        emit({"finding": "work-index-maintain-blocked", "file": idx_path,
              "reason": "marker-splice-failed", "detected_at": today})
        skipped += 1
        return
    if new_text == text:
        # idempotent no-op: enum already byte-identical; nothing to write.
        written += 1
        return
    if not dry_run:
        try:
            write_atomic(dirpath, idx_path, new_text)
        except Exception as exc:
            emit({"finding": "work-index-maintain-blocked", "file": idx_path,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            skipped += 1
            return
    written += 1
    emit({"finding": "work-index-refresh", "file": idx_path,
          "detected_at": today})


for spoke in target_spokes:
    spoke_dir = os.path.join(work_home, spoke)
    if not os.path.isdir(spoke_dir):
        emit({"finding": "work-index-maintain-skipped", "file": spoke_dir,
              "reason": "spoke-dir-absent", "detected_at": today})
        skipped += 1
        continue
    # Top-level deliverables/+reference/ — present on a FLAT spoke (parent_folder = spoke).
    top_deliv = os.path.join(spoke_dir, "deliverables")
    top_ref = os.path.join(spoke_dir, "reference")
    if os.path.isdir(top_deliv):
        process_dir(top_deliv, spoke, spoke)
    if os.path.isdir(top_ref):
        process_dir(top_ref, spoke, spoke)
    # Per-sub-project deliverables/+reference/ — present on a MASTER spoke. Each
    # sub-project is a DIRECT child dir of the master (no literal sub-projects/ dir);
    # index its own deliverables/+reference/ (parent_folder = sub name). Only true
    # sub-projects (owning deliverables/ or reference/) are descended — the shared
    # shape predicate (work-spoke-layout.sh) via the manifest, so a plain non-sub
    # folder (e.g. People/) is never descended and mints no _index.md.
    children = sorted(SUBS.get(spoke, []))
    for sub in children:
        sub_dir = os.path.join(spoke_dir, sub)
        sub_deliv = os.path.join(sub_dir, "deliverables")
        sub_ref = os.path.join(sub_dir, "reference")
        if os.path.isdir(sub_deliv):
            process_dir(sub_deliv, spoke, sub)
        if os.path.isdir(sub_ref):
            process_dir(sub_ref, spoke, sub)
    # mint/refresh an _index.md for a DE-EXEMPTED plain folder
    # (People/, Meetings/, ...) — a WSL_OTHER_DIRS folder whose vault-view path
    # Work/<spoke>/<folder> matches an overlay path_routing de-exemption glob. Derived from
    # the mandate SoT (NOT a hardcoded People/ list); the shipped empty overlay yields NO
    # matches (zero new targets — preserves the _g4_park invariant). An adopter's registered
    # glob de-exempts its folder. parent_folder = spoke (a top-level folder under the spoke).
    for other in sorted(OTHERS.get(spoke, [])):
        rel = "Work/%s/%s" % (spoke, other)
        if _deexempt_match(rel):
            process_dir(os.path.join(spoke_dir, other), spoke, spoke)

print("work-index-maintain: written=%d skipped=%d dry_run=%s"
      % (written, skipped, dry_run), file=sys.stderr)
PY

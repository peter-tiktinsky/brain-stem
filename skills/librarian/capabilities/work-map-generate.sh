#!/bin/bash
# work-map-generate — regenerate the GENERATED work-map directory-map block inside a
# work spoke's CLAUDE.md FROM DISK. This is the WORK surface (the work CLAUDE.md's
# "what lives where" directory map), the disjoint counterpart to the BINDER surface
# the situating card owns (project-context-situating). The two never overlap: the
# card is the cross-plan binder orientation, the work-map is the on-disk directory
# map of the spoke itself (disjoint roles — the work surface vs the binder surface).
# The work CLAUDE.md is scaffolded by skills/govern/lib/project-workspace/scaffold.sh
# with a FROZEN cross-tool block contract: a `## What lives where` directory map
# bounded by `<!-- work-map:start generated:true -->` … `<!-- work-map:end -->`,
# closing with the `_Auto-maintained by \`librarian work-map-generate\` — do not
# hand-edit this block._` line. Everything OUTSIDE those markers (the identity line,
# the README/updates pointer, the binder pointer) is OWNED by scaffold.sh — this
# generator PRESERVES it byte-for-byte and replaces ONLY the inside-markers content.
# The map is DERIVED from the top level of $WORK_HOME/<spoke>/ ONLY (not recursive).
# Layout detection mirrors scaffold.sh's two shapes:
#   MASTER  — the spoke has sub-project dirs (top-level dirs that are NOT
#             deliverables/ or reference/) and NO top-level deliverables/+reference/.
#             The body lists the actual sub-project dir names as sub-projects.
#   FLAT    — otherwise. The body lists deliverables/ (polished work) + reference/
#             (raw notes) + README.md + updates.md with their roles.
# The block body is DETERMINISTIC on the same disk state (idempotent: a re-run
# without a disk change is byte-identical).
# Survivorship / leave-orphan: this generator NEVER injects markers into a
# CLAUDE.md that does not already carry them. If the spoke's CLAUDE.md is ABSENT, or
# carries NO work-map:start/work-map:end markers (a legacy / hand-authored CLAUDE.md),
# it DEFENSIVELY SKIPS with a finding — it does not impose the new shape on an
# orphan. An absent spoke dir is the same defensive skip. Block-and-log, exit 0,
# never crash.
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT R-GOV-2/R-GOV-3):
#   Files written:
#     - $WORK_HOME/<spoke>/CLAUDE.md  (atomic temp+os.replace; the work-map MARKER
#         BLOCK ONLY — the text strictly between work-map:start and work-map:end is
#         replaced, the markers themselves and EVERYTHING outside them are preserved
#         byte-for-byte. The block already carries the generated:true sentinel via
#         the marker line. Re-run without a disk change == byte-identical.)
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: null (no JSON Schema governs the generated markdown block; the block is a
#     deterministic directory-map projection of the spoke's top-level disk state).
#   Pre-write validation:
#     - the work home must resolve to a directory (absent => block-and-log, no write,
#       exit 0 — never crash).
#     - the spoke dir must exist (absent => defensive skip + finding, no write).
#     - the spoke CLAUDE.md must exist AND already carry BOTH work-map markers (else
#       leave-orphan defensive skip + finding — NEVER inject markers, NEVER write a
#       README/updates or any other file).
#     - atomic temp-file + os.replace.
#   Failure mode: BLOCK-AND-LOG. An absent dir / absent-or-marker-less CLAUDE.md /
#     unreadable CLAUDE.md emits a finding and is SKIPPED; no partial/garbage write;
#     exit 0 always. Never write-and-hope.
#   Maintainer-provenance (R-GOV-3): the work-map block in $WORK_HOME/<spoke>/CLAUDE.md
#     is a librarian-maintained GENERATED region; this capability is its sole
#     originating writer. It writes ONLY that marker block. It NEVER writes README.md,
#     updates.md, anything under deliverables/ or reference/, the work CLAUDE.md
#     content OUTSIDE the markers, or anything under PLANS_ROOT.
# CLI:
#   work-map-generate.sh                  # regenerate every spoke's work-map block
#   work-map-generate.sh --spoke <key>    # regenerate one spoke's block only
#   work-map-generate.sh --dry-run        # findings + would-be writes, NO write
#   work-map-generate.sh --help
# Env overrides (testing):
#   WORK_HOME / BRAIN_STEM_WORK_HOME   work spokes root (test isolation; resolved the
#                                      way scaffold.sh resolves it — WORK_HOME wins,
#                                      then BRAIN_STEM_WORK_HOME, then $HOME/work)
#   PLANS_DIR / PLANS_ROOT             plan-tree root (resolved via paths.sh; the
#                                      work-map writes to $WORK_HOME, NOT PLANS_ROOT,
#                                      but paths.sh is sourced for sibling parity)
#   FINDINGS_OUTPUT                    NDJSON sink (default: stdout)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24 (data via argv, never
# piped stdin — feedback_python_heredoc_argv). Read-only spoke walk + atomic block
# write inside the work CLAUDE.md.

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
BOOTSTRAP="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --spoke)   SPOKE_FILTER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    # EXPLICIT opt-in — inject the work-map markers into a
    # marker-less (legacy/hand-authored) CLAUDE.md so it can be brought under maintenance.
    # OFF by default (the leave-orphan posture is preserved on a normal run).
    --bootstrap-markers) BOOTSTRAP="true"; shift ;;
    -h|--help) sed -n '2,76p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "work-map-generate: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- work-home resolution (the scaffold.sh order: WORK_HOME -> BRAIN_STEM_WORK_HOME
#     -> $HOME/work). Honored for test isolation. -------------------------------
WORK_HOME="${WORK_HOME:-${BRAIN_STEM_WORK_HOME:-$HOME/work}}"
case "$WORK_HOME" in */) WORK_HOME="${WORK_HOME%/}" ;; esac

# --- shape-detection helper (single SoT for sub-project classification) --------
# Source work-spoke-layout.sh so the sub-project/other-folder split reads ONE
# shared predicate; the classification crosses into the python3 heredoc below via
# a small manifest tempfile (path passed by argv — no exported python state).
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/work-spoke-layout.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/work-spoke-layout.sh"; } \
  || { [ -r "$_REPO_LIB/work-spoke-layout.sh" ] && source "$_REPO_LIB/work-spoke-layout.sh"; } \
  || { echo "work-map-generate: shape helper work-spoke-layout.sh not found" >&2; exit 3; }

CLASSIFY_MANIFEST="$(mktemp)" || { echo "work-map-generate: mktemp failed" >&2; exit 3; }
trap 'rm -f "$CLASSIFY_MANIFEST"' EXIT

# Emit one target spoke's classification (via the helper) into the manifest.
_wmg_emit_classification() {
  local sp="$1" dir="$2" nm
  classify_top_level "$dir"
  {
    printf 'SPOKE\t%s\n' "$sp"
    printf 'MASTER\t%s\n' "$WSL_IS_MASTER"
    printf 'DELIV\t%s\n' "$WSL_HAS_DELIV"
    printf 'REF\t%s\n' "$WSL_HAS_REF"
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
  _wmg_emit_classification "$SPOKE_FILTER" "$WORK_HOME/$SPOKE_FILTER"
elif [ -d "$WORK_HOME" ]; then
  for _sp_path in "$WORK_HOME"/*; do
    [ -d "$_sp_path" ] || continue
    _sp_name=$(basename "$_sp_path")
    case "$_sp_name" in .*) continue ;; esac
    _wmg_emit_classification "$_sp_name" "$_sp_path"
  done
fi

python3 - "$WORK_HOME" "$DRY_RUN" "$SPOKE_FILTER" "$CLASSIFY_MANIFEST" "$BOOTSTRAP" <<'PY'
import json, os, sys, tempfile
from datetime import date

work_home, dry_s, spoke_filter, manifest_path = sys.argv[1:5]
bootstrap = (len(sys.argv) > 5 and sys.argv[5] == "true")
dry_run = (dry_s == "true")
spoke_filter = spoke_filter or None
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

# Classification manifest (built bash-side via work-spoke-layout.sh — the single
# shape-detection SoT). One record per target spoke; the shape split (sub-project
# vs other folder) is READ here, never re-derived, so the classification can
# never drift from the other work walkers.
CLASSIFY = {}
try:
    with open(manifest_path, encoding="utf-8") as _mf:
        _cur = None
        for _line in _mf:
            _line = _line.rstrip("\n")
            if not _line:
                continue
            if "\t" in _line:
                _tag, _val = _line.split("\t", 1)
            else:
                _tag, _val = _line, ""
            if _tag == "SPOKE":
                _cur = {"is_master": False, "has_deliv": False, "has_ref": False,
                        "subprojects": [], "other_dirs": []}
                CLASSIFY[_val] = _cur
            elif _cur is None:
                continue
            elif _tag == "MASTER":
                _cur["is_master"] = (_val == "1")
            elif _tag == "DELIV":
                _cur["has_deliv"] = (_val == "1")
            elif _tag == "REF":
                _cur["has_ref"] = (_val == "1")
            elif _tag == "SUB":
                _cur["subprojects"].append(_val)
            elif _tag == "OTHER":
                _cur["other_dirs"].append(_val)
except Exception:
    CLASSIFY = {}

START = "<!-- work-map:start generated:true -->"
START_PREFIX = "<!-- work-map:start"   # tolerate an attribute drift on the open marker
END = "<!-- work-map:end -->"


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log: the work home must resolve ------------------------------
if not work_home or not os.path.isdir(work_home):
    emit({"finding": "work-map-generate-blocked", "file": work_home or "(unset)",
          "reason": "work-home-absent", "detected_at": today})
    print("work-map-generate: work home absent (%s); nothing to map"
          % (work_home or "(unset)"), file=sys.stderr)
    sys.exit(0)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None


def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix=".CLAUDE.md.workmap.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)


# --- top-level layout projection (NOT recursive) ----------------------------
# Layout MASTER/FLAT + the sub-project / other-folder split come from the shared
# work-spoke-layout.sh helper (via the classification manifest) — a top-level dir
# is a sub-project IFF it owns its own deliverables/ or reference/, and is_master
# is (>=1 shape-qualified sub) AND NOT has_deliv AND NOT has_ref. README/updates
# presence is a plain file check (not the shape idiom). Lists are sorted here so
# render order is deterministic regardless of the bash-side glob order.
def scan_spoke(spoke, spoke_dir):
    c = CLASSIFY.get(spoke, {"is_master": False, "has_deliv": False,
                             "has_ref": False, "subprojects": [], "other_dirs": []})
    has_readme = os.path.isfile(os.path.join(spoke_dir, "README.md"))
    has_updates = os.path.isfile(os.path.join(spoke_dir, "updates.md"))
    return {
        "is_master": c["is_master"],
        "has_deliv": c["has_deliv"],
        "has_ref": c["has_ref"],
        "subprojects": sorted(c["subprojects"]),
        "other_dirs": sorted(c["other_dirs"]),
        "has_readme": has_readme,
        "has_updates": has_updates,
    }


# --- render the inside-markers block body -----------------------------------
# This is the text that sits BETWEEN the markers (the markers themselves are emitted
# by the splice, preserved from the file). It reproduces scaffold.sh's frozen shape:
# the `## What lives where` heading, the role list, then the closing auto-maintained
# line. Deterministic + bounded.
def render_block_body(spoke, info):
    lines = ["## What lives where", ""]
    if info["is_master"]:
        lines.append("- Sub-projects: each owns its own `deliverables/` (polished, "
                     "audience-facing work) +")
        lines.append("  `reference/` (raw notes / source material). This master holds "
                     "none of its own.")
        for sp in info["subprojects"]:
            lines.append("  - `%s/` — sub-project." % sp)
        if info["other_dirs"]:
            lines.append("- Other top-level folders (not sub-projects): %s"
                         % ", ".join("`%s/`" % d for d in info["other_dirs"]))
    else:
        if info["has_deliv"]:
            lines.append("- `deliverables/` — polished, audience-facing work.")
        if info["has_ref"]:
            lines.append("- `reference/` — raw notes / source material.")
        # A FLAT spoke can ALSO hand-carry sub-project dirs (a subdir that owns its own
        # deliverables/ or reference/). The FLAT/else branch previously dropped info["subprojects"]
        # entirely — only the master branch rendered them (283-284) — so a FLAT spoke that grew a
        # sub-project rendered a map missing it (while work-index-maintain still minted its
        # _index.md). Render them here too, mirroring the master branch's "— sub-project." label; a
        # FLAT-context top-level bullet (no nested "Sub-projects:" parent, hence no indent).
        for sp in info["subprojects"]:
            lines.append("- `%s/` — sub-project." % sp)
        # a FLAT spoke can ALSO carry plain top-level folders
        # (e.g. People/) — render them the way the MASTER branch already does (279-281).
        # Was: the FLAT/else branch dropped info["other_dirs"] entirely.
        if info["other_dirs"]:
            lines.append("- Other top-level folders (not sub-projects): %s"
                         % ", ".join("`%s/`" % d for d in info["other_dirs"]))
    if info["has_readme"]:
        lines.append("- `README.md` — scope / outcome / definition-of-done.")
    if info["has_updates"]:
        lines.append("- `updates.md` — append-only updates log.")
    lines.append("")
    lines.append("_Auto-maintained by `librarian work-map-generate` — do not "
                 "hand-edit this block._")
    return "\n".join(lines)


def splice_block(text, body):
    """Replace the text BETWEEN the start/end markers with `body`, preserving the
    markers and everything outside them byte-for-byte. Returns (new_text, ok)."""
    si = text.find(START_PREFIX)
    ei = text.find(END)
    if si == -1 or ei == -1 or ei < si:
        return (None, False)
    # The open marker line ends at its newline; the close marker line starts at ei.
    open_line_end = text.find("\n", si)
    if open_line_end == -1:
        return (None, False)
    head = text[:open_line_end + 1]      # up to and including the open-marker newline
    tail = text[ei:]                     # from the close marker onward (preserved)
    return (head + body + "\n" + tail, True)


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

spokes_written = 0
spokes_skipped = 0

for spoke in target_spokes:
    spoke_dir = os.path.join(work_home, spoke)
    # absent spoke dir -> defensive skip + finding (never crash).
    if not os.path.isdir(spoke_dir):
        emit({"finding": "work-map-generate-skipped", "file": spoke_dir,
              "reason": "spoke-dir-absent", "detected_at": today})
        spokes_skipped += 1
        continue
    claude_md = os.path.join(spoke_dir, "CLAUDE.md")
    # leave-orphan: an ABSENT CLAUDE.md is skipped (do not mint a new shape).
    if not os.path.isfile(claude_md):
        emit({"finding": "work-map-generate-skipped", "file": claude_md,
              "reason": "claude-md-absent", "detected_at": today})
        spokes_skipped += 1
        continue
    text = read_text(claude_md)
    if text is None:
        emit({"finding": "work-map-generate-blocked", "file": claude_md,
              "reason": "claude-md-unreadable", "detected_at": today})
        spokes_skipped += 1
        continue
    # leave-orphan: a CLAUDE.md with NO work-map markers is a legacy / hand-authored
    # file — SKIP untouched (never inject markers into a file that lacks the shape).
    if START_PREFIX not in text or END not in text:
        # default is PRESERVED leave-orphan (skip + finding, never
        # inject markers on a normal run). The EXPLICIT --bootstrap-markers opt-in injects
        # an empty marker pair so a marker-less (legacy/hand-authored) CLAUDE.md is brought
        # under maintenance; the splice below fills the block body.
        if bootstrap:
            text = text.rstrip("\n") + "\n\n" + START + "\n" + END + "\n"
        else:
            emit({"finding": "work-map-generate-skipped", "file": claude_md,
                  "reason": "no-work-map-markers", "detected_at": today})
            spokes_skipped += 1
            continue

    info = scan_spoke(spoke, spoke_dir)
    body = render_block_body(spoke, info)
    new_text, ok = splice_block(text, body)
    if not ok:
        emit({"finding": "work-map-generate-blocked", "file": claude_md,
              "reason": "marker-splice-failed", "detected_at": today})
        spokes_skipped += 1
        continue

    if new_text == text:
        # idempotent no-op: block already byte-identical; nothing to write.
        spokes_written += 1
        continue

    if not dry_run:
        try:
            write_atomic(spoke_dir, claude_md, new_text)
        except Exception as exc:
            emit({"finding": "work-map-generate-blocked", "file": claude_md,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            spokes_skipped += 1
            continue
    spokes_written += 1

print("work-map-generate: spokes-written=%d spokes-skipped=%d dry_run=%s"
      % (spokes_written, spokes_skipped, dry_run), file=sys.stderr)
PY

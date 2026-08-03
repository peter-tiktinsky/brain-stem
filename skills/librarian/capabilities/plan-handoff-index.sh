#!/bin/bash
# plan-handoff-index — generate the per-spoke binder handoff surface:
# <plans-root>/_projects/<spoke>/handoff-chronicle.md (R-BIND-4 / R-BIND-7) — the
# session-handoff reconciliation chronicle across every plan launched from the
# spoke, re-derived from each plan's handoff.md on every run. Implements R-BIND-4.
# Distinct from the shipped handoff-disposition-check.sh (a close-out
# missing-disposition checker, NOT a chronicle generator).
# This is the PRIMARY (re-derive) half of the R-GOV-1a composite maintainer for
# handoff-chronicle.md:
#   primary       = librarian (THIS — full re-derive from every handoff.md block)
#   secondary-role = hook (hooks/handoff-chronicle-append.sh — incremental append)
# The two surfaces are DISJOINT by construction (full rebuild here vs.
# append-one-block-in-the-sentinel-region in the hook). This capability owns the
# whole file: frontmatter + intro + the sentinel-bounded chronicle region. The
# hook appends ONLY inside the sentinel region. A re-derive rebuilds the region
# from disk (so it absorbs whatever the hook appended since the last run), and an
# append adds the newest block at the region head without touching the rest.
# The plans home resolves robustly the way sibling capabilities resolve it —
# PLANS_ROOT/PLANS_DIR override, else paths.sh, never a hardcoded user-home
# literal. The _projects/ scaffold proper is the install unit's scope; this
# capability mkdir -p's its OWN output home on demand (generation, not install
# scaffolding).
# Grouping/scope (R-BIND-7): the chronicle is per-spoke — only plans whose
# manifest project: key matches the target spoke contribute blocks. The plan slug
# is the dir basename; the handoff source is <plan-dir>/handoff.md (handoff.md at
# any depth per repo convention — every plan dir that carries one contributes).
# Block shape (R-BIND-7, TRANSCRIBED from D3:187, verbatim contract clause:
# "Append-only, newest-first. One block per session: source handoff.md path +
# session number/date + the **Next session:** line + a one-line summary harvested
# from ### Locks captured / ### Decision-Quality Protocol passes. It NEVER
# concatenates handoff bodies. Harvest-reliability fallback: when a handoff block
# lacks those canonical subsections, harvest the first ~200 chars of the block
# body rather than emitting an empty row."):
#   - SOURCE  the handoff.md path (a relative pointer under the binder).
#   - SESSION the session number and/or date parsed from the session heading.
#   - NEXT    the `Next session...` line verbatim (the single most load-bearing
#             carry-forward line); — when the block has none.
#   - SUMMARY a ONE-LINE summary harvested ONLY from the canonical subsections
#             ### Locks captured / ### Decision-Quality Protocol passes; when both
#             are absent, the FALLBACK harvests the first ~200 chars of the block
#             body. Bodies are NEVER concatenated — exactly one harvested line.
# Ordering (R-BIND-7 "newest-first"): within a handoff.md the session blocks are
# emitted newest-first (a block parsed later in the file — a higher session number
# later date — sorts ABOVE an earlier one), and across the spoke the handoffs
# are ordered by (descending session-key, plan-slug) so the most recent session
# across all spoke plans heads the chronicle. Append-only semantics (R-BIND-7):
# the chronicle is never pruned/rewritten destructively — a re-derive rebuilds the
# full newest-first projection from the current handoff.md set (it adds blocks for
# new sessions; it does not delete the historical record from the source
# handoffs, which are themselves append-only session records).
# Re-derive from each handoff.md every run; a missing/empty/malformed handoff =
# DEFENSIVE SKIP + a finding, never an error (R-BIND-10a defensive default).
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT R-GOV-2/R-GOV-3):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/handoff-chronicle.md  (atomic temp+os.replace;
#         full-file re-derive — the librarian role owns the WHOLE file). The
#         sentinel-bounded region the SECONDARY-ROLE hook-append writer touches is
#         EXACTLY:
#             <!-- handoff-chronicle:start --> … <!-- handoff-chronicle:end -->
#         (the per-block newest-first chronicle body). The hook appends one block
#         at the region HEAD inside those markers and touches nothing else; this
#         librarian capability rebuilds the entire region (plus the frontmatter
#         and the intro prose outside the markers) on a full re-derive.
#         PERMITTED CONCURRENT WRITERS to the sentinel region:
#         hooks/handoff-chronicle-append.sh AND its session-close adaptor
#         capabilities/binder-handoff-append-wrapper.sh are the sanctioned
#         append-one-block writers to this same '<!-- handoff-chronicle:start --> …
#         :end -->' region. They append; THIS full re-derive ABSORBS an appended
#         block IDEMPOTENTLY — the re-derive rebuilds the whole region from the
#         source handoff.md set and renders the same block byte-for-byte, so a
#         block the adaptor appended (then re-derived here) produces NO
#         duplication. Session-close fires the append BEFORE this re-derive.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: null (no JSON Schema governs the generated binder chronicle markdown;
#     handoff-chronicle.md is a generated human-readable projection — the block
#     shape is fixed by R-BIND-7, not a shipped schema). Body-structure authority:
#     the R-BIND-7 handoff-chronicle artifact contract (the ratified
#     binder-contract decision).
#   Pre-write validation:
#     - the plans home must resolve to a directory (absent => block-and-log, no
#       write, exit 0 — R-BIND-10a defensive class, never crash).
#     - each handoff.md is read defensively; a missing/unreadable/empty handoff
#       is SKIPPED with a finding, never an error; a plan with no parseable
#       session blocks contributes none (and an empty spoke renders a valid empty
#       chronicle).
#     - atomic temp-file + os.replace; the sentinel markers are emitted on every
#       re-derive so the hook always has a region to append into.
#   Failure mode: BLOCK-AND-LOG. A handoff that cannot be read/parsed emits a
#     finding and is skipped; no partial/garbage write. Never write-and-hope.
#   Maintainer-provenance (R-GOV-3, R-GOV-1a): handoff-chronicle.md is a COMPOSITE
#     artifact (R-BIND-4); this capability writes ONLY its declared ROLE surface —
#     the librarian RE-DERIVE role (full rebuild of the whole file incl. the
#     sentinel region). It NEVER performs the hook's role (a routine
#     append-one-block-at-the-head). It NEVER writes research-index.md,
#     decision-log.md, the research/ symlink farm, plan manifests, or any plan
#     handoff.md / _research/ content. It reads handoff.md and writes ONLY
#     handoff-chronicle.md.
# CLI:
#   plan-handoff-index.sh                 # regenerate every spoke's chronicle
#   plan-handoff-index.sh --spoke <key>   # regenerate one spoke's chronicle only
#   plan-handoff-index.sh --dry-run       # findings + would-be writes, NO write
#   plan-handoff-index.sh --help
# Env overrides (testing):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh)
#   FINDINGS_OUTPUT         NDJSON sink (default: stdout)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24. Read-only handoff.md
# walk + atomic file write(s).

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
    *) echo "plan-handoff-index: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- plans home resolution (robust; the sibling pattern) ---------------------
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

python3 - "$PLANS_ROOT" "$DRY_RUN" "$SPOKE_FILTER" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root, dry_s, spoke_filter = sys.argv[1:4]
dry_run = (dry_s == "true")
spoke_filter = spoke_filter or None
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

# The sentinel-bounded region the SECONDARY-ROLE hook-append writer touches
# (R-GOV-2 field-1; the EXACT region named in the C-OUT). MUST match the hook's
# markers byte-for-byte (hooks/handoff-chronicle-append.sh).
SENT_START = "<!-- handoff-chronicle:start -->"
SENT_END = "<!-- handoff-chronicle:end -->"


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log: the plans home must resolve -----------------------------
if not plans_root or not os.path.isdir(plans_root):
    emit({"finding": "plan-handoff-index-blocked", "file": plans_root or "(unset)",
          "reason": "plans-home-absent", "detected_at": today})
    print("plan-handoff-index: plans home absent (%s); nothing to index"
          % (plans_root or "(unset)"), file=sys.stderr)
    sys.exit(0)

PROJECTS = os.path.join(plans_root, "_projects")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None


# --- walk every manifest under the plans tree -------------------------------
# Each manifest carries project: (the owning-spoke machine identity),
# parent_plan: (lineage), title: (display). The plan slug is the dir basename.
# A plan's handoff source is <plan-dir>/handoff.md.
def walk_manifests(root):
    found = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not d.startswith(".")]
        # do not descend into the binder home itself
        if os.path.abspath(dp) == os.path.abspath(PROJECTS):
            dns[:] = []
            continue
        if "manifest.json" not in fns:
            continue
        mp = os.path.join(dp, "manifest.json")
        man = read_json(mp)
        if man is None:
            # defensive skip + finding (R-BIND-10a) — never crash on a bad manifest.
            emit({"finding": "plan-handoff-index-blocked", "file": mp,
                  "reason": "manifest-parse-failed", "detected_at": today})
            continue
        # /(): keep only real plans. A real plan has a `status` field
        # OR a sibling spec.md; a corpus/synthetic fixture has neither. The single
        # accept clause subsumes the corpus_version/slots reject (those fixtures also
        # lack status+spec.md); if a future corpus_version dir ever declares status,
        # revisit — this clause alone would admit it.
        if not (("status" in man) or os.path.exists(os.path.join(dp, "spec.md"))):
            continue
        found.append((dp, man))
    return found


manifests = walk_manifests(plans_root)


def slug_of(plan_dir):
    return os.path.basename(plan_dir.rstrip("/"))


def field(man, key, default=""):
    v = man.get(key)
    if v is None:
        return default
    return v


# --- session-block parsing (R-BIND-7) ---------------------------------------
# A handoff.md is an append-only session record. Session blocks are delimited by
# a session heading: an H2..H4 line whose TEXT BEGINS with a real session-entry
# shape — "(Alignment )Session <N|SN|:...>", a bare "S<N>" ordinal, or a
# date-prefixed "YYYY-MM-DD ..." heading. Everything before the first session
# heading is a preamble (plan title / cold-start context) and is NOT a block.
# The shape is ANCHORED to the heading-text start (not "any line mentioning
# session + a digit") so a narrative subsection like "### Forward roadmap
# (Session <N>+)" or "## Critical info for Session <N>" is NOT a false boundary
#. The Session-followed-by-a-date form ("## Session 2026-06-24 — ...") is a
# valid boundary but its date is parsed as the date sort-key, NOT the ordinal (
# see SESSION_NUM_RE); S-prefixed ordinals ("", "Session") and the colon
# form ("Session: ...") parse too.
SESSION_HEADING_RE = re.compile(
    r"^(#{2,4})\s+"
    r"((?:alignment\s+)?session\s*(?::|s?[0-9])"
    r"|s[0-9]+\b"
    r"|[0-9]{4}-[0-9]{2}-[0-9]{2}\b)"
    r".*$",
    re.IGNORECASE,
)
# the `Next session...` carry-forward line, in any of its shipped forms
# (**Next session:** / **Next session does:** / **Next session start conditions:**
# **Next session entry point:** ...). The verbatim line is harvested.
NEXT_RE = re.compile(r"^\s*\**\s*next session\b", re.IGNORECASE)
# the canonical harvest subsections (R-BIND-7): ### Locks captured /
# ### Decision-Quality Protocol passes.
LOCKS_RE = re.compile(r"^#{2,4}\s+locks captured\b", re.IGNORECASE)
DQP_RE = re.compile(r"^#{2,4}\s+decision[- ]quality protocol passes\b", re.IGNORECASE)
# a session ordinal extractor for the newest-first sort key. Captures the ordinal
# after "session" (optionally colon- or S-prefixed) OR a bare leading "S<N>"; the
# trailing (?![0-9])(?!-DD-DD) guard rejects a YYYY-MM-DD date so a
# "Session 2026-06-24" heading yields NO spurious 2026 ordinal — the date is
# picked up by DATE_RE instead. ""/"Session"→69/74; "Session <N>a"→<N>.
SESSION_NUM_RE = re.compile(r"(?:\bsession\s*:?\s*|^)S?([0-9]+)(?![0-9])(?!-[0-9]{2}-[0-9]{2})", re.IGNORECASE)
DATE_RE = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})")

# The harvested next-session line carries its OWN "**Next session…:**" label verbatim,
# and the renderer then prepends its own "- **Next session:** " label — doubling it. Strip the
# harvested leading label (all shipped forms: "**Next session:**" / "**Next session does:**" /
# "**Next session start conditions:**" / "**Next session entry point:**") BEFORE the prepend, so
# the block carries the label exactly once. Requires the label colon, so a colon-less body line
# is never over-stripped. DEFINED IDENTICALLY in hooks/handoff-chronicle-append.sh +
# skills/librarian/capabilities/plan-handoff-index.sh so append<->re-derive stay byte-identical.
_NEXT_LABEL_RE = re.compile(r"^\**\s*next session\b[^:]*:\s*\**\s*", re.IGNORECASE)


def strip_next_label(s):
    return _NEXT_LABEL_RE.sub("", s or "").strip()


def first_nonblank_chars(lines, limit=200):
    """FALLBACK (R-BIND-7): harvest the first ~limit chars of the block body
    (the lines after the session heading), as ONE collapsed line, when neither
    canonical subsection is present. Never empty if the block has any body."""
    body = " ".join(l.strip() for l in lines if l.strip())
    body = re.sub(r"\s+", " ", body).strip()
    if not body:
        return ""
    if len(body) > limit:
        # cut at limit on a word boundary where possible, then add an ellipsis.
        cut = body[:limit]
        sp = cut.rfind(" ")
        if sp > limit - 40:   # only trim to a word boundary if it is close
            cut = cut[:sp]
        return cut.rstrip() + "…"
    return body


def harvest_subsection_line(lines, hdr_re):
    """Return a ONE-LINE summary from the named canonical subsection: the first
    non-blank content line under the matching ### header (NEVER the whole body —
    R-BIND-7 'never concatenates'). Returns '' when the subsection is absent."""
    n = len(lines)
    for i, l in enumerate(lines):
        if hdr_re.match(l):
            for j in range(i + 1, n):
                t = lines[j].strip()
                if t.startswith("#"):
                    break   # ran into the next heading; subsection had no body
                # strip a leading list bullet / quote marker for the one-liner
                t2 = re.sub(r"^[-*>]\s+", "", t).strip()
                if t2:
                    return re.sub(r"\s+", " ", t2)[:280]
            return ""
    return ""


def parse_blocks(text, src_rel):
    """Parse a handoff.md into session blocks. Returns a list of block dicts in
    DOCUMENT order (the caller reverses for newest-first). Each block carries:
      session (heading text), session_key (sortable), next_line, summary, idx."""
    lines = text.splitlines()
    # locate session-heading boundaries
    bounds = [i for i, l in enumerate(lines) if SESSION_HEADING_RE.match(l)]
    blocks = []
    if not bounds:
        # DT-2 chronicle-membership fallback (/HCM). A handoff with NO recognized
        # session heading (e.g. a STATUS-REPORT-6-shaped record) still JOINS the
        # chronicle as EXACTLY ONE synthesized block — never dropped, never phantom-
        # split. The summary/date are harvested from the BODY (after any leading YAML
        # frontmatter) so a frontmatter-only handoff does not yield a `--- title: ...
        # ---` metadata summary; the per-block path slices body_lines past the heading
        # and so never sees frontmatter either. Ordering falls to any date in the body
        # (else the -1 ordinal floor + document position). Renders BYTE-IDENTICALLY to
        # the hooks/handoff-chronicle-append.sh fallback so append/re-derive stay idempotent.
        fb_body = lines
        if fb_body and fb_body[0].strip() == "---":
            for _i in range(1, len(fb_body)):
                if fb_body[_i].strip() == "---":
                    fb_body = fb_body[_i + 1:]
                    break
        fb_next = ""
        for l in fb_body:
            if NEXT_RE.match(l):
                fb_next = re.sub(r"\s+", " ", l.strip())
                break
        fb_summary = harvest_subsection_line(fb_body, LOCKS_RE)
        fb_src = "locks-captured"
        if not fb_summary:
            fb_summary = harvest_subsection_line(fb_body, DQP_RE)
            fb_src = "decision-quality-protocol-passes"
        if not fb_summary:
            fb_summary = first_nonblank_chars(fb_body, 200)
            fb_src = "fallback-no-session-heading"
        fb_date = DATE_RE.search("\n".join(fb_body))
        blocks.append({
            "session": "(no recognized session heading)",
            "session_key": (-1, fb_date.group(1) if fb_date else "", 0),
            "next_line": fb_next, "summary": fb_summary, "summary_src": fb_src,
            "src_rel": src_rel,
        })
        return blocks
    for k, start in enumerate(bounds):
        end = bounds[k + 1] if k + 1 < len(bounds) else len(lines)
        heading = lines[start].lstrip("# ").strip()
        body_lines = lines[start + 1:end]
        # NEXT line (verbatim) — first matching line in the block (incl. heading).
        next_line = ""
        for l in lines[start:end]:
            if NEXT_RE.match(l):
                next_line = re.sub(r"\s+", " ", l.strip())
                break
        # SUMMARY: canonical subsections first (Locks captured, then DQP passes);
        # FALLBACK to the first ~200 chars of the block body.
        summary = harvest_subsection_line(body_lines, LOCKS_RE)
        src = "locks-captured"
        if not summary:
            summary = harvest_subsection_line(body_lines, DQP_RE)
            src = "decision-quality-protocol-passes"
        if not summary:
            summary = first_nonblank_chars(body_lines, 200)
            src = "fallback-first-200-chars"
        # session sort key: prefer an explicit session ordinal, else the date,
        # else document position. Higher key == newer (sorts first).
        snum = SESSION_NUM_RE.search(heading)
        sdate = DATE_RE.search(heading)
        skey = (int(snum.group(1)) if snum else -1,
                sdate.group(1) if sdate else "",
                k)   # document position is the final tiebreak (newer == later)
        blocks.append({
            "session": heading, "session_key": skey, "next_line": next_line,
            "summary": summary, "summary_src": src, "src_rel": src_rel,
        })
    return blocks


# --- assemble blocks per spoke ----------------------------------------------
# spoke -> [block dicts] (each block already carries its source plan + heading).
spokes = {}

for plan_dir, man in manifests:
    spoke = str(field(man, "project") or "").strip()
    if not spoke:
        # missing project: => cannot attribute to a spoke; skip silently
        # (R-BIND-10a missing-field-empty; this is not an error).
        continue
    if spoke_filter and spoke != spoke_filter:
        continue
    slug = slug_of(plan_dir)
    handoff_path = os.path.join(plan_dir, "handoff.md")
    if not os.path.isfile(handoff_path):
        # no handoff for this plan — contributes nothing; not an error.
        continue
    text = read_text(handoff_path)
    if text is None:
        emit({"finding": "plan-handoff-index-handoff-unreadable",
              "file": handoff_path, "plan": slug, "spoke": spoke,
              "reason": "read-failed", "detected_at": today})
        continue
    if not text.strip():
        emit({"finding": "plan-handoff-index-handoff-empty",
              "file": handoff_path, "plan": slug, "spoke": spoke,
              "reason": "empty-handoff", "detected_at": today})
        continue
    # relative pointer to the source handoff (under the plans root).
    src_rel = os.path.relpath(handoff_path, plans_root)
    try:
        blocks = parse_blocks(text, src_rel)
    except Exception as exc:
        emit({"finding": "plan-handoff-index-handoff-malformed",
              "file": handoff_path, "plan": slug, "spoke": spoke,
              "reason": "parse-failed", "error": str(exc), "detected_at": today})
        continue
    if not blocks:
        # a handoff with no parseable session boundary — skip + finding (it
        # contributes no block; never an empty row, never a crash).
        emit({"finding": "plan-handoff-index-no-session-blocks",
              "file": handoff_path, "plan": slug, "spoke": spoke,
              "reason": "no-session-heading-found", "detected_at": today})
        continue
    for b in blocks:
        b["plan_slug"] = slug
    spokes.setdefault(spoke, []).extend(blocks)


# --- render one chronicle per spoke -----------------------------------------
def md_link(text, target):
    # deterministic relative-path link (R-GOV-7 binder roll-up class).
    return "[%s](%s)" % (text, target)


def esc(cell):
    return (cell or "").replace("|", "\\|")


def write_atomic(dirpath, target, body):
    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._handoff-chronicle.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, target)


spokes_written = 0
blocks_total = 0

# When a --spoke filter names a spoke with no contributing plans, still render an
# empty chronicle for it (idempotent empty surface).
target_spokes = sorted(spokes.keys())
if spoke_filter and spoke_filter not in spokes:
    target_spokes = [spoke_filter] if not target_spokes else sorted(set(target_spokes) | {spoke_filter})

for spoke in target_spokes:
    blocks = spokes.get(spoke, [])
    binder_home = os.path.join(PROJECTS, spoke)
    chronicle = os.path.join(binder_home, "handoff-chronicle.md")

    # newest-first (R-BIND-7): sort by descending session_key, then plan-slug.
    ordered = sorted(blocks, key=lambda b: (b["session_key"], b["plan_slug"]), reverse=True)

    # tags item-pattern: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$  (R-GOV-4)
    tag_spoke = re.sub(r"[^a-z0-9-]", "-", spoke.lower()).strip("-") or "spoke"

    head_lines = [
        "---",
        "type: index",
        'tags: ["#projects/%s"]' % tag_spoke,
        "updated: %s" % today,
        "parent_folder: _projects",
        "---",
        "",
        "# %s — Handoff Chronicle" % spoke,
        "",
        "_Auto-generated by `librarian plan-handoff-index` (full re-derive) and "
        "`hooks/handoff-chronicle-append.sh` (incremental append). Do not hand-edit._",
        "",
        "Append-only, newest-first session-handoff reconciliation (R-BIND-7): one "
        "block per session across every `%s`-spoke plan's `handoff.md` — source "
        "path + session number/date + the `Next session:` line + a one-line summary "
        "harvested from `### Locks captured` / `### Decision-Quality Protocol "
        "passes` (or the first ~200 chars of the block body when those subsections "
        "are absent). Handoff bodies are never concatenated." % spoke,
        "",
        "The chronicle blocks below live inside the sentinel region; the append "
        "hook adds the newest block at the region head, the librarian re-derive "
        "rebuilds the whole region from disk.",
        "",
        SENT_START,
        "",
    ]

    body_lines = []
    for b in ordered:
        blocks_total += 1
        plan = b["plan_slug"]
        src_rel = b["src_rel"]
        # SOURCE: a relative pointer to the handoff.md (../../<plan>/handoff.md
        # under the binder home _projects/<spoke>/). Use the plans-root-relative
        # path prefixed to climb out of _projects/<spoke>/.
        src_link = md_link(src_rel, "../../%s" % src_rel)
        next_line = strip_next_label(b["next_line"]) or "—"
        summary = b["summary"] or "—"
        body_lines.append("### %s — %s" % (esc(plan), esc(b["session"])))
        body_lines.append("")
        body_lines.append("- **Source:** %s" % src_link)
        body_lines.append("- **Next session:** %s" % esc(next_line))
        body_lines.append("- **Summary** (%s): %s" % (b["summary_src"], esc(summary)))
        body_lines.append("")

    if not body_lines:
        body_lines = ["_No session handoffs in this spoke yet._", ""]

    tail_lines = [SENT_END, ""]

    content = "\n".join(head_lines + body_lines + tail_lines).rstrip() + "\n"

    if not dry_run:
        try:
            os.makedirs(binder_home, exist_ok=True)
        except Exception as exc:
            emit({"finding": "plan-handoff-index-blocked", "file": binder_home,
                  "reason": "mkdir-failed", "error": str(exc), "detected_at": today})
            continue
        try:
            write_atomic(binder_home, chronicle, content)
        except Exception as exc:
            emit({"finding": "plan-handoff-index-blocked", "file": chronicle,
                  "reason": "write-failed", "error": str(exc), "detected_at": today})
            continue
    spokes_written += 1

print("plan-handoff-index: spokes=%d source-manifests=%d blocks=%d dry_run=%s"
      % (spokes_written, len(manifests), blocks_total, dry_run), file=sys.stderr)
PY

#!/bin/bash
# handoff-chronicle-append — the SECONDARY-ROLE (incremental append) half of the
# R-GOV-1a composite maintainer for the per-spoke binder handoff chronicle
# _projects/<spoke>/handoff-chronicle.md (R-BIND-4 / R-BIND-7). It appends ONE
# block for the NEWEST session of a just-written handoff.md, newest-first, at the
# HEAD of the sentinel-bounded chronicle region — and touches nothing else.
# Composite split (R-GOV-1a):
#   primary       = librarian (skills/librarian/capabilities/plan-handoff-index.sh —
#                   FULL re-derive of the whole file from every handoff.md block)
#   secondary-role = hook (THIS — incremental append of the newest block only)
# The two surfaces are DISJOINT by construction: the re-derive rebuilds the entire
# file (frontmatter + intro + the whole sentinel region); the append inserts one
# block at the region head INSIDE the markers and never rewrites prior blocks,
# never touches the frontmatter/intro, never rotates or re-derives. A routine
# append never rebuilds; a re-derive never appends-one-block.
# THE SENTINEL REGION (R-GOV-2 field-1 — the EXACT region this writer touches):
#     <!-- handoff-chronicle:start --> … <!-- handoff-chronicle:end -->
# The append inserts the new block immediately AFTER the start marker (so the
# newest session is first) and leaves the start/end markers, the frontmatter, and
# the intro prose untouched. The markers MUST match the librarian capability's
# byte-for-byte.
# THE TRIGGER SEAM (recorded build pick). D3 (R-BIND-7) and D4 specify the block
# CONTENT and the append/re-derive role split, but neither D3 nor D4 names a
# Claude Code hook EVENT that appends to handoff-chronicle.md — the five D4 flows
# (F-CAP/PRE/PROMO/RECON/MAINT) own library promotion, not session-handoff
# capture, so the trigger SURFACE is open per the SoT. Following the
# library-log-append.sh precedent (a SCRIPT-form hook the flow seam
# invokes, NOT a settings.json event hook), this appender is invoked at the
# session-handoff capture seam — session-close, the moment a session's handoff.md
# is finalized (the same seam handoff-disposition-check runs at). It takes the
# just-written handoff.md path + its owning spoke as arguments; no settings.json
# UserPromptSubmit/PostToolUse registration is required (the seam is a librarian/
# close-out invocation, exactly like library-log-append). The full re-derive is
# the backstop for any session the seam misses (idempotent; absorbs the block).
# Output Contract (per CLAUDE.md skill-creation rule; C-OUT R-GOV-2/R-GOV-3):
#   Files written:
#     - {PLANS_ROOT}/_projects/<spoke>/handoff-chronicle.md — append ONE block at
#       the HEAD of the sentinel region
#           <!-- handoff-chronicle:start --> … <!-- handoff-chronicle:end -->
#       (the EXACT bounded region; atomic temp+os.replace). When the chronicle
#       file does not yet exist, the appender bootstraps the frontmatter + intro +
#       an empty sentinel region first, then inserts the block — so the hook is
#       safe to fire before the first librarian re-derive.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT) on block-and-log.
#   Schema: null (no JSON Schema governs the generated chronicle markdown; the
#     block shape is fixed by R-BIND-7). Body-structure authority: the R-BIND-7
#     handoff-chronicle artifact contract.
#   Pre-write validation:
#     - the handoff.md arg must be a readable non-empty file (else block-and-log,
#       no write).
#     - the spoke arg must be non-empty (else block-and-log, no write).
#     - the newest session block must parse (a handoff with no session heading =>
#       block-and-log finding, no write — never an empty block).
#     - atomic temp-file + os.replace; the insert lands ONLY inside the sentinels.
#   Failure mode: BLOCK-AND-LOG. A malformed/empty handoff emits a finding and
#     writes nothing. Never write-and-hope.
#   Maintainer-provenance (R-GOV-3, R-GOV-1a): this hook writes ONLY the
#     append-one-block role surface of the composite, ONLY inside the sentinel
#     region. It NEVER re-derives the whole file, never rewrites prior blocks,
#     never touches the frontmatter/intro outside the markers, and never rotates
#     (the librarian plan-handoff-index re-derive owns that role).
#   Session-close adaptor + full-re-derive idempotency: this hook
#     takes POSITIONAL args, so it is driven into the session-close capability chain
#     by the thin adaptor capabilities/binder-handoff-append-wrapper.sh, which
#     accepts --spoke, resolves the active spoke's just-finalized handoff.md, and
#     invokes this hook. Session-close fires the adaptor (this append) BEFORE the
#     librarian plan-handoff-index full re-derive (the append-before-re-derive ordering). The
#     re-derive ABSORBS the appended block IDEMPOTENTLY — it rebuilds the whole
#     sentinel region from the source handoff.md set and renders the same block
#     byte-for-byte (this hook mirrors the re-derive's block render exactly), so an
#     appended-then-re-derived block produces NO duplication. THIS hook + the
#     re-derive are the PERMITTED CONCURRENT WRITERS to the sentinel region.
# CLI (the close-out / session-handoff seam invokes the append form):
#   handoff-chronicle-append.sh <handoff.md path> <spoke> [<plan-slug>]
#   handoff-chronicle-append.sh --help
# Env overrides (testing / wiring):
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh).
#   FINDINGS_OUTPUT         NDJSON sink for block-and-log findings (default: stdout).
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

case "${1:-}" in
  -h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

HANDOFF_ARG="${1:-}"
SPOKE_ARG="${2:-}"
PLAN_SLUG_ARG="${3:-}"

# --- plans home resolution (the sibling capability pattern; never hardcoded) ---
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

python3 - "$PLANS_ROOT" "$HANDOFF_ARG" "$SPOKE_ARG" "$PLAN_SLUG_ARG" <<'PY'
import json, os, re, sys, tempfile
from datetime import date

plans_root, handoff_arg, spoke, plan_slug = sys.argv[1:5]
out = os.environ.get("FINDINGS_OUTPUT", "")
today = date.today().isoformat()

# The sentinel markers — MUST match plan-handoff-index.sh byte-for-byte.
SENT_START = "<!-- handoff-chronicle:start -->"
SENT_END = "<!-- handoff-chronicle:end -->"


def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# --- block-and-log pre-write validation -------------------------------------
if not spoke.strip():
    emit({"finding": "handoff-chronicle-append-blocked", "file": handoff_arg or "(unset)",
          "reason": "empty-spoke", "detected_at": today})
    print("handoff-chronicle-append: empty <spoke>; no write", file=sys.stderr)
    sys.exit(2)

if not handoff_arg.strip() or not os.path.isfile(handoff_arg):
    emit({"finding": "handoff-chronicle-append-blocked", "file": handoff_arg or "(unset)",
          "reason": "handoff-missing", "spoke": spoke, "detected_at": today})
    print("handoff-chronicle-append: handoff.md missing (%s); no write"
          % (handoff_arg or "(unset)"), file=sys.stderr)
    sys.exit(2)

try:
    with open(handoff_arg, encoding="utf-8") as fh:
        text = fh.read()
except Exception as exc:
    emit({"finding": "handoff-chronicle-append-blocked", "file": handoff_arg,
          "reason": "read-failed", "error": str(exc), "spoke": spoke,
          "detected_at": today})
    print("handoff-chronicle-append: handoff unreadable; no write", file=sys.stderr)
    sys.exit(2)

if not text.strip():
    emit({"finding": "handoff-chronicle-append-blocked", "file": handoff_arg,
          "reason": "empty-handoff", "spoke": spoke, "detected_at": today})
    print("handoff-chronicle-append: empty handoff; no write", file=sys.stderr)
    sys.exit(2)

if not plan_slug.strip():
    # derive the plan slug from the handoff's parent dir basename.
    plan_slug = os.path.basename(os.path.dirname(os.path.abspath(handoff_arg)))


# --- session-block parsing (R-BIND-7) — newest block ONLY -------------------
# Mirrors plan-handoff-index.sh's parser exactly so the append and the re-derive
# render IDENTICAL block text (idempotent absorption). The appender extracts only
# the NEWEST session block (the highest session ordinal / latest date / last in
# document order) and renders it once.
# SESSION_HEADING_RE / SESSION_NUM_RE are byte-identical to the librarian
# re-derive (skills/librarian/capabilities/plan-handoff-index.sh) — the recognizer
# region is parity-gated. Heading shape is ANCHORED to the heading-text start
# (narrative "...(Session N)" is not a false boundary); the ordinal parser
# rejects a YYYY-MM-DD date and parses S-prefixed / colon forms.
SESSION_HEADING_RE = re.compile(
    r"^(#{2,4})\s+"
    r"((?:alignment\s+)?session\s*(?::|s?[0-9])"
    r"|s[0-9]+\b"
    r"|[0-9]{4}-[0-9]{2}-[0-9]{2}\b)"
    r".*$",
    re.IGNORECASE,
)
NEXT_RE = re.compile(r"^\s*\**\s*next session\b", re.IGNORECASE)
LOCKS_RE = re.compile(r"^#{2,4}\s+locks captured\b", re.IGNORECASE)
DQP_RE = re.compile(r"^#{2,4}\s+decision[- ]quality protocol passes\b", re.IGNORECASE)
SESSION_NUM_RE = re.compile(r"(?:\bsession\s*:?\s*|^)S?([0-9]+)(?![0-9])(?!-[0-9]{2}-[0-9]{2})", re.IGNORECASE)
DATE_RE = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})")


def first_nonblank_chars(lines, limit=200):
    body = " ".join(l.strip() for l in lines if l.strip())
    body = re.sub(r"\s+", " ", body).strip()
    if not body:
        return ""
    if len(body) > limit:
        cut = body[:limit]
        sp = cut.rfind(" ")
        if sp > limit - 40:
            cut = cut[:sp]
        return cut.rstrip() + "…"
    return body


def harvest_subsection_line(lines, hdr_re):
    n = len(lines)
    for i, l in enumerate(lines):
        if hdr_re.match(l):
            for j in range(i + 1, n):
                t = lines[j].strip()
                if t.startswith("#"):
                    break
                t2 = re.sub(r"^[-*>]\s+", "", t).strip()
                if t2:
                    return re.sub(r"\s+", " ", t2)[:280]
            return ""
    return ""


lines = text.splitlines()
bounds = [i for i, l in enumerate(lines) if SESSION_HEADING_RE.match(l)]
if not bounds:
    # DT-2 chronicle-membership fallback (/HCM). A handoff with NO recognized
    # session heading still JOINS the chronicle as EXACTLY ONE synthesized block —
    # never blocked/dropped, never phantom-split. The summary/date are harvested from
    # the BODY (after any leading YAML frontmatter) so a frontmatter-only handoff does
    # not yield a `--- title: ... ---` metadata summary. Renders BYTE-IDENTICALLY to
    # the plan-handoff-index.sh re-derive fallback so append/re-derive stay idempotent.
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
    parsed = [{"session": "(no recognized session heading)",
               "session_key": (-1, fb_date.group(1) if fb_date else "", 0),
               "next_line": fb_next, "summary": fb_summary, "summary_src": fb_src}]
else:
    # parse every block, pick the newest by the same sort key as the re-derive.
    parsed = []
    for k, start in enumerate(bounds):
        end = bounds[k + 1] if k + 1 < len(bounds) else len(lines)
        heading = lines[start].lstrip("# ").strip()
        body_lines = lines[start + 1:end]
        next_line = ""
        for l in lines[start:end]:
            if NEXT_RE.match(l):
                next_line = re.sub(r"\s+", " ", l.strip())
                break
        summary = harvest_subsection_line(body_lines, LOCKS_RE)
        src = "locks-captured"
        if not summary:
            summary = harvest_subsection_line(body_lines, DQP_RE)
            src = "decision-quality-protocol-passes"
        if not summary:
            summary = first_nonblank_chars(body_lines, 200)
            src = "fallback-first-200-chars"
        snum = SESSION_NUM_RE.search(heading)
        sdate = DATE_RE.search(heading)
        skey = (int(snum.group(1)) if snum else -1,
                sdate.group(1) if sdate else "", k)
        parsed.append({"session": heading, "session_key": skey,
                       "next_line": next_line, "summary": summary, "summary_src": src})

newest = max(parsed, key=lambda b: b["session_key"])

src_rel = os.path.relpath(os.path.abspath(handoff_arg), plans_root)


def esc(cell):
    return (cell or "").replace("|", "\\|")


# render the single block IDENTICALLY to the re-derive's render_row.
next_line = newest["next_line"] or "—"
summary = newest["summary"] or "—"
block = "\n".join([
    "### %s — %s" % (esc(plan_slug), esc(newest["session"])),
    "",
    "- **Source:** [%s](../../%s)" % (src_rel, src_rel),
    "- **Next session:** %s" % esc(next_line),
    "- **Summary** (%s): %s" % (newest["summary_src"], esc(summary)),
    "",
])


# --- target chronicle file + sentinel region --------------------------------
binder_home = os.path.join(plans_root, "_projects", spoke)
chronicle = os.path.join(binder_home, "handoff-chronicle.md")

tag_spoke = re.sub(r"[^a-z0-9-]", "-", spoke.lower()).strip("-") or "spoke"


def bootstrap_file():
    """Bootstrap the frontmatter + intro + an empty sentinel region so the hook
    is safe to fire before the first librarian re-derive. The re-derive owns the
    canonical bootstrap; this mirrors it closely enough that the next re-derive
    produces a byte-stable file."""
    return "\n".join([
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
        "Append-only, newest-first session-handoff reconciliation (R-BIND-7). "
        "Bootstrapped by the append hook; the librarian re-derive rebuilds the "
        "full projection.",
        "",
        SENT_START,
        "",
        SENT_END,
        "",
    ])


def atomic_write(target, content):
    d = os.path.dirname(target) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="._handoff-chronicle.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


if os.path.isfile(chronicle):
    try:
        with open(chronicle, encoding="utf-8") as fh:
            existing = fh.read()
    except Exception as exc:
        emit({"finding": "handoff-chronicle-append-blocked", "file": chronicle,
              "reason": "read-failed", "error": str(exc), "spoke": spoke,
              "detected_at": today})
        print("handoff-chronicle-append: chronicle unreadable; no write", file=sys.stderr)
        sys.exit(2)
    if SENT_START not in existing or SENT_END not in existing:
        # the file exists but has no sentinel region — do NOT rewrite it (that is
        # the librarian re-derive's role, not the hook's). Block-and-log so the
        # re-derive repairs it; the hook never re-derives.
        emit({"finding": "handoff-chronicle-append-blocked", "file": chronicle,
              "reason": "sentinel-region-absent",
              "detail": "the librarian re-derive must seed the sentinel region; the hook never re-derives",
              "spoke": spoke, "detected_at": today})
        print("handoff-chronicle-append: sentinel region absent; deferring to the "
              "librarian re-derive (no write)", file=sys.stderr)
        sys.exit(2)
    base = existing
else:
    base = bootstrap_file()

# insert the block immediately AFTER the start marker (newest-first), touching
# ONLY the sentinel region. Split on the FIRST occurrence of the start marker.
idx = base.index(SENT_START) + len(SENT_START)
head = base[:idx]
tail = base[idx:]
# normalize a single blank line after the marker, then the new block.
tail = tail.lstrip("\n")
new_content = head + "\n\n" + block + tail
if not new_content.endswith("\n"):
    new_content += "\n"

atomic_write(chronicle, new_content)
print("handoff-chronicle-append: appended 1 block (%s / %s) to %s"
      % (plan_slug, newest["session"], chronicle), file=sys.stderr)
sys.exit(0)
PY

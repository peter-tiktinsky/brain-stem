#!/bin/bash
# library-log-rotate — the librarian (rotation/audit) half of the R-GOV-1a
# composite maintainer for the library global change log _library/log.md.
# R-GOV-1a disjoint-surface contract: the appender HOOK (hooks/library-log-append.sh)
# is the SOLE appender of routine entries; THIS librarian capability owns rotation,
# audit, and any full re-derive — and NEVER appends a routine entry. The two
# surfaces are disjoint by construction (append-tail vs. rotate/rebuild).
# Rotation (R-LIB-8 size_limits {max_lines: 2000, split_strategy: rotate to
# log-archive/<YYYY>.md at threshold} — calibrated to one-liner density, NOT the
# handoff block-entry cap): when log.md exceeds the threshold, the event lines are
# MOVED out of the live log into per-year archives _library/log-archive/<YYYY>.md
# (grouped by each line's ISO-date year), the C-FM-LOG frontmatter is preserved,
# and the live log continues fresh (frontmatter + a rotation-marker line) so the
# appender keeps appending to a small live tail. Each per-year archive is itself a
# C-FM-LOG log artifact (type: log, log-type: library-change) so it stays a
# governed, R-47/R-05-compliant surface.
# Audit: emits a rotation finding (how many lines moved, to which archives) and a
# rotation-not-due finding when invoked under threshold (idempotent no-op).
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written (ONLY when over threshold):
#     - {LIBRARY}/log-archive/<YYYY>.md   the rotated-out event lines for year
#                                          <YYYY> (created or appended; each
#                                          carries C-FM-LOG frontmatter). Atomic.
#     - {LIBRARY}/log.md                   reset to frontmatter + a rotation
#                                          marker; the live tail continues. Atomic.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: governance/frontmatter-rules.json#types.log (the strict-tier log
#     contract every archive + the live log conform to).
#   Pre-write validation:
#     - the library home + log.md must resolve (absent -> block-and-log, exit 0,
#       never crash — nothing to rotate).
#     - under threshold -> rotation-not-due finding, ZERO writes (idempotent).
#     - atomic temp+os.replace on every write.
#   Failure mode: BLOCK-AND-LOG. A malformed log emits a finding and writes
#     nothing. Never write-and-hope.
#   Maintainer-provenance (R-GOV-3, R-GOV-1a): this capability writes ONLY the
#     rotation/archive role surface of the composite. It NEVER appends a routine
#     event line (the hook owns that); it rotates + audits only.
# CLI:
#   library-log-rotate.sh             # rotate when over threshold (default)
#   library-log-rotate.sh --dry-run   # report would-rotate counts; NO writes
#   library-log-rotate.sh --help
# Env overrides (testing):
#   LIBRARY_DIR    library home (default: $PLANS_DIR/_library -> $PLANS_ROOT/_library).
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh).
#   LOG_MAX_LINES  rotation threshold (default 2000 per R-LIB-8 size_limits).
#   FINDINGS_OUTPUT  NDJSON sink (default: stdout).
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

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
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "library-log-rotate: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
LIBRARY="${LIBRARY_DIR:-${PLANS_DIR:-$PLANS_ROOT}/_library}"
case "$LIBRARY" in */) LIBRARY="${LIBRARY%/}" ;; esac

LOG_MD="$LIBRARY/log.md"
LOG_MAX_LINES="${LOG_MAX_LINES:-2000}"

python3 - "$LIBRARY" "$LOG_MD" "$LOG_MAX_LINES" "$DRY_RUN" <<'PY'
import json, os, re, sys, tempfile
from datetime import date, datetime, timezone

library, log_md, max_lines_s, dry_s = sys.argv[1:5]
dry_run = (dry_s == "true")
try:
    max_lines = int(max_lines_s)
except ValueError:
    max_lines = 2000

out = os.environ.get("FINDINGS_OUTPUT", "")
today = date.today().isoformat()
now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
LOG_SUBTYPE = "library-change"

# event-line shape (R-LIB-8): YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>
EVENT_RE = re.compile(r"^(\d{4})-\d{2}-\d{2}T[0-9:]+Z?\s+\[[A-Z]+\]\s+\S+")

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def atomic_write(target, content):
    d = os.path.dirname(target) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="._logrot.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

def log_frontmatter(title, blurb):
    return (
        "---\n"
        "type: log\n"
        "log-type: %s\n"
        "date: %s\n"
        "timestamp: %s\n"
        "tags: [\"#log/%s\"]\n"
        "---\n"
        "\n"
        "# %s\n"
        "\n"
        "%s\n"
        "\n"
    ) % (LOG_SUBTYPE, today, now_iso, LOG_SUBTYPE, title, blurb)

# --- block-and-log: nothing to rotate ---------------------------------------
if not os.path.isfile(log_md):
    emit({"finding": "library-log-rotate-blocked", "file": log_md,
          "reason": "log-absent", "detected_at": today})
    print("library-log-rotate: log.md absent (%s); nothing to rotate" % log_md,
          file=sys.stderr)
    sys.exit(0)

try:
    with open(log_md, encoding="utf-8") as fh:
        text = fh.read()
except OSError as exc:
    emit({"finding": "library-log-rotate-blocked", "file": log_md,
          "reason": "read-failed", "error": str(exc), "detected_at": today})
    sys.exit(0)

total_lines = sum(1 for _ in text.splitlines())

# --- under threshold -> idempotent no-op ------------------------------------
if total_lines <= max_lines:
    emit({"finding": "library-log-rotation-not-due", "file": log_md,
          "lines": total_lines, "max_lines": max_lines, "detected_at": today})
    print("library-log-rotate: %d <= %d lines; rotation not due" % (total_lines, max_lines),
          file=sys.stderr)
    sys.exit(0)

# --- split the live log: frontmatter (kept) vs event lines (rotated out) -----
# Frontmatter is everything up to and including the closing --- fence; the
# preamble prose between the fence and the first event line is kept on the live
# log. Event lines (the ones matching EVENT_RE) are the rotation payload.
lines = text.split("\n")
# locate the frontmatter close fence
fm_end = -1
if lines and lines[0].strip() == "---":
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fm_end = i
            break

event_lines = []
kept_preamble = []
for idx, ln in enumerate(lines):
    if fm_end >= 0 and idx <= fm_end:
        continue  # frontmatter body — handled by reseeding the live log below
    if EVENT_RE.match(ln):
        event_lines.append(ln)
    else:
        # non-event prose (the bootstrap blurb) — keep it on the live log
        if ln.strip():
            kept_preamble.append(ln)

if not event_lines:
    emit({"finding": "library-log-rotation-not-due", "file": log_md,
          "lines": total_lines, "max_lines": max_lines,
          "reason": "over-line-count-but-no-event-lines-to-rotate",
          "detected_at": today})
    print("library-log-rotate: over threshold but no event lines; no-op",
          file=sys.stderr)
    sys.exit(0)

# group event lines by their ISO-date year
by_year = {}
for ln in event_lines:
    m = EVENT_RE.match(ln)
    yr = m.group(1) if m else "unknown"
    by_year.setdefault(yr, []).append(ln)

if dry_run:
    emit({"finding": "library-log-rotation-would-rotate", "file": log_md,
          "lines": total_lines, "max_lines": max_lines,
          "events": len(event_lines),
          "archives": ",".join(sorted("%s.md" % y for y in by_year)),
          "detected_at": today})
    print("library-log-rotate: DRY-RUN would rotate %d events -> %s"
          % (len(event_lines), ", ".join(sorted("%s.md" % y for y in by_year))),
          file=sys.stderr)
    sys.exit(0)

archive_dir = os.path.join(library, "log-archive")
os.makedirs(archive_dir, exist_ok=True)
written_archives = []
for yr in sorted(by_year):
    arc_path = os.path.join(archive_dir, "%s.md" % yr)
    payload = "\n".join(by_year[yr]) + "\n"
    if os.path.isfile(arc_path):
        try:
            with open(arc_path, encoding="utf-8") as fh:
                cur = fh.read()
        except OSError:
            cur = ""
        if cur and not cur.endswith("\n"):
            cur += "\n"
        new_arc = cur + payload
    else:
        blurb = ("Rotated library change-log events for %s (R-LIB-8 split_strategy: "
                 "rotate to log-archive/<YYYY>.md). Append-only.") % yr
        new_arc = log_frontmatter("Library Change Log — %s" % yr, blurb) + payload
    atomic_write(arc_path, new_arc)
    written_archives.append(arc_path)

# --- reset the live log: frontmatter + preamble + a rotation marker ----------
# Reseed a fresh C-FM-LOG frontmatter (the live log continues from empty tail).
live_blurb = ("Global append-only change log for the library (per-article changelogs "
              "are killed). One ISO-timestamped line per promotion / amend / supersede "
              "event: `YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>`. Rotates to "
              "`log-archive/<YYYY>.md` past %d lines." % max_lines)
live = log_frontmatter("Library Change Log", live_blurb)
# an AUDIT marker line records the rotation in the live log (this is the
# librarian's rotation/audit role — NOT a routine append; the ACTION is AUDIT).
marker = "%s [AUDIT] log-archive/ — rotated %d events to %s" % (
    now_iso, len(event_lines), ", ".join(os.path.basename(p) for p in sorted(written_archives)))
live += marker + "\n"
atomic_write(log_md, live)

emit({"finding": "library-log-rotated", "file": log_md,
      "events_rotated": len(event_lines), "from_lines": total_lines,
      "archives": ",".join(sorted(os.path.basename(p) for p in written_archives)),
      "max_lines": max_lines, "detected_at": today})
print("library-log-rotate: rotated %d events -> %s (live log reset)"
      % (len(event_lines), ", ".join(os.path.basename(p) for p in sorted(written_archives))),
      file=sys.stderr)
PY
exit 0

#!/bin/bash
# library-log-append — the SOLE appender of routine entries to the library global
# change log _library/log.md (the C-FM-LOG log-artifact contract). One
# ISO-timestamped line per promotion/amend/supersede event (Flows 3/4):
#
#     YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>
#
# This is the `hook` half of the composite maintainer for log.md:
#   primary = hook (THIS — incremental append-tail; seeds the C-FM-LOG
#             frontmatter at bootstrap; detects the rotation threshold)
#   secondary-role = librarian (library-log-rotate — rotation/audit/rebuild)
# The two surfaces are DISJOINT by construction (append-tail here vs.
# rotate/rebuild in the librarian capability). This hook NEVER rebuilds, audits,
# or rotates the body itself — on a detected over-threshold it DELEGATES the
# rotation write to the librarian capability (or, when that capability is
# unreachable, emits a rotation-due finding and keeps appending). It never owns
# the rotate write.
#
# ACTION enum: INGEST | UPDATE | AUDIT | LINT | PROMOTE | SUPERSEDE.
#   The flow seams emit the promotion subset; AUDIT/LINT are reserved for the
#   librarian audit/lint events that share the log. The enum is ENFORCED here:
#   a bogus ACTION is block-and-logged (no write).
#
# Event -> ACTION mapping (the seam contract):
#   PROMOTE    a new universal article promoted into the library (PROMO-6 half).
#   INGEST     a _raw/ immutable provenance original copied at promotion (CAP-3).
#   UPDATE     an in-place amend (F-RECON-4): updated: bumped, body edited.
#   SUPERSEDE  a supersede edit (F-RECON-3): old article marked superseded_by.
#
# C-FM-LOG frontmatter (seeded ONCE at bootstrap — the file's first append):
#   type: log               reuses the SHIPPED log type (no new type minted).
#   log-type: library-change   a REGISTERED log-subtype value
#                              (governance/log-subtype-registry.json#log_subtypes).
#   date / timestamp        ISO file-creation date + instant (strict-tier log
#                           required fields: [type, log-type, date, timestamp]).
#   tags: ["#log/library-change"]   non-empty, R-47-compliant, R-05-canonical.
#
# R-33 placement advisory: the shipped log type no longer declares an
# expected_path (vault Logs/ retired at G3), so R-33 does not fire for log-type
# files. _library/log.md is suppressed from vault-view via the Obsidian userIgnoreFilters. This
# appender writes directly (os.replace), never through the Edit/PostToolUse
# surface that would re-fire the guard.
#
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written:
#     - {LIBRARY}/log.md   append-only tail (+ a one-time C-FM-LOG frontmatter
#                          block on the bootstrap append). Atomic temp+os.replace.
#   Schema: governance/frontmatter-rules.json#types.log (the strict-tier log
#     contract the bootstrap frontmatter conforms to) + the registered
#     library-change subtype in governance/log-subtype-registry.json#log_subtypes.
#   Pre-write validation:
#     - the library home must resolve (absent -> create it; the log's home is
#       _library/ which the scaffold/promotion already materialized).
#     - the ACTION must be in the enum (bogus -> block-and-log, no write).
#     - the <path> arg must be non-empty (else block-and-log).
#   Failure mode: BLOCK-AND-LOG. A malformed event emits a finding and writes
#     nothing. Never write-and-hope.
#   Maintainer-provenance: this hook writes ONLY the
#     append-tail role surface of the composite. It NEVER rotates, audits, or
#     re-derives the log body (the librarian library-log-rotate capability owns
#     that role); a routine append never rebuilds.
#
# CLI (the flow seam invokes the append form; the others are operational):
#   library-log-append.sh <ACTION> <path> [<note>]   # append one event line
#   library-log-append.sh --help
#
# Env overrides (testing / wiring):
#   LIBRARY_DIR    library home (default: $PLANS_DIR/_library -> $PLANS_ROOT/_library).
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh).
#   LOG_MAX_LINES  rotation threshold (default 2000 per size_limits).
#   ROTATE_CAP     path to the librarian rotation capability (default resolved
#                  live-install-first, then the dev repo).
#   FINDINGS_OUTPUT  NDJSON sink for block-and-log findings (default: stderr-safe stdout).
#
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
  -h|--help) sed -n '2,84p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

ACTION="${1:-}"
LOG_PATH_ARG="${2:-}"
NOTE_ARG="${3:-}"

# --- library home resolution (the sibling capability pattern; never hardcoded) -
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
LIBRARY="${LIBRARY_DIR:-${PLANS_DIR:-$PLANS_ROOT}/_library}"
case "$LIBRARY" in */) LIBRARY="${LIBRARY%/}" ;; esac

LOG_MD="$LIBRARY/log.md"
LOG_MAX_LINES="${LOG_MAX_LINES:-2000}"

# --- the librarian rotation capability (delegated rotate write) ---------------
ROTATE_CAP="${ROTATE_CAP:-}"
if [[ -z "$ROTATE_CAP" ]]; then
  for c in "$CLAUDE_HOME_RES/skills/librarian/capabilities/library-log-rotate.sh" \
           "$_REPO_ROOT/skills/librarian/capabilities/library-log-rotate.sh"; do
    if [[ -f "$c" ]]; then ROTATE_CAP="$c"; break; fi
  done
fi

python3 - "$LIBRARY" "$LOG_MD" "$ACTION" "$LOG_PATH_ARG" "$NOTE_ARG" "$LOG_MAX_LINES" <<'PY'
import json, os, sys, tempfile
from datetime import date, datetime, timezone

library, log_md, action, path_arg, note_arg, max_lines_s = sys.argv[1:7]
try:
    max_lines = int(max_lines_s)
except ValueError:
    max_lines = 2000

out = os.environ.get("FINDINGS_OUTPUT", "")
today = date.today().isoformat()
now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# ACTION enum (EXACT). A bogus ACTION block-and-logs (no write).
ACTION_ENUM = ("INGEST", "UPDATE", "AUDIT", "LINT", "PROMOTE", "SUPERSEDE")
# library-change is the REGISTERED log-subtype value (defined in
# governance/log-subtype-registry.json#log_subtypes); C-FM-LOG requires log-type
# to be a registered subtype value.
LOG_SUBTYPE = "library-change"

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# --- block-and-log: ACTION enum + non-empty path ----------------------------
if action not in ACTION_ENUM:
    emit({"finding": "library-log-append-blocked", "file": log_md,
          "reason": "action-not-in-enum", "action": action or "(empty)",
          "enum": "|".join(ACTION_ENUM), "detected_at": today})
    print("library-log-append: ACTION '%s' not in enum (%s); no write"
          % (action or "(empty)", "|".join(ACTION_ENUM)), file=sys.stderr)
    sys.exit(2)

if not path_arg.strip():
    emit({"finding": "library-log-append-blocked", "file": log_md,
          "reason": "empty-path", "action": action, "detected_at": today})
    print("library-log-append: empty <path> for [%s]; no write" % action, file=sys.stderr)
    sys.exit(2)

os.makedirs(library, exist_ok=True)

# --- C-FM-LOG frontmatter (seeded ONCE at bootstrap) ------------------------
# type: log (shipped type) + log-type: library-change (registered subtype) +
# strict-tier required date/timestamp + non-empty R-47/R-05-compliant tags.
def bootstrap_frontmatter():
    return (
        "---\n"
        "type: log\n"
        "log-type: %s\n"
        "date: %s\n"
        "timestamp: %s\n"
        "tags: [\"#log/%s\"]\n"
        "---\n"
        "\n"
        "# Library Change Log\n"
        "\n"
        "Global append-only change log for the library (per-article changelogs are\n"
        "killed). One ISO-timestamped line per promotion / amend / supersede event:\n"
        "`YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>`. Rotates to\n"
        "`log-archive/<YYYY>.md` past %d lines.\n"
        "\n"
    ) % (LOG_SUBTYPE, today, now_iso, LOG_SUBTYPE, max_lines)

# --- the event line (library-index.sh staleness reader-compatible) ----------
# Reader regex (library-index.sh): ^(\d{4}-\d{2}-\d{2})T[0-9:]+Z?\s+\[[A-Z]+\]\s+(\S+)
# so <path>'s first segment must be the topic. We emit the path verbatim.
note = note_arg.strip()
# normalize newlines out of the note so one event == one physical line.
note = note.replace("\r", " ").replace("\n", " ").strip()
line = "%s [%s] %s" % (now_iso, action, path_arg.strip())
if note:
    line += " — %s" % note   # em dash separator per the event-line format
line += "\n"

def atomic_write(target, content):
    d = os.path.dirname(target) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="._log.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

# --- append-tail (the ONLY write this hook performs) ------------------------
# Survivorship: read the existing body, append the new line, atomic-replace.
# A bootstrap append seeds the frontmatter first.
if os.path.isfile(log_md):
    try:
        with open(log_md, encoding="utf-8") as fh:
            existing = fh.read()
    except OSError as exc:
        emit({"finding": "library-log-append-blocked", "file": log_md,
              "reason": "read-failed", "error": str(exc), "detected_at": today})
        sys.exit(2)
    if not existing.endswith("\n") and existing:
        existing += "\n"
    new_content = existing + line
else:
    new_content = bootstrap_frontmatter() + line

atomic_write(log_md, new_content)

# --- rotation THRESHOLD DETECTION (the hook detects; the librarian rotates) --
# disjoint surfaces: the hook NEVER rotates the body. On over-threshold
# it signals (exit code 10) so the shell wrapper delegates to the librarian
# library-log-rotate capability. When that capability is unreachable, the
# wrapper instead emits a rotation-due finding (the appender keeps appending).
total = sum(1 for _ in new_content.splitlines())
if total > max_lines:
    print("library-log-append: ROTATE-DUE (%d > %d lines)" % (total, max_lines),
          file=sys.stderr)
    sys.exit(10)

sys.exit(0)
PY
RC=$?

# --- delegate rotation to the librarian capability on the ROTATE-DUE signal ---
# The append already happened (exit code 10 means "appended AND over threshold").
# The hook NEVER rotates the body itself: it hands the rotate write to
# the librarian capability. If that capability is unreachable, emit a
# rotation-due finding and keep going — the live log continues to accept appends.
if [[ "$RC" -eq 10 ]]; then
  if [[ -n "$ROTATE_CAP" && -f "$ROTATE_CAP" ]]; then
    LIBRARY_DIR="$LIBRARY" LOG_MAX_LINES="$LOG_MAX_LINES" \
      bash "$ROTATE_CAP" >/dev/null 2>&1 || true
  elif command -v emit_finding >/dev/null 2>&1; then
    emit_finding "library-log-rotation-due" "$LOG_MD" \
      "reason" "log exceeded threshold; rotation capability unreachable" \
      "max_lines" "$LOG_MAX_LINES"
  fi
  exit 0
fi

exit "$RC"
